-- Replace the code-owned matching document while preserving the operator's
-- compact scoring projection and every prior immutable policy revision. The
-- shell migration finalizer in lib/db.sh replaces the temporary hash values
-- with SHA-256 hashes after SQLite commits this transaction.
CREATE TEMP TABLE migration_014_policy(
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    old_revision_id INTEGER NOT NULL,
    new_revision_id INTEGER
);

INSERT INTO migration_014_policy(singleton, old_revision_id)
SELECT 1, id
  FROM variant_policy_revisions
 WHERE is_active=1
   AND json_type(policy_json,'$.matching.official_chain_visibility') IS NULL;

INSERT INTO variant_policy_revisions(
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash,
    is_active, activated_at
)
SELECT json_set(
         old.policy_json,
         '$.matching.official_chain_visibility',
         json('{"eligible":"current_gid_is_null_or_equals_gid","replaced":"current_gid_is_non_null_and_differs_from_gid","retain_replaced_history":true,"validate_references_as_pairs":true}'),
         '$.matching.visible_contradictions',
         json_insert(json_extract(old.policy_json,'$.matching.visible_contradictions'),
           '$[#]','chain_reference_invalid',
           '$[#]','chain_key_mismatch',
           '$[#]','chain_conflict',
           '$[#]','chain_cycle',
           '$[#]','chain_branch',
           '$[#]','chain_multiple_terminals')
       ),
       printf('%064d', old.id),
       printf('%064d', old.id + 1000000000),
       old.scoring_hash,
       old.operations_hash,
       0,
       strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM migration_014_policy AS context
  JOIN variant_policy_revisions AS old
    ON old.id=context.old_revision_id;

UPDATE migration_014_policy
   SET new_revision_id=last_insert_rowid();

UPDATE variant_policy_revisions
   SET is_active=0
 WHERE id=(SELECT old_revision_id FROM migration_014_policy);

UPDATE variant_policy_revisions
   SET is_active=1,
       activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id=(SELECT new_revision_id FROM migration_014_policy);

UPDATE variant_jobs
   SET priority=MAX(priority,500),
       available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       continuation_cursor_json=NULL,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE job_type='discover' AND status='queued'
   AND group_id IN (SELECT id FROM variant_groups WHERE is_active=1);

INSERT OR IGNORE INTO variant_jobs(job_type,group_id,source_gid,priority,status)
SELECT 'discover', grouped.id, grouped.source_gid, 500, 'queued'
  FROM variant_groups AS grouped
 WHERE grouped.is_active=1;

UPDATE variant_discovery_runs
   SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       last_error_class='uncertain',
       last_error='matching policy changed; rediscovery restarted'
 WHERE group_id IN (SELECT id FROM variant_groups WHERE is_active=1)
   AND status='running';

DROP TABLE migration_014_policy;
