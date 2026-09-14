-- Repair historical terminal timestamps and publish the class-lifted identity
-- projection used by runtime reconciliation, review APIs, metrics, and the
-- startup repair below.  These views are intentionally read-only: a metrics
-- snapshot must not become a maintenance command.

UPDATE variant_jobs
   SET completed_at = COALESCE(completed_at, updated_at)
 WHERE status IN ('completed', 'failed', 'cancelled')
   AND completed_at IS NULL;

UPDATE variant_actions
   SET completed_at = COALESCE(completed_at, updated_at)
 WHERE status IN ('succeeded', 'permanent_error', 'superseded')
   AND completed_at IS NULL;

-- Discovery runs have a stricter lifecycle CHECK: only a completed run may
-- carry completed_at.  This repairs legacy completed rows without changing
-- the meaning of failed, cancelled, running, or retryable runs.
UPDATE variant_discovery_runs
   SET completed_at = COALESCE(completed_at, updated_at)
 WHERE status = 'completed'
   AND completed_at IS NULL;

-- An active confirmed group is one same-book equivalence class.  A GID that
-- has no active confirmed membership is its own singleton class.
CREATE VIEW variant_identity_active_membership AS
SELECT member.gid,
       member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped
    ON grouped.id = member.group_id
   AND grouped.is_active = 1
 WHERE member.membership_state = 'confirmed';

CREATE VIEW variant_identity_gid_class AS
WITH relevant(gid) AS (
  SELECT gid FROM variant_identity_active_membership
  UNION
  SELECT grouped.source_gid
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id = review.group_id
   WHERE review.review_type = 'candidate_identity'
  UNION
  SELECT candidate_gid
    FROM variant_reviews
   WHERE review_type = 'candidate_identity'
  UNION
  SELECT low_gid FROM gallery_identity_pairs
  UNION
  SELECT high_gid FROM gallery_identity_pairs
)
SELECT relevant.gid,
       COALESCE(active.class_gid, relevant.gid) AS class_gid,
       active.active_group_id,
       COALESCE(active.class_size, 1) AS class_size
  FROM relevant
  LEFT JOIN variant_identity_active_membership AS active
    ON active.gid = relevant.gid;

-- A review is hidden when its live source, candidate, or winner choice has
-- been replaced by official chain metadata.  The audit row remains durable.
CREATE VIEW variant_identity_review_visibility AS
SELECT review.id AS review_id,
       CASE WHEN EXISTS (
              SELECT 1
                FROM variant_groups AS source_group
                JOIN galleries AS source_gallery
                  ON source_gallery.gid = source_group.source_gid
               WHERE source_group.id = review.group_id
                 AND source_gallery.current_gid IS NOT NULL
                 AND source_gallery.current_gid <> source_gallery.gid
            )
             OR (review.candidate_gid IS NOT NULL AND EXISTS (
              SELECT 1
                FROM galleries AS candidate_gallery
               WHERE candidate_gallery.gid = review.candidate_gid
                 AND candidate_gallery.current_gid IS NOT NULL
                 AND candidate_gallery.current_gid <> candidate_gallery.gid
            ))
             OR (review.review_type = 'winner' AND EXISTS (
              SELECT 1
                FROM json_each(review.choices_json) AS choice
                JOIN galleries AS choice_gallery
                  ON choice_gallery.gid = CAST(choice.value AS INTEGER)
               WHERE choice_gallery.current_gid IS NOT NULL
                 AND choice_gallery.current_gid <> choice_gallery.gid
            ))
            THEN 0 ELSE 1 END AS is_visible
  FROM variant_reviews AS review;

-- Different-book decisions are lifted from raw GIDs to unordered active
-- equivalence-class pairs.  Same-book decisions are represented by the class
-- itself and therefore do not need a separate edge here.
CREATE VIEW variant_identity_class_pair AS
SELECT MIN(low_class.class_gid, high_class.class_gid) AS low_class_gid,
       MAX(low_class.class_gid, high_class.class_gid) AS high_class_gid,
       'different_book' AS decision,
       MIN(pair.current_review_id) AS supporting_review_id
  FROM gallery_identity_pairs AS pair
  JOIN variant_reviews AS review ON review.id = pair.current_review_id
  JOIN variant_identity_gid_class AS low_class ON low_class.gid = pair.low_gid
  JOIN variant_identity_gid_class AS high_class ON high_class.gid = pair.high_gid
 WHERE review.status = 'resolved'
   AND review.decision = 'different_book'
   AND low_class.class_gid <> high_class.class_gid
 GROUP BY 1, 2;

-- Keep all pending candidate rows in this view, including rows currently
-- superseded by a prior projection.  Reclassification after an ungroup can
-- make such evidence the new representative.  Rank visible rows first so a
-- replaced audit row cannot suppress a live candidate.
CREATE VIEW variant_identity_pending_candidate AS
WITH classified AS (
  SELECT review.id AS review_id,
         review.group_id,
         grouped.source_gid,
         review.candidate_gid,
         MIN(source_class.class_gid, candidate_class.class_gid) AS low_class_gid,
         MAX(source_class.class_gid, candidate_class.class_gid) AS high_class_gid,
         source_class.class_size AS source_class_size,
         candidate_class.class_size AS candidate_class_size,
         CASE WHEN owner.is_active = 1 THEN 1 ELSE 0 END AS owner_is_active,
         visibility.is_visible,
         CASE
           WHEN source_class.class_gid = candidate_class.class_gid
             THEN 'same_book'
           WHEN class_pair.decision = 'different_book'
             THEN 'different_book'
           ELSE NULL
         END AS implied_decision,
         CASE
           WHEN source_class.class_gid = candidate_class.class_gid THEN (
             SELECT MIN(same_pair.current_review_id)
               FROM gallery_identity_pairs AS same_pair
               JOIN variant_reviews AS support
                 ON support.id = same_pair.current_review_id
               JOIN variant_identity_gid_class AS support_low
                 ON support_low.gid = same_pair.low_gid
               JOIN variant_identity_gid_class AS support_high
                 ON support_high.gid = same_pair.high_gid
              WHERE support.decision = 'same_book'
                AND support_low.class_gid = source_class.class_gid
                AND support_high.class_gid = source_class.class_gid
           )
           ELSE class_pair.supporting_review_id
         END AS supporting_review_id
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id = review.group_id
    JOIN variant_groups AS owner ON owner.id = review.group_id
    JOIN variant_identity_gid_class AS source_class
      ON source_class.gid = grouped.source_gid
    JOIN variant_identity_gid_class AS candidate_class
      ON candidate_class.gid = review.candidate_gid
    JOIN variant_identity_review_visibility AS visibility
      ON visibility.review_id = review.id
    LEFT JOIN variant_identity_class_pair AS class_pair
      ON class_pair.low_class_gid = MIN(source_class.class_gid, candidate_class.class_gid)
     AND class_pair.high_class_gid = MAX(source_class.class_gid, candidate_class.class_gid)
   WHERE review.review_type = 'candidate_identity'
     AND review.status = 'pending'
)
SELECT classified.*,
       CASE WHEN classified.implied_decision IS NULL
                  AND classified.is_visible = 1 THEN
         ROW_NUMBER() OVER (
           PARTITION BY classified.low_class_gid, classified.high_class_gid
           ORDER BY classified.is_visible DESC,
                    classified.owner_is_active DESC,
                    classified.review_id
         )
       END AS rank
  FROM classified;

-- One actionable representative per unknown unordered class pair.  The
-- superseded_at column is deliberately not used as an input: it is a durable
-- materialization of this projection and may need to be cleared after an
-- identity class changes.
CREATE VIEW variant_identity_actionable_review AS
SELECT review_id,
       group_id,
       source_gid,
       candidate_gid,
       low_class_gid,
       high_class_gid,
       source_class_size,
       candidate_class_size,
       owner_is_active
  FROM variant_identity_pending_candidate
 WHERE implied_decision IS NULL
   AND is_visible = 1
   AND rank = 1;

-- Candidate review ownership and class blocking are separate relationships.
-- A durable review owned by an inactive historical group still blocks each
-- active group containing one endpoint, while the owner retains its own
-- candidate_pending audit state until that representative is resolved.
CREATE VIEW variant_identity_group_review_state AS
WITH candidate_blocked(group_id) AS (
  SELECT actionable.group_id
    FROM variant_identity_actionable_review AS actionable
  UNION
  SELECT member_class.active_group_id
    FROM variant_identity_actionable_review AS actionable
    JOIN variant_identity_gid_class AS member_class
      ON member_class.class_gid IN (
           actionable.low_class_gid, actionable.high_class_gid)
   WHERE member_class.active_group_id IS NOT NULL
)
SELECT grouped.id AS group_id,
       CASE
         WHEN EXISTS (
           SELECT 1 FROM candidate_blocked
            WHERE candidate_blocked.group_id = grouped.id
         ) THEN 'candidate_pending'
         WHEN EXISTS (
           SELECT 1
             FROM variant_reviews AS winner
             JOIN variant_identity_review_visibility AS visibility
               ON visibility.review_id = winner.id
            WHERE winner.group_id = grouped.id
              AND winner.review_type = 'winner'
              AND winner.status = 'pending'
              AND winner.superseded_at IS NULL
              AND visibility.is_visible = 1
         ) THEN 'winner_pending'
         ELSE 'none'
       END AS review_state
  FROM variant_groups AS grouped;

-- Repair the persisted projection for all groups, including inactive owners.
UPDATE variant_groups AS grouped
   SET review_state = (
         SELECT projected.review_state
           FROM variant_identity_group_review_state AS projected
          WHERE projected.group_id = grouped.id
       ),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE review_state IS NOT (
         SELECT projected.review_state
           FROM variant_identity_group_review_state AS projected
          WHERE projected.group_id = grouped.id
       );
