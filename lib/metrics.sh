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

metrics_job_type_is_valid() {
  case "${1:-}" in
  discover | evaluate | reconcile_actions | reconcile_retention | policy_scoring_sweep) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_job_status_is_valid() {
  case "${1:-}" in
  queued | leased | completed | failed | cancelled) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_job_error_class_is_valid() {
  case "${1:-}" in
  transient | permanent | configuration | uncertain) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_job_outcome_is_valid() {
  case "${1:-}" in
  completed | continued | retryable_error | permanent_error | configuration_error | cancelled) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_review_type_is_valid() {
  case "${1:-}" in
  candidate_identity | winner) return 0 ;;
  *) return 1 ;;
  esac
}

metrics_nonnegative_integer_is_valid() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

metrics_runtime_start() {
  local component="${1:-}"
  metrics_component_is_valid "${component}" || return 1

  db_write_as "runtime:${component}" \
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

  db_write_as "runtime:${component}" \
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
# HELP yomiko_runtime_success_stale_after_seconds Maximum supported age of the latest successful component run before it is stale.
# TYPE yomiko_runtime_success_stale_after_seconds gauge
# HELP yomiko_runtime_last_failure_timestamp_seconds Unix timestamp of the latest failed component run.
# TYPE yomiko_runtime_last_failure_timestamp_seconds gauge
# HELP yomiko_runtime_last_duration_seconds Duration of the latest completed component run in seconds.
# TYPE yomiko_runtime_last_duration_seconds gauge
# HELP yomiko_runtime_last_exit_code Exit status of the latest completed component run.
# TYPE yomiko_runtime_last_exit_code gauge
# HELP yomiko_variant_jobs Persisted variant jobs by type and lifecycle status; terminal statuses are retained history, not active incidents.
# TYPE yomiko_variant_jobs gauge
# HELP yomiko_variant_job_errors Persisted variant jobs with a bounded error class by lifecycle status; failed rows are retained history.
# TYPE yomiko_variant_job_errors gauge
# HELP yomiko_variant_job_outcomes_total Persisted variant job lifecycle outcomes by job type and outcome.
# TYPE yomiko_variant_job_outcomes_total counter
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
# HELP yomiko_variant_actionable_reviews Current reviews actionable in the web queue by review type.
# TYPE yomiko_variant_actionable_reviews gauge
# HELP yomiko_variant_review_outcome_audit_records Retained variant review audit records by review type and projected terminal resolution.
# TYPE yomiko_variant_review_outcome_audit_records gauge
# HELP yomiko_variant_groups Variant groups by activity and review state.
# TYPE yomiko_variant_groups gauge
# HELP yomiko_variant_discovery_due_groups Active groups currently due for discovery by reason.
# TYPE yomiko_variant_discovery_due_groups gauge
# HELP yomiko_variant_invariant_violations Records violating a fixed Yomiko data invariant.
# TYPE yomiko_variant_invariant_violations gauge
# HELP yomiko_gallery_data_quality_records Records with a bounded data-quality problem.
# TYPE yomiko_gallery_data_quality_records gauge
# HELP yomiko_gallery_status Current gallery counts in an exhaustive exclusive partition. Precedence is rated_variant_canonical > rated_variant_alternate > rated_variant_pending_selection > different_book > pending_rating > hath_requested > unclassified; hath_requested means a newer H@H request or attempt watermark exists, not that a client is transferring now.
# TYPE yomiko_gallery_status gauge
# HELP yomiko_galleries Total number of rows in the galleries table from the same read snapshot as yomiko_gallery_status.
# TYPE yomiko_galleries gauge
EOF
}

metrics_sql() {
  cat <<'EOF'
WITH
snapshot AS (
  SELECT CAST(strftime('%s','now') AS INTEGER) AS now_epoch,
         strftime('%Y-%m-%dT%H:%M:%SZ','now') AS now_text
),
components(component, stale_after_seconds) AS (
  VALUES ('scheduler_tick', 180), ('variant_worker', 240), ('scan', 900)
),
job_types(job_type) AS (
  VALUES ('discover'), ('evaluate'), ('reconcile_actions'),
         ('reconcile_retention'), ('policy_scoring_sweep')
),
job_statuses(status) AS (
  VALUES ('queued'), ('leased'), ('completed'), ('failed'), ('cancelled')
),
job_outcomes(outcome) AS (
  VALUES ('completed'), ('continued'), ('retryable_error'),
         ('permanent_error'), ('configuration_error'), ('cancelled')
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
review_outcome_dimensions(review_type, resolution, precedence) AS (
  VALUES ('candidate_identity', 'same_book', 1),
         ('candidate_identity', 'different_book', 2),
         ('candidate_identity', 'superseded', 3),
         ('winner', 'winner', 4),
         ('winner', 'superseded', 5)
),
gallery_statuses(precedence, state) AS (
  VALUES (1, 'rated_variant_canonical'),
         (2, 'rated_variant_alternate'),
         (3, 'rated_variant_pending_selection'),
         (4, 'different_book'),
         (5, 'pending_rating'),
         (6, 'hath_requested'),
         (7, 'unclassified')
),
active_variant_roles(gid, state) AS (
  SELECT active.gid,
         CASE
           WHEN MAX(CASE WHEN grouped.canonical_gid = active.gid THEN 1 ELSE 0 END) = 1
             THEN 'rated_variant_canonical'
           WHEN MAX(CASE WHEN grouped.canonical_gid IS NOT NULL THEN 1 ELSE 0 END) = 1
             THEN 'rated_variant_alternate'
           ELSE 'rated_variant_pending_selection'
         END AS state
    FROM variant_identity_active_membership AS active
    JOIN variant_groups AS grouped ON grouped.id = active.active_group_id
   GROUP BY active.gid
),
different_book_endpoints(gid) AS (
  SELECT pair.low_gid
    FROM gallery_identity_pairs AS pair
    JOIN variant_reviews AS review ON review.id = pair.current_review_id
   WHERE review.status = 'resolved'
     AND review.decision = 'different_book'
  UNION
  SELECT pair.high_gid
    FROM gallery_identity_pairs AS pair
    JOIN variant_reviews AS review ON review.id = pair.current_review_id
   WHERE review.status = 'resolved'
     AND review.decision = 'different_book'
),
gallery_status_projection(gid, state) AS (
  SELECT gallery.gid,
         CASE
           WHEN roles.state IS NOT NULL THEN roles.state
           WHEN EXISTS (
             SELECT 1
               FROM different_book_endpoints AS endpoint
              WHERE endpoint.gid = gallery.gid
           ) THEN 'different_book'
           WHEN length(COALESCE(gallery.file_path, '')) > 0
            AND COALESCE(gallery.feedbacked_at, '') = ''
            AND COALESCE(gallery.self_rating, 0) = 0
            AND gallery.rated_then_deleted_at IS NULL
             THEN 'pending_rating'
           WHEN length(COALESCE(gallery.file_path, '')) = 0
            AND MAX(
                  COALESCE(gallery.hath_last_attempted_at, ''),
                  COALESCE(gallery.hath_requested_at, '')
                ) <> ''
            AND MAX(
                  COALESCE(gallery.hath_last_attempted_at, ''),
                  COALESCE(gallery.hath_requested_at, '')
                ) > COALESCE(gallery.rated_then_deleted_at, '')
             THEN 'hath_requested'
           ELSE 'unclassified'
         END
    FROM galleries AS gallery
    LEFT JOIN active_variant_roles AS roles ON roles.gid = gallery.gid
),
gallery_status_counts(state, value) AS (
  SELECT state, COUNT(*)
    FROM gallery_status_projection
   GROUP BY state
),
discovery_age_statuses(status) AS (
  VALUES ('running'), ('retryable')
),
runtime_rows AS (
  SELECT components.component,
         components.stale_after_seconds,
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
  SELECT job_type, status, last_error_class AS error_class, COUNT(*) AS value
    FROM variant_jobs WHERE last_error_class IS NOT NULL
   GROUP BY job_type, status, last_error_class
),
job_outcome_counts AS (
  SELECT job_type, outcome, value
    FROM variant_job_outcome_counters
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
review_outcome_counts AS (
  SELECT review.review_type, lifecycle.resolution, COUNT(*) AS value
    FROM variant_reviews AS review
    JOIN variant_review_product_lifecycle AS lifecycle
      ON lifecycle.review_id = review.id
   WHERE lifecycle.projected_status = 'resolved'
     AND lifecycle.resolution IS NOT NULL
   GROUP BY review.review_type, lifecycle.resolution
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
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', component, '', '', stale_after_seconds FROM runtime_rows
UNION ALL
SELECT 24, 'yomiko_runtime_last_failure_timestamp_seconds', component, '', '', last_failure FROM runtime_rows
UNION ALL
SELECT 25, 'yomiko_runtime_last_duration_seconds', component, '', '', last_duration_seconds FROM runtime_rows
UNION ALL
SELECT 26, 'yomiko_runtime_last_exit_code', component, '', '', last_exit_code FROM runtime_rows
UNION ALL
SELECT 30, 'yomiko_variant_jobs', types.job_type, statuses.status, '', COALESCE(counts.value,0)
  FROM job_types AS types CROSS JOIN job_statuses AS statuses
  LEFT JOIN job_counts AS counts ON counts.job_type=types.job_type AND counts.status=statuses.status
UNION ALL
SELECT 31, 'yomiko_variant_job_errors', job_type, status, error_class, value FROM job_error_counts
UNION ALL
SELECT 32, 'yomiko_variant_job_outcomes_total', types.job_type, outcomes.outcome, '', COALESCE(counts.value,0)
  FROM job_types AS types CROSS JOIN job_outcomes AS outcomes
  LEFT JOIN job_outcome_counts AS counts
    ON counts.job_type=types.job_type AND counts.outcome=outcomes.outcome
UNION ALL
SELECT 33, 'yomiko_variant_runnable_jobs', types.job_type, '', '', COALESCE(counts.value,0)
  FROM job_types AS types LEFT JOIN runnable_job_counts AS counts USING(job_type)
UNION ALL
SELECT 34, 'yomiko_variant_oldest_runnable_job_age_seconds', types.job_type, '', '', COALESCE(ages.value,0)
  FROM job_types AS types LEFT JOIN oldest_runnable_jobs AS ages USING(job_type)
UNION ALL
SELECT 35, 'yomiko_variant_job_max_attempts', types.job_type, statuses.status, '', COALESCE(attempts.value,0)
  FROM job_types AS types CROSS JOIN job_statuses AS statuses
  LEFT JOIN job_max_attempts AS attempts ON attempts.job_type=types.job_type AND attempts.status=statuses.status
UNION ALL
SELECT 36, 'yomiko_variant_high_attempt_jobs', types.job_type, '', '', COALESCE(high.value,0)
  FROM job_types AS types LEFT JOIN high_attempt_jobs AS high USING(job_type)
UNION ALL
SELECT 37, 'yomiko_variant_jobs_created_recent', types.job_type, '1h', '', COALESCE(recent.value,0)
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
SELECT 53 + dimensions.precedence, 'yomiko_variant_review_outcome_audit_records', dimensions.review_type, dimensions.resolution, '',
       COALESCE(counts.value,0)
  FROM review_outcome_dimensions AS dimensions
  LEFT JOIN review_outcome_counts AS counts
    ON counts.review_type=dimensions.review_type
   AND counts.resolution=dimensions.resolution
UNION ALL
SELECT 59, 'yomiko_variant_actionable_reviews', counts.review_type, '', '', counts.value
  FROM actionable_review_counts AS counts
UNION ALL
SELECT 61, 'yomiko_variant_groups', activity, review_state, '', value FROM group_counts
UNION ALL
SELECT 62, 'yomiko_variant_discovery_due_groups', reasons.reason, '', '', COALESCE(counts.value,0)
  FROM (SELECT 'never_completed' AS reason UNION ALL SELECT 'matching_revision' UNION ALL SELECT 'scheduled_time') AS reasons
  LEFT JOIN due_group_counts AS counts USING(reason)
UNION ALL
SELECT 63, 'yomiko_variant_invariant_violations', invariant, '', '', value FROM invariant_counts
UNION ALL
SELECT 64, 'yomiko_gallery_data_quality_records', problem, '', '', value FROM quality_counts
UNION ALL
SELECT 64 + statuses.precedence, 'yomiko_gallery_status', statuses.state, '', '',
       COALESCE(counts.value,0)
  FROM gallery_statuses AS statuses
  LEFT JOIN gallery_status_counts AS counts ON counts.state = statuses.state
UNION ALL
SELECT 70, 'yomiko_galleries', '', '', '', COUNT(*)
  FROM galleries
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
  local stale_after_components='' runtime_component
  local job_status_sample_count=0 job_outcome_sample_count=0
  local actionable_review_sample_count=0 review_outcome_sample_count=0
  local -A job_status_samples=() job_outcome_samples=() job_error_samples=() actionable_review_samples=() review_outcome_samples=()
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
    yomiko_runtime_success_stale_after_seconds)
      metrics_component_is_valid "${label_one}" || return 1
      case ",${stale_after_components}," in
      *",${label_one},"*) return 1 ;;
      esac
      stale_after_components+="${label_one},"
      metrics_append_sample "${metric}" "${value}" component "${label_one}" ;;
    yomiko_variant_jobs | yomiko_variant_job_max_attempts)
      metrics_job_type_is_valid "${label_one}" || return 1
      metrics_job_status_is_valid "${label_two}" || return 1
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" status "${label_two}"
      if [[ "${metric}" == yomiko_variant_jobs ]]; then
        local job_key="${label_one}|${label_two}"
        [[ -z "${job_status_samples[${job_key}]+present}" ]] || return 1
        job_status_samples["${job_key}"]=1
        job_status_sample_count=$((job_status_sample_count + 1))
      fi
      ;;
    yomiko_variant_job_outcomes_total)
      metrics_job_type_is_valid "${label_one}" || return 1
      metrics_job_outcome_is_valid "${label_two}" || return 1
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" outcome "${label_two}"
      local outcome_key="${label_one}|${label_two}"
      [[ -z "${job_outcome_samples[${outcome_key}]+present}" ]] || return 1
      job_outcome_samples["${outcome_key}"]=1
      job_outcome_sample_count=$((job_outcome_sample_count + 1))
      ;;
    yomiko_variant_job_errors)
      metrics_job_type_is_valid "${label_one}" || return 1
      metrics_job_status_is_valid "${label_two}" || return 1
      metrics_job_error_class_is_valid "${label_three}" || return 1
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" status "${label_two}" error_class "${label_three}"
      local error_key="${label_one}|${label_two}|${label_three}"
      [[ -z "${job_error_samples[${error_key}]+present}" ]] || return 1
      job_error_samples["${error_key}"]=1
      ;;
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
    yomiko_variant_review_outcome_audit_records)
      [[ "${label_three}" == '""' ]] && label_three=''
      metrics_review_type_is_valid "${label_one}" || return 1
      [[ -z "${label_three}" ]] || return 1
      case "${label_one}|${label_two}" in
      candidate_identity\|same_book | candidate_identity\|different_book | \
      candidate_identity\|superseded | winner\|winner | winner\|superseded) ;;
      *) return 1 ;;
      esac
      metrics_nonnegative_integer_is_valid "${value}" || return 1
      local review_outcome_key="${label_one}|${label_two}"
      [[ -z "${review_outcome_samples[${review_outcome_key}]+present}" ]] || return 1
      review_outcome_samples["${review_outcome_key}"]=1
      review_outcome_sample_count=$((review_outcome_sample_count + 1))
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" resolution "${label_two}" ;;
    yomiko_variant_actionable_reviews)
      [[ "${label_two}" == '""' ]] && label_two=''
      [[ "${label_three}" == '""' ]] && label_three=''
      metrics_review_type_is_valid "${label_one}" || return 1
      [[ -z "${label_two}" && -z "${label_three}" ]] || return 1
      metrics_nonnegative_integer_is_valid "${value}" || return 1
      local actionable_review_key="${label_one}"
      [[ -z "${actionable_review_samples[${actionable_review_key}]+present}" ]] || return 1
      actionable_review_samples["${actionable_review_key}"]=1
      actionable_review_sample_count=$((actionable_review_sample_count + 1))
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" ;;
    yomiko_variant_groups)
      metrics_append_sample "${metric}" "${value}" activity "${label_one}" review_state "${label_two}" ;;
    yomiko_variant_discovery_due_groups)
      metrics_append_sample "${metric}" "${value}" reason "${label_one}" ;;
    yomiko_variant_invariant_violations)
      metrics_append_sample "${metric}" "${value}" invariant "${label_one}" ;;
    yomiko_gallery_data_quality_records)
      metrics_append_sample "${metric}" "${value}" problem "${label_one}" ;;
    yomiko_gallery_status)
      metrics_append_sample "${metric}" "${value}" state "${label_one}" ;;
    yomiko_galleries)
      metrics_append_sample "${metric}" "${value}" ;;
    *) return 1 ;;
    esac
  done <<<"${rows}"

  [[ "${job_status_sample_count}" -eq 25 ]] || return 1
  [[ "${job_outcome_sample_count}" -eq 30 ]] || return 1
  [[ "${actionable_review_sample_count}" -eq 2 ]] || return 1
  [[ "${review_outcome_sample_count}" -eq 5 ]] || return 1
  local job_type job_status job_outcome job_key outcome_key
  for job_type in discover evaluate reconcile_actions reconcile_retention policy_scoring_sweep; do
    for job_status in queued leased completed failed cancelled; do
      job_key="${job_type}|${job_status}"
      [[ -n "${job_status_samples[${job_key}]+present}" ]] || return 1
    done
    for job_outcome in completed continued retryable_error permanent_error configuration_error cancelled; do
      outcome_key="${job_type}|${job_outcome}"
      [[ -n "${job_outcome_samples[${outcome_key}]+present}" ]] || return 1
    done
  done

  local review_type review_resolution review_outcome_key
  for review_type in candidate_identity winner; do
    case "${review_type}" in
    candidate_identity)
      for review_resolution in same_book different_book superseded; do
        review_outcome_key="${review_type}|${review_resolution}"
        [[ -n "${review_outcome_samples[${review_outcome_key}]+present}" ]] || return 1
      done
      ;;
    winner)
      for review_resolution in winner superseded; do
        review_outcome_key="${review_type}|${review_resolution}"
        [[ -n "${review_outcome_samples[${review_outcome_key}]+present}" ]] || return 1
      done
      ;;
    esac
  done

  for runtime_component in scheduler_tick variant_worker scan; do
    case ",${stale_after_components}," in
    *",${runtime_component},"*) ;;
    *) return 1 ;;
    esac
  done

  printf '%s' "${payload}"
}
