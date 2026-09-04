#!/usr/bin/env bash

# Durable primitives for the `yomiko variants` command family. The caller is
# expected to source common.sh and db.sh first.

VARIANTS_WORK_LOCK_PATH="/tmp/yomiko-variants.lockfile"
VARIANTS_EXPLICIT_FEEDBACK_PRIORITY=1000
# Returned by variants_downgrade_feedback when the GID has no confirmed group.
# Callers must then preserve the existing single-gallery feedback path.
VARIANTS_NOT_GROUPED_STATUS=3
# Returned when a review was resolved concurrently or no longer describes the
# current candidate/evaluation state. CGI maps this stable status to HTTP 409.
VARIANTS_REVIEW_STALE_STATUS=3
# Returned when a requested identity decision would contradict the monotonic
# same-book equivalence classes. CGI maps this stable status to HTTP 409.
VARIANTS_IDENTITY_CONFLICT_STATUS=4

variants_validate_gid() {
  local gid="$1"
  [[ "${gid}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Invalid GID '${gid}'. Must be a positive integer."
    return 1
  }
}

variants_validate_positive_integer() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Invalid ${label} '${value}'. Must be a positive integer."
    return 1
  }
}

# Rebuild the transaction-local identity-class projection and make the stored
# candidate-review queue agree with it. Callers must already hold a
# BEGIN IMMEDIATE transaction. They may populate identity_reconcile_extra_gid
# before invoking this block when a transaction introduces endpoints that are
# not yet referenced by a review or pair (discovery publication does this).
variants_identity_reconcile_sql() {
  cat <<'SQL'
DROP TABLE IF EXISTS temp.identity_actionable_review;
DROP TABLE IF EXISTS temp.identity_pending_candidate;
DROP TABLE IF EXISTS temp.identity_class_pair;
DROP TABLE IF EXISTS temp.identity_affected_group;
DROP TABLE IF EXISTS temp.identity_evaluation_due_group;
DROP TABLE IF EXISTS temp.identity_gid_class;
DROP TABLE IF EXISTS temp.identity_active_membership;
DROP TABLE IF EXISTS temp.identity_relevant_gid;
DROP TABLE IF EXISTS temp.identity_invariant_guard;
CREATE TEMP TABLE IF NOT EXISTS identity_reconcile_extra_gid(
  gid INTEGER PRIMARY KEY
);

CREATE TEMP TABLE identity_active_membership AS
SELECT member.gid, member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped
    ON grouped.id=member.group_id AND grouped.is_active=1
 WHERE member.membership_state='confirmed';

CREATE TEMP TABLE identity_relevant_gid(gid INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT gid FROM identity_active_membership;
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT grouped.source_gid
  FROM variant_reviews AS review
  JOIN variant_groups AS grouped ON grouped.id=review.group_id
 WHERE review.review_type='candidate_identity';
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT candidate_gid FROM variant_reviews
 WHERE review_type='candidate_identity';
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT low_gid FROM gallery_identity_pairs;
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT high_gid FROM gallery_identity_pairs;
INSERT OR IGNORE INTO identity_relevant_gid(gid)
SELECT gid FROM identity_reconcile_extra_gid;

CREATE TEMP TABLE identity_gid_class(
  gid INTEGER PRIMARY KEY,
  class_gid INTEGER NOT NULL,
  active_group_id INTEGER,
  class_size INTEGER NOT NULL
);
INSERT INTO identity_gid_class(gid,class_gid,active_group_id,class_size)
SELECT relevant.gid,
       COALESCE(active.class_gid,relevant.gid),
       active.active_group_id,
       COALESCE(active.class_size,1)
  FROM identity_relevant_gid AS relevant
  LEFT JOIN identity_active_membership AS active ON active.gid=relevant.gid;

CREATE TEMP TABLE identity_invariant_guard(
  conflict_count INTEGER NOT NULL CHECK(conflict_count=0)
);
INSERT INTO identity_invariant_guard(conflict_count)
SELECT
  (SELECT COUNT(*) FROM (
     SELECT gid FROM identity_active_membership GROUP BY gid HAVING COUNT(*)>1
   ))
  + (SELECT COUNT(*) FROM gallery_identity_pairs WHERE low_gid=high_gid)
  + (SELECT COUNT(*)
       FROM variant_reviews AS review
       JOIN variant_groups AS grouped ON grouped.id=review.group_id
      WHERE review.review_type='candidate_identity'
        AND grouped.source_gid=review.candidate_gid)
  + (SELECT COUNT(*)
       FROM gallery_identity_pairs AS pair
       JOIN variant_reviews AS review ON review.id=pair.current_review_id
       JOIN identity_gid_class AS low_class ON low_class.gid=pair.low_gid
       JOIN identity_gid_class AS high_class ON high_class.gid=pair.high_gid
      WHERE (review.decision='different_book'
             AND low_class.class_gid=high_class.class_gid)
         OR (review.decision='same_book'
             AND low_class.class_gid<>high_class.class_gid))
  + (SELECT COUNT(*) FROM (
       SELECT MIN(low_class.class_gid,high_class.class_gid) AS low_class_gid,
              MAX(low_class.class_gid,high_class.class_gid) AS high_class_gid
         FROM gallery_identity_pairs AS pair
         JOIN variant_reviews AS review ON review.id=pair.current_review_id
         JOIN identity_gid_class AS low_class ON low_class.gid=pair.low_gid
         JOIN identity_gid_class AS high_class ON high_class.gid=pair.high_gid
        WHERE low_class.class_gid<>high_class.class_gid
        GROUP BY 1,2
       HAVING COUNT(DISTINCT review.decision)>1
     ));

CREATE TEMP TABLE identity_class_pair(
  low_class_gid INTEGER NOT NULL,
  high_class_gid INTEGER NOT NULL,
  decision TEXT NOT NULL,
  supporting_review_id INTEGER NOT NULL,
  PRIMARY KEY(low_class_gid,high_class_gid)
);
INSERT INTO identity_class_pair(
  low_class_gid,high_class_gid,decision,supporting_review_id
)
SELECT MIN(low_class.class_gid,high_class.class_gid),
       MAX(low_class.class_gid,high_class.class_gid),
       'different_book', MIN(pair.current_review_id)
  FROM gallery_identity_pairs AS pair
  JOIN variant_reviews AS review ON review.id=pair.current_review_id
  JOIN identity_gid_class AS low_class ON low_class.gid=pair.low_gid
  JOIN identity_gid_class AS high_class ON high_class.gid=pair.high_gid
 WHERE review.status='resolved' AND review.decision='different_book'
   AND low_class.class_gid<>high_class.class_gid
 GROUP BY 1,2;

CREATE TEMP TABLE identity_pending_candidate AS
SELECT classified.*,
       CASE WHEN classified.implied_decision IS NULL THEN
         ROW_NUMBER() OVER (
           PARTITION BY classified.low_class_gid,classified.high_class_gid
           ORDER BY classified.owner_is_active DESC,classified.review_id
         )
       END AS rank
  FROM (
    SELECT review.id AS review_id, review.group_id,
           grouped.source_gid, review.candidate_gid,
           MIN(source_class.class_gid,candidate_class.class_gid) AS low_class_gid,
           MAX(source_class.class_gid,candidate_class.class_gid) AS high_class_gid,
           source_class.class_size AS source_class_size,
           candidate_class.class_size AS candidate_class_size,
           CASE WHEN owner.is_active=1 THEN 1 ELSE 0 END AS owner_is_active,
           CASE
             WHEN source_class.class_gid=candidate_class.class_gid
               THEN 'same_book'
             WHEN class_pair.decision='different_book'
               THEN 'different_book'
             ELSE NULL
           END AS implied_decision,
           CASE
             WHEN source_class.class_gid=candidate_class.class_gid THEN (
               SELECT MIN(pair.current_review_id)
                 FROM gallery_identity_pairs AS pair
                 JOIN variant_reviews AS support ON support.id=pair.current_review_id
                 JOIN identity_gid_class AS support_low ON support_low.gid=pair.low_gid
                 JOIN identity_gid_class AS support_high ON support_high.gid=pair.high_gid
                WHERE support.decision='same_book'
                  AND support_low.class_gid=source_class.class_gid
                  AND support_high.class_gid=source_class.class_gid
             )
             ELSE class_pair.supporting_review_id
           END AS supporting_review_id
      FROM variant_reviews AS review
      JOIN variant_groups AS grouped ON grouped.id=review.group_id
      JOIN variant_groups AS owner ON owner.id=review.group_id
      JOIN identity_gid_class AS source_class ON source_class.gid=grouped.source_gid
      JOIN identity_gid_class AS candidate_class ON candidate_class.gid=review.candidate_gid
      LEFT JOIN identity_class_pair AS class_pair
        ON class_pair.low_class_gid=MIN(source_class.class_gid,candidate_class.class_gid)
       AND class_pair.high_class_gid=MAX(source_class.class_gid,candidate_class.class_gid)
     WHERE review.review_type='candidate_identity' AND review.status='pending'
  ) AS classified;

CREATE TEMP TABLE identity_actionable_review(
  review_id INTEGER PRIMARY KEY,
  low_class_gid INTEGER NOT NULL,
  high_class_gid INTEGER NOT NULL
);
INSERT INTO identity_actionable_review(review_id,low_class_gid,high_class_gid)
SELECT review_id,low_class_gid,high_class_gid
  FROM identity_pending_candidate
 WHERE implied_decision IS NULL AND rank=1;

CREATE TEMP TABLE identity_affected_group(
  group_id INTEGER PRIMARY KEY,
  prior_review_state TEXT NOT NULL
);
INSERT OR IGNORE INTO identity_affected_group(group_id,prior_review_state)
SELECT DISTINCT classes.active_group_id,grouped.review_state
  FROM identity_pending_candidate AS pending
  JOIN identity_gid_class AS classes
    ON classes.class_gid IN (pending.low_class_gid,pending.high_class_gid)
  JOIN variant_groups AS grouped ON grouped.id=classes.active_group_id
 WHERE classes.active_group_id IS NOT NULL;

UPDATE variant_reviews AS review
   SET superseded_at=COALESCE(review.superseded_at,
                             strftime('%Y-%m-%dT%H:%M:%SZ','now')),
       evidence_json=json_set(
         review.evidence_json,'$.identity_projection',json(
           (SELECT json_object(
             'reason',CASE
               WHEN pending.implied_decision='same_book' THEN 'same_class'
               WHEN pending.implied_decision='different_book' THEN 'known_different_book'
               ELSE 'duplicate_class_pair' END,
             'implied_decision',pending.implied_decision,
             'supporting_review_id',pending.supporting_review_id,
             'representative_review_id',CASE
               WHEN pending.implied_decision IS NULL THEN (
                 SELECT actionable.review_id
                   FROM identity_actionable_review AS actionable
                  WHERE actionable.low_class_gid=pending.low_class_gid
                    AND actionable.high_class_gid=pending.high_class_gid
               ) ELSE NULL END
           ) FROM identity_pending_candidate AS pending
              WHERE pending.review_id=review.id)))
 WHERE review.id IN (
   SELECT review_id FROM identity_pending_candidate
    WHERE implied_decision IS NOT NULL OR rank>1
 )
   AND (
     review.superseded_at IS NULL
     OR json_extract(review.evidence_json,'$.identity_projection') IS NOT json(
       (SELECT json_object(
         'reason',CASE
           WHEN pending.implied_decision='same_book' THEN 'same_class'
           WHEN pending.implied_decision='different_book' THEN 'known_different_book'
           ELSE 'duplicate_class_pair' END,
         'implied_decision',pending.implied_decision,
         'supporting_review_id',pending.supporting_review_id,
         'representative_review_id',CASE
           WHEN pending.implied_decision IS NULL THEN (
             SELECT actionable.review_id
               FROM identity_actionable_review AS actionable
              WHERE actionable.low_class_gid=pending.low_class_gid
                AND actionable.high_class_gid=pending.high_class_gid
           ) ELSE NULL END
       ) FROM identity_pending_candidate AS pending
          WHERE pending.review_id=review.id))
   );

UPDATE variant_reviews
   SET superseded_at=NULL,
       evidence_json=json_remove(evidence_json,'$.identity_projection')
 WHERE id IN (SELECT review_id FROM identity_actionable_review)
   AND (superseded_at IS NOT NULL
        OR json_type(evidence_json,'$.identity_projection') IS NOT NULL);

UPDATE variant_groups AS grouped
   SET review_state=CASE
         WHEN EXISTS (
           SELECT 1
             FROM identity_actionable_review AS actionable
             JOIN identity_gid_class AS member_class
               ON member_class.class_gid IN (
                    actionable.low_class_gid,actionable.high_class_gid)
            WHERE member_class.active_group_id=grouped.id
         ) THEN 'candidate_pending'
         WHEN EXISTS (
           SELECT 1 FROM variant_reviews AS winner
            WHERE winner.group_id=grouped.id
              AND winner.review_type='winner' AND winner.status='pending'
              AND winner.superseded_at IS NULL
         ) THEN 'winner_pending'
         ELSE 'none' END,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE grouped.id IN (SELECT group_id FROM identity_affected_group)
   AND grouped.review_state<>CASE
         WHEN EXISTS (
           SELECT 1
             FROM identity_actionable_review AS actionable
             JOIN identity_gid_class AS member_class
               ON member_class.class_gid IN (
                    actionable.low_class_gid,actionable.high_class_gid)
            WHERE member_class.active_group_id=grouped.id
         ) THEN 'candidate_pending'
         WHEN EXISTS (
           SELECT 1 FROM variant_reviews AS winner
            WHERE winner.group_id=grouped.id
              AND winner.review_type='winner' AND winner.status='pending'
              AND winner.superseded_at IS NULL
         ) THEN 'winner_pending'
         ELSE 'none' END;

-- Only an actual candidate-block transition needs a fresh evaluation.  The
-- pending projection intentionally includes superseded reviews so an
-- ungroup can reopen them, but stable superseded evidence must not keep
-- scheduling the same groups forever.
CREATE TEMP TABLE identity_evaluation_due_group(
  group_id INTEGER PRIMARY KEY
);
INSERT INTO identity_evaluation_due_group(group_id)
SELECT affected.group_id
  FROM identity_affected_group AS affected
  JOIN variant_groups AS grouped ON grouped.id=affected.group_id
 WHERE affected.prior_review_state='candidate_pending'
   AND grouped.is_active=1
   AND grouped.review_state='none';

UPDATE variant_jobs
   SET priority=MAX(priority,1000),
       available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE job_type='evaluate' AND status='queued'
   AND (priority<1000
        OR available_at>strftime('%Y-%m-%dT%H:%M:%SZ','now'))
   AND group_id IN (SELECT group_id FROM identity_evaluation_due_group);
INSERT OR IGNORE INTO variant_jobs(job_type,group_id,source_gid,priority,status)
SELECT 'evaluate',due.group_id,grouped.source_gid,1000,'queued'
  FROM identity_evaluation_due_group AS due
  JOIN variant_groups AS grouped ON grouped.id=due.group_id;
SQL
}

# Persist feedback, create or reactivate its group, seed the source as a
# confirmed member, and coalesce discovery plus the source rating action in one
# transaction. The group id is the only stdout emitted by this primitive.
variants_enqueue_feedback() {
  local gid="$1"
  local rating="$2"
  local group_id

  variants_validate_gid "${gid}" || return 1
  if [[ ! "${rating}" =~ ^(8|9|10|11)$ ]]; then
    log_err "Invalid variant feedback rating '${rating}'. Must be 8 through 11."
    return 1
  fi

  # The temporary context table keeps group selection and all dependent writes
  # in one IMMEDIATE transaction and one SQLite connection.
  group_id="$(db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :rating ${rating}" \
    ".parameter set :priority ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_enqueue_context (
       singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
       group_id INTEGER NOT NULL
     );
     INSERT INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, grouped.id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id = member.group_id
        WHERE member.gid = :gid
          AND member.membership_state = 'confirmed'
        ORDER BY grouped.is_active DESC, grouped.id
        LIMIT 1;
     INSERT OR IGNORE INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, id FROM variant_groups
        WHERE source_gid = :gid
        ORDER BY is_active DESC, id
        LIMIT 1;
     INSERT INTO variant_groups(source_gid, desired_rating)
       SELECT gallery.gid, :rating FROM galleries AS gallery
        WHERE gallery.gid = :gid
          AND NOT EXISTS (SELECT 1 FROM variant_enqueue_context);
     INSERT OR IGNORE INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, id FROM variant_groups
        WHERE source_gid = :gid
        ORDER BY id DESC LIMIT 1;
     UPDATE galleries
        SET self_rating = :rating,
            feedbacked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE gid = :gid
        AND EXISTS (SELECT 1 FROM variant_enqueue_context);
     UPDATE variant_groups
        SET desired_rating = :rating,
            is_active = 1,
            latest_feedback_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT group_id FROM variant_enqueue_context);
     INSERT INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, metadata_snapshot_json, decided_at
     )
     SELECT context.group_id, gallery.gid, 'confirmed', 'automatic', 0,
            json_object('kind', 'feedback_source'),
            json_object(
              'gid', gallery.gid, 'token', gallery.token,
              'title', gallery.title, 'title_jpn', gallery.title_jpn,
              'uploader', gallery.uploader,
              'posted', gallery.posted, 'filecount', gallery.file_count,
              'filesize', gallery.filesize, 'expunged', gallery.expunged,
              'rating', gallery.rating,
              'favorite_count', gallery.favorite_count,
              'rating_count', gallery.rating_count,
              'popularity_fetched_at', gallery.popularity_fetched_at,
              'tags', CASE WHEN json_valid(gallery.tags) THEN json(gallery.tags) ELSE json('[]') END,
              'thumb', gallery.thumb, 'first_gid', gallery.first_gid,
              'first_key', gallery.first_key, 'parent_gid', gallery.parent_gid,
              'parent_key', gallery.parent_key, 'current_gid', gallery.current_gid,
              'current_key', gallery.current_key
            ),
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
       FROM galleries AS gallery
       CROSS JOIN variant_enqueue_context AS context
      WHERE gallery.gid = :gid
     ON CONFLICT(group_id, gid) DO UPDATE SET
       membership_state = 'confirmed',
       decision_source = 'automatic',
       evidence_json = excluded.evidence_json,
       metadata_snapshot_json = excluded.metadata_snapshot_json,
       decided_at = excluded.decided_at,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_enqueue_context)
        AND job_type = 'discover' AND status = 'queued';
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     ) SELECT 'discover', group_id, :gid, :priority, 'queued'
         FROM variant_enqueue_context;
     UPDATE variant_actions
        SET status = 'superseded',
            lease_owner = NULL, lease_expires_at = NULL, lease_job_id = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_enqueue_context)
        AND gid = :gid AND action_type = 'rating'
        AND desired_value <> CAST(CASE :rating WHEN 11 THEN 10 ELSE :rating END AS TEXT)
        AND status <> 'superseded';
     INSERT INTO variant_actions(
       group_id, gid, action_type, desired_value, decision_revision_id
     )
     SELECT context.group_id, :gid, 'rating',
            CAST(CASE :rating WHEN 11 THEN 10 ELSE :rating END AS TEXT), policy.id
       FROM variant_enqueue_context AS context
       JOIN variant_policy_revisions AS policy ON policy.is_active = 1
     WHERE 1
     ON CONFLICT(action_type, gid, desired_value, decision_revision_id) DO UPDATE SET
       group_id = excluded.group_id,
       status = CASE
         WHEN variant_actions.status = 'superseded' THEN 'pending'
         ELSE variant_actions.status
       END,
       available_at = CASE
         WHEN variant_actions.status = 'superseded'
           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         ELSE variant_actions.available_at
       END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       completed_at = CASE
         WHEN variant_actions.status = 'superseded' THEN NULL
         ELSE variant_actions.completed_at
       END;
     COMMIT;
     SELECT group_id FROM variant_enqueue_context;")" || return

  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Failed to resolve a variant group for GID ${gid}."
    return 1
  }
  printf '%s\n' "${group_id}"
}

# Apply a rating below the variant threshold to an existing confirmed group.
# This stores only desired state: remote actions and archive deletion remain the
# responsibility of the variants worker. The group id is the only stdout on
# success; VARIANTS_NOT_GROUPED_STATUS means no confirmed group and no writes.
variants_downgrade_feedback() {
  local gid="$1"
  local rating="$2"
  local group_id

  variants_validate_gid "${gid}" || return 1
  if [[ ! "${rating}" =~ ^[1-7]$ ]]; then
    log_err "Invalid variant downgrade rating '${rating}'. Must be 1 through 7."
    return 1
  fi

  group_id="$(db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :rating ${rating}" \
    ".parameter set :priority ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_downgrade_context (
       singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
       group_id INTEGER NOT NULL,
       policy_revision_id INTEGER NOT NULL
     );
     INSERT INTO variant_downgrade_context(
       singleton, group_id, policy_revision_id
     )
       SELECT 1, grouped.id,
              (SELECT id FROM variant_policy_revisions
                WHERE is_active = 1 LIMIT 1)
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id = member.group_id
        WHERE member.gid = :gid
          AND member.membership_state = 'confirmed'
        ORDER BY grouped.is_active DESC, grouped.id
        LIMIT 1;
     UPDATE variant_groups
        SET desired_rating = :rating,
            is_active = 0,
            latest_feedback_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT group_id FROM variant_downgrade_context);
     UPDATE galleries
        SET self_rating = :rating,
            feedbacked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE gid IN (
        SELECT member.gid
          FROM gallery_variants AS member
          JOIN variant_downgrade_context AS context
            ON context.group_id = member.group_id
         WHERE member.membership_state = 'confirmed'
      );
     UPDATE variant_actions
        SET status = 'superseded',
            lease_owner = NULL, lease_expires_at = NULL, lease_job_id = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_downgrade_context)
        AND status <> 'superseded'
        AND NOT EXISTS (
          SELECT 1
            FROM gallery_variants AS member
           WHERE member.group_id = variant_actions.group_id
             AND member.gid = variant_actions.gid
             AND member.membership_state = 'confirmed'
             AND variant_actions.decision_revision_id = (
               SELECT policy_revision_id FROM variant_downgrade_context
             )
             AND (
               (variant_actions.action_type = 'rating'
                 AND variant_actions.desired_value = CAST(:rating AS TEXT))
               OR (variant_actions.action_type = 'favorite_remove'
                 AND variant_actions.desired_value = 'favdel')
               OR (variant_actions.action_type = 'archive_cleanup'
                 AND variant_actions.desired_value = 'delete')
             )
        );
     INSERT INTO variant_actions(
       group_id, gid, action_type, desired_value, decision_revision_id
     )
       SELECT context.group_id, member.gid, desired.action_type,
              desired.desired_value, context.policy_revision_id
         FROM variant_downgrade_context AS context
         JOIN gallery_variants AS member
           ON member.group_id = context.group_id
          AND member.membership_state = 'confirmed'
         CROSS JOIN (
           SELECT 'rating' AS action_type, CAST(:rating AS TEXT) AS desired_value
           UNION ALL SELECT 'favorite_remove', 'favdel'
           UNION ALL SELECT 'archive_cleanup', 'delete'
         ) AS desired
        WHERE 1
     ON CONFLICT(action_type, gid, desired_value, decision_revision_id) DO UPDATE SET
       group_id = excluded.group_id,
       status = CASE
         WHEN variant_actions.status = 'superseded' THEN 'pending'
         ELSE variant_actions.status
       END,
       available_at = CASE
         WHEN variant_actions.status = 'superseded'
           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         ELSE variant_actions.available_at
       END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       completed_at = CASE
         WHEN variant_actions.status = 'superseded' THEN NULL
         ELSE variant_actions.completed_at
       END;
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_downgrade_context)
        AND job_type = 'reconcile_actions' AND status = 'queued';
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     ) SELECT 'reconcile_actions', group_id, :gid, :priority, 'queued'
         FROM variant_downgrade_context;
     COMMIT;
     SELECT group_id FROM variant_downgrade_context;")" || return

  if [[ -z "${group_id}" ]]; then
    return "${VARIANTS_NOT_GROUPED_STATUS}"
  fi
  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Failed to resolve a variant group for GID ${gid}."
    return 1
  }
  printf '%s\n' "${group_id}"
}

# CLI enqueue is intentionally a stored-intent wrapper. Feedback integrations
# should call variants_enqueue_feedback directly so persistence and enqueueing
# cannot be split across transactions.
variants_enqueue_group() {
  local gid="$1"
  local rating

  variants_validate_gid "${gid}" || return 1
  rating="$(db_query \
    ".parameter set :gid ${gid}" \
    "SELECT self_rating FROM galleries WHERE gid = :gid;")" || return
  if [[ -z "${rating}" ]]; then
    log_err "Gallery GID ${gid} was not found."
    return 1
  fi
  if [[ ! "${rating}" =~ ^(8|9|10|11)$ ]]; then
    log_err "Gallery GID ${gid} has stored rating ${rating}; variants require 8 through 11."
    return 1
  fi
  variants_enqueue_feedback "${gid}" "${rating}"
}

# Destructively detach one or more confirmed galleries from every current and
# historical identity projection while preserving their stored feedback. Each
# selected GID becomes a fresh singleton source group, while non-selected
# members of each touched active group are copied into a fresh remainder group.
variants_ungroup() (
  local force="$1"
  shift
  local gids=("$@")
  local gid gids_json unique_count preflight result answer lock_fd

  ((${#gids[@]} > 0)) || {
    log_err "ungroup requires at least one GID."
    return 1
  }
  for gid in "${gids[@]}"; do
    variants_validate_gid "${gid}" || return 1
  done
  gids_json="$(printf '%s\n' "${gids[@]}" | jq -sc 'map(tonumber)')" || return
  unique_count="$(jq 'unique | length' <<<"${gids_json}")" || return
  if [[ "${unique_count}" -ne "${#gids[@]}" ]]; then
    log_err "ungroup GIDs must be distinct."
    return 1
  fi
  gids_json="$(jq -c 'sort' <<<"${gids_json}")" || return

  exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
  if ! flock -n "${lock_fd}"; then
    log_err "Cannot ungroup gallery identities while another variants worker is active."
    return 1
  fi

  preflight="$(db_query \
    ".parameter set :gids $(db_parameter_text "${gids_json}")" \
    "WITH reset_gid AS (
       SELECT CAST(value AS INTEGER) AS gid FROM json_each(:gids)
     ), touched_group AS (
       SELECT DISTINCT grouped.id
         FROM reset_gid
         JOIN gallery_variants AS member
           ON member.gid=reset_gid.gid AND member.membership_state='confirmed'
         JOIN variant_groups AS grouped
           ON grouped.id=member.group_id AND grouped.is_active=1
     ), identity_review AS (
       SELECT DISTINCT review.id
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
        WHERE review.review_type='candidate_identity'
          AND (grouped.source_gid IN (SELECT gid FROM reset_gid)
            OR review.candidate_gid IN (SELECT gid FROM reset_gid))
     )
     SELECT json_object(
       'gids', json(:gids),
       'existing_galleries', (SELECT count(*) FROM galleries
                               WHERE gid IN (SELECT gid FROM reset_gid)),
       'active_confirmed_memberships', (SELECT count(*)
          FROM reset_gid WHERE 1=(SELECT count(*)
            FROM gallery_variants AS member
            JOIN variant_groups AS grouped ON grouped.id=member.group_id
           WHERE member.gid=reset_gid.gid
             AND member.membership_state='confirmed' AND grouped.is_active=1)),
       'groups', (SELECT count(*) FROM touched_group),
       'pairs', (SELECT count(*) FROM gallery_identity_pairs
                  WHERE low_gid IN (SELECT gid FROM reset_gid)
                     OR high_gid IN (SELECT gid FROM reset_gid)),
       'reviews', (SELECT count(*) FROM identity_review),
       'memberships', (SELECT count(*) FROM gallery_variants
                        WHERE gid IN (SELECT gid FROM reset_gid)),
       'jobs', (SELECT count(*) FROM variant_jobs
                 WHERE group_id IN (SELECT id FROM touched_group)
                   AND status IN ('queued','leased')),
       'actions', (SELECT count(*) FROM variant_actions
                    WHERE group_id IN (SELECT id FROM touched_group)
                      AND status IN ('pending','in_flight','retryable_error',
                                     'permanent_error','configuration_error'))
     );")" || return

  if [[ "$(jq -r '.existing_galleries' <<<"${preflight}")" -ne "${#gids[@]}" ]]; then
    log_err "Every ungroup GID must exist in the gallery database."
    return 1
  fi
  if [[ "$(jq -r '.active_confirmed_memberships' <<<"${preflight}")" -ne "${#gids[@]}" ]]; then
    log_err "Every ungroup GID must be confirmed in exactly one active group."
    return 1
  fi

  if [[ "${force}" -ne 1 ]]; then
    printf 'Ungroup preview: %s\n' "$(jq -c '.' <<<"${preflight}")" >&2
    printf 'Rebuild these identity groups and delete their review evidence? [y/N] ' >&2
    read -r answer
    case "${answer}" in
    y | Y | yes | YES | Yes) ;;
    *) log "Ungroup cancelled."; return 1 ;;
    esac
  fi

  result="$(db_query \
    ".parameter set :gids $(db_parameter_text "${gids_json}")" \
    ".parameter set :priority ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE identity_reset_gid(
       gid INTEGER PRIMARY KEY
     );
     INSERT INTO identity_reset_gid(gid)
       SELECT CAST(value AS INTEGER) FROM json_each(:gids);
     CREATE TEMP TABLE identity_reset_guard(
       valid INTEGER NOT NULL CHECK(valid = 1)
     );
     INSERT INTO identity_reset_guard(valid)
       SELECT CASE WHEN
         (SELECT count(*) FROM galleries
           WHERE gid IN (SELECT gid FROM identity_reset_gid)) =
           (SELECT count(*) FROM identity_reset_gid)
         AND NOT EXISTS (
           SELECT 1 FROM identity_reset_gid AS reset
            WHERE 1 <> (SELECT count(*)
              FROM gallery_variants AS member
              JOIN variant_groups AS grouped ON grouped.id=member.group_id
             WHERE member.gid=reset.gid
               AND member.membership_state='confirmed'
               AND grouped.is_active=1))
         THEN 1 ELSE 0 END;

     CREATE TEMP TABLE identity_reset_group AS
       SELECT DISTINCT grouped.*
         FROM identity_reset_gid AS reset
         JOIN gallery_variants AS member
           ON member.gid=reset.gid AND member.membership_state='confirmed'
         JOIN variant_groups AS grouped
           ON grouped.id=member.group_id AND grouped.is_active=1;
     CREATE TEMP TABLE identity_reset_member AS
       SELECT member.*
         FROM gallery_variants AS member
        WHERE member.group_id IN (SELECT id FROM identity_reset_group)
          AND member.membership_state='confirmed'
          AND member.gid NOT IN (SELECT gid FROM identity_reset_gid);
     CREATE TEMP TABLE identity_reset_selected_member AS
       SELECT member.*, grouped.desired_rating, grouped.latest_feedback_at
         FROM identity_reset_gid AS reset
         JOIN gallery_variants AS member
           ON member.gid=reset.gid AND member.membership_state='confirmed'
         JOIN variant_groups AS grouped
           ON grouped.id=member.group_id AND grouped.is_active=1;
     CREATE TEMP TABLE identity_reset_projection_group(group_id INTEGER PRIMARY KEY);
     INSERT INTO identity_reset_projection_group(group_id)
       SELECT DISTINCT member.group_id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped
           ON grouped.id=member.group_id AND grouped.is_active=1
        WHERE member.gid IN (SELECT gid FROM identity_reset_gid)
          AND member.group_id NOT IN (SELECT id FROM identity_reset_group);
     CREATE TEMP TABLE identity_reset_review(review_id INTEGER PRIMARY KEY);
     INSERT INTO identity_reset_review(review_id)
       SELECT review.id
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
        WHERE review.review_type='candidate_identity'
          AND (grouped.source_gid IN (SELECT gid FROM identity_reset_gid)
            OR review.candidate_gid IN (SELECT gid FROM identity_reset_gid));
     CREATE TEMP TABLE identity_reset_result(
       pairs_deleted INTEGER NOT NULL,
       reviews_deleted INTEGER NOT NULL,
       memberships_deleted INTEGER NOT NULL
     );
     INSERT INTO identity_reset_result
       SELECT
         (SELECT count(*) FROM gallery_identity_pairs
           WHERE low_gid IN (SELECT gid FROM identity_reset_gid)
              OR high_gid IN (SELECT gid FROM identity_reset_gid)),
         (SELECT count(*) FROM identity_reset_review),
         (SELECT count(*) FROM gallery_variants
           WHERE gid IN (SELECT gid FROM identity_reset_gid));

     UPDATE variant_discovery_runs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            last_error_class=NULL, last_error='identity group ungrouped',
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id IN (SELECT id FROM identity_reset_group)
        AND status IN ('running','retryable');
     UPDATE variant_jobs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id IN (SELECT id FROM identity_reset_group)
        AND status IN ('queued','leased');
     UPDATE variant_actions
        SET status='superseded', lease_owner=NULL, lease_expires_at=NULL,
            lease_job_id=NULL, completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
       WHERE group_id IN (SELECT id FROM identity_reset_group)
        AND status IN ('pending','in_flight','retryable_error',
                       'permanent_error','configuration_error');
     UPDATE variant_canonical_decisions
        SET status='reset',
            superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            supersede_reason='identity_reset'
      WHERE status='active'
        AND (group_id IN (SELECT id FROM identity_reset_group)
             OR selected_gid IN (SELECT gid FROM identity_reset_gid));
     UPDATE variant_reviews
        SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE review_type='winner' AND status='pending' AND superseded_at IS NULL
        AND group_id IN (SELECT id FROM identity_reset_group);
     UPDATE variant_groups
        SET canonical_gid=NULL, is_active=0, review_state='none',
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id IN (SELECT id FROM identity_reset_group);
     UPDATE variant_groups
        SET canonical_gid=NULL,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE canonical_gid IN (SELECT gid FROM identity_reset_gid);

     DELETE FROM gallery_identity_pairs
      WHERE low_gid IN (SELECT gid FROM identity_reset_gid)
         OR high_gid IN (SELECT gid FROM identity_reset_gid);
     DELETE FROM variant_reviews
      WHERE id IN (SELECT review_id FROM identity_reset_review);
     DELETE FROM gallery_variants
      WHERE gid IN (SELECT gid FROM identity_reset_gid);

     CREATE TEMP TABLE identity_reset_replacement(
       old_group_id INTEGER PRIMARY KEY,
       new_group_id INTEGER NOT NULL UNIQUE,
       source_gid INTEGER NOT NULL
     );
     INSERT INTO identity_reset_replacement(old_group_id,new_group_id,source_gid)
       SELECT old.id,
              (SELECT COALESCE(MAX(id),0) FROM variant_groups)
                + row_number() OVER (ORDER BY old.id),
              CASE WHEN EXISTS (
                     SELECT 1 FROM identity_reset_member AS member
                      WHERE member.group_id=old.id AND member.gid=old.source_gid)
                   THEN old.source_gid
                   ELSE (SELECT MIN(member.gid) FROM identity_reset_member AS member
                          WHERE member.group_id=old.id) END
         FROM identity_reset_group AS old
        WHERE EXISTS (SELECT 1 FROM identity_reset_member AS member
                       WHERE member.group_id=old.id)
        ORDER BY old.id;
     INSERT INTO variant_groups(
       id,source_gid,desired_rating,is_active,review_state,latest_feedback_at,
       created_at,updated_at)
       SELECT replacement.new_group_id,replacement.source_gid,old.desired_rating,
              1,'none',old.latest_feedback_at,
              strftime('%Y-%m-%dT%H:%M:%SZ','now'),
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM identity_reset_replacement AS replacement
         JOIN identity_reset_group AS old ON old.id=replacement.old_group_id;
     INSERT INTO gallery_variants(
       group_id,gid,membership_state,decision_source,match_score,evidence_json,
       metadata_snapshot_json,variant_score,variant_state,
       decided_at,matching_revision,created_at,updated_at)
       SELECT replacement.new_group_id,member.gid,'confirmed',
              member.decision_source,member.match_score,member.evidence_json,
              member.metadata_snapshot_json,NULL,'undetermined',
              member.decided_at,member.matching_revision,
              strftime('%Y-%m-%dT%H:%M:%SZ','now'),
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM identity_reset_member AS member
         JOIN identity_reset_replacement AS replacement
           ON replacement.old_group_id=member.group_id;
     UPDATE variant_groups
        SET review_state=CASE WHEN EXISTS (
              SELECT 1 FROM variant_reviews AS review
               WHERE review.review_type='candidate_identity'
                 AND review.status='pending'
                 AND (review.group_id=variant_groups.id OR EXISTS (
                   SELECT 1
                     FROM gallery_variants AS historical_member
                     JOIN gallery_variants AS current_member
                       ON current_member.gid=historical_member.gid
                      AND current_member.membership_state='confirmed'
                    WHERE historical_member.group_id=review.group_id
                      AND historical_member.membership_state='confirmed'
                      AND current_member.group_id=variant_groups.id)))
            THEN 'candidate_pending' ELSE 'none' END
      WHERE id IN (SELECT new_group_id FROM identity_reset_replacement);
     INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
       SELECT 'discover',new_group_id,source_gid,:priority,'queued'
         FROM identity_reset_replacement;

     CREATE TEMP TABLE identity_reset_source(
       gid INTEGER PRIMARY KEY,
       new_group_id INTEGER NOT NULL UNIQUE,
       desired_rating INTEGER NOT NULL,
       latest_feedback_at TEXT NOT NULL
     );
     INSERT INTO identity_reset_source(
       gid,new_group_id,desired_rating,latest_feedback_at)
       SELECT selected.gid,
              (SELECT COALESCE(MAX(id),0) FROM variant_groups)
                + row_number() OVER (ORDER BY selected.gid),
              selected.desired_rating,selected.latest_feedback_at
         FROM identity_reset_selected_member AS selected
        ORDER BY selected.gid;
     INSERT INTO variant_groups(
       id,source_gid,desired_rating,is_active,review_state,latest_feedback_at,
       created_at,updated_at)
       SELECT source.new_group_id,source.gid,source.desired_rating,
              1,'none',source.latest_feedback_at,
              strftime('%Y-%m-%dT%H:%M:%SZ','now'),
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM identity_reset_source AS source;
     INSERT INTO gallery_variants(
       group_id,gid,membership_state,decision_source,match_score,evidence_json,
       metadata_snapshot_json,variant_score,variant_state,
       decided_at,matching_revision,created_at,updated_at)
       SELECT source.new_group_id,source.gid,'confirmed','automatic',0,
              json_object('kind','ungroup_source'),
              selected.metadata_snapshot_json,NULL,'undetermined',
              strftime('%Y-%m-%dT%H:%M:%SZ','now'),selected.matching_revision,
              strftime('%Y-%m-%dT%H:%M:%SZ','now'),
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM identity_reset_source AS source
         JOIN identity_reset_selected_member AS selected
           ON selected.gid=source.gid;
     INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
       SELECT 'discover',new_group_id,gid,:priority,'queued'
         FROM identity_reset_source;

     $(variants_identity_reconcile_sql)

     SELECT json_object(
       'ungrouped',json('true'),'gids',json(:gids),
       'pairs_deleted',(SELECT pairs_deleted FROM identity_reset_result),
       'reviews_deleted',(SELECT reviews_deleted FROM identity_reset_result),
       'memberships_deleted',(SELECT memberships_deleted FROM identity_reset_result),
       'replacement_groups',(SELECT count(*) FROM identity_reset_replacement),
       'source_groups',(SELECT count(*) FROM identity_reset_source),
       'rediscovery_queued',
         (SELECT count(*) FROM identity_reset_replacement)
           + (SELECT count(*) FROM identity_reset_source)
     );
     COMMIT;")" || {
       log_err "Gallery ungroup failed; state was rolled back."
       return 1
     }

  printf '%s\n' "${result}"
)

variants_status_is_valid() {
  case "$1" in
  active | inactive | none | candidate_pending | winner_pending | queued | leased | completed | failed | cancelled | pending | resolved | in_flight | succeeded | retryable_error | permanent_error | configuration_error | superseded) return 0 ;;
  *) return 1 ;;
  esac
}

# Emit one JSON document. Nested state remains JSON rather than JSON-encoded
# strings by constructing the complete document inside SQLite.
variants_list_json() {
  local gid="${1:-0}"
  local status="${2:-}"

  [[ "${gid}" == "0" ]] || variants_validate_gid "${gid}" || return 1
  if [[ -n "${status}" ]] && ! variants_status_is_valid "${status}"; then
    log_err "Invalid variant status '${status}'."
    return 1
  fi

  db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :status $(db_parameter_text "${status}")" \
    "SELECT json_object('groups', COALESCE(json_group_array(json(group_json)), json('[]')))
       FROM (
         SELECT json_object(
           'source_gid', grouped.source_gid,
           'desired_rating', grouped.desired_rating,
           'status', CASE grouped.is_active WHEN 1 THEN 'active' ELSE 'inactive' END,
           'canonical_gid', grouped.canonical_gid,
           'canonical_decision_id', (SELECT decision.id
                                      FROM variant_canonical_decisions AS decision
                                     WHERE decision.group_id=grouped.id
                                       AND decision.status='active'),
           'selection_source', CASE WHEN EXISTS (
                                      SELECT 1 FROM variant_canonical_decisions AS decision
                                       WHERE decision.group_id=grouped.id
                                         AND decision.status='active')
                                    THEN 'manual' ELSE 'automatic' END,
           'review_state', grouped.review_state,
           'last_discovered_at', grouped.last_discovered_at,
           'last_evaluated_at', grouped.last_evaluated_at,
           'next_discovery_at', grouped.next_discovery_at,
           'active_evaluation_id', grouped.active_evaluation_id,
           'members', json(COALESCE((
             SELECT json_group_array(json_object(
               'gid', member.gid, 'membership_state', member.membership_state,
               'decision_source', member.decision_source,
               'match_score', member.match_score, 'variant_score', member.variant_score,
               'variant_state', member.variant_state,
               'evidence', json(member.evidence_json),
               'metadata_snapshot', json(member.metadata_snapshot_json),
               'variant_score_breakdown', (
                 SELECT json(score.value)
                   FROM variant_evaluations AS evaluation
                   JOIN json_each(evaluation.member_scores_json) AS score
                  WHERE evaluation.id = grouped.active_evaluation_id
                    AND CAST(json_extract(score.value, '$.gid') AS INTEGER) = member.gid
               )
             )) FROM gallery_variants AS member WHERE member.group_id = grouped.id
           ), '[]')),
           'jobs', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', job.id, 'job_type', job.job_type, 'source_gid', job.source_gid,
               'priority', job.priority, 'status', job.status,
               'attempt_count', job.attempt_count, 'available_at', job.available_at,
               'lease_owner', job.lease_owner, 'lease_expires_at', job.lease_expires_at,
               'last_error_class', job.last_error_class, 'last_error', job.last_error
             )) FROM variant_jobs AS job WHERE job.group_id = grouped.id
           ), '[]')),
           'reviews', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', review.id, 'review_type', review.review_type,
               'candidate_gid', review.candidate_gid, 'evaluation_id', review.evaluation_id,
               'status', CASE WHEN review.superseded_at IS NOT NULL
                              THEN 'resolved' ELSE review.status END,
               'decision', review.decision,
               'resolution', CASE WHEN review.superseded_at IS NOT NULL
                                  THEN 'superseded' ELSE review.decision END,
               'selected_gid', review.selected_gid, 'evidence', json(review.evidence_json),
               'choices', json(review.choices_json)
             )) FROM variant_reviews AS review WHERE review.group_id = grouped.id
               AND NOT EXISTS (
                 SELECT 1 FROM galleries AS visible_source
                  WHERE visible_source.gid=grouped.source_gid
                    AND visible_source.current_gid IS NOT NULL
                    AND visible_source.current_gid<>visible_source.gid)
               AND NOT EXISTS (
                 SELECT 1 FROM galleries AS visible_candidate
                  WHERE visible_candidate.gid=review.candidate_gid
                    AND visible_candidate.current_gid IS NOT NULL
                    AND visible_candidate.current_gid<>visible_candidate.gid)
               AND NOT EXISTS (
                 SELECT 1 FROM json_each(review.choices_json) AS visible_choice
                  JOIN galleries AS visible_gallery
                    ON visible_gallery.gid=CAST(visible_choice.value AS INTEGER)
                 WHERE visible_gallery.current_gid IS NOT NULL
                   AND visible_gallery.current_gid<>visible_gallery.gid)
           ), '[]')),
           'actions', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', action.id, 'evaluation_id', action.evaluation_id,
               'gid', action.gid, 'action_type', action.action_type,
               'desired_value', action.desired_value, 'status', action.status,
               'attempt_count', action.attempt_count, 'available_at', action.available_at,
               'last_error_class', action.last_error_class,
               'last_error', action.last_error,
               'result', CASE WHEN action.result_json IS NULL
                              THEN NULL ELSE json(action.result_json) END
             )) FROM variant_actions AS action WHERE action.group_id = grouped.id
           ), '[]'))
         ) AS group_json
         FROM variant_groups AS grouped
         WHERE (:gid = 0 OR grouped.source_gid = :gid OR EXISTS (
                  SELECT 1 FROM gallery_variants AS member
                   WHERE member.group_id = grouped.id AND member.gid = :gid
                ))
           AND (:status = ''
             OR (:status = 'active' AND grouped.is_active = 1)
             OR (:status = 'inactive' AND grouped.is_active = 0)
             OR grouped.review_state = :status
             OR EXISTS (SELECT 1 FROM variant_jobs AS job
                         WHERE job.group_id = grouped.id AND job.status = :status)
             OR EXISTS (SELECT 1 FROM variant_reviews AS review
                         WHERE review.group_id = grouped.id AND review.status = :status)
             OR EXISTS (SELECT 1 FROM variant_actions AS action
                         WHERE action.group_id = grouped.id AND action.status = :status))
         ORDER BY grouped.id
       );"
}

# Public evaluation is addressed by a gallery GID. The relational group ID is
# resolved internally and never becomes part of the CLI contract.
variants_evaluate_gid() {
  local gid="$1"
  local group_id

  variants_validate_gid "${gid}" || return 1
  group_id="$(db_query \
    ".parameter set :gid ${gid}" \
    "SELECT CASE WHEN count(*) = 1 THEN max(id) END
       FROM variant_groups AS grouped
      WHERE grouped.is_active = 1
        AND (grouped.source_gid = :gid OR EXISTS (
          SELECT 1 FROM gallery_variants AS member
           WHERE member.group_id = grouped.id
             AND member.gid = :gid
             AND member.membership_state = 'confirmed'
        ));")" || return

  if [[ ! "${group_id}" =~ ^[1-9][0-9]*$ ]]; then
    log_err "No unique active variant group found for GID ${gid}."
    return 1
  fi

  variants_evaluate_group "${group_id}"
}

variants_work() (
  local max_jobs=1
  local dry_run=0
  local allow_remote_jobs=1
  local lock_fd queued_json queued_count owner claim_json result status
  local attempted=0 discovery_attempted=0 jobs_json='[]'
  local remote_mutations_remaining="${VARIANTS_REMOTE_MUTATIONS_PER_RUN}"

  if declare -F exh_remote_writes_enabled >/dev/null 2>&1 &&
    ! exh_remote_writes_enabled; then
    allow_remote_jobs=0
    remote_mutations_remaining=0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --max-jobs=*) max_jobs="${1#*=}"; shift ;;
    --max-jobs)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        log_err "Missing value for --max-jobs."
        return 1
      fi
      max_jobs="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) log_err "Unknown variants work option: $1"; return 1 ;;
    esac
  done
  variants_validate_positive_integer "max jobs" "${max_jobs}" || return 1

  if [[ "${dry_run}" -eq 1 ]]; then
    queued_json="$(db_query \
      ".parameter set :max_jobs ${max_jobs}" \
      ".parameter set :matching_revision ${VARIANTS_MATCHING_REVISION}" \
      ".parameter set :allow_remote_jobs ${allow_remote_jobs}" \
      "WITH supported AS (
         SELECT id, job_type, source_gid, priority, status, available_at
           FROM variant_jobs
          WHERE job_type IN ('discover', 'evaluate', 'policy_scoring_sweep',
                             'reconcile_actions', 'reconcile_retention')
            AND (:allow_remote_jobs = 1 OR
                 job_type NOT IN ('reconcile_actions','reconcile_retention'))
            AND status = 'queued'
            AND available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         UNION ALL
         SELECT NULL, 'discover', grouped.source_gid,
                CASE WHEN COALESCE(grouped.completed_matching_revision, 0)
                                <> :matching_revision THEN 500 ELSE 100 END,
                'due', COALESCE(grouped.next_discovery_at,
                                strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
           FROM variant_groups AS grouped
          WHERE grouped.is_active = 1
            AND (COALESCE(grouped.completed_matching_revision, 0)
                   <> :matching_revision
              OR (grouped.next_discovery_at IS NOT NULL
                  AND grouped.next_discovery_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
            AND NOT EXISTS (SELECT 1 FROM variant_jobs AS job
                             WHERE job.group_id = grouped.id
                               AND job.job_type = 'discover'
                               AND job.status IN ('queued', 'leased'))
       )
       SELECT COALESCE(json_group_array(json_object(
         'id', id, 'job_type', job_type,
         'source_gid', source_gid, 'priority', priority, 'status', status,
         'available_at', available_at
       )), json('[]'))
         FROM (SELECT * FROM supported
                ORDER BY priority DESC, id LIMIT :max_jobs);"
    )" || return
    if yomiko_in_api_mode; then
      local selected_ids action_preflight='[]' public_jobs errors='[]'
      local remote_would_use=0 local_would_use=0 preflight_rows
      local source_gid gid action_type file_path hath_attempted state item
      selected_ids="$(jq -c '[.[].id | select(. != null)]' <<<"${queued_json}")" || return
      preflight_rows="$(db_query \
        ".parameter set :selected_ids $(db_parameter_text "${selected_ids}")" \
        "SELECT job.source_gid || char(9) || action.gid || char(9) ||
                action.action_type || char(9) || COALESCE(gallery.file_path,'') || char(9) ||
                COALESCE(gallery.hath_last_attempted_at,'')
           FROM variant_jobs AS job
           JOIN json_each(:selected_ids) AS selected ON selected.value=job.id
           JOIN variant_actions AS action ON action.group_id=job.group_id
           JOIN galleries AS gallery ON gallery.gid=action.gid
          WHERE job.job_type='reconcile_actions'
            AND action.status IN ('pending','retryable_error','configuration_error')
            AND action.available_at<=strftime('%Y-%m-%dT%H:%M:%SZ','now')
          ORDER BY job.priority DESC, action.id;")" || return
      while IFS=$'\t' read -r source_gid gid action_type file_path hath_attempted; do
        [[ -n "${source_gid}" ]] || continue
        case "${action_type}" in
        archive_cleanup)
          local_would_use=$((local_would_use + 1))
          if [[ -z "${file_path}" ]]; then
            state=no_archive_path
          elif ! archive_filename_is_safe "${file_path}"; then
            state=unsafe_path
            errors="$(jq -c --argjson gid "${gid}" '. + [{gid:$gid,class:"permanent",message:"unsafe archive path"}]' <<<"${errors}")"
          elif [[ -f "${ARCHIVED_DIR}/${file_path}" && ! -L "${ARCHIVED_DIR}/${file_path}" ]]; then
            state=regular_file
          else
            state=missing_or_non_regular
          fi
          ;;
        hath_request)
          remote_would_use=$((remote_would_use + 1))
          if [[ -n "${file_path}" ]] && ! archive_filename_is_safe "${file_path}"; then
            state=unsafe_or_non_regular_archive_path
            errors="$(jq -c --argjson gid "${gid}" \
              '. + [{gid:$gid,class:"permanent",message:"unsafe archive path"}]' <<<"${errors}")"
          elif [[ -n "${file_path}" ]] &&
            ( [[ -e "${ARCHIVED_DIR}/${file_path}" ]] || [[ -L "${ARCHIVED_DIR}/${file_path}" ]] ) &&
            ! variants_retention_archive_is_regular "${file_path}" 2>/dev/null; then
            state=unsafe_or_non_regular_archive_path
            errors="$(jq -c --argjson gid "${gid}" \
              '. + [{gid:$gid,class:"permanent",message:"archive path is not a regular file"}]' <<<"${errors}")"
          elif variants_retention_archive_is_regular "${file_path}" 2>/dev/null; then
            state=canonical_archive_present
          elif variants_retention_hath_tree_contains_gid "${gid}"; then
            state=hath_tree_present
          elif [[ -n "${hath_attempted}" ]]; then
            local hath_deadline
            hath_deadline="$(db_query \
              ".parameter set :attempted $(db_parameter_text "${hath_attempted}")" \
              ".parameter set :interval ${VARIANTS_HATH_RETRY_INTERVAL_SECONDS}" \
              "SELECT strftime('%Y-%m-%dT%H:%M:%SZ',:attempted,
                       '+' || :interval || ' seconds');")" || return
            if [[ "${hath_deadline}" > "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ]]; then
              state=hath_cooldown
            else
              state=hath_request_due
            fi
          else
            state=hath_request_due
          fi
          ;;
        rating | favorite_move | favorite_remove)
          remote_would_use=$((remote_would_use + 1))
          state=remote_request_needed
          ;;
        *) state=unknown_action ;;
        esac
        item="$(jq -nc --argjson source_gid "${source_gid}" --argjson gid "${gid}" \
          --arg action_type "${action_type}" --arg state "${state}" \
          --arg available_at "${hath_deadline:-}" \
          '{source_gid:$source_gid,gid:$gid,action_type:$action_type,state:$state} |
           if $available_at != "" and $state == "hath_cooldown" then .available_at=$available_at else . end')"
        action_preflight="$(jq -c --argjson item "${item}" '. + [$item]' <<<"${action_preflight}")"
      done <<<"${preflight_rows}"
      if ((remote_would_use > remote_mutations_remaining)); then
        remote_would_use="${remote_mutations_remaining}"
      fi
      if jq -e 'any(.[]; .action_type=="favorite_move")' >/dev/null <<<"${action_preflight}" &&
        ! variants_actions_favorite_categories >/dev/null 2>&1; then
        errors="$(jq -c '. + [{class:"configuration",message:"favorite categories must be distinct values from 0 through 9"}]' <<<"${errors}")"
      fi
      public_jobs="$(jq -c 'map(del(.id))' <<<"${queued_json}")" || return
      queued_count="$(jq 'length' <<<"${queued_json}")"
      jq -nc --argjson jobs "${public_jobs}" --argjson preflight "${action_preflight}" \
        --argjson remote_limit "${remote_mutations_remaining}" \
        --argjson remote_would_use "${remote_would_use}" \
        --argjson local_would_use "${local_would_use}" --argjson errors "${errors}" \
        --argjson may_continue "$([[ "${queued_count}" -ge "${max_jobs}" ]] && printf true || printf false)" \
        '{locked:false,dry_run:true,jobs:$jobs,preflight:$preflight,
          budgets:{remote_mutations:{limit:$remote_limit,would_use:$remote_would_use},
                   local_cleanups:{limit:null,would_use:$local_would_use}},
          errors:$errors,continuation:{may_have_more_jobs:$may_continue}}'
    else
      queued_count="$(jq 'length' <<<"${queued_json}")"
      log "Variants worker would attempt ${queued_count} supported queued job(s)."
    fi
    return 0
  fi

  exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
  if ! flock -n "${lock_fd}"; then
    if yomiko_in_api_mode; then
      printf '{"locked":true,"dry_run":false,"jobs":[]}\n'
    else
      log "Another variants worker is already in progress."
    fi
    return 0
  fi

  variants_worker_requeue_expired_leases >/dev/null || return
  variants_worker_cancel_inactive_discovery >/dev/null || return
  if [[ "${allow_remote_jobs}" -eq 1 ]] &&
    declare -F variants_retention_self_heal >/dev/null 2>&1; then
    variants_retention_self_heal >/dev/null || return
  fi
  if [[ "${allow_remote_jobs}" -eq 1 ]] &&
    declare -F variants_retention_schedule_recovery >/dev/null 2>&1; then
    variants_retention_schedule_recovery >/dev/null || return
  fi
  if [[ "${allow_remote_jobs}" -eq 1 ]] &&
    declare -F variants_actions_schedule_recovery >/dev/null 2>&1; then
    variants_actions_schedule_recovery >/dev/null || return
  fi
  variants_worker_schedule_discovery >/dev/null || return
  owner="worker-$$-$(date -u +%s)"
  while ((attempted < max_jobs)); do
    claim_json="$(variants_worker_claim_job "${owner}" "$((1 - discovery_attempted))")" || return
    [[ -n "${claim_json}" ]] || break
    status=0
    case "$(jq -r '.job_type' <<<"${claim_json}")" in
    discover)
      discovery_attempted=1
      result="$(variants_worker_handle_discover "${claim_json}" "${owner}")" || status=$?
      ;;
    evaluate)
      result="$(variants_worker_handle_evaluate "${claim_json}" "${owner}")" || status=$?
      ;;
    policy_scoring_sweep)
      result="$(variants_worker_handle_policy_scoring_sweep "${claim_json}" "${owner}")" || status=$?
      ;;
    reconcile_actions)
      result="$(variants_worker_handle_reconcile_actions "${claim_json}" "${owner}" \
        "${remote_mutations_remaining}")" || status=$?
      ;;
    reconcile_retention)
      result="$(variants_worker_handle_reconcile_retention "${claim_json}" "${owner}")" || status=$?
      ;;
    *) return 1 ;;
    esac
    if [[ "${status}" -ne 0 || -z "${result}" ]] || ! jq -e . >/dev/null 2>&1 <<<"${result}"; then
      log_err "Variant worker handler failed for job $(jq -r '.id' <<<"${claim_json}")."
      [[ "${status}" -ne 0 ]] && return "${status}"
      return 1
    fi
    jobs_json="$(jq -c --argjson item "${result}" '. + [$item]' <<<"${jobs_json}")" || return
    if [[ "$(jq -r '.job_type' <<<"${result}")" == reconcile_actions ]]; then
      remote_mutations_remaining=$((remote_mutations_remaining - $(jq -r '.remote_mutations // 0' <<<"${result}")))
      ((remote_mutations_remaining >= 0)) || return 1
    fi
    attempted=$((attempted + 1))
  done
  if yomiko_in_api_mode; then
    printf '{"locked":false,"dry_run":false,"jobs":%s}\n' "${jobs_json}"
  else
    log "Variants worker attempted ${attempted} supported job(s)."
  fi
)

# Reviews are deliberately a separate public surface from `variants list`.
# Only review IDs and gallery GIDs cross this boundary; relational IDs remain
# internal to the transaction below.
variants_validate_review_id() {
  local review_id="$1"
  [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Invalid review ID '${review_id}'. Must be a positive integer."
    return 1
  }
}

variants_reviews_json() {
  local status="${1:-}"

  [[ -z "${status}" || "${status}" == pending || "${status}" == resolved ]] || {
    log_err "Invalid review status '${status}'. Expected pending or resolved."
    return 1
  }

  db_query \
    ".parameter set :status $(db_parameter_text "${status}")" \
    "BEGIN IMMEDIATE;
     -- Visibility is derived from live chain metadata. Pending reviews that
     -- became impossible to act on are retained as audit rows but removed
     -- from the actionable projection with explicit internal evidence.
     UPDATE variant_reviews
        SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            evidence_json=json_set(evidence_json,'$.internal_visibility',json_object(
              'reason','replaced_gallery'))
      WHERE review_type IN ('candidate_identity','winner')
        AND status='pending' AND superseded_at IS NULL
        AND (
          EXISTS (SELECT 1 FROM galleries AS source
                  JOIN variant_groups AS source_group
                    ON source_group.source_gid=source.gid
                 WHERE source_group.id=variant_reviews.group_id
                   AND source.current_gid IS NOT NULL
                   AND source.current_gid<>source.gid)
          OR (variant_reviews.candidate_gid IS NOT NULL AND EXISTS (
                SELECT 1 FROM galleries AS candidate
                 WHERE candidate.gid=variant_reviews.candidate_gid
                   AND candidate.current_gid IS NOT NULL
                   AND candidate.current_gid<>candidate.gid))
          OR (variant_reviews.review_type='winner' AND EXISTS (
                SELECT 1 FROM json_each(variant_reviews.choices_json) AS choice
                 JOIN galleries AS selected
                   ON selected.gid=CAST(choice.value AS INTEGER)
                WHERE selected.current_gid IS NOT NULL
                  AND selected.current_gid<>selected.gid))
        );
     $(variants_identity_reconcile_sql)
     UPDATE variant_groups AS grouped
        SET review_state=CASE
          WHEN EXISTS (
            SELECT 1 FROM identity_actionable_review AS actionable
             JOIN identity_gid_class AS member_class
               ON member_class.class_gid IN (
                    actionable.low_class_gid,actionable.high_class_gid)
            WHERE member_class.active_group_id=grouped.id
          ) THEN 'candidate_pending'
          WHEN EXISTS (
            SELECT 1 FROM variant_reviews AS winner
             WHERE winner.group_id=grouped.id AND winner.review_type='winner'
               AND winner.status='pending' AND winner.superseded_at IS NULL
          ) THEN 'winner_pending'
          ELSE 'none' END,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE grouped.is_active=1;
     SELECT json_object(
       'actionable_count',
         (SELECT COUNT(*) FROM identity_actionable_review)
         + (SELECT COUNT(*) FROM variant_reviews
             WHERE review_type='winner' AND status='pending'
               AND superseded_at IS NULL),
       'reviews',COALESCE(json_group_array(json(review_json)),json('[]')))
       FROM (
         SELECT json_object(
           'id', review.id,
           'review_type', review.review_type,
           'source_gid', grouped.source_gid,
           'candidate_gid', review.candidate_gid,
           'covered_review_count', CASE
             WHEN review.review_type='candidate_identity'
              AND review.id IN (SELECT review_id FROM identity_actionable_review)
             THEN (SELECT COUNT(*) FROM identity_pending_candidate AS covered
                    JOIN identity_pending_candidate AS current
                      ON current.review_id=review.id
                   WHERE covered.low_class_gid=current.low_class_gid
                     AND covered.high_class_gid=current.high_class_gid)
             ELSE NULL END,
           'source_class_size', CASE
             WHEN review.review_type='candidate_identity'
             THEN (SELECT source_class_size FROM identity_pending_candidate
                    WHERE review_id=review.id) ELSE NULL END,
           'candidate_class_size', CASE
             WHEN review.review_type='candidate_identity'
             THEN (SELECT candidate_class_size FROM identity_pending_candidate
                    WHERE review_id=review.id) ELSE NULL END,
           'status', CASE WHEN review.superseded_at IS NOT NULL
                          THEN 'resolved' ELSE review.status END,
           'decision', review.decision,
           'resolution', CASE WHEN review.superseded_at IS NOT NULL
                              THEN 'superseded' ELSE review.decision END,
           'selected_gid', review.selected_gid,
           'evidence', CASE WHEN review.review_type = 'candidate_identity'
             THEN json(json_remove(
               review.evidence_json,
               '$.source_snapshot.tags',
               '$.candidate_snapshot.tags',
               '$.normalized.creators_source',
               '$.normalized.creators_candidate',
               '$.normalized.content_tags_source',
               '$.normalized.content_tags_candidate'
             ))
             ELSE json(review.evidence_json) END,
           'source', json_object(
             'gid', source_gallery.gid,
             'token', source_gallery.token,
             'title', COALESCE(json_extract(source_member.metadata_snapshot_json, '$.title'), source_gallery.title),
             'title_jpn', COALESCE(json_extract(source_member.metadata_snapshot_json, '$.title_jpn'), source_gallery.title_jpn),
             'file_count', COALESCE(json_extract(source_member.metadata_snapshot_json, '$.filecount'), source_gallery.file_count),
             'expunged', COALESCE(json_extract(source_member.metadata_snapshot_json, '$.expunged'), source_gallery.expunged),
             'thumb', COALESCE(NULLIF(json_extract(source_member.metadata_snapshot_json, '$.thumb'), ''), source_gallery.thumb),
             'file_path', source_gallery.file_path,
             'archive_state', CASE WHEN COALESCE(source_gallery.file_path, '') = '' THEN 'not_archived' ELSE 'archived' END,
             'metadata_snapshot', CASE WHEN source_member.metadata_snapshot_json IS NULL
               THEN NULL ELSE json(json_remove(source_member.metadata_snapshot_json, '$.tags')) END
           ),
           'candidate', CASE WHEN review.candidate_gid IS NULL THEN NULL ELSE json_object(
             'gid', candidate_gallery.gid,
             'token', candidate_gallery.token,
             'title', COALESCE(json_extract(candidate_member.metadata_snapshot_json, '$.title'), candidate_gallery.title),
             'title_jpn', COALESCE(json_extract(candidate_member.metadata_snapshot_json, '$.title_jpn'), candidate_gallery.title_jpn),
             'file_count', COALESCE(json_extract(candidate_member.metadata_snapshot_json, '$.filecount'), candidate_gallery.file_count),
             'expunged', COALESCE(json_extract(candidate_member.metadata_snapshot_json, '$.expunged'), candidate_gallery.expunged),
             'thumb', COALESCE(NULLIF(json_extract(candidate_member.metadata_snapshot_json, '$.thumb'), ''), candidate_gallery.thumb),
             'file_path', candidate_gallery.file_path,
             'archive_state', CASE WHEN COALESCE(candidate_gallery.file_path, '') = '' THEN 'not_archived' ELSE 'archived' END,
             'metadata_snapshot', CASE WHEN candidate_member.metadata_snapshot_json IS NULL
               THEN NULL ELSE json(json_remove(candidate_member.metadata_snapshot_json, '$.tags')) END
           ) END,
           'choices', json(COALESCE((
             SELECT json_group_array(json(choice_json)) FROM (
               SELECT json_object(
                 'gid', choice_gallery.gid,
                 'token', choice_gallery.token,
                 'title', COALESCE(json_extract(snapshot.value, '$.title'), choice_gallery.title),
                 'title_jpn', COALESCE(json_extract(snapshot.value, '$.title_jpn'), choice_gallery.title_jpn),
                 'thumb', choice_gallery.thumb,
                 'file_path', choice_gallery.file_path,
                 'archive_state', CASE WHEN COALESCE(choice_gallery.file_path, '') = '' THEN 'not_archived' ELSE 'archived' END,
                 'variant_score', json_extract(score.value, '$.score'),
                 'variant_score_breakdown', json(score.value)
               ) AS choice_json
                 FROM json_each(review.choices_json) AS choice
                 LEFT JOIN variant_evaluations AS review_evaluation
                   ON review_evaluation.id = review.evaluation_id
                 JOIN galleries AS choice_gallery
                   ON choice_gallery.gid = CAST(choice.value AS INTEGER)
                 LEFT JOIN json_each(review_evaluation.member_scores_json) AS score
                   ON CAST(json_extract(score.value, '$.gid') AS INTEGER) = choice_gallery.gid
                 LEFT JOIN json_each(review_evaluation.metadata_snapshot_json) AS snapshot
                   ON CAST(json_extract(snapshot.value, '$.gid') AS INTEGER) = choice_gallery.gid
                ORDER BY CAST(choice.key AS INTEGER)
             )
           ), '[]')),
           'created_at', review.created_at,
           'resolved_at', COALESCE(review.resolved_at, review.superseded_at)
         ) AS review_json
           FROM variant_reviews AS review
           JOIN variant_groups AS grouped ON grouped.id = review.group_id
           JOIN galleries AS source_gallery ON source_gallery.gid = grouped.source_gid
           LEFT JOIN gallery_variants AS source_member
             ON source_member.group_id = review.group_id
            AND source_member.gid = grouped.source_gid
           LEFT JOIN galleries AS candidate_gallery
             ON candidate_gallery.gid = review.candidate_gid
           LEFT JOIN gallery_variants AS candidate_member
             ON candidate_member.group_id = review.group_id
            AND candidate_member.gid = review.candidate_gid
          WHERE (
                 (:status = '' AND (
                  review.status='resolved'
                  OR (review.review_type='winner' AND review.status='pending'
                      AND review.superseded_at IS NULL)
                  OR review.id IN (SELECT review_id FROM identity_actionable_review)))
             OR (:status = 'pending' AND (
                  (review.review_type='winner' AND review.status='pending'
                   AND review.superseded_at IS NULL)
                  OR review.id IN (SELECT review_id FROM identity_actionable_review)))
             OR (:status = 'resolved' AND
                 review.status = 'resolved'))
            AND NOT EXISTS (
              SELECT 1 FROM galleries AS live_source
               WHERE live_source.gid=grouped.source_gid
                 AND live_source.current_gid IS NOT NULL
                 AND live_source.current_gid<>live_source.gid)
            AND NOT EXISTS (
              SELECT 1 FROM galleries AS live_candidate
               WHERE live_candidate.gid=review.candidate_gid
                 AND live_candidate.current_gid IS NOT NULL
                 AND live_candidate.current_gid<>live_candidate.gid)
            AND NOT EXISTS (
              SELECT 1 FROM json_each(review.choices_json) AS visible_choice
               JOIN galleries AS visible_gallery
                 ON visible_gallery.gid=CAST(visible_choice.value AS INTEGER)
              WHERE visible_gallery.current_gid IS NOT NULL
                AND visible_gallery.current_gid<>visible_gallery.gid)
          ORDER BY review.id
       );
     COMMIT;"
}

# Resolve one pending review. The context INSERT is intentionally narrow: it
# rechecks pending status, current membership/evaluation ownership, and the
# selected winner choice while holding BEGIN IMMEDIATE. An empty context is a
# stale decision and commits no mutation.
variants_resolve_review() {
  local review_id="$1"
  local decision="$2"
  local selected_gid="${3:-}"
  local decision_sql
  local result

  variants_validate_review_id "${review_id}" || return 1
  case "${decision}" in
  same-book) decision_sql="same_book" ;;
  different-book) decision_sql="different_book" ;;
  winner) decision_sql="winner" ;;
  *) log_err "Invalid review decision '${decision}'."; return 1 ;;
  esac
  if [[ -n "${selected_gid}" ]]; then
    variants_validate_gid "${selected_gid}" || return 1
  elif [[ "${decision}" == winner ]]; then
    log_err "Winner decisions require --gid GID."
    return 1
  fi
  if [[ "${decision}" != winner && -n "${selected_gid}" ]]; then
    log_err "--gid is only valid for winner decisions."
    return 1
  fi

  decision_sql="$(db_parameter_text "${decision_sql}")"
  selected_gid="${selected_gid:-0}"

  result="$(db_query \
    ".parameter init" \
    ".parameter set :review_id ${review_id}" \
    ".parameter set :decision ${decision_sql}" \
    ".parameter set :selected_gid ${selected_gid}" \
    "BEGIN IMMEDIATE;
     $(variants_identity_reconcile_sql)
     CREATE TEMP TABLE variant_review_conflict(
       singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
       reason TEXT NOT NULL
     );
     INSERT INTO variant_review_conflict(singleton, reason)
     SELECT 1, 'same-book identity decisions must be reset before rejection'
       FROM variant_reviews AS review
       JOIN variant_groups AS grouped ON grouped.id = review.group_id
       JOIN gallery_identity_pairs AS pair
         ON pair.low_gid = MIN(grouped.source_gid, review.candidate_gid)
        AND pair.high_gid = MAX(grouped.source_gid, review.candidate_gid)
       JOIN variant_reviews AS current_review
         ON current_review.id = pair.current_review_id
      WHERE review.id = :review_id
        AND review.review_type = 'candidate_identity'
        AND review.status = 'pending' AND review.superseded_at IS NULL
        AND :decision = 'different_book'
        AND current_review.decision = 'same_book'
        AND EXISTS (
          SELECT 1 FROM gallery_variants AS candidate
           WHERE candidate.group_id = review.group_id
             AND candidate.gid = review.candidate_gid
             AND candidate.membership_state = 'candidate');
     INSERT OR IGNORE INTO variant_review_conflict(singleton, reason)
     SELECT 1, 'same-book identity decisions must be reset before rejection'
       FROM identity_pending_candidate
      WHERE review_id=:review_id AND implied_decision='same_book'
        AND :decision='different_book';
     INSERT OR IGNORE INTO variant_review_conflict(singleton, reason)
     SELECT 1, 'same-book merge crosses an existing different-book decision'
       FROM identity_pending_candidate AS pending
       JOIN variant_groups AS grouped ON grouped.id=pending.group_id
       JOIN gallery_identity_pairs AS pair
         ON pair.current_review_id=pending.supporting_review_id
      WHERE pending.review_id=:review_id
        AND pending.implied_decision='different_book'
        AND :decision='same_book'
        AND (pair.low_gid<>MIN(grouped.source_gid,pending.candidate_gid)
          OR pair.high_gid<>MAX(grouped.source_gid,pending.candidate_gid));
     CREATE TEMP TABLE variant_review_effort AS
       SELECT pending.low_class_gid,pending.high_class_gid,
              (SELECT COUNT(*) FROM identity_pending_candidate AS covered
                WHERE covered.low_class_gid=pending.low_class_gid
                  AND covered.high_class_gid=pending.high_class_gid) AS covered_reviews
         FROM identity_pending_candidate AS pending
        WHERE pending.review_id=:review_id;
     CREATE TEMP TABLE variant_review_previously_blocked(group_id INTEGER PRIMARY KEY);
     INSERT OR IGNORE INTO variant_review_previously_blocked(group_id)
       SELECT classes.active_group_id
         FROM variant_review_effort AS effort
         JOIN identity_gid_class AS classes
           ON classes.class_gid IN (effort.low_class_gid,effort.high_class_gid)
         JOIN variant_groups AS grouped ON grouped.id=classes.active_group_id
        WHERE classes.active_group_id IS NOT NULL
          AND grouped.review_state='candidate_pending';
     CREATE TEMP TABLE variant_review_context(
       review_id INTEGER PRIMARY KEY,
       review_type TEXT NOT NULL,
       group_id INTEGER NOT NULL,
       source_gid INTEGER NOT NULL,
       candidate_gid INTEGER,
       evaluation_id INTEGER,
       policy_revision_id INTEGER NOT NULL,
       survivor_group_id INTEGER NOT NULL,
       selected_gid INTEGER,
       canonical_decision_id INTEGER
     );
     INSERT INTO variant_review_context(
       review_id, review_type, group_id, source_gid, candidate_gid,
       evaluation_id, policy_revision_id, survivor_group_id, selected_gid
     )
     SELECT review.id, review.review_type, review.group_id, grouped.source_gid,
            review.candidate_gid, review.evaluation_id, review.policy_revision_id,
            CASE WHEN review.review_type = 'candidate_identity' THEN COALESCE((
              SELECT MIN(active_group.id)
                FROM variant_groups AS active_group
               WHERE active_group.is_active = 1
                 AND (active_group.id = review.group_id OR EXISTS (
                   SELECT 1
                     FROM gallery_variants AS reviewed_member
                     JOIN gallery_variants AS active_member
                       ON active_member.gid = reviewed_member.gid
                      AND active_member.membership_state = 'confirmed'
                    WHERE reviewed_member.group_id = review.group_id
                      AND reviewed_member.membership_state = 'confirmed'
                      AND active_member.group_id = active_group.id
                 ))
            ), review.group_id) ELSE review.group_id END,
            CASE WHEN review.review_type = 'winner' THEN :selected_gid ELSE NULL END
       FROM variant_reviews AS review
       JOIN variant_groups AS grouped ON grouped.id = review.group_id
      WHERE review.id = :review_id
        AND review.status = 'pending' AND review.superseded_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM galleries AS live_source
           WHERE live_source.gid=grouped.source_gid
             AND live_source.current_gid IS NOT NULL
             AND live_source.current_gid<>live_source.gid)
        AND NOT EXISTS (
          SELECT 1 FROM galleries AS live_candidate
           WHERE live_candidate.gid=review.candidate_gid
             AND live_candidate.current_gid IS NOT NULL
             AND live_candidate.current_gid<>live_candidate.gid)
        AND NOT EXISTS (
          SELECT 1 FROM galleries AS live_choice
           WHERE live_choice.gid=:selected_gid
             AND live_choice.current_gid IS NOT NULL
             AND live_choice.current_gid<>live_choice.gid)
        AND NOT EXISTS (SELECT 1 FROM variant_review_conflict)
        AND (
          (review.review_type = 'candidate_identity'
           AND :decision IN ('same_book', 'different_book')
           AND EXISTS (
             SELECT 1 FROM gallery_variants AS candidate
              WHERE candidate.group_id = review.group_id
                AND candidate.gid = review.candidate_gid
                AND candidate.membership_state = 'candidate'))
          OR
          (review.review_type = 'winner'
           AND :decision = 'winner'
           AND grouped.active_evaluation_id = review.evaluation_id
           AND EXISTS (
             SELECT 1 FROM json_each(review.choices_json) AS choice
              WHERE CAST(choice.value AS INTEGER) = :selected_gid)
           AND EXISTS (
             SELECT 1 FROM gallery_variants AS selected
              WHERE selected.group_id = review.group_id
                AND selected.gid = :selected_gid
                AND selected.membership_state = 'confirmed'))
        );

     CREATE TEMP TABLE variant_review_merge_groups(
       group_id INTEGER PRIMARY KEY
     );
     INSERT INTO variant_review_merge_groups(group_id)
       SELECT survivor_group_id FROM variant_review_context
        WHERE review_type = 'candidate_identity' AND :decision = 'same_book';
     INSERT OR IGNORE INTO variant_review_merge_groups(group_id)
       SELECT other_member.group_id
         FROM variant_review_context AS context
         JOIN gallery_variants AS other_member
           ON other_member.gid = context.candidate_gid
          AND other_member.membership_state = 'confirmed'
         JOIN variant_groups AS other_group
           ON other_group.id = other_member.group_id
          AND other_group.is_active = 1
        WHERE context.review_type = 'candidate_identity'
          AND :decision = 'same_book';
     UPDATE variant_review_context
        SET survivor_group_id = (SELECT MIN(group_id) FROM variant_review_merge_groups)
      WHERE review_type = 'candidate_identity' AND :decision = 'same_book';

     -- A positive merge may replace the current negative edge for this exact
     -- reviewed pair, but it may not cross any other current different-book
     -- edge between the prospective equivalence classes.
     INSERT OR IGNORE INTO variant_review_conflict(singleton, reason)
     SELECT 1, 'same-book merge crosses an existing different-book decision'
       FROM variant_review_context AS context
       JOIN gallery_identity_pairs AS pair
         ON (pair.low_gid = context.candidate_gid OR EXISTS (
           SELECT 1 FROM gallery_variants AS low_member
            WHERE low_member.group_id IN (SELECT group_id FROM variant_review_merge_groups)
              AND low_member.membership_state = 'confirmed'
              AND low_member.gid = pair.low_gid))
        AND (pair.high_gid = context.candidate_gid OR EXISTS (
           SELECT 1 FROM gallery_variants AS high_member
            WHERE high_member.group_id IN (SELECT group_id FROM variant_review_merge_groups)
              AND high_member.membership_state = 'confirmed'
              AND high_member.gid = pair.high_gid))
       JOIN variant_reviews AS pair_review ON pair_review.id = pair.current_review_id
      WHERE context.review_type = 'candidate_identity'
        AND :decision = 'same_book'
        AND pair_review.decision = 'different_book'
        AND NOT (
          pair.low_gid = MIN(context.source_gid, context.candidate_gid)
          AND pair.high_gid = MAX(context.source_gid, context.candidate_gid)
        )
      LIMIT 1;
     DELETE FROM variant_review_context
      WHERE EXISTS (SELECT 1 FROM variant_review_conflict);

     -- A merge is safe only when no confirmed member copied from the exact
     -- merge set also belongs to a third active group.
     DELETE FROM variant_review_context
      WHERE review_type = 'candidate_identity'
        AND :decision = 'same_book'
        AND EXISTS (
          SELECT 1
            FROM gallery_variants AS merge_member
            JOIN gallery_variants AS conflict
              ON conflict.gid = merge_member.gid
             AND conflict.membership_state = 'confirmed'
            JOIN variant_groups AS conflict_group
              ON conflict_group.id = conflict.group_id
           WHERE merge_member.group_id IN (SELECT group_id FROM variant_review_merge_groups)
             AND merge_member.membership_state = 'confirmed'
             AND conflict_group.is_active = 1
             AND conflict.group_id NOT IN (SELECT group_id FROM variant_review_merge_groups));

     UPDATE variant_groups
        SET is_active = 0,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT group_id FROM variant_review_merge_groups)
        AND id <> (SELECT survivor_group_id FROM variant_review_context);
     UPDATE variant_jobs
        SET status = 'cancelled',
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id IN (SELECT group_id FROM variant_review_merge_groups)
        AND group_id <> (SELECT survivor_group_id FROM variant_review_context)
        AND status = 'queued';

     UPDATE gallery_variants
        SET membership_state = CASE WHEN :decision = 'same_book' THEN 'confirmed' ELSE 'rejected' END,
            decision_source = 'manual',
            match_score = match_score
              - COALESCE(json_extract(evidence_json, '$.manual_adjustment'), 0),
            evidence_json = json_remove(json_set(evidence_json,
              '$.manual_decision', :decision,
              '$.manual_review_id', :review_id,
              '$.manual_decided_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
              '$.manual_adjustment'),
            decided_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_review_context)
        AND gid = (SELECT candidate_gid FROM variant_review_context)
        AND (SELECT review_type FROM variant_review_context) = 'candidate_identity';

     INSERT INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, metadata_snapshot_json, variant_score,
       variant_state, decided_at
     )
       SELECT context.survivor_group_id, member.gid, member.membership_state,
              member.decision_source, member.match_score, member.evidence_json,
              member.metadata_snapshot_json, NULL,
              'undetermined', member.decided_at
         FROM variant_review_context AS context
         JOIN gallery_variants AS member
           ON member.group_id IN (SELECT group_id FROM variant_review_merge_groups)
           OR (member.group_id=context.group_id AND member.gid=context.candidate_gid)
        WHERE context.review_type = 'candidate_identity'
          AND :decision = 'same_book'
          AND member.membership_state = 'confirmed'
          AND (member.gid <> context.candidate_gid OR member.group_id = context.group_id)
      ON CONFLICT(group_id, gid) DO UPDATE SET
        membership_state = 'confirmed',
        decision_source = CASE
          WHEN excluded.gid = (SELECT candidate_gid FROM variant_review_context)
            THEN 'manual' ELSE gallery_variants.decision_source END,
        match_score = CASE
          WHEN excluded.gid = (SELECT candidate_gid FROM variant_review_context)
            THEN excluded.match_score ELSE gallery_variants.match_score END,
        evidence_json = CASE
          WHEN excluded.gid = (SELECT candidate_gid FROM variant_review_context)
            THEN excluded.evidence_json ELSE gallery_variants.evidence_json END,
        metadata_snapshot_json = CASE
          WHEN excluded.gid = (SELECT candidate_gid FROM variant_review_context)
            THEN excluded.metadata_snapshot_json ELSE gallery_variants.metadata_snapshot_json END,
        decided_at = CASE
          WHEN excluded.gid = (SELECT candidate_gid FROM variant_review_context)
            THEN excluded.decided_at ELSE gallery_variants.decided_at END,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     UPDATE variant_groups
        SET desired_rating = COALESCE((
              SELECT latest.desired_rating FROM variant_groups AS latest
               WHERE latest.id IN (SELECT group_id FROM variant_review_merge_groups)
               ORDER BY latest.latest_feedback_at DESC, latest.id DESC LIMIT 1), desired_rating),
            latest_feedback_at = COALESCE((
              SELECT MAX(latest.latest_feedback_at) FROM variant_groups AS latest
               WHERE latest.id IN (SELECT group_id FROM variant_review_merge_groups)
            ), latest_feedback_at),
            is_active = 1,
            review_state = CASE
              WHEN EXISTS (SELECT 1 FROM variant_reviews AS pending
                            WHERE pending.review_type = 'candidate_identity'
                              AND pending.status = 'pending'
                              AND pending.superseded_at IS NULL
                              AND (pending.group_id = variant_groups.id OR EXISTS (
                                SELECT 1
                                  FROM gallery_variants AS pending_member
                                  JOIN gallery_variants AS grouped_member
                                    ON grouped_member.gid = pending_member.gid
                                   AND grouped_member.membership_state = 'confirmed'
                                 WHERE pending_member.group_id = pending.group_id
                                   AND pending_member.membership_state = 'confirmed'
                                   AND grouped_member.group_id = variant_groups.id
                              ))) THEN 'candidate_pending'
              WHEN EXISTS (SELECT 1 FROM variant_reviews AS pending
                            WHERE pending.group_id = variant_groups.id
                              AND pending.review_type = 'winner'
                              AND pending.status = 'pending'
                              AND pending.superseded_at IS NULL) THEN 'winner_pending'
              ELSE 'none' END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT survivor_group_id FROM variant_review_context)
        AND (SELECT review_type FROM variant_review_context) = 'candidate_identity';
     -- Resolve the source review before inserting the replacement evaluation.
     -- The evaluation supersede trigger must never classify this successful
     -- resolution as superseded.
     UPDATE variant_reviews
        SET status = 'resolved', decision = :decision,
            selected_gid = CASE WHEN review_type = 'winner' THEN :selected_gid ELSE NULL END,
            resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT review_id FROM variant_review_context)
        AND (SELECT review_type FROM variant_review_context) = 'winner';
     UPDATE variant_canonical_decisions
        SET status='superseded',
            superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            supersede_reason='replaced_by_new_winner'
      WHERE group_id=(SELECT group_id FROM variant_review_context)
        AND status='active'
        AND (SELECT review_type FROM variant_review_context)='winner';
     INSERT INTO variant_canonical_decisions(
       group_id, selected_gid, source_review_id, policy_revision_id,
       member_fingerprint, status)
       SELECT context.group_id, context.selected_gid, context.review_id,
              context.policy_revision_id,
              (SELECT json_group_array(gid) FROM (
                 SELECT gid FROM gallery_variants
                  WHERE group_id=context.group_id AND membership_state='confirmed'
                  ORDER BY gid
               )),
              'active'
         FROM variant_review_context AS context
       WHERE context.review_type='winner';
     UPDATE variant_review_context
        SET canonical_decision_id=last_insert_rowid()
      WHERE review_type='winner';
     INSERT INTO variant_evaluations(
       group_id, policy_revision_id, supersedes_evaluation_id, state,
       metadata_snapshot_json, member_scores_json, selected_canonical_gid,
       tied_gids_json, canonical_decision_id)
       SELECT context.group_id, old.policy_revision_id, old.id, 'completed',
              old.metadata_snapshot_json,
              old.member_scores_json,
              context.selected_gid, NULL, context.canonical_decision_id
         FROM variant_review_context AS context
         JOIN variant_evaluations AS old ON old.id = context.evaluation_id
        WHERE context.review_type = 'winner';
     UPDATE gallery_variants
        SET variant_score = (SELECT json_extract(item.value, '$.score')
                               FROM variant_evaluations AS current
                               JOIN json_each(current.member_scores_json) AS item
                              WHERE current.id = last_insert_rowid()
                                AND CAST(json_extract(item.value, '$.gid') AS INTEGER) = gallery_variants.gid),
            variant_state = CASE WHEN gid = (SELECT selected_gid FROM variant_review_context)
                                 THEN 'canonical' ELSE 'alternate' END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_review_context)
        AND membership_state = 'confirmed'
        AND (SELECT review_type FROM variant_review_context) = 'winner';
     UPDATE variant_reviews
        SET status = 'resolved', decision = :decision,
            selected_gid = CASE WHEN review_type = 'winner' THEN :selected_gid ELSE NULL END,
            resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            evidence_json = CASE WHEN review_type = 'candidate_identity' THEN
              json_set(evidence_json,
                '$.source_snapshot', json_object(
                  'gid', (SELECT source_gid FROM variant_review_context)),
                '$.candidate_snapshot', json_object(
                  'gid', (SELECT candidate_gid FROM variant_review_context)))
              ELSE evidence_json END
      WHERE id = (SELECT review_id FROM variant_review_context);
     INSERT INTO gallery_identity_pairs(low_gid, high_gid, current_review_id)
       SELECT MIN(source_gid, candidate_gid), MAX(source_gid, candidate_gid), review_id
         FROM variant_review_context
        WHERE review_type = 'candidate_identity'
     ON CONFLICT(low_gid, high_gid) DO UPDATE SET
       current_review_id = excluded.current_review_id;
     UPDATE variant_groups
        SET active_evaluation_id = CASE WHEN (SELECT review_type FROM variant_review_context) = 'winner'
                                       THEN last_insert_rowid() ELSE active_evaluation_id END,
            canonical_gid = CASE WHEN (SELECT review_type FROM variant_review_context) = 'winner'
                                 THEN (SELECT selected_gid FROM variant_review_context) ELSE canonical_gid END,
            review_state = CASE
              WHEN EXISTS (SELECT 1 FROM variant_reviews AS pending
                            WHERE pending.status = 'pending'
                              AND pending.superseded_at IS NULL
                              AND pending.review_type = 'candidate_identity'
                              AND (pending.group_id = variant_groups.id OR EXISTS (
                                SELECT 1
                                  FROM gallery_variants AS pending_member
                                  JOIN gallery_variants AS grouped_member
                                    ON grouped_member.gid = pending_member.gid
                                   AND grouped_member.membership_state = 'confirmed'
                                 WHERE pending_member.group_id = pending.group_id
                                   AND pending_member.membership_state = 'confirmed'
                                   AND grouped_member.group_id = variant_groups.id
                              ))) THEN 'candidate_pending'
              WHEN EXISTS (SELECT 1 FROM variant_reviews AS pending
                            WHERE pending.group_id = variant_groups.id AND pending.status = 'pending'
                              AND pending.superseded_at IS NULL
                              AND pending.review_type = 'winner') THEN 'winner_pending'
              ELSE 'none' END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT survivor_group_id FROM variant_review_context)
         OR ((SELECT review_type FROM variant_review_context) = 'candidate_identity'
             AND (id = (SELECT group_id FROM variant_review_context)
               OR id IN (SELECT group_id FROM variant_review_merge_groups)));
     UPDATE variant_jobs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL,
            last_error='evaluation superseded by manual canonical decision',
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=(SELECT group_id FROM variant_review_context)
        AND job_type='evaluate' AND status='queued'
        AND (SELECT review_type FROM variant_review_context)='winner';
     UPDATE variant_jobs
        SET priority = MAX(priority, 1000),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT survivor_group_id FROM variant_review_context)
        AND job_type = 'evaluate' AND status = 'queued'
        AND (SELECT review_type FROM variant_review_context) = 'candidate_identity';
     INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
       SELECT 'evaluate', survivor_group_id, source_gid, 1000, 'queued'
         FROM variant_review_context
        WHERE review_type = 'candidate_identity';
     UPDATE variant_jobs
        SET priority = MAX(priority, 1000),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_review_context)
        AND job_type = 'reconcile_actions' AND status = 'queued'
        AND (SELECT review_type FROM variant_review_context) = 'winner';
     INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
       SELECT 'reconcile_actions', group_id, source_gid, 1000, 'queued'
         FROM variant_review_context
        WHERE review_type = 'winner';
     $(variants_identity_reconcile_sql)
     SELECT CASE WHEN EXISTS (SELECT 1 FROM variant_review_context)
       THEN (SELECT json_object(
               'resolved', json('true'), 'review_id', review_id,
               'review_type', review_type, 'decision', :decision,
               'source_gid', source_gid, 'candidate_gid', candidate_gid,
               'selected_gid', selected_gid,
               'canonical_decision_id', canonical_decision_id,
               'selection_source', CASE WHEN review_type='winner' THEN 'manual' ELSE NULL END,
               'evaluation_created', json(CASE WHEN review_type = 'winner' THEN 'true' ELSE 'false' END),
               'reevaluation_queued', json(CASE WHEN review_type = 'candidate_identity' THEN 'true' ELSE 'false' END),
               'merged_group', json(CASE WHEN :decision='same_book'
                                           AND (SELECT COUNT(*) FROM variant_review_merge_groups)>1
                                         THEN 'true' ELSE 'false' END),
               'reviews_collapsed', CASE WHEN review_type='candidate_identity'
                 THEN MAX(COALESCE((SELECT covered_reviews FROM variant_review_effort),1)-1,0)
                 ELSE 0 END,
               'groups_unblocked', CASE WHEN review_type='candidate_identity' THEN (
                 SELECT COUNT(*) FROM variant_review_previously_blocked AS blocked
                  JOIN variant_groups AS current ON current.id=blocked.group_id
                 WHERE current.is_active=1 AND current.review_state<>'candidate_pending'
               ) ELSE 0 END
             ) FROM variant_review_context)
       WHEN EXISTS (SELECT 1 FROM variant_review_conflict)
       THEN '__identity_conflict__'
       ELSE '' END;
     COMMIT;")" || return

  if [[ "${result}" == "__identity_conflict__" ]]; then
    log_err "Review ${review_id} conflicts with an existing gallery identity decision; reset the affected GID before splitting a same-book group."
    return "${VARIANTS_IDENTITY_CONFLICT_STATUS}"
  fi
  if [[ -z "${result}" ]]; then
    log_err "Review ${review_id} is stale or its decision no longer matches current state."
    return "${VARIANTS_REVIEW_STALE_STATUS}"
  fi
  printf '%s\n' "${result}"
}

cmd_variants() {
  local subcommand="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "${subcommand}" in
  enqueue)
    if [[ $# -ne 1 ]]; then
      log_err "Usage: yomiko variants enqueue <gid>"
      return 1
    fi
    variants_enqueue_group "$1" >/dev/null || return
    if yomiko_in_api_mode; then
      printf '{"variant_queued":true}\n'
    else
      log "Queued variant discovery for GID $1."
    fi
    ;;
  list)
    local gid=0 status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --gid=*) gid="${1#*=}"; shift ;;
      --gid)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --gid."; return 1; }
        gid="$2"; shift 2 ;;
      --status=*) status="${1#*=}"; shift ;;
      --status)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --status."; return 1; }
        status="$2"; shift 2 ;;
      *) log_err "Unknown variants list option: $1"; return 1 ;;
      esac
    done
    variants_list_json "${gid}" "${status}"
    ;;
  evaluate)
    if [[ $# -ne 1 ]]; then
      log_err "Usage: yomiko variants evaluate <gid>"
      return 1
    fi
    variants_evaluate_gid "$1"
    ;;
  reviews)
    local review_status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --status=*) review_status="${1#*=}"; shift ;;
      --status)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --status."; return 1; }
        review_status="$2"; shift 2 ;;
      *) log_err "Unknown variants reviews option: $1"; return 1 ;;
      esac
    done
    variants_reviews_json "${review_status}"
    ;;
  resolve)
    [[ $# -ge 1 ]] || { log_err "Usage: yomiko variants resolve <review-id> --decision <same-book|different-book|winner> [--gid GID]"; return 1; }
    local review_id="$1" resolve_decision="" resolve_gid=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --decision=*) resolve_decision="${1#*=}"; shift ;;
      --decision)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --decision."; return 1; }
        resolve_decision="$2"; shift 2 ;;
      --gid=*) resolve_gid="${1#*=}"; shift ;;
      --gid)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --gid."; return 1; }
        resolve_gid="$2"; shift 2 ;;
      *) log_err "Unknown variants resolve option: $1"; return 1 ;;
      esac
    done
    [[ -n "${resolve_decision}" ]] || { log_err "Missing value for --decision."; return 1; }
    variants_resolve_review "${review_id}" "${resolve_decision}" "${resolve_gid}"
    ;;
  ungroup)
    local ungroup_force=0
    local -a ungroup_gids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --force) ungroup_force=1; shift ;;
      --*) log_err "Unknown variants ungroup option: $1"; return 1 ;;
      *) ungroup_gids+=("$1"); shift ;;
      esac
    done
    ((${#ungroup_gids[@]} > 0)) || {
      log_err "Usage: yomiko variants ungroup <gid>... [--force]"
      return 1
    }
    variants_ungroup "${ungroup_force}" "${ungroup_gids[@]}"
    ;;
  policy-show) variants_policy_show "$@" ;;
  policy-check) variants_policy_check "$@" ;;
  policy-activate) variants_policy_activate "$@" ;;
  work) variants_work "$@" ;;
  *)
    log_err "Usage: yomiko variants <enqueue|list|work|evaluate|reviews|resolve|ungroup|policy-show|policy-check|policy-activate>"
    return 1
    ;;
  esac
}
