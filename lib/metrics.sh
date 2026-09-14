#!/usr/bin/env bash

# Prometheus exposition and best-effort runtime heartbeat helpers. The
# renderer deliberately accepts only fixed labels from the SQL projection;
# gallery identifiers, paths, owners, and error text never cross this file's
# metrics output boundary.

metrics_component_is_valid() {
  case "${1:-}" in
  scheduler_tick | variant_worker | scan) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_runtime_start() {
  local component="${1:-}"
  metrics_component_is_valid "${component}" || return 1

  db_query \
    ".parameter set :component $(db_parameter_text "${component}")" \
    "BEGIN IMMEDIATE;
     UPDATE runtime_component_state
        SET last_started_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE component=:component;
     SELECT changes();
     COMMIT;" >/dev/null
}

metrics_runtime_finish() {
  local component="${1:-}" result="${2:-}" duration="${3:-}" exit_code="${4:-}"
  metrics_component_is_valid "${component}" || return 1
  case "${result}" in
  success | failure) ;;
  *) return 1 ;;
  esac
  [[ "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  [[ "${exit_code}" =~ ^[0-9]+$ ]] || return 1

  db_query \
    ".parameter set :component $(db_parameter_text "${component}")" \
    ".parameter set :result $(db_parameter_text "${result}")" \
    ".parameter set :duration ${duration}" \
    ".parameter set :exit_code ${exit_code}" \
    "BEGIN IMMEDIATE;
     UPDATE runtime_component_state
        SET success_count = success_count + CASE WHEN :result='success' THEN 1 ELSE 0 END,
            failure_count = failure_count + CASE WHEN :result='failure' THEN 1 ELSE 0 END,
            last_success_at = CASE WHEN :result='success'
                                   THEN strftime('%Y-%m-%dT%H:%M:%SZ','now')
                                   ELSE last_success_at END,
            last_failure_at = CASE WHEN :result='failure'
                                   THEN strftime('%Y-%m-%dT%H:%M:%SZ','now')
                                   ELSE last_failure_at END,
            last_duration_seconds=:duration,
            last_exit_code=:exit_code,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE component=:component;
     SELECT changes();
     COMMIT;" >/dev/null
}

# Run a command while preserving its exact exit status. Telemetry failures are
# reported but never change the command result.
metrics_runtime_run() {
  local component="${1:-}"
  shift || return 1
  metrics_component_is_valid "${component}" || return 1

  if ! metrics_runtime_start "${component}"; then
    log_err "Failed to record ${component} start; continuing."
  fi

  local started_at finished_at duration status=0
  started_at="$(date -u +%s)" || started_at=0
  "${@}" || status=$?
  finished_at="$(date -u +%s)" || finished_at="${started_at}"
  duration=$((finished_at - started_at))
  ((duration >= 0)) || duration=0

  local result=success
  ((status == 0)) || result=failure
  if ! metrics_runtime_finish "${component}" "${result}" "${duration}" "${status}"; then
    log_err "Failed to record ${component} result; continuing."
  fi
  return "${status}"
}

metrics_escape_label() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "${value}"
}

metrics_number_is_valid() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

metrics_label_text() {
  local label_name="$1" label_value="$2"
  printf '%s="%s"' "${label_name}" "$(metrics_escape_label "${label_value}")"
}

metrics_sample() {
  local name="$1" value="$2"
  shift 2
  local labels=() label_name label_value
  while [[ $# -gt 0 ]]; do
    label_name="$1"
    label_value="$2"
    labels+=("$(metrics_label_text "${label_name}" "${label_value}")")
    shift 2
  done
  if [[ "${#labels[@]}" -gt 0 ]]; then
    printf '%s{%s} %s\n' "${name}" "$(IFS=,; echo "${labels[*]}")" "${value}"
  else
    printf '%s %s\n' "${name}" "${value}"
  fi
}

metrics_append_sample() {
  payload+="$(metrics_sample "$@")"$'\n'
}

metrics_help_and_type() {
  cat <<'EOF'
# HELP yomiko_build_info Constant build identity for the running Yomiko image.
# TYPE yomiko_build_info gauge
# HELP yomiko_database_schema_version Highest applied Yomiko database schema version.
# TYPE yomiko_database_schema_version gauge
# HELP yomiko_database_file_size_bytes Size of a local SQLite database file in bytes.
# TYPE yomiko_database_file_size_bytes gauge
# HELP yomiko_runtime_runs_total Persisted completed runtime runs by component and result.
# TYPE yomiko_runtime_runs_total counter
# HELP yomiko_runtime_last_started_timestamp_seconds Unix timestamp of the latest component start.
# TYPE yomiko_runtime_last_started_timestamp_seconds gauge
# HELP yomiko_runtime_last_success_timestamp_seconds Unix timestamp of the latest successful component run.
# TYPE yomiko_runtime_last_success_timestamp_seconds gauge
# HELP yomiko_runtime_last_failure_timestamp_seconds Unix timestamp of the latest failed component run.
# TYPE yomiko_runtime_last_failure_timestamp_seconds gauge
# HELP yomiko_runtime_last_duration_seconds Duration of the latest completed component run in seconds.
# TYPE yomiko_runtime_last_duration_seconds gauge
# HELP yomiko_runtime_last_exit_code Exit status of the latest completed component run.
# TYPE yomiko_runtime_last_exit_code gauge
# HELP yomiko_variant_jobs Durable variant jobs by type and status.
# TYPE yomiko_variant_jobs gauge
# HELP yomiko_variant_job_errors Durable variant jobs with a bounded error class.
# TYPE yomiko_variant_job_errors gauge
# HELP yomiko_variant_runnable_jobs Variant jobs whose queued availability time is due.
# TYPE yomiko_variant_runnable_jobs gauge
# HELP yomiko_variant_oldest_runnable_job_age_seconds Age of the oldest runnable variant job.
# TYPE yomiko_variant_oldest_runnable_job_age_seconds gauge
# HELP yomiko_variant_job_max_attempts Maximum attempt count among variant jobs by type and status.
# TYPE yomiko_variant_job_max_attempts gauge
# HELP yomiko_variant_high_attempt_jobs Nonterminal variant jobs with at least five attempts.
# TYPE yomiko_variant_high_attempt_jobs gauge
# HELP yomiko_variant_jobs_created_recent Variant jobs created during the fixed one-hour window.
# TYPE yomiko_variant_jobs_created_recent gauge
# HELP yomiko_variant_actions Durable variant actions by type, status, and bounded error class.
# TYPE yomiko_variant_actions gauge
# HELP yomiko_variant_runnable_actions Variant actions whose pending or retryable availability time is due.
# TYPE yomiko_variant_runnable_actions gauge
# HELP yomiko_variant_oldest_runnable_action_age_seconds Age of the oldest runnable variant action.
# TYPE yomiko_variant_oldest_runnable_action_age_seconds gauge
# HELP yomiko_variant_oldest_action_state_age_seconds Age of the oldest failed or uncertain action state.
# TYPE yomiko_variant_oldest_action_state_age_seconds gauge
# HELP yomiko_variant_action_max_attempts Maximum attempt count among variant actions by type and status.
# TYPE yomiko_variant_action_max_attempts gauge
# HELP yomiko_variant_high_attempt_actions Nonterminal variant actions with at least five attempts.
# TYPE yomiko_variant_high_attempt_actions gauge
# HELP yomiko_variant_expired_leases Variant leases at or before the metrics snapshot time.
# TYPE yomiko_variant_expired_leases gauge
# HELP yomiko_variant_discovery_runs Discovery runs by phase and lifecycle status.
# TYPE yomiko_variant_discovery_runs gauge
# HELP yomiko_variant_discovery_errors Unfinished or failed discovery runs by bounded error class.
# TYPE yomiko_variant_discovery_errors gauge
# HELP yomiko_variant_oldest_discovery_run_age_seconds Age of the oldest running or retryable discovery run.
# TYPE yomiko_variant_oldest_discovery_run_age_seconds gauge
# HELP yomiko_variant_discovery_candidates Staged discovery candidates by state and bounded error class.
# TYPE yomiko_variant_discovery_candidates gauge
# HELP yomiko_variant_reviews Variant reviews by type and lifecycle status.
# TYPE yomiko_variant_reviews gauge
# HELP yomiko_variant_actionable_reviews Current class-lifted actionable reviews by type.
# TYPE yomiko_variant_actionable_reviews gauge
# HELP yomiko_variant_oldest_pending_review_age_seconds Age of the oldest pending review.
# TYPE yomiko_variant_oldest_pending_review_age_seconds gauge
# HELP yomiko_variant_groups Variant groups by activity and review state.
# TYPE yomiko_variant_groups gauge
# HELP yomiko_variant_discovery_due_groups Active groups currently due for discovery by reason.
# TYPE yomiko_variant_discovery_due_groups gauge
# HELP yomiko_variant_invariant_violations Records violating a fixed Yomiko data invariant.
# TYPE yomiko_variant_invariant_violations gauge
# HELP yomiko_gallery_data_quality_records Records with a bounded data-quality problem.
# TYPE yomiko_gallery_data_quality_records gauge
EOF
}

metrics_sql() {
  cat <<'EOF'
WITH
snapshot AS (
  SELECT CAST(strftime('%s','now') AS INTEGER) AS now_epoch,
         strftime('%Y-%m-%dT%H:%M:%SZ','now') AS now_text
),
components(component) AS (
  VALUES ('scheduler_tick'), ('variant_worker'), ('scan')
),
job_types(job_type) AS (
  VALUES ('discover'), ('evaluate'), ('reconcile_actions'),
         ('reconcile_retention'), ('policy_scoring_sweep')
),
job_statuses(status) AS (
  VALUES ('queued'), ('leased'), ('completed'), ('failed'), ('cancelled')
),
action_types(action_type) AS (
  VALUES ('rating'), ('favorite_move'), ('favorite_remove'),
         ('hath_request'), ('archive_cleanup')
),
action_statuses(status) AS (
  VALUES ('pending'), ('in_flight'), ('succeeded'), ('retryable_error'),
         ('permanent_error'), ('configuration_error'), ('superseded')
),
discovery_phases(phase) AS (
  VALUES ('seed_refresh'), ('chain_walk'), ('search'), ('gdata'),
         ('popularity'), ('publish')
),
discovery_statuses(status) AS (
  VALUES ('running'), ('retryable'), ('completed'), ('failed'), ('cancelled')
),
review_types(review_type) AS (
  VALUES ('candidate_identity'), ('winner')
),
review_statuses(status) AS (
  VALUES ('pending'), ('resolved')
),
discovery_age_statuses(status) AS (
  VALUES ('running'), ('retryable')
),
runtime_rows AS (
  SELECT components.component,
         COALESCE(state.success_count,0) AS success_count,
         COALESCE(state.failure_count,0) AS failure_count,
         COALESCE(CAST(strftime('%s',state.last_started_at) AS INTEGER),0) AS last_started,
         COALESCE(CAST(strftime('%s',state.last_success_at) AS INTEGER),0) AS last_success,
         COALESCE(CAST(strftime('%s',state.last_failure_at) AS INTEGER),0) AS last_failure,
         COALESCE(state.last_duration_seconds,0) AS last_duration_seconds,
         COALESCE(state.last_exit_code,0) AS last_exit_code
    FROM components
    LEFT JOIN runtime_component_state AS state USING(component)
),
job_counts AS (
  SELECT job_type, status, COUNT(*) AS value
    FROM variant_jobs GROUP BY job_type, status
),
job_error_counts AS (
  SELECT job_type, last_error_class AS error_class, COUNT(*) AS value
    FROM variant_jobs WHERE last_error_class IS NOT NULL
   GROUP BY job_type, last_error_class
),
runnable_job_counts AS (
  SELECT job_type, COUNT(*) AS value
    FROM variant_jobs, snapshot
   WHERE status='queued' AND available_at <= snapshot.now_text
   GROUP BY job_type
),
oldest_runnable_jobs AS (
  SELECT job_type,
         MAX(0, snapshot.now_epoch - COALESCE(CAST(strftime('%s',MIN(created_at)) AS INTEGER),snapshot.now_epoch)) AS value
    FROM variant_jobs, snapshot
   WHERE status='queued' AND available_at <= snapshot.now_text
   GROUP BY job_type
),
job_max_attempts AS (
  SELECT job_type, status, MAX(attempt_count) AS value
    FROM variant_jobs GROUP BY job_type, status
),
high_attempt_jobs AS (
  SELECT job_type, COUNT(*) AS value
    FROM variant_jobs
   WHERE status IN ('queued','leased') AND attempt_count >= 5
   GROUP BY job_type
),
recent_jobs AS (
  SELECT job_type, COUNT(*) AS value
    FROM variant_jobs, snapshot
   WHERE CAST(strftime('%s',created_at) AS INTEGER) >= snapshot.now_epoch - 3600
   GROUP BY job_type
),
action_counts AS (
  SELECT action_type, status, COALESCE(last_error_class,'none') AS error_class,
         COUNT(*) AS value
    FROM variant_actions GROUP BY action_type, status, COALESCE(last_error_class,'none')
),
runnable_action_counts AS (
  SELECT action_type, COUNT(*) AS value
    FROM variant_actions, snapshot
   WHERE status IN ('pending','retryable_error')
     AND available_at <= snapshot.now_text
   GROUP BY action_type
),
oldest_runnable_actions AS (
  SELECT action_type,
         MAX(0, snapshot.now_epoch - COALESCE(CAST(strftime('%s',MIN(created_at)) AS INTEGER),snapshot.now_epoch)) AS value
    FROM variant_actions, snapshot
   WHERE status IN ('pending','retryable_error')
     AND available_at <= snapshot.now_text
   GROUP BY action_type
),
oldest_action_states AS (
  SELECT action_type, status, COALESCE(last_error_class,'none') AS error_class,
         MAX(0, snapshot.now_epoch - COALESCE(CAST(strftime('%s',MIN(updated_at)) AS INTEGER),snapshot.now_epoch)) AS value
    FROM variant_actions, snapshot
   WHERE status IN ('retryable_error','permanent_error','configuration_error')
   GROUP BY action_type, status, COALESCE(last_error_class,'none')
),
action_max_attempts AS (
  SELECT action_type, status, MAX(attempt_count) AS value
    FROM variant_actions GROUP BY action_type, status
),
high_attempt_actions AS (
  SELECT action_type, COUNT(*) AS value
    FROM variant_actions
   WHERE status IN ('pending','in_flight','retryable_error','configuration_error')
     AND attempt_count >= 5
   GROUP BY action_type
),
discovery_counts AS (
  SELECT phase, status, COUNT(*) AS value
    FROM variant_discovery_runs GROUP BY phase, status
),
discovery_error_counts AS (
  SELECT phase, last_error_class AS error_class, COUNT(*) AS value
    FROM variant_discovery_runs
   WHERE status IN ('running','retryable','failed') AND last_error_class IS NOT NULL
   GROUP BY phase, last_error_class
),
oldest_discovery_runs AS (
  SELECT phase, status,
         MAX(0, snapshot.now_epoch - COALESCE(CAST(strftime('%s',MIN(created_at)) AS INTEGER),snapshot.now_epoch)) AS value
    FROM variant_discovery_runs, snapshot
   WHERE status IN ('running','retryable')
   GROUP BY phase, status
),
candidate_counts AS (
  SELECT state, COALESCE(last_error_class,'none') AS error_class, COUNT(*) AS value
    FROM variant_discovery_candidates
   GROUP BY state, COALESCE(last_error_class,'none')
),
review_counts AS (
  SELECT review_type, status, COUNT(*) AS value
    FROM variant_reviews GROUP BY review_type, status
),
oldest_pending_reviews AS (
  SELECT review_type,
         MAX(0, snapshot.now_epoch - COALESCE(CAST(strftime('%s',MIN(created_at)) AS INTEGER),snapshot.now_epoch)) AS value
    FROM variant_reviews, snapshot
   WHERE status='pending' AND superseded_at IS NULL
   GROUP BY review_type
),
actionable_review_counts AS (
  SELECT types.review_type,
         CASE types.review_type
           WHEN 'candidate_identity' THEN (
             SELECT COUNT(*) FROM variant_identity_actionable_review
           )
           WHEN 'winner' THEN (
             SELECT COUNT(*)
               FROM variant_reviews AS winner
               JOIN variant_identity_review_visibility AS visibility
                 ON visibility.review_id=winner.id
              WHERE winner.review_type='winner'
                AND winner.status='pending'
                AND winner.superseded_at IS NULL
                AND visibility.is_visible=1
           )
         END AS value
    FROM review_types AS types
),
group_counts AS (
  SELECT CASE WHEN is_active=1 THEN 'active' ELSE 'inactive' END AS activity,
         review_state, COUNT(*) AS value
    FROM variant_groups GROUP BY activity, review_state
),
due_group_counts AS (
  SELECT CASE
           WHEN last_discovered_at IS NULL THEN 'never_completed'
           WHEN COALESCE(completed_matching_revision,0) <> 5 THEN 'matching_revision'
           ELSE 'scheduled_time'
         END AS reason, COUNT(*) AS value
    FROM variant_groups, snapshot
   WHERE is_active=1
     AND (last_discovered_at IS NULL
       OR COALESCE(completed_matching_revision,0) <> 5
       OR (next_discovery_at IS NOT NULL AND next_discovery_at <= snapshot.now_text))
   GROUP BY reason
),
invariant_counts(invariant,value) AS (
  SELECT 'canonical_not_confirmed', COUNT(*)
    FROM variant_groups AS grouped
   WHERE grouped.canonical_gid IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM gallery_variants AS member
        WHERE member.group_id=grouped.id AND member.gid=grouped.canonical_gid
          AND member.membership_state='confirmed'
     )
  UNION ALL
  SELECT 'canonical_projection_mismatch', COUNT(*)
    FROM variant_groups AS grouped
   WHERE (grouped.active_evaluation_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM variant_evaluations AS evaluation
             WHERE evaluation.id=grouped.active_evaluation_id
               AND evaluation.state='completed'
               AND (grouped.canonical_gid IS NOT evaluation.canonical_gid)
         ))
      OR EXISTS (
            SELECT 1 FROM variant_canonical_decisions AS decision
             WHERE decision.group_id=grouped.id AND decision.status='active'
               AND decision.canonical_gid IS NOT grouped.canonical_gid
         )
      OR EXISTS (
            SELECT 1 FROM gallery_variants AS member
             WHERE member.group_id=grouped.id
               AND member.membership_state='confirmed'
               AND ((member.variant_state='canonical') <> COALESCE(member.gid=grouped.canonical_gid,0))
         )
  UNION ALL
  SELECT 'review_state_mismatch', COUNT(*)
    FROM variant_groups AS grouped
   WHERE grouped.review_state <> (
     SELECT projected.review_state
       FROM variant_identity_group_review_state AS projected
      WHERE projected.group_id=grouped.id
   )
  UNION ALL
  SELECT 'multiple_unfinished_discovery_runs',
         (SELECT COALESCE(SUM(value-1),0) FROM (
            SELECT group_id, COUNT(*) AS value FROM variant_discovery_runs
             WHERE status IN ('running','retryable') GROUP BY group_id HAVING COUNT(*) > 1
          ) AS by_group)
       + (SELECT COALESCE(SUM(value-1),0) FROM (
            SELECT job_id, COUNT(*) AS value FROM variant_discovery_runs
             WHERE status IN ('running','retryable') GROUP BY job_id HAVING COUNT(*) > 1
          ) AS by_job)
  UNION ALL
  SELECT 'active_work_missing_lease',
         (SELECT COUNT(*) FROM variant_jobs
           WHERE status='leased' AND (lease_owner IS NULL OR lease_expires_at IS NULL))
       + (SELECT COUNT(*) FROM variant_actions
           WHERE status='in_flight' AND (lease_owner IS NULL OR lease_expires_at IS NULL))
       + (SELECT COUNT(*) FROM variant_discovery_runs
           WHERE status='running' AND (lease_owner IS NULL OR lease_expires_at IS NULL))
  UNION ALL
  SELECT 'terminal_missing_completed_at',
         (SELECT COUNT(*) FROM variant_jobs
           WHERE status IN ('completed','failed','cancelled') AND completed_at IS NULL)
       + (SELECT COUNT(*) FROM variant_actions
           WHERE status IN ('succeeded','permanent_error','superseded') AND completed_at IS NULL)
       + (SELECT COUNT(*) FROM variant_discovery_runs
           WHERE status='completed' AND completed_at IS NULL)
  UNION ALL
  SELECT 'retained_canonical_marked_deleted', COUNT(*)
    FROM variant_groups AS grouped
    JOIN variant_evaluations AS evaluation
      ON evaluation.id=grouped.active_evaluation_id AND evaluation.state='completed'
    JOIN galleries AS canonical ON canonical.gid=grouped.canonical_gid
   WHERE grouped.is_active=1 AND grouped.desired_rating=11
     AND grouped.canonical_gid IS NOT NULL
     AND canonical.rated_then_deleted_at IS NOT NULL
  UNION ALL
  SELECT 'unsafe_archive_path', COUNT(*)
    FROM galleries
   WHERE COALESCE(file_path,'') <> ''
     AND (instr(file_path,'/') > 0 OR file_path IN ('.','..')
       OR instr(file_path,char(10)) > 0 OR instr(file_path,char(13)) > 0)
),
quality_counts(problem,value) AS (
  SELECT 'missing_tags', COUNT(*)
    FROM galleries AS gallery
    JOIN gallery_variants AS member ON member.gid=gallery.gid
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
   WHERE grouped.is_active=1 AND member.membership_state='confirmed'
     AND gallery.tags IS NULL
  UNION ALL
  SELECT 'missing_page_count', COUNT(*)
    FROM galleries AS gallery
    JOIN gallery_variants AS member ON member.gid=gallery.gid
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
   WHERE grouped.is_active=1 AND member.membership_state='confirmed'
     AND gallery.file_count IS NULL
  UNION ALL
  SELECT 'missing_popularity', COUNT(*)
    FROM galleries AS gallery
    JOIN gallery_variants AS member ON member.gid=gallery.gid
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
   WHERE grouped.is_active=1 AND member.membership_state='confirmed'
     AND (gallery.favorite_count IS NULL OR gallery.rating_count IS NULL)
)
SELECT 10, 'yomiko_database_schema_version', '', '', '', COALESCE(MAX(version),0)
  FROM _schema_version
UNION ALL
SELECT 20, 'yomiko_runtime_runs_total', component, 'success', '', success_count FROM runtime_rows
UNION ALL
SELECT 20, 'yomiko_runtime_runs_total', component, 'failure', '', failure_count FROM runtime_rows
UNION ALL
SELECT 21, 'yomiko_runtime_last_started_timestamp_seconds', component, '', '', last_started FROM runtime_rows
UNION ALL
SELECT 22, 'yomiko_runtime_last_success_timestamp_seconds', component, '', '', last_success FROM runtime_rows
UNION ALL
SELECT 23, 'yomiko_runtime_last_failure_timestamp_seconds', component, '', '', last_failure FROM runtime_rows
UNION ALL
SELECT 24, 'yomiko_runtime_last_duration_seconds', component, '', '', last_duration_seconds FROM runtime_rows
UNION ALL
SELECT 25, 'yomiko_runtime_last_exit_code', component, '', '', last_exit_code FROM runtime_rows
UNION ALL
SELECT 30, 'yomiko_variant_jobs', types.job_type, statuses.status, '', COALESCE(counts.value,0)
  FROM job_types AS types CROSS JOIN job_statuses AS statuses
  LEFT JOIN job_counts AS counts ON counts.job_type=types.job_type AND counts.status=statuses.status
UNION ALL
SELECT 31, 'yomiko_variant_job_errors', job_type, error_class, '', value FROM job_error_counts
UNION ALL
SELECT 32, 'yomiko_variant_runnable_jobs', types.job_type, '', '', COALESCE(counts.value,0)
  FROM job_types AS types LEFT JOIN runnable_job_counts AS counts USING(job_type)
UNION ALL
SELECT 33, 'yomiko_variant_oldest_runnable_job_age_seconds', types.job_type, '', '', COALESCE(ages.value,0)
  FROM job_types AS types LEFT JOIN oldest_runnable_jobs AS ages USING(job_type)
UNION ALL
SELECT 34, 'yomiko_variant_job_max_attempts', types.job_type, statuses.status, '', COALESCE(attempts.value,0)
  FROM job_types AS types CROSS JOIN job_statuses AS statuses
  LEFT JOIN job_max_attempts AS attempts ON attempts.job_type=types.job_type AND attempts.status=statuses.status
UNION ALL
SELECT 35, 'yomiko_variant_high_attempt_jobs', types.job_type, '', '', COALESCE(high.value,0)
  FROM job_types AS types LEFT JOIN high_attempt_jobs AS high USING(job_type)
UNION ALL
SELECT 36, 'yomiko_variant_jobs_created_recent', types.job_type, '1h', '', COALESCE(recent.value,0)
  FROM job_types AS types LEFT JOIN recent_jobs AS recent USING(job_type)
UNION ALL
SELECT 40, 'yomiko_variant_actions', action_type, status, error_class, value FROM action_counts
UNION ALL
SELECT 41, 'yomiko_variant_runnable_actions', types.action_type, '', '', COALESCE(counts.value,0)
  FROM action_types AS types LEFT JOIN runnable_action_counts AS counts USING(action_type)
UNION ALL
SELECT 42, 'yomiko_variant_oldest_runnable_action_age_seconds', types.action_type, '', '', COALESCE(ages.value,0)
  FROM action_types AS types LEFT JOIN oldest_runnable_actions AS ages USING(action_type)
UNION ALL
SELECT 43, 'yomiko_variant_oldest_action_state_age_seconds', action_type, status, error_class, value FROM oldest_action_states
UNION ALL
SELECT 44, 'yomiko_variant_action_max_attempts', action_type, status, '', value FROM action_max_attempts
UNION ALL
SELECT 45, 'yomiko_variant_high_attempt_actions', types.action_type, '', '', COALESCE(high.value,0)
  FROM action_types AS types LEFT JOIN high_attempt_actions AS high USING(action_type)
UNION ALL
SELECT 46, 'yomiko_variant_expired_leases', 'job', '', '',
       (SELECT COUNT(*) FROM variant_jobs, snapshot WHERE status='leased' AND lease_expires_at <= snapshot.now_text)
UNION ALL
SELECT 46, 'yomiko_variant_expired_leases', 'action', '', '',
       (SELECT COUNT(*) FROM variant_actions, snapshot WHERE status='in_flight' AND lease_expires_at <= snapshot.now_text)
UNION ALL
SELECT 46, 'yomiko_variant_expired_leases', 'discovery_run', '', '',
       (SELECT COUNT(*) FROM variant_discovery_runs, snapshot WHERE status='running' AND lease_expires_at <= snapshot.now_text)
UNION ALL
SELECT 50, 'yomiko_variant_discovery_runs', phases.phase, statuses.status, '', COALESCE(counts.value,0)
  FROM discovery_phases AS phases CROSS JOIN discovery_statuses AS statuses
  LEFT JOIN discovery_counts AS counts ON counts.phase=phases.phase AND counts.status=statuses.status
UNION ALL
SELECT 51, 'yomiko_variant_discovery_errors', phase, error_class, '', value FROM discovery_error_counts
UNION ALL
SELECT 52, 'yomiko_variant_oldest_discovery_run_age_seconds', phases.phase, statuses.status, '', COALESCE(ages.value,0)
  FROM discovery_phases AS phases CROSS JOIN discovery_age_statuses AS statuses
  LEFT JOIN oldest_discovery_runs AS ages ON ages.phase=phases.phase AND ages.status=statuses.status
UNION ALL
SELECT 53, 'yomiko_variant_discovery_candidates', state, error_class, '', value FROM candidate_counts
UNION ALL
SELECT 54, 'yomiko_variant_reviews', types.review_type, statuses.status, '', COALESCE(counts.value,0)
  FROM review_types AS types CROSS JOIN review_statuses AS statuses
  LEFT JOIN review_counts AS counts ON counts.review_type=types.review_type AND counts.status=statuses.status
UNION ALL
SELECT 55, 'yomiko_variant_actionable_reviews', counts.review_type, '', '', counts.value
  FROM actionable_review_counts AS counts
UNION ALL
SELECT 56, 'yomiko_variant_oldest_pending_review_age_seconds', types.review_type, '', '', COALESCE(ages.value,0)
  FROM review_types AS types LEFT JOIN oldest_pending_reviews AS ages USING(review_type)
UNION ALL
SELECT 57, 'yomiko_variant_groups', activity, review_state, '', value FROM group_counts
UNION ALL
SELECT 58, 'yomiko_variant_discovery_due_groups', reasons.reason, '', '', COALESCE(counts.value,0)
  FROM (SELECT 'never_completed' AS reason UNION ALL SELECT 'matching_revision' UNION ALL SELECT 'scheduled_time') AS reasons
  LEFT JOIN due_group_counts AS counts USING(reason)
UNION ALL
SELECT 60, 'yomiko_variant_invariant_violations', invariant, '', '', value FROM invariant_counts
UNION ALL
SELECT 61, 'yomiko_gallery_data_quality_records', problem, '', '', value FROM quality_counts
ORDER BY 1, 2, 3, 4, 5;
EOF
}

metrics_emit_payload() {
  local payload=''
  local build_version="${YOMIKO_BUILD_VERSION:-dev}"
  [[ -n "${build_version}" ]] || build_version=dev
  payload+="$(metrics_help_and_type)"$'\n'

  local file_name file_size
  for file_name in main wal shm; do
    case "${file_name}" in
    main) file_size="$(stat -c '%s' "${DB_PATH}" 2>/dev/null || true)" ;;
    wal) file_size="$(stat -c '%s' "${DB_PATH}-wal" 2>/dev/null || true)" ;;
    shm) file_size="$(stat -c '%s' "${DB_PATH}-shm" 2>/dev/null || true)" ;;
    esac
    [[ "${file_size}" =~ ^[0-9]+$ ]] || file_size=0
    metrics_append_sample yomiko_database_file_size_bytes "${file_size}" file "${file_name}"
  done
  metrics_append_sample yomiko_build_info 1 version "${build_version}"

  local rows
  if ! rows="$(db_query '.mode tabs' '.headers off' "BEGIN; $(metrics_sql) COMMIT;")"; then
    return 1
  fi

  local sort metric label_one label_two label_three value
  while IFS=$'\t' read -r sort metric label_one label_two label_three value; do
    [[ -n "${metric}" ]] || continue
    [[ "${sort}" =~ ^[0-9]+$ ]] || return 1
    metrics_number_is_valid "${value}" || return 1
    case "${metric}" in
    yomiko_database_schema_version)
      metrics_append_sample "${metric}" "${value}" ;;
    yomiko_runtime_runs_total)
      metrics_append_sample "${metric}" "${value}" component "${label_one}" result "${label_two}" ;;
    yomiko_runtime_last_started_timestamp_seconds | \
    yomiko_runtime_last_success_timestamp_seconds | \
    yomiko_runtime_last_failure_timestamp_seconds | \
    yomiko_runtime_last_duration_seconds | yomiko_runtime_last_exit_code)
      metrics_append_sample "${metric}" "${value}" component "${label_one}" ;;
    yomiko_variant_jobs | yomiko_variant_job_max_attempts)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" status "${label_two}" ;;
    yomiko_variant_job_errors)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" error_class "${label_two}" ;;
    yomiko_variant_runnable_jobs | yomiko_variant_oldest_runnable_job_age_seconds | \
    yomiko_variant_high_attempt_jobs)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" ;;
    yomiko_variant_jobs_created_recent)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" window "${label_two}" ;;
    yomiko_variant_actions | yomiko_variant_oldest_action_state_age_seconds)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" status "${label_two}" error_class "${label_three}" ;;
    yomiko_variant_runnable_actions | yomiko_variant_oldest_runnable_action_age_seconds | \
    yomiko_variant_high_attempt_actions)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" ;;
    yomiko_variant_action_max_attempts)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" status "${label_two}" ;;
    yomiko_variant_expired_leases)
      metrics_append_sample "${metric}" "${value}" resource "${label_one}" ;;
    yomiko_variant_discovery_runs | yomiko_variant_oldest_discovery_run_age_seconds)
      metrics_append_sample "${metric}" "${value}" phase "${label_one}" status "${label_two}" ;;
    yomiko_variant_discovery_errors)
      metrics_append_sample "${metric}" "${value}" phase "${label_one}" error_class "${label_two}" ;;
    yomiko_variant_discovery_candidates)
      metrics_append_sample "${metric}" "${value}" state "${label_one}" error_class "${label_two}" ;;
    yomiko_variant_reviews)
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" status "${label_two}" ;;
    yomiko_variant_actionable_reviews)
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" ;;
    yomiko_variant_oldest_pending_review_age_seconds)
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" ;;
    yomiko_variant_groups)
      metrics_append_sample "${metric}" "${value}" activity "${label_one}" review_state "${label_two}" ;;
    yomiko_variant_discovery_due_groups)
      metrics_append_sample "${metric}" "${value}" reason "${label_one}" ;;
    yomiko_variant_invariant_violations)
      metrics_append_sample "${metric}" "${value}" invariant "${label_one}" ;;
    yomiko_gallery_data_quality_records)
      metrics_append_sample "${metric}" "${value}" problem "${label_one}" ;;
    *) return 1 ;;
    esac
  done <<<"${rows}"

  printf '%s' "${payload}"
}
