-- Canonicalize Priority 1 persisted names while leaving historical migrations
-- untouched.  The public CLI/API adapters continue to expose their legacy
-- spellings until a separate contract migration.

-- Abort before changing any row when a mixed legacy/canonical JSON object is
-- ambiguous.  JSON null is a value here: a present null and a present non-null
-- value are different values and must be inspected by the operator.
CREATE TEMP TABLE migration_021_json_conflicts(
    source TEXT NOT NULL,
    row_id TEXT NOT NULL,
    field TEXT NOT NULL,
    PRIMARY KEY(source, row_id, field)
);

INSERT INTO migration_021_json_conflicts(source, row_id, field)
SELECT 'gallery_variants.metadata_snapshot', group_id || ':' || gid, 'first_token'
  FROM gallery_variants
 WHERE json_type(metadata_snapshot_json, '$.first_key') IS NOT NULL
   AND json_type(metadata_snapshot_json, '$.first_token') IS NOT NULL
   AND NOT (json_extract(metadata_snapshot_json, '$.first_key') IS json_extract(metadata_snapshot_json, '$.first_token'))
UNION ALL
SELECT 'gallery_variants.metadata_snapshot', group_id || ':' || gid, 'parent_token'
  FROM gallery_variants
 WHERE json_type(metadata_snapshot_json, '$.parent_key') IS NOT NULL
   AND json_type(metadata_snapshot_json, '$.parent_token') IS NOT NULL
   AND NOT (json_extract(metadata_snapshot_json, '$.parent_key') IS json_extract(metadata_snapshot_json, '$.parent_token'))
UNION ALL
SELECT 'gallery_variants.metadata_snapshot', group_id || ':' || gid, 'current_token'
  FROM gallery_variants
 WHERE json_type(metadata_snapshot_json, '$.current_key') IS NOT NULL
   AND json_type(metadata_snapshot_json, '$.current_token') IS NOT NULL
   AND NOT (json_extract(metadata_snapshot_json, '$.current_key') IS json_extract(metadata_snapshot_json, '$.current_token'))
UNION ALL
SELECT 'variant_discovery_candidates.gdata', run_id || ':' || gid || ':' || token, 'first_token'
  FROM variant_discovery_candidates
 WHERE json_type(gdata_json, '$.first_key') IS NOT NULL
   AND json_type(gdata_json, '$.first_token') IS NOT NULL
   AND NOT (json_extract(gdata_json, '$.first_key') IS json_extract(gdata_json, '$.first_token'))
UNION ALL
SELECT 'variant_discovery_candidates.gdata', run_id || ':' || gid || ':' || token, 'parent_token'
  FROM variant_discovery_candidates
 WHERE json_type(gdata_json, '$.parent_key') IS NOT NULL
   AND json_type(gdata_json, '$.parent_token') IS NOT NULL
   AND NOT (json_extract(gdata_json, '$.parent_key') IS json_extract(gdata_json, '$.parent_token'))
UNION ALL
SELECT 'variant_discovery_candidates.gdata', run_id || ':' || gid || ':' || token, 'current_token'
  FROM variant_discovery_candidates
 WHERE json_type(gdata_json, '$.current_key') IS NOT NULL
   AND json_type(gdata_json, '$.current_token') IS NOT NULL
   AND NOT (json_extract(gdata_json, '$.current_key') IS json_extract(gdata_json, '$.current_token'))
UNION ALL
SELECT 'variant_reviews.evidence.source', id, 'first_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.source_snapshot.first_key') IS NOT NULL
   AND json_type(evidence_json, '$.source_snapshot.first_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.source_snapshot.first_key') IS json_extract(evidence_json, '$.source_snapshot.first_token'))
UNION ALL
SELECT 'variant_reviews.evidence.candidate', id, 'first_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.candidate_snapshot.first_key') IS NOT NULL
   AND json_type(evidence_json, '$.candidate_snapshot.first_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.candidate_snapshot.first_key') IS json_extract(evidence_json, '$.candidate_snapshot.first_token'))
UNION ALL
SELECT 'variant_reviews.evidence.source', id, 'parent_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.source_snapshot.parent_key') IS NOT NULL
   AND json_type(evidence_json, '$.source_snapshot.parent_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.source_snapshot.parent_key') IS json_extract(evidence_json, '$.source_snapshot.parent_token'))
UNION ALL
SELECT 'variant_reviews.evidence.candidate', id, 'parent_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.candidate_snapshot.parent_key') IS NOT NULL
   AND json_type(evidence_json, '$.candidate_snapshot.parent_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.candidate_snapshot.parent_key') IS json_extract(evidence_json, '$.candidate_snapshot.parent_token'))
UNION ALL
SELECT 'variant_reviews.evidence.source', id, 'current_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.source_snapshot.current_key') IS NOT NULL
   AND json_type(evidence_json, '$.source_snapshot.current_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.source_snapshot.current_key') IS json_extract(evidence_json, '$.source_snapshot.current_token'))
UNION ALL
SELECT 'variant_reviews.evidence.candidate', id, 'current_token'
  FROM variant_reviews
 WHERE json_type(evidence_json, '$.candidate_snapshot.current_key') IS NOT NULL
   AND json_type(evidence_json, '$.candidate_snapshot.current_token') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.candidate_snapshot.current_key') IS json_extract(evidence_json, '$.candidate_snapshot.current_token'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key, 'first_token'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.first_key') IS NOT NULL
   AND json_type(item.value, '$.first_token') IS NOT NULL
   AND NOT (json_extract(item.value, '$.first_key') IS json_extract(item.value, '$.first_token'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key, 'parent_token'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.parent_key') IS NOT NULL
   AND json_type(item.value, '$.parent_token') IS NOT NULL
   AND NOT (json_extract(item.value, '$.parent_key') IS json_extract(item.value, '$.parent_token'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key, 'current_token'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.current_key') IS NOT NULL
   AND json_type(item.value, '$.current_token') IS NOT NULL
   AND NOT (json_extract(item.value, '$.current_key') IS json_extract(item.value, '$.current_token'))
UNION ALL
SELECT 'variant_jobs.cursor', id, 'target_policy_revision_id'
  FROM variant_jobs
 WHERE json_type(continuation_cursor_json, '$.target_revision_id') IS NOT NULL
   AND json_type(continuation_cursor_json, '$.target_policy_revision_id') IS NOT NULL
   AND NOT (json_extract(continuation_cursor_json, '$.target_revision_id') IS json_extract(continuation_cursor_json, '$.target_policy_revision_id'));

CREATE TEMP TABLE migration_021_abort_conflicts(value INTEGER NOT NULL CHECK(value = 0));
CREATE TEMP TRIGGER migration_021_abort_mixed_json
BEFORE INSERT ON migration_021_abort_conflicts
WHEN EXISTS (SELECT 1 FROM migration_021_json_conflicts)
BEGIN
    SELECT RAISE(ABORT, 'migration 021 found conflicting legacy and canonical JSON names');
END;
INSERT INTO migration_021_abort_conflicts(value) VALUES (0);

-- Rename the relational columns. galleries.rating is intentionally retained
-- because it has the same meaning and name as the ExHentai API field.
DROP VIEW IF EXISTS variant_job_diagnostics;
ALTER TABLE galleries RENAME COLUMN first_key TO first_token;
ALTER TABLE galleries RENAME COLUMN parent_key TO parent_token;
ALTER TABLE galleries RENAME COLUMN current_key TO current_token;
ALTER TABLE variant_actions RENAME COLUMN decision_revision_id TO policy_revision_id;
ALTER TABLE variant_jobs RENAME COLUMN scoring_revision_id TO target_policy_revision_id;
ALTER TABLE variant_evaluations RENAME COLUMN selected_canonical_gid TO canonical_gid;
ALTER TABLE variant_canonical_decisions RENAME COLUMN selected_gid TO canonical_gid;
ALTER TABLE variant_reviews RENAME COLUMN selected_gid TO canonical_gid;

-- Recreate the policy-target index with its canonical name. SQLite updates
-- references in trigger/view definitions when columns are renamed, while
-- index identifiers themselves are not renamed.
DROP INDEX IF EXISTS idx_variant_jobs_scoring_target;
CREATE INDEX idx_variant_jobs_policy_target
ON variant_jobs(job_type, target_policy_revision_id, status, id);

-- SQLite cannot update a view that still refers to a renamed column. Recreate
-- the diagnostics projection with the canonical policy-target name.
CREATE VIEW variant_job_diagnostics AS
WITH current_reconcile_groups AS (
    SELECT group_id FROM variant_jobs
     WHERE job_type = 'reconcile_actions' AND status IN ('queued', 'leased')
), current_action_rows AS (
    SELECT action.* FROM variant_actions AS action
    JOIN current_reconcile_groups AS current ON current.group_id = action.group_id
     WHERE action.status IN ('pending', 'retryable_error', 'configuration_error', 'in_flight')
), action_counts AS (
    SELECT group_id,
           SUM(status = 'pending') AS pending_action_count,
           SUM(status IN ('retryable_error', 'configuration_error')) AS action_error_count,
           SUM(status = 'in_flight') AS in_flight_action_count,
           SUM(status = 'in_flight' AND lease_expires_at IS NOT NULL
               AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) AS expired_action_lease_count,
           MIN(CASE WHEN status IN ('pending', 'retryable_error', 'configuration_error') THEN available_at END) AS next_action_available_at,
           MIN(CASE WHEN status = 'in_flight' AND lease_expires_at IS NOT NULL THEN lease_expires_at END) AS earliest_action_lease_expires_at,
           MIN(CASE WHEN status = 'in_flight' AND lease_expires_at IS NOT NULL
                    AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN lease_expires_at END) AS earliest_expired_action_lease_at
      FROM current_action_rows GROUP BY group_id
), active_action_lines AS (
    SELECT group_id, available_at, id,
           'id=' || id || ' gid=' || gid ||
           ' type=' || replace(replace(replace(action_type, char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' desired=' || replace(replace(replace(desired_value, char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' status=' || replace(replace(replace(status, char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' attempts=' || attempt_count || ' available_at=' || available_at AS line
      FROM current_action_rows
), active_action_summaries AS (
    SELECT group_id, group_concat(line, char(10)) AS active_actions FROM (
      SELECT group_id, line FROM active_action_lines ORDER BY group_id, available_at, id
    ) GROUP BY group_id
), action_error_lines AS (
    SELECT group_id, available_at, id,
           'id=' || id || ' gid=' || gid ||
           ' type=' || replace(replace(replace(action_type, char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' status=' || replace(replace(replace(status, char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' class=' || replace(replace(replace(COALESCE(last_error_class, ''), char(13), ' '), char(10), ' '), char(9), ' ') ||
           ' error=' || replace(replace(replace(COALESCE(last_error, ''), char(13), ' '), char(10), ' '), char(9), ' ') AS line
      FROM current_action_rows WHERE status IN ('retryable_error', 'configuration_error')
), action_error_summaries AS (
    SELECT group_id, group_concat(line, char(10)) AS action_errors FROM (
      SELECT group_id, line FROM action_error_lines ORDER BY group_id, available_at, id
    ) GROUP BY group_id
), job_rows AS (
    SELECT job.id AS job_id, job.job_type, job.group_id, job.source_gid, job.priority, job.status,
           job.attempt_count AS job_attempt_count, job.available_at AS job_available_at,
           job.lease_owner, job.lease_expires_at, job.target_policy_revision_id,
           job.continuation_cursor_json, job.created_at, job.updated_at, job.completed_at,
           job.last_error_class AS job_error_class, job.last_error AS job_error,
           CASE WHEN job.status = 'queued' AND job.available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN 1 ELSE 0 END AS schedule_due,
           CASE WHEN job.status = 'leased' AND job.lease_expires_at IS NOT NULL
                     AND job.lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN 1 ELSE 0 END AS job_lease_expired,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN COALESCE(counts.pending_action_count, 0) ELSE 0 END AS pending_action_count,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN COALESCE(counts.action_error_count, 0) ELSE 0 END AS action_error_count,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN COALESCE(counts.in_flight_action_count, 0) ELSE 0 END AS in_flight_action_count,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN COALESCE(counts.expired_action_lease_count, 0) ELSE 0 END AS expired_action_lease_count,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN COALESCE(counts.pending_action_count, 0) + COALESCE(counts.action_error_count, 0) + COALESCE(counts.in_flight_action_count, 0) ELSE 0 END AS active_action_count,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN counts.next_action_available_at END AS next_action_available_at,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN counts.earliest_action_lease_expires_at END AS earliest_action_lease_expires_at,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN counts.earliest_expired_action_lease_at END AS earliest_expired_action_lease_at,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN active.active_actions END AS active_actions,
           CASE WHEN job.job_type = 'reconcile_actions' AND job.status IN ('queued', 'leased') THEN errors.action_errors END AS action_errors
      FROM variant_jobs AS job
      LEFT JOIN action_counts AS counts ON counts.group_id = job.group_id
      LEFT JOIN active_action_summaries AS active ON active.group_id = job.group_id
      LEFT JOIN action_error_summaries AS errors ON errors.group_id = job.group_id
), classified_jobs AS (
    SELECT job_rows.*,
           CASE WHEN status IN ('completed', 'failed', 'cancelled') THEN status
                WHEN job_lease_expired = 1 THEN 'expired_job_lease'
                WHEN expired_action_lease_count > 0 THEN 'expired_action_lease'
                WHEN NULLIF(TRIM(job_error), '') IS NOT NULL THEN 'job_error'
                WHEN action_error_count > 0 THEN 'action_error'
                WHEN status = 'leased' THEN 'leased'
                WHEN schedule_due = 0 AND status = 'queued' THEN 'scheduled'
                WHEN schedule_due = 1 AND status = 'queued' THEN 'ready'
                ELSE 'unknown' END AS diagnostic_state
      FROM job_rows
), wait_times AS (
    SELECT classified_jobs.*,
           CASE WHEN status IN ('completed', 'failed', 'cancelled') OR job_lease_expired = 1 OR expired_action_lease_count > 0 THEN NULL
                WHEN status = 'leased' AND lease_expires_at IS NOT NULL THEN lease_expires_at
                WHEN status = 'queued' AND job_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN job_available_at
                WHEN status = 'queued' AND next_action_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN next_action_available_at
                ELSE NULL END AS wait_until
      FROM classified_jobs
)
SELECT job_id, job_type, group_id, source_gid, priority, status, job_attempt_count,
       job_available_at, lease_owner, lease_expires_at, target_policy_revision_id,
       continuation_cursor_json, created_at, updated_at, completed_at, job_error_class,
       job_error, schedule_due, job_lease_expired, diagnostic_state, wait_until,
       active_action_count, pending_action_count, action_error_count, in_flight_action_count,
       expired_action_lease_count, next_action_available_at, earliest_action_lease_expires_at,
       active_actions, action_errors,
       CASE WHEN job_lease_expired = 1 THEN 'job lease expired at ' || lease_expires_at
            WHEN expired_action_lease_count > 0 THEN 'action lease expired at ' || earliest_expired_action_lease_at
            WHEN NULLIF(TRIM(job_error), '') IS NOT NULL THEN 'job error: ' || replace(replace(replace(job_error, char(13), ' '), char(10), ' '), char(9), ' ')
            WHEN action_error_count > 0 THEN 'current action errors: ' || action_errors
            WHEN status = 'leased' THEN 'leased by ' || COALESCE(lease_owner, 'unknown owner') || ' until ' || COALESCE(lease_expires_at, 'unknown')
            WHEN status = 'queued' AND job_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN 'job available at ' || job_available_at
            WHEN status = 'queued' AND next_action_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now') THEN 'next action available at ' || next_action_available_at
            WHEN active_action_count > 0 AND in_flight_action_count > 0 THEN 'active actions are in flight'
            WHEN active_action_count > 0 THEN 'active actions are waiting'
            WHEN status = 'queued' AND schedule_due = 1 THEN 'queued job is ready to run'
            WHEN status IN ('completed', 'failed', 'cancelled') THEN 'job is ' || status
            ELSE 'no current blocker recorded' END AS reason
  FROM wait_times;

-- Rewrite gallery metadata snapshots and discovery staging snapshots for the
-- renamed chain fields. The ExHentai-compatible rating key is retained.
UPDATE gallery_variants
   SET metadata_snapshot_json = json_remove(
     json_set(json_set(json_set(metadata_snapshot_json,
       '$.first_token', json_extract(metadata_snapshot_json, '$.first_key')),
       '$.parent_token', json_extract(metadata_snapshot_json, '$.parent_key')),
       '$.current_token', json_extract(metadata_snapshot_json, '$.current_key')),
     '$.first_key', '$.parent_key', '$.current_key');

UPDATE variant_discovery_candidates
   SET gdata_json = json_remove(
     json_set(json_set(json_set(gdata_json,
       '$.first_token', json_extract(gdata_json, '$.first_key')),
       '$.parent_token', json_extract(gdata_json, '$.parent_key')),
       '$.current_token', json_extract(gdata_json, '$.current_key')),
     '$.first_key', '$.parent_key', '$.current_key')
 WHERE gdata_json IS NOT NULL;

-- Immutable evaluation snapshots are arrays of compact metadata objects.
-- Preserve array order, nulls, and all unrelated fields while rewriting each
-- object independently.
DROP TRIGGER variant_evaluations_no_update;
UPDATE variant_evaluations
   SET metadata_snapshot_json = (
     SELECT COALESCE(json_group_array(json(item.value)), json('[]'))
       FROM (
         SELECT json_remove(
           json_set(json_set(json_set(value,
             '$.first_token', json_extract(value, '$.first_key')),
             '$.parent_token', json_extract(value, '$.parent_key')),
             '$.current_token', json_extract(value, '$.current_key')),
           '$.first_key', '$.parent_key', '$.current_key') AS value
           FROM json_each(variant_evaluations.metadata_snapshot_json)
          ORDER BY CAST(key AS INTEGER)
       ) AS item
   )
 WHERE json_type(metadata_snapshot_json) = 'array';
CREATE TRIGGER variant_evaluations_no_update
BEFORE UPDATE ON variant_evaluations
BEGIN
    SELECT RAISE(ABORT, 'variant evaluations are immutable');
END;

-- Review evidence freezes source/candidate metadata under these two known
-- paths. Resolved candidate snapshots may already be GID-only objects.
UPDATE variant_reviews
   SET evidence_json = json_set(evidence_json, '$.source_snapshot',
     json(json_remove(json_set(json_set(json_set(
       json_extract(evidence_json, '$.source_snapshot'),
       '$.first_token', json_extract(evidence_json, '$.source_snapshot.first_key')),
       '$.parent_token', json_extract(evidence_json, '$.source_snapshot.parent_key')),
       '$.current_token', json_extract(evidence_json, '$.source_snapshot.current_key')),
       '$.first_key', '$.parent_key', '$.current_key')))
 WHERE json_type(evidence_json, '$.source_snapshot') = 'object';

UPDATE variant_reviews
   SET evidence_json = json_set(evidence_json, '$.candidate_snapshot',
     json(json_remove(json_set(json_set(json_set(
       json_extract(evidence_json, '$.candidate_snapshot'),
       '$.first_token', json_extract(evidence_json, '$.candidate_snapshot.first_key')),
       '$.parent_token', json_extract(evidence_json, '$.candidate_snapshot.parent_key')),
       '$.current_token', json_extract(evidence_json, '$.candidate_snapshot.current_key')),
       '$.first_key', '$.parent_key', '$.current_key')))
 WHERE json_type(evidence_json, '$.candidate_snapshot') = 'object';

-- Matching evidence is stored as JSON objects/arrays and historically used
-- the word key in the contradiction label. This string is not rewritten in
-- immutable policy revisions; only persisted evidence and future output use
-- the canonical token vocabulary.
UPDATE gallery_variants
   SET evidence_json = replace(evidence_json, 'chain_key_mismatch', 'chain_token_mismatch');
UPDATE variant_discovery_candidates
   SET evidence_json = replace(evidence_json, 'chain_key_mismatch', 'chain_token_mismatch')
 WHERE evidence_json IS NOT NULL;
UPDATE variant_reviews
   SET evidence_json = replace(evidence_json, 'chain_key_mismatch', 'chain_token_mismatch');

-- Policy-sweep cursors are internal durable work state, not public output.
UPDATE variant_jobs
   SET continuation_cursor_json = json_set(
     json_remove(continuation_cursor_json, '$.target_revision_id'),
     '$.target_policy_revision_id',
     json_extract(continuation_cursor_json, '$.target_revision_id'))
 WHERE job_type = 'policy_scoring_sweep'
   AND continuation_cursor_json IS NOT NULL
   AND json_type(continuation_cursor_json, '$.target_revision_id') IS NOT NULL;

DROP TRIGGER migration_021_abort_mixed_json;
DROP TABLE migration_021_abort_conflicts;
DROP TABLE migration_021_json_conflicts;
