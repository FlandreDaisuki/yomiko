-- Persist the latest authorized H@H attempt separately from the latest
-- confirmed successful request.  This watermark is intentionally conservative:
-- an in-flight action may already have reached the remote service.
ALTER TABLE galleries ADD COLUMN hath_last_attempted_at TEXT;

UPDATE galleries
   SET hath_last_attempted_at = (
         SELECT MAX(candidate.timestamp)
           FROM (
             SELECT galleries.hath_requested_at AS timestamp
             UNION ALL
             SELECT action.last_attempt_at
               FROM variant_actions AS action
              WHERE action.gid = galleries.gid
                AND action.action_type = 'hath_request'
                AND (
                  action.status = 'in_flight'
                  OR json_extract(action.result_json, '$.mutation_sent') = 1
                )
           ) AS candidate
       )
 WHERE hath_requested_at IS NOT NULL
    OR EXISTS (
         SELECT 1
           FROM variant_actions AS action
          WHERE action.gid = galleries.gid
            AND action.action_type = 'hath_request'
            AND (
              action.status = 'in_flight'
              OR json_extract(action.result_json, '$.mutation_sent') = 1
            )
       );

-- Normalize the known blocked rating-11 cleanup state without attempting to
-- infer filesystem truth.  Runtime recovery performs that part under the
-- archive lock.
CREATE TEMP TABLE variant_blocked_recovery_groups(
    group_id INTEGER PRIMARY KEY,
    source_gid INTEGER NOT NULL
);

INSERT INTO variant_blocked_recovery_groups(group_id, source_gid)
SELECT DISTINCT grouped.id, grouped.source_gid
  FROM variant_groups AS grouped
  JOIN variant_actions AS action ON action.group_id = grouped.id
 WHERE grouped.is_active = 1
   AND grouped.desired_rating = 11
   AND action.action_type = 'archive_cleanup'
   AND action.status = 'retryable_error'
   AND action.last_error_class = 'transient'
   AND action.last_error = 'canonical archive is not available';

UPDATE variant_actions
   SET status = 'superseded',
       lease_owner = NULL,
       lease_expires_at = NULL,
       lease_job_id = NULL,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE group_id IN (SELECT group_id FROM variant_blocked_recovery_groups)
   AND action_type = 'archive_cleanup'
   AND status = 'retryable_error'
   AND last_error_class = 'transient'
   AND last_error = 'canonical archive is not available';

UPDATE variant_jobs
   SET priority = MAX(priority, 500),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'reconcile_actions'
   AND status = 'queued'
   AND group_id IN (SELECT group_id FROM variant_blocked_recovery_groups);

INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
SELECT 'reconcile_actions', blocked.group_id, blocked.source_gid, 500, 'queued'
  FROM variant_blocked_recovery_groups AS blocked
 WHERE NOT EXISTS (
         SELECT 1
           FROM variant_jobs AS job
          WHERE job.group_id = blocked.group_id
            AND job.job_type = 'reconcile_actions'
            AND job.status IN ('queued', 'leased')
       );
