-- Expose one read-only operational row per variant job.  Actions are grouped
-- by variant group only while a reconciliation job is current; they do not
-- represent durable historical job ownership.

CREATE VIEW variant_job_diagnostics AS
WITH current_reconcile_groups AS (
    SELECT group_id
      FROM variant_jobs
     WHERE job_type = 'reconcile_actions'
       AND status IN ('queued', 'leased')
),
current_action_rows AS (
    SELECT action.*
      FROM variant_actions AS action
      JOIN current_reconcile_groups AS current
        ON current.group_id = action.group_id
     WHERE action.status IN (
         'pending', 'retryable_error', 'configuration_error', 'in_flight'
     )
),
action_counts AS (
    SELECT group_id,
           SUM(status = 'pending') AS pending_action_count,
           SUM(status IN ('retryable_error', 'configuration_error'))
               AS action_error_count,
           SUM(status = 'in_flight') AS in_flight_action_count,
           SUM(
               status = 'in_flight'
               AND lease_expires_at IS NOT NULL
               AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
           ) AS expired_action_lease_count,
           MIN(CASE
                 WHEN status IN ('pending', 'retryable_error', 'configuration_error')
                 THEN available_at
               END) AS next_action_available_at,
           MIN(CASE
                 WHEN status = 'in_flight' AND lease_expires_at IS NOT NULL
                 THEN lease_expires_at
               END) AS earliest_action_lease_expires_at,
           MIN(CASE
                 WHEN status = 'in_flight'
                  AND lease_expires_at IS NOT NULL
                  AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                 THEN lease_expires_at
               END) AS earliest_expired_action_lease_at
      FROM current_action_rows
     GROUP BY group_id
),
active_action_lines AS (
    SELECT group_id,
           available_at,
           id,
           'id=' || id
             || ' gid=' || gid
             || ' type=' || replace(replace(replace(action_type, char(13), ' '), char(10), ' '), char(9), ' ')
             || ' desired=' || replace(replace(replace(desired_value, char(13), ' '), char(10), ' '), char(9), ' ')
             || ' status=' || replace(replace(replace(status, char(13), ' '), char(10), ' '), char(9), ' ')
             || ' attempts=' || attempt_count
             || ' available_at=' || available_at AS line
      FROM current_action_rows
),
active_action_summaries AS (
    SELECT group_id, group_concat(line, char(10)) AS active_actions
      FROM (
            SELECT group_id, line
              FROM active_action_lines
             ORDER BY group_id, available_at, id
           )
     GROUP BY group_id
),
action_error_lines AS (
    SELECT group_id,
           available_at,
           id,
           'id=' || id
             || ' gid=' || gid
             || ' type=' || replace(replace(replace(action_type, char(13), ' '), char(10), ' '), char(9), ' ')
             || ' status=' || replace(replace(replace(status, char(13), ' '), char(10), ' '), char(9), ' ')
             || ' class=' || replace(replace(replace(COALESCE(last_error_class, ''), char(13), ' '), char(10), ' '), char(9), ' ')
             || ' error=' || replace(replace(replace(COALESCE(last_error, ''), char(13), ' '), char(10), ' '), char(9), ' ') AS line
      FROM current_action_rows
     WHERE status IN ('retryable_error', 'configuration_error')
),
action_error_summaries AS (
    SELECT group_id, group_concat(line, char(10)) AS action_errors
      FROM (
            SELECT group_id, line
              FROM action_error_lines
             ORDER BY group_id, available_at, id
           )
     GROUP BY group_id
),
job_rows AS (
    SELECT job.id AS job_id,
           job.job_type,
           job.group_id,
           job.source_gid,
           job.priority,
           job.status,
           job.attempt_count AS job_attempt_count,
           job.available_at AS job_available_at,
           job.lease_owner,
           job.lease_expires_at,
           job.scoring_revision_id,
           job.continuation_cursor_json,
           job.created_at,
           job.updated_at,
           job.completed_at,
           job.last_error_class AS job_error_class,
           job.last_error AS job_error,
           CASE
             WHEN job.status = 'queued'
              AND job.available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             THEN 1 ELSE 0
           END AS schedule_due,
           CASE
             WHEN job.status = 'leased'
              AND job.lease_expires_at IS NOT NULL
              AND job.lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             THEN 1 ELSE 0
           END AS job_lease_expired,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN COALESCE(counts.pending_action_count, 0)
                ELSE 0 END AS pending_action_count,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN COALESCE(counts.action_error_count, 0)
                ELSE 0 END AS action_error_count,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN COALESCE(counts.in_flight_action_count, 0)
                ELSE 0 END AS in_flight_action_count,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN COALESCE(counts.expired_action_lease_count, 0)
                ELSE 0 END AS expired_action_lease_count,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN COALESCE(counts.pending_action_count, 0)
                   + COALESCE(counts.action_error_count, 0)
                   + COALESCE(counts.in_flight_action_count, 0)
                ELSE 0 END AS active_action_count,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN counts.next_action_available_at END AS next_action_available_at,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN counts.earliest_action_lease_expires_at END
                AS earliest_action_lease_expires_at,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN counts.earliest_expired_action_lease_at END
                AS earliest_expired_action_lease_at,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN active.active_actions END AS active_actions,
           CASE WHEN job.job_type = 'reconcile_actions'
                     AND job.status IN ('queued', 'leased')
                THEN errors.action_errors END AS action_errors
      FROM variant_jobs AS job
      LEFT JOIN action_counts AS counts ON counts.group_id = job.group_id
      LEFT JOIN active_action_summaries AS active ON active.group_id = job.group_id
      LEFT JOIN action_error_summaries AS errors ON errors.group_id = job.group_id
),
classified_jobs AS (
    SELECT job_rows.*,
           CASE
             WHEN status IN ('completed', 'failed', 'cancelled') THEN status
             WHEN job_lease_expired = 1 THEN 'expired_job_lease'
             WHEN expired_action_lease_count > 0 THEN 'expired_action_lease'
             WHEN NULLIF(TRIM(job_error), '') IS NOT NULL THEN 'job_error'
             WHEN action_error_count > 0 THEN 'action_error'
             WHEN status = 'leased' THEN 'leased'
             WHEN schedule_due = 0 AND status = 'queued' THEN 'scheduled'
             WHEN schedule_due = 1 AND status = 'queued' THEN 'ready'
             ELSE 'unknown'
           END AS diagnostic_state
      FROM job_rows
),
wait_times AS (
    SELECT classified_jobs.*,
           CASE
             WHEN status IN ('completed', 'failed', 'cancelled')
               OR job_lease_expired = 1
               OR expired_action_lease_count > 0
             THEN NULL
             WHEN status = 'leased' AND lease_expires_at IS NOT NULL
             THEN lease_expires_at
             WHEN status = 'queued'
              AND job_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             THEN job_available_at
             WHEN status = 'queued'
              AND next_action_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             THEN next_action_available_at
             ELSE NULL
           END AS wait_until
      FROM classified_jobs
)
SELECT job_id,
       job_type,
       group_id,
       source_gid,
       priority,
       status,
       job_attempt_count,
       job_available_at,
       lease_owner,
       lease_expires_at,
       scoring_revision_id,
       continuation_cursor_json,
       created_at,
       updated_at,
       completed_at,
       job_error_class,
       job_error,
       schedule_due,
       job_lease_expired,
       diagnostic_state,
       wait_until,
       active_action_count,
       pending_action_count,
       action_error_count,
       in_flight_action_count,
       expired_action_lease_count,
       next_action_available_at,
       earliest_action_lease_expires_at,
       active_actions,
       action_errors,
       CASE
         WHEN job_lease_expired = 1
         THEN 'job lease expired at ' || lease_expires_at
         WHEN expired_action_lease_count > 0
         THEN 'action lease expired at ' || earliest_expired_action_lease_at
         WHEN NULLIF(TRIM(job_error), '') IS NOT NULL
         THEN 'job error: ' || replace(replace(replace(job_error, char(13), ' '), char(10), ' '), char(9), ' ')
         WHEN action_error_count > 0
         THEN 'current action errors: ' || action_errors
         WHEN status = 'leased'
         THEN 'leased by ' || COALESCE(lease_owner, 'unknown owner')
              || ' until ' || COALESCE(lease_expires_at, 'unknown')
         WHEN status = 'queued'
          AND job_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         THEN 'job available at ' || job_available_at
         WHEN status = 'queued'
          AND next_action_available_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         THEN 'next action available at ' || next_action_available_at
         WHEN active_action_count > 0 AND in_flight_action_count > 0
         THEN 'active actions are in flight'
         WHEN active_action_count > 0
         THEN 'active actions are waiting'
         WHEN status = 'queued' AND schedule_due = 1
         THEN 'queued job is ready to run'
         WHEN status IN ('completed', 'failed', 'cancelled')
         THEN 'job is ' || status
         ELSE 'no current blocker recorded'
       END AS reason
  FROM wait_times;
