-- Keep current same-book identity independent from operational action intent.
-- is_active remains the desired-operation/retention lifecycle; identity_active
-- is the durable owner flag used by identity, discovery, review, and reads.
ALTER TABLE variant_groups ADD COLUMN identity_active INTEGER NOT NULL DEFAULT 1
    CHECK (identity_active IN (0, 1));

-- The old triggers made operational activity the identity authority. Historical
-- groups can legitimately overlap there after a merge or rating downgrade, so
-- remove those guards before consolidating membership below. The replacement
-- identity triggers are installed after the backfill.
DROP TRIGGER IF EXISTS gallery_variants_one_active_group_insert;
DROP TRIGGER IF EXISTS gallery_variants_one_active_group_update;
DROP TRIGGER IF EXISTS variant_groups_no_conflict_on_activation;

-- Historical inactive groups can overlap after a merge or a low-rating
-- downgrade. Choose the existing operational group when one exists; otherwise
-- retain the lowest group id as the deterministic audit owner. Copy confirmed
-- membership to that owner without deleting the historical rows.
CREATE TEMP TABLE identity_migration_owner(
    group_id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL
);
WITH RECURSIVE
group_member(group_id, gid) AS (
    SELECT group_id, gid
      FROM gallery_variants
     WHERE membership_state = 'confirmed'
),
edge(group_id, other_group_id) AS (
    SELECT left_member.group_id, right_member.group_id
      FROM group_member AS left_member
      JOIN group_member AS right_member
        ON right_member.gid = left_member.gid
       AND right_member.group_id <> left_member.group_id
),
reachable(root_id, group_id) AS (
    SELECT id, id
      FROM variant_groups
     WHERE EXISTS (SELECT 1 FROM group_member WHERE group_id = id)
    UNION
    SELECT reachable.root_id, edge.other_group_id
      FROM reachable
      JOIN edge ON edge.group_id = reachable.group_id
),
component_owner(root_id, owner_id) AS (
    SELECT reachable.root_id,
           COALESCE(
             MIN(CASE WHEN grouped.is_active = 1 THEN reachable.group_id END),
             MIN(reachable.group_id)
           )
      FROM reachable
      JOIN variant_groups AS grouped ON grouped.id = reachable.group_id
     GROUP BY reachable.root_id
)
INSERT INTO identity_migration_owner(group_id, owner_id)
SELECT root_id, owner_id FROM component_owner;

INSERT OR IGNORE INTO gallery_variants(
    group_id, gid, membership_state, decision_source, match_score,
    evidence_json, metadata_snapshot_json, variant_score,
    variant_state, decided_at, created_at, updated_at)
SELECT owner.owner_id, member.gid, member.membership_state,
       member.decision_source, member.match_score, member.evidence_json,
       member.metadata_snapshot_json, member.variant_score,
       member.variant_state, member.decided_at,
       member.created_at, member.updated_at
  FROM identity_migration_owner AS owner
  JOIN gallery_variants AS member ON member.group_id = owner.group_id
 WHERE member.membership_state = 'confirmed'
   AND owner.owner_id <> owner.group_id;

UPDATE variant_groups
   SET identity_active = CASE
     WHEN id IN (SELECT owner_id FROM identity_migration_owner) THEN 1
     WHEN EXISTS (SELECT 1 FROM gallery_variants AS member
                   WHERE member.group_id = variant_groups.id
                     AND member.membership_state = 'confirmed') THEN 0
     ELSE is_active
   END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

-- Only identity owners may receive confirmed members.
CREATE TRIGGER gallery_variants_one_identity_group_insert
BEFORE INSERT ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups
              WHERE id = NEW.group_id AND identity_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.identity_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another identity group');
END;

CREATE TRIGGER gallery_variants_one_identity_group_update
BEFORE UPDATE OF group_id, gid, membership_state ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups
              WHERE id = NEW.group_id AND identity_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.identity_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another identity group');
END;

CREATE TRIGGER variant_groups_no_identity_conflict_on_activation
BEFORE UPDATE OF identity_active ON variant_groups
WHEN OLD.identity_active = 0 AND NEW.identity_active = 1
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN gallery_variants AS other ON other.gid = member.gid
       JOIN variant_groups AS other_group ON other_group.id = other.group_id
      WHERE member.group_id = NEW.id
        AND member.membership_state = 'confirmed'
        AND other.membership_state = 'confirmed'
        AND other.group_id <> NEW.id
        AND other_group.identity_active = 1
 )
BEGIN
    SELECT RAISE(ABORT, 'identity group has a member confirmed in another identity group');
END;

CREATE INDEX idx_variant_groups_identity_active
ON variant_groups(identity_active, id);
CREATE INDEX idx_variant_groups_identity_stale
ON variant_groups(identity_active, next_discovery_at, id)
WHERE identity_active = 1;

-- Winner selection and replacement work are no longer current for ratings
-- below 11. Keep every row as audit history and make only the durable current
-- work non-actionable.
UPDATE variant_reviews
   SET superseded_at = COALESCE(superseded_at,
                                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       evidence_json = json_set(evidence_json,
         '$.superseded_reason', 'identity_authority_rating_policy')
 WHERE review_type = 'winner'
   AND status = 'pending'
   AND superseded_at IS NULL
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_reviews.group_id
                  AND grouped.desired_rating < 11);

UPDATE variant_actions
   SET status = 'superseded',
       lease_owner = NULL, lease_expires_at = NULL, lease_job_id = NULL,
       completed_at = COALESCE(completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE action_type = 'hath_request'
   AND status <> 'superseded'
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_actions.group_id
                  AND grouped.desired_rating < 11);

UPDATE variant_jobs
   SET status = 'cancelled',
       completed_at = COALESCE(completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       last_error = 'winner evaluation is only current for rating 11'
 WHERE job_type = 'evaluate'
   AND status IN ('queued', 'leased')
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_jobs.group_id
                  AND grouped.desired_rating < 11);

-- Rebuild the identity views against the new authority. The view names stay
-- stable so metrics, review APIs, and transaction-local projections retain one
-- documented read contract.
DROP VIEW IF EXISTS variant_identity_group_review_state;
DROP VIEW IF EXISTS variant_identity_actionable_review;
DROP VIEW IF EXISTS variant_identity_pending_candidate;
DROP VIEW IF EXISTS variant_identity_class_pair;
DROP VIEW IF EXISTS variant_identity_gid_class;
DROP VIEW IF EXISTS variant_identity_active_membership;
DROP VIEW IF EXISTS variant_identity_review_visibility;

CREATE VIEW variant_identity_active_membership AS
SELECT member.gid,
       member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped
    ON grouped.id = member.group_id
   AND grouped.identity_active = 1
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
  SELECT candidate_gid FROM variant_reviews
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

CREATE VIEW variant_identity_review_visibility AS
SELECT review.id AS review_id,
       CASE WHEN EXISTS (
              SELECT 1
                FROM variant_groups AS source_group
                JOIN galleries AS source_gallery ON source_gallery.gid = source_group.source_gid
               WHERE source_group.id = review.group_id
                 AND source_gallery.current_gid IS NOT NULL
                 AND source_gallery.current_gid <> source_gallery.gid
            )
             OR (review.candidate_gid IS NOT NULL AND EXISTS (
              SELECT 1 FROM galleries AS candidate_gallery
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
            )) THEN 0 ELSE 1 END AS is_visible
  FROM variant_reviews AS review;

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

CREATE VIEW variant_identity_pending_candidate AS
WITH classified AS (
  SELECT review.id AS review_id, review.group_id, grouped.source_gid,
         review.candidate_gid,
         MIN(source_class.class_gid, candidate_class.class_gid) AS low_class_gid,
         MAX(source_class.class_gid, candidate_class.class_gid) AS high_class_gid,
         source_class.class_size AS source_class_size,
         candidate_class.class_size AS candidate_class_size,
         CASE WHEN owner.identity_active = 1 THEN 1 ELSE 0 END AS owner_is_active,
         visibility.is_visible,
         CASE
           WHEN source_class.class_gid = candidate_class.class_gid THEN 'same_book'
           WHEN class_pair.decision = 'different_book' THEN 'different_book'
           ELSE NULL
         END AS implied_decision,
         CASE
           WHEN source_class.class_gid = candidate_class.class_gid THEN (
             SELECT MIN(same_pair.current_review_id)
               FROM gallery_identity_pairs AS same_pair
               JOIN variant_reviews AS support ON support.id = same_pair.current_review_id
               JOIN variant_identity_gid_class AS support_low ON support_low.gid = same_pair.low_gid
               JOIN variant_identity_gid_class AS support_high ON support_high.gid = same_pair.high_gid
              WHERE support.decision = 'same_book'
                AND support_low.class_gid = source_class.class_gid
                AND support_high.class_gid = source_class.class_gid
           )
           ELSE class_pair.supporting_review_id
         END AS supporting_review_id
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id = review.group_id
    JOIN variant_groups AS owner ON owner.id = review.group_id
    JOIN variant_identity_gid_class AS source_class ON source_class.gid = grouped.source_gid
    JOIN variant_identity_gid_class AS candidate_class ON candidate_class.gid = review.candidate_gid
    JOIN variant_identity_review_visibility AS visibility ON visibility.review_id = review.id
    LEFT JOIN variant_identity_class_pair AS class_pair
      ON class_pair.low_class_gid = MIN(source_class.class_gid, candidate_class.class_gid)
     AND class_pair.high_class_gid = MAX(source_class.class_gid, candidate_class.class_gid)
   WHERE review.review_type = 'candidate_identity'
     AND review.status = 'pending'
)
SELECT classified.*,
       CASE WHEN classified.implied_decision IS NULL AND classified.is_visible = 1 THEN
         ROW_NUMBER() OVER (
           PARTITION BY classified.low_class_gid, classified.high_class_gid
           ORDER BY classified.is_visible DESC,
                    classified.owner_is_active DESC, classified.review_id)
       END AS rank
  FROM classified;

CREATE VIEW variant_identity_actionable_review AS
SELECT review_id, group_id, source_gid, candidate_gid,
       low_class_gid, high_class_gid, source_class_size,
       candidate_class_size, owner_is_active
  FROM variant_identity_pending_candidate
 WHERE implied_decision IS NULL AND is_visible = 1 AND rank = 1;

CREATE VIEW variant_identity_group_review_state AS
WITH candidate_blocked(group_id) AS (
  SELECT actionable.group_id FROM variant_identity_actionable_review AS actionable
  UNION
  SELECT member_class.active_group_id
    FROM variant_identity_actionable_review AS actionable
    JOIN variant_identity_gid_class AS member_class
      ON member_class.class_gid IN (actionable.low_class_gid, actionable.high_class_gid)
   WHERE member_class.active_group_id IS NOT NULL
)
SELECT grouped.id AS group_id,
       CASE
         WHEN EXISTS (SELECT 1 FROM candidate_blocked
                       WHERE candidate_blocked.group_id = grouped.id)
           THEN 'candidate_pending'
         WHEN EXISTS (
           SELECT 1 FROM variant_reviews AS winner
           JOIN variant_identity_review_visibility AS visibility ON visibility.review_id = winner.id
          WHERE winner.group_id = grouped.id
            AND winner.review_type = 'winner'
            AND winner.status = 'pending'
            AND winner.superseded_at IS NULL
            AND grouped.desired_rating = 11
            AND visibility.is_visible = 1
         ) THEN 'winner_pending'
         ELSE 'none'
       END AS review_state
  FROM variant_groups AS grouped;

UPDATE variant_groups AS grouped
   SET review_state = (SELECT projected.review_state
                         FROM variant_identity_group_review_state AS projected
                        WHERE projected.group_id = grouped.id),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE review_state IS NOT (SELECT projected.review_state
                              FROM variant_identity_group_review_state AS projected
                             WHERE projected.group_id = grouped.id);

-- Requeue only identity discovery for rated owners. A downloaded but unrated
-- gallery remains outside discovery until feedback establishes intent.
UPDATE variant_jobs
   SET status = 'cancelled',
       completed_at = COALESCE(completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       last_error = 'identity authority migration superseded non-owner work'
 WHERE job_type = 'discover'
   AND status = 'queued'
   AND group_id IN (SELECT id FROM variant_groups WHERE identity_active = 0);

INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
SELECT 'discover', grouped.id, grouped.source_gid, 1000, 'queued'
  FROM variant_groups AS grouped
  JOIN galleries AS gallery ON gallery.gid = grouped.source_gid
 WHERE grouped.identity_active = 1
   AND (COALESCE(gallery.feedbacked_at, '') <> ''
        OR COALESCE(gallery.self_rating, 0) BETWEEN 1 AND 11)
   AND NOT EXISTS (
     SELECT 1 FROM variant_jobs AS job
      WHERE job.group_id = grouped.id
        AND job.job_type = 'discover'
        AND job.status IN ('queued', 'leased')
   );
