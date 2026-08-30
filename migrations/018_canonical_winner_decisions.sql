-- Durable manual canonical selections and optimistic guards for queued
-- evaluations.  The immutable evaluation/review rows remain the audit log;
-- this table is the current decision projection.
CREATE TABLE variant_canonical_decisions (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    selected_gid INTEGER NOT NULL REFERENCES galleries(gid),
    source_review_id INTEGER NOT NULL UNIQUE REFERENCES variant_reviews(id),
    policy_revision_id INTEGER NOT NULL REFERENCES variant_policy_revisions(id),
    member_fingerprint TEXT NOT NULL CHECK (json_valid(member_fingerprint)),
    status TEXT NOT NULL CHECK (status IN ('active', 'superseded', 'reset')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    superseded_at TEXT,
    supersede_reason TEXT,
    CHECK (
      (status = 'active' AND superseded_at IS NULL AND supersede_reason IS NULL)
      OR
      (status <> 'active' AND superseded_at IS NOT NULL AND supersede_reason IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_variant_canonical_decisions_active_group
ON variant_canonical_decisions(group_id)
WHERE status = 'active';
CREATE INDEX idx_variant_canonical_decisions_group
ON variant_canonical_decisions(group_id, id DESC);

CREATE TRIGGER variant_canonical_decisions_validate_member_insert
BEFORE INSERT ON variant_canonical_decisions
WHEN NOT EXISTS (
    SELECT 1 FROM gallery_variants
     WHERE group_id = NEW.group_id
       AND gid = NEW.selected_gid
       AND membership_state = 'confirmed'
)
BEGIN
    SELECT RAISE(ABORT, 'canonical decision must select a confirmed group member');
END;

ALTER TABLE variant_jobs ADD COLUMN expected_evaluation_id INTEGER
    REFERENCES variant_evaluations(id);

UPDATE variant_jobs
   SET expected_evaluation_id = (
         SELECT active_evaluation_id FROM variant_groups
          WHERE id = variant_jobs.group_id
       )
 WHERE job_type = 'evaluate' AND expected_evaluation_id IS NULL;

CREATE TRIGGER variant_jobs_fill_expected_evaluation
AFTER INSERT ON variant_jobs
WHEN NEW.job_type = 'evaluate' AND NEW.expected_evaluation_id IS NULL
BEGIN
    UPDATE variant_jobs
       SET expected_evaluation_id = (
             SELECT active_evaluation_id FROM variant_groups
              WHERE id = NEW.group_id
           )
     WHERE id = NEW.id;
END;

CREATE TRIGGER variant_jobs_validate_expected_evaluation_insert
BEFORE INSERT ON variant_jobs
WHEN NEW.job_type = 'evaluate'
 AND NEW.expected_evaluation_id IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM variant_evaluations
      WHERE id = NEW.expected_evaluation_id AND group_id = NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'expected evaluation must belong to the job group');
END;

CREATE TRIGGER variant_jobs_validate_expected_evaluation_update
BEFORE UPDATE OF job_type, group_id, expected_evaluation_id ON variant_jobs
WHEN NEW.job_type = 'evaluate'
 AND NEW.expected_evaluation_id IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM variant_evaluations
      WHERE id = NEW.expected_evaluation_id AND group_id = NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'expected evaluation must belong to the job group');
END;

-- Backfill only an unambiguous, still-valid resolved winner.  Older resolver
-- rows may have resolved_at == superseded_at because the evaluation trigger
-- ran before the review update; that timestamp equality is an expected form
-- of the historical winner-resolution transaction and is accepted here.
WITH ranked_winners AS (
    SELECT review.id, review.group_id, review.selected_gid,
           review.evaluation_id, review.policy_revision_id,
           review.resolved_at,
           (SELECT json_group_array(gid) FROM (
              SELECT gid FROM gallery_variants
               WHERE group_id = review.group_id AND membership_state='confirmed'
               ORDER BY gid
            )) AS member_fingerprint,
           ROW_NUMBER() OVER (
             PARTITION BY review.group_id
             ORDER BY review.resolved_at DESC, review.id DESC
           ) AS rank
      FROM variant_reviews AS review
     WHERE review.review_type='winner'
       AND review.status='resolved'
       AND review.decision='winner'
       AND review.selected_gid IS NOT NULL
       AND (review.superseded_at IS NULL
            OR review.superseded_at = review.resolved_at)
       AND EXISTS (
           SELECT 1 FROM gallery_variants AS member
            WHERE member.group_id=review.group_id
              AND member.gid=review.selected_gid
              AND member.membership_state='confirmed'
       )
)
INSERT INTO variant_canonical_decisions(
    group_id, selected_gid, source_review_id, policy_revision_id,
    member_fingerprint, status
)
SELECT group_id, selected_gid, id, policy_revision_id,
       member_fingerprint, 'active'
  FROM ranked_winners
 WHERE rank=1;

UPDATE variant_reviews AS review
   SET superseded_at=COALESCE(review.superseded_at,
                              strftime('%Y-%m-%dT%H:%M:%SZ','now'))
 WHERE review.review_type='winner'
   AND review.status='pending'
   AND review.superseded_at IS NULL
   AND EXISTS (
       SELECT 1 FROM variant_canonical_decisions AS decision
        WHERE decision.group_id=review.group_id
          AND decision.status='active'
          AND EXISTS (
              SELECT 1 FROM json_each(review.choices_json) AS choice
               WHERE CAST(choice.value AS INTEGER)=decision.selected_gid
          )
   );

UPDATE gallery_variants AS member
   SET variant_state=CASE WHEN member.gid=decision.selected_gid
                          THEN 'canonical' ELSE 'alternate' END,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM variant_canonical_decisions AS decision
 WHERE decision.status='active'
   AND decision.group_id=member.group_id
   AND member.membership_state='confirmed';

UPDATE variant_groups AS grouped
   SET canonical_gid=(SELECT decision.selected_gid
                        FROM variant_canonical_decisions AS decision
                       WHERE decision.group_id=grouped.id
                         AND decision.status='active'),
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE EXISTS (SELECT 1 FROM variant_canonical_decisions AS decision
                WHERE decision.group_id=grouped.id AND decision.status='active');
