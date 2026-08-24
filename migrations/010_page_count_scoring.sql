-- Add the default canonical page-count score without rewriting an operator's
-- customized policy. Older expanded policies remain executable; only the
-- known migration-006 default is advanced automatically.
CREATE TEMP TABLE migration_010_policy (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    old_revision_id INTEGER NOT NULL,
    new_revision_id INTEGER
);

INSERT INTO migration_010_policy(singleton, old_revision_id)
SELECT 1, id
  FROM variant_policy_revisions
 WHERE is_active = 1
   AND content_hash = 'da687dc4a0474cec0e02f2005144864e8e655533bfba6b525209e92f2d4e560f';

INSERT OR IGNORE INTO variant_policy_revisions(
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash
)
SELECT json_set(
         old.policy_json,
         '$.scoring.page_count',
         json('{"cap":30,"formula":"min(cap,filecount-offset)","missing_count_points":0,"offset":70}')
       ),
       'e5be1191ab859a44e2823ce35c125ebf93459585be6feb1705d43f4fb3365e2f',
       old.matching_hash,
       '5b0a943e7aaa8dab63b06b8eb792fd6d3c41a25141e5c697ee2e65625a00847b',
       old.operations_hash
  FROM migration_010_policy AS context
  JOIN variant_policy_revisions AS old ON old.id = context.old_revision_id;

UPDATE migration_010_policy
   SET new_revision_id = (
         SELECT id
           FROM variant_policy_revisions
          WHERE content_hash = 'e5be1191ab859a44e2823ce35c125ebf93459585be6feb1705d43f4fb3365e2f'
       );

UPDATE variant_policy_revisions
   SET is_active = 0
 WHERE id = (SELECT old_revision_id FROM migration_010_policy);

UPDATE variant_policy_revisions
   SET is_active = 1,
       activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = (SELECT new_revision_id FROM migration_010_policy);

INSERT OR IGNORE INTO variant_jobs(
    job_type, priority, status, scoring_revision_id
)
SELECT 'policy_scoring_sweep', 500, 'queued', new_revision_id
  FROM migration_010_policy
 WHERE EXISTS (SELECT 1 FROM variant_groups);

UPDATE variant_jobs
   SET priority = MAX(priority, 500),
       scoring_revision_id = (SELECT new_revision_id FROM migration_010_policy),
       continuation_cursor_json = NULL,
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'policy_scoring_sweep'
   AND status IN ('queued', 'leased')
   AND EXISTS (SELECT 1 FROM migration_010_policy);

DROP TABLE migration_010_policy;
