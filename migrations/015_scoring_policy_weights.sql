-- Apply the requested scoring weights to the active policy while preserving
-- unrelated operator-owned policy choices. Hashes are finalized by db_init
-- after this migration commits because SQLite has no portable SHA-256
-- primitive.
CREATE TEMP TABLE migration_015_policy (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    old_revision_id INTEGER NOT NULL,
    new_revision_id INTEGER
);

INSERT INTO migration_015_policy(singleton, old_revision_id)
SELECT 1, id
  FROM variant_policy_revisions
 WHERE is_active = 1
   AND (
       json_extract(policy_json, '$.scoring.expunged_adjustment') <> -2000
       OR json_extract(policy_json, '$.scoring.favorite_popularity.cap') <> 400
       OR json_extract(policy_json, '$.scoring.rating_confidence.cap') <> 400
       OR json_extract(policy_json, '$.scoring.posted_rank.step') <> 5
       OR json_extract(policy_json, '$.scoring.tag_scores."other:full color"') <> 500
       OR json_extract(policy_json, '$.scoring.tag_scores."other:uncensored"') <> 500
   );

INSERT INTO variant_policy_revisions(
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash,
    is_active, activated_at
)
SELECT json_set(
           old.policy_json,
           '$.scoring.expunged_adjustment', -2000,
           '$.scoring.favorite_popularity.cap', 400,
           '$.scoring.rating_confidence.cap', 400,
           '$.scoring.posted_rank.step', 5,
           '$.scoring.tag_scores."other:full color"', 500,
           '$.scoring.tag_scores."other:uncensored"', 500
       ),
       printf('%064d', 0), old.matching_hash, printf('%064d', 0),
       old.operations_hash, 0,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM migration_015_policy AS context
  JOIN variant_policy_revisions AS old
    ON old.id = context.old_revision_id;

UPDATE migration_015_policy
   SET new_revision_id = last_insert_rowid();

UPDATE variant_policy_revisions
   SET is_active = 0
 WHERE id = (SELECT old_revision_id FROM migration_015_policy);

UPDATE variant_policy_revisions
   SET is_active = 1,
       activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = (SELECT new_revision_id FROM migration_015_policy);

INSERT OR IGNORE INTO variant_jobs(job_type, priority, status, scoring_revision_id)
SELECT 'policy_scoring_sweep', 500, 'queued', new_revision_id
  FROM migration_015_policy
 WHERE EXISTS (SELECT 1 FROM variant_groups);

UPDATE variant_jobs
   SET priority = MAX(priority, 500),
       scoring_revision_id = (SELECT new_revision_id FROM migration_015_policy),
       continuation_cursor_json = NULL,
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'policy_scoring_sweep'
   AND status IN ('queued', 'leased')
   AND EXISTS (SELECT 1 FROM migration_015_policy);

DROP TABLE migration_015_policy;
