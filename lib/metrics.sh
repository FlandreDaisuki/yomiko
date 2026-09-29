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
# HELP yomiko_variant_unresolved_job_failures Current applicable tasks whose latest terminal job failed, by job type and error class.
# TYPE yomiko_variant_unresolved_job_failures gauge
# HELP yomiko_variant_job_outcomes_total Persisted variant job lifecycle outcomes by job type and outcome.
# TYPE yomiko_variant_job_outcomes_total counter
# HELP yomiko_variant_runnable_jobs Variant jobs whose queued availability time is due.
# TYPE yomiko_variant_runnable_jobs gauge
# HELP yomiko_variant_job_max_attempts Maximum attempt count among variant jobs by type and status.
# TYPE yomiko_variant_job_max_attempts gauge
# HELP yomiko_variant_high_attempt_jobs Nonterminal variant jobs with at least five attempts.
# TYPE yomiko_variant_high_attempt_jobs gauge
# HELP yomiko_variant_jobs_created_recent Variant jobs created during the fixed one-hour window.
# TYPE yomiko_variant_jobs_created_recent gauge
# HELP yomiko_variant_actions Durable variant actions by type, status, and bounded error class.
# TYPE yomiko_variant_actions gauge
# HELP yomiko_variant_unresolved_action_failures Current applicable action tasks whose latest recorded attempt failed, by action type and error class.
# TYPE yomiko_variant_unresolved_action_failures gauge
# HELP yomiko_variant_runnable_actions Variant actions whose pending or retryable availability time is due.
# TYPE yomiko_variant_runnable_actions gauge
# HELP yomiko_variant_action_max_attempts Maximum attempt count among variant actions by type and status.
# TYPE yomiko_variant_action_max_attempts gauge
# HELP yomiko_variant_high_attempt_actions Nonterminal variant actions with at least five attempts.
# TYPE yomiko_variant_high_attempt_actions gauge
# HELP yomiko_variant_expired_leases Variant leases at or before the metrics snapshot time.
# TYPE yomiko_variant_expired_leases gauge
# HELP yomiko_variant_discovery_errors Unfinished or failed discovery runs by bounded error class.
# TYPE yomiko_variant_discovery_errors gauge
# HELP yomiko_uploader_revision_publication_blocked Current discovery components blocked by provider uploader-revision validation.
# TYPE yomiko_uploader_revision_publication_blocked gauge
# HELP yomiko_variant_actionable_reviews Current pending review cards visible in the review queue by review type.
# TYPE yomiko_variant_actionable_reviews gauge
# HELP yomiko_variant_groups Current identity-active variant groups.
# TYPE yomiko_variant_groups gauge
# HELP yomiko_variant_discovery_due_groups Active groups currently due for discovery by reason.
# TYPE yomiko_variant_discovery_due_groups gauge
# HELP yomiko_variant_invariant_violations Records violating a fixed Yomiko data invariant.
# TYPE yomiko_variant_invariant_violations gauge
# HELP yomiko_gallery_data_quality_records Records with a bounded data-quality problem.
# TYPE yomiko_gallery_data_quality_records gauge
# HELP yomiko_gallery_status Current revision-terminal gallery counts in an exhaustive exclusive partition. Precedence is rated_11_variant_canonical > rated_11_variant_alternate > canonical_selection_unresolved > rated_under_11_variant_grouped_galleries > candidate_identity_review_pending > different_book > pending_rating > hath_requested > unclassified; canonical states require an active rating-11 group, canonical_selection_unresolved does not imply an actionable review, and candidate_identity_review_pending requires one. hath_requested means a newer H@H request or attempt watermark exists, not that a client is transferring now.
# TYPE yomiko_gallery_status gauge
# HELP yomiko_raw_galleries_rows Total number of rows in the galleries table, including revision predecessors.
# TYPE yomiko_raw_galleries_rows gauge
# HELP yomiko_galleries Current revision-terminal gallery count from the same read snapshot as yomiko_gallery_status.
# TYPE yomiko_galleries gauge
EOF
}

# Materialize the revision snapshot and active membership used by gallery-status
# metrics once per read-only SQLite connection. The persistent schema-28 views
# recursively expand the entire gallery table for every consumer; the request
# path uses this target-seeded projection instead. Metrics seeds every gallery
# to identify current terminals, including incomplete or blocked ones.
metrics_request_snapshot_sql() {
  cat <<SQL
CREATE TEMP TABLE metrics_revision_projection AS
$(variants_revision_projection_sql status)
SELECT revision_gid,terminal_gid,component_gid,component_size,ready,
       is_terminal,blocked_reason,component_gids
  FROM revision_projection;
CREATE TEMP TABLE metrics_ready_revision_terminals AS
SELECT terminal_gid AS gid
  FROM metrics_revision_projection
 WHERE ready=1 AND is_terminal=1;
CREATE INDEX metrics_ready_revision_terminals_gid
    ON metrics_ready_revision_terminals(gid);

CREATE INDEX metrics_revision_projection_revision_gid
    ON metrics_revision_projection(revision_gid);
CREATE TEMP VIEW revision_projection AS
SELECT revision_gid,terminal_gid,component_gid,component_size,ready,
       is_terminal,blocked_reason,component_gids,NULL AS edge_provenance
  FROM metrics_revision_projection;
CREATE TEMP VIEW scoreable_revision_terminals AS
SELECT gid FROM metrics_ready_revision_terminals;

CREATE TEMP TABLE metrics_identity_active_membership AS
SELECT member.gid,
       member.group_id AS active_group_id
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped
    ON grouped.id=member.group_id AND grouped.identity_active=1
 WHERE member.membership_state='confirmed'
   AND EXISTS (SELECT 1
                 FROM metrics_ready_revision_terminals AS scoreable
                WHERE scoreable.gid=member.gid);
CREATE INDEX metrics_identity_active_membership_gid
    ON metrics_identity_active_membership(gid);

CREATE TEMP TABLE metrics_review_projection_cache(
  kind TEXT NOT NULL,
  key_id INTEGER,
  group_id INTEGER,
  source_gid INTEGER,
  candidate_gid INTEGER,
  low_class_gid INTEGER,
  high_class_gid INTEGER,
  source_class_size INTEGER,
  candidate_class_size INTEGER,
  owner_is_active INTEGER,
  is_visible INTEGER,
  superseded_at TEXT,
  implied_decision TEXT,
  supporting_review_id INTEGER,
  rank INTEGER,
  terminal_gid INTEGER,
  component_gid INTEGER,
  component_size INTEGER,
  ready INTEGER,
  is_terminal INTEGER,
  blocked_reason TEXT,
  component_gids TEXT,
  edge_provenance TEXT
);
INSERT INTO metrics_review_projection_cache(
  kind,key_id,group_id,source_gid,candidate_gid,low_class_gid,
  high_class_gid,source_class_size,candidate_class_size,owner_is_active,
  is_visible,superseded_at,implied_decision,supporting_review_id,rank,
  terminal_gid,component_gid,component_size,ready,is_terminal,
  blocked_reason,component_gids,edge_provenance
)
$(variants_review_identity_projection_sql);
CREATE INDEX metrics_review_projection_cache_kind_key_idx
    ON metrics_review_projection_cache(kind,key_id);
CREATE TEMP VIEW identity_review_visibility AS
SELECT key_id AS review_id,is_visible
  FROM metrics_review_projection_cache
 WHERE kind='visibility';
CREATE TEMP VIEW identity_pending_candidate AS
SELECT key_id AS review_id,group_id,source_gid,candidate_gid,
       low_class_gid,high_class_gid,source_class_size,candidate_class_size,
       owner_is_active,is_visible,superseded_at,implied_decision,
       supporting_review_id,rank
  FROM metrics_review_projection_cache
 WHERE kind='pending';
CREATE TEMP TABLE metrics_actionable_reviews(
  review_type TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);
INSERT INTO metrics_actionable_reviews
SELECT 'candidate_identity', COUNT(*)
  FROM identity_pending_candidate
 WHERE implied_decision IS NULL
   AND is_visible=1
   AND rank=1
   AND superseded_at IS NULL
UNION ALL
SELECT 'winner', COUNT(*)
  FROM variant_reviews AS winner
  JOIN identity_review_visibility AS visibility
    ON visibility.review_id=winner.id
  JOIN variant_groups AS grouped ON grouped.id=winner.group_id
 WHERE winner.review_type='winner'
   AND winner.status='pending'
   AND winner.superseded_at IS NULL
   AND grouped.identity_active=1
   AND grouped.desired_rating=11
   AND visibility.is_visible=1;
SQL
}

# TODO(metrics): Restore an oldest runnable-job age metric if an operator alert
# needs the age of currently due queued jobs.
# TODO(metrics): Restore an oldest runnable-action age metric if an operator
# alert needs the age of currently due pending or retryable actions.
# TODO(metrics): Restore an oldest active discovery-run age metric if an operator
# alert needs the age of the current running or retryable run.
# TODO(metrics): Reconsider exporting discovery-run phase/status for debugging
# if direct SQL inspection of variant_discovery_runs is insufficient. Historical run
# rows do not represent the current revision-terminal gallery count.
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
job_failure_classes(error_class) AS (
  VALUES ('transient'), ('permanent'), ('configuration'), ('uncertain'),
         ('unknown')
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
gallery_statuses(precedence, state) AS (
  VALUES (1, 'rated_11_variant_canonical'),
         (2, 'rated_11_variant_alternate'),
         (3, 'canonical_selection_unresolved'),
         (4, 'rated_under_11_variant_grouped_galleries'),
         (5, 'candidate_identity_review_pending'),
         (6, 'different_book'),
         (7, 'pending_rating'),
         (8, 'hath_requested'),
         (9, 'unclassified')
),
active_variant_roles(gid, state) AS (
  SELECT active.gid,
         CASE
           WHEN MAX(CASE WHEN grouped.is_active=1 AND grouped.desired_rating=11
                              AND grouped.canonical_gid = active.gid THEN 1 ELSE 0 END) = 1
             THEN 'rated_11_variant_canonical'
           WHEN MAX(CASE WHEN grouped.is_active=1 AND grouped.desired_rating=11
                              AND grouped.canonical_gid IS NOT NULL THEN 1 ELSE 0 END) = 1
             THEN 'rated_11_variant_alternate'
           WHEN MAX(CASE WHEN grouped.is_active=1 AND grouped.desired_rating=11
                           THEN 1 ELSE 0 END) = 1
             THEN 'canonical_selection_unresolved'
           ELSE 'rated_under_11_variant_grouped_galleries'
         END AS state
    FROM metrics_identity_active_membership AS active
    JOIN variant_groups AS grouped ON grouped.id = active.active_group_id
   GROUP BY active.gid
),
actionable_identity_candidates(gid) AS (
  SELECT DISTINCT revision.terminal_gid
    FROM identity_pending_candidate AS pending
    JOIN metrics_revision_projection AS revision
      ON revision.revision_gid = pending.candidate_gid
   WHERE pending.implied_decision IS NULL
     AND pending.is_visible=1
     AND pending.rank=1
     AND pending.superseded_at IS NULL
     AND revision.ready=1
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
               FROM actionable_identity_candidates AS candidate
              WHERE candidate.gid = gallery.gid
           ) THEN 'candidate_identity_review_pending'
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
    FROM metrics_revision_projection AS terminal
    JOIN galleries AS gallery ON gallery.gid=terminal.revision_gid
    LEFT JOIN active_variant_roles AS roles ON roles.gid = gallery.gid
   WHERE terminal.is_terminal=1
),
gallery_status_counts(state, value) AS (
  SELECT state, COUNT(*)
    FROM gallery_status_projection
   GROUP BY state
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
latest_terminal_jobs AS (
  SELECT job_type, group_id, target_policy_revision_id, status,
         COALESCE(last_error_class,'unknown') AS error_class,
         ROW_NUMBER() OVER (
           PARTITION BY job_type, COALESCE(group_id,0) ORDER BY id DESC
         ) AS terminal_rank
    FROM variant_jobs
   WHERE status IN ('completed','failed','cancelled')
),
unresolved_job_failure_counts AS (
  SELECT job.job_type, job.error_class, COUNT(*) AS value
    FROM latest_terminal_jobs AS job
    LEFT JOIN variant_groups AS grouped ON grouped.id=job.group_id
   WHERE job.terminal_rank=1 AND job.status='failed'
     AND (
       (job.job_type='discover' AND grouped.identity_active=1)
       OR (job.job_type='evaluate' AND grouped.identity_active=1
           AND grouped.is_active=1 AND grouped.desired_rating=11)
       OR (job.job_type='reconcile_actions' AND grouped.is_active=1)
       OR (job.job_type='reconcile_retention' AND grouped.identity_active=1
           AND grouped.is_active=1 AND grouped.desired_rating=11)
       OR (job.job_type='policy_scoring_sweep' AND EXISTS (
             SELECT 1 FROM variant_policy_revisions AS policy
              WHERE policy.id=job.target_policy_revision_id AND policy.is_active=1))
     )
   GROUP BY job.job_type, job.error_class
),
job_outcome_counts AS (
  SELECT job_type, outcome, value
    FROM variant_job_outcome_counters
),
-- TODO(metrics): surface sustained starvation by correlating the age/count of
-- due, claimable jobs at attempt_count=0 with windowed progress across distinct
-- jobs. Fresh heartbeats and rising retry attempts are not queue progress; due
-- jobs may also be prerequisite-blocked, so account for claimability over time.
-- Prior recurrence: stale retries, pre-claim recovery, discovery continuation.
runnable_job_counts AS (
  SELECT job_type, COUNT(*) AS value
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
latest_current_actions AS (
  SELECT action.action_type, action.gid, action.status,
         action.last_error_class,
         json_extract(action.result_json,'$.outcome') AS last_outcome,
         ROW_NUMBER() OVER (
           PARTITION BY action.action_type, action.gid ORDER BY action.id DESC
         ) AS task_rank
    FROM variant_actions AS action
    JOIN variant_groups AS grouped
      ON grouped.id=action.group_id AND grouped.identity_active=1
),
current_action_failures AS (
  SELECT action_type,
         CASE
           WHEN status IN ('retryable_error','configuration_error','permanent_error')
             AND last_error_class IS NOT NULL THEN last_error_class
           WHEN last_outcome IN ('transient','uncertain','configuration','permanent')
             THEN last_outcome
           WHEN status IN ('retryable_error','configuration_error','permanent_error')
             THEN 'unknown'
         END AS error_class
    FROM latest_current_actions
   WHERE task_rank=1
     AND status IN ('pending','in_flight','retryable_error',
                    'configuration_error','permanent_error')
),
unresolved_action_failure_counts AS (
  SELECT action_type, error_class, COUNT(*) AS value
    FROM current_action_failures
   WHERE error_class IS NOT NULL
   GROUP BY action_type, error_class
),
runnable_action_counts AS (
  SELECT action_type, COUNT(*) AS value
    FROM variant_actions, snapshot
   WHERE status IN ('pending','retryable_error')
     AND available_at <= snapshot.now_text
   GROUP BY action_type
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
discovery_error_counts AS (
  SELECT phase, last_error_class AS error_class, COUNT(*) AS value
    FROM variant_discovery_runs
   WHERE status IN ('running','retryable','failed') AND last_error_class IS NOT NULL
   GROUP BY phase, last_error_class
),
blocked_publication_reasons(reason) AS (
  VALUES ('reference_incomplete'), ('scope_incomplete'),
         ('scoring_input_incomplete'), ('token_mismatch'),
         ('relation_conflict'), ('cycle'), ('branch'), ('multiple_terminals')
),
blocked_publication_counts(reason, value) AS (
  SELECT reasons.reason,
         COALESCE(SUM(CASE WHEN run.blocked_reason = reasons.reason
                           THEN MAX(run.blocked_component_count, 1) ELSE 0 END), 0)
    FROM blocked_publication_reasons AS reasons
    LEFT JOIN variant_discovery_runs AS run
      ON run.status IN ('running','retryable')
   GROUP BY reasons.reason
),
actionable_review_counts AS (
  SELECT review_type, value FROM metrics_actionable_reviews
),
group_counts AS (
  SELECT COUNT(*) AS value
    FROM variant_groups
   WHERE identity_active=1
),
due_group_counts AS (
  SELECT CASE
           WHEN last_discovered_at IS NULL THEN 'never_completed'
           WHEN COALESCE(completed_matching_revision,0) <> 6 THEN 'matching_revision'
           ELSE 'scheduled_time'
         END AS reason, COUNT(*) AS value
    FROM variant_groups, snapshot
   WHERE identity_active=1
     AND (last_discovered_at IS NULL
       OR COALESCE(completed_matching_revision,0) <> 6
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
   WHERE ((grouped.active_evaluation_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM variant_evaluations AS evaluation
             WHERE evaluation.id=grouped.active_evaluation_id
               AND evaluation.state='completed'
               AND (grouped.canonical_gid IS NOT evaluation.canonical_gid)
         ))
     OR EXISTS (
            SELECT 1 FROM variant_canonical_decisions AS decision
             WHERE decision.group_id=grouped.id AND decision.status='active'
               AND (decision.canonical_gid IS NOT grouped.canonical_gid
                 OR NOT EXISTS (SELECT 1 FROM gallery_variants AS selected
                                 WHERE selected.group_id=decision.group_id
                                   AND selected.gid=decision.canonical_gid
                                   AND selected.membership_state='confirmed')
                 OR decision.member_fingerprint IS NOT (
                   SELECT json_group_array(gid) FROM (
                     SELECT gid FROM gallery_variants
                      WHERE group_id=decision.group_id
                        AND membership_state='confirmed'
                      ORDER BY gid)))
         )
      OR EXISTS (
            SELECT 1 FROM gallery_variants AS member
             WHERE member.group_id=grouped.id
               AND member.membership_state='confirmed'
               AND member.variant_state IS NOT CASE
                 WHEN grouped.canonical_gid IS NULL THEN 'undetermined'
                 WHEN member.gid=grouped.canonical_gid THEN 'canonical'
                 ELSE 'alternate' END
         ))
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
   WHERE grouped.identity_active=1 AND grouped.is_active=1
     AND grouped.desired_rating=11
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
   WHERE grouped.identity_active=1 AND grouped.is_active=1
     AND member.membership_state='confirmed'
     AND gallery.tags IS NULL
  UNION ALL
  SELECT 'missing_page_count', COUNT(*)
    FROM galleries AS gallery
    JOIN gallery_variants AS member ON member.gid=gallery.gid
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
   WHERE grouped.identity_active=1 AND grouped.is_active=1
     AND member.membership_state='confirmed'
     AND gallery.file_count IS NULL
  UNION ALL
  SELECT 'missing_popularity', COUNT(*)
    FROM galleries AS gallery
    JOIN gallery_variants AS member ON member.gid=gallery.gid
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
   WHERE grouped.identity_active=1 AND grouped.is_active=1
     AND member.membership_state='confirmed'
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
SELECT 31, 'yomiko_variant_unresolved_job_failures', types.job_type,
       classes.error_class, '', COALESCE(counts.value,0)
  FROM job_types AS types CROSS JOIN job_failure_classes AS classes
  LEFT JOIN unresolved_job_failure_counts AS counts
    ON counts.job_type=types.job_type AND counts.error_class=classes.error_class
UNION ALL
SELECT 32, 'yomiko_variant_job_outcomes_total', types.job_type, outcomes.outcome, '', COALESCE(counts.value,0)
  FROM job_types AS types CROSS JOIN job_outcomes AS outcomes
  LEFT JOIN job_outcome_counts AS counts
    ON counts.job_type=types.job_type AND counts.outcome=outcomes.outcome
UNION ALL
SELECT 33, 'yomiko_variant_runnable_jobs', types.job_type, '', '', COALESCE(counts.value,0)
  FROM job_types AS types LEFT JOIN runnable_job_counts AS counts USING(job_type)
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
SELECT 40, 'yomiko_variant_unresolved_action_failures', types.action_type,
       classes.error_class, '', COALESCE(counts.value,0)
  FROM action_types AS types CROSS JOIN job_failure_classes AS classes
  LEFT JOIN unresolved_action_failure_counts AS counts
    ON counts.action_type=types.action_type AND counts.error_class=classes.error_class
UNION ALL
SELECT 41, 'yomiko_variant_runnable_actions', types.action_type, '', '', COALESCE(counts.value,0)
  FROM action_types AS types LEFT JOIN runnable_action_counts AS counts USING(action_type)
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
SELECT 51, 'yomiko_variant_discovery_errors', phase, error_class, '', value FROM discovery_error_counts
UNION ALL
SELECT 54, 'yomiko_uploader_revision_publication_blocked', reason, '', '', value
  FROM blocked_publication_counts
UNION ALL
SELECT 59, 'yomiko_variant_actionable_reviews', review_type, '', '', value
  FROM actionable_review_counts
UNION ALL
SELECT 61, 'yomiko_variant_groups', '', '', '', value FROM group_counts
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
SELECT 70, 'yomiko_raw_galleries_rows', '', '', '', COUNT(*)
  FROM galleries
UNION ALL
SELECT 71, 'yomiko_galleries', '', '', '', COUNT(*)
  FROM metrics_revision_projection
 WHERE is_terminal=1
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

  # Use a non-whitespace, non-printing separator so empty label columns remain
  # positional when Bash reads the renderer rows.  Tab is an IFS whitespace
  # character and collapses the empty fields in rows such as
  # `schema_version\t''\t''\t''\tvalue`.
  local metrics_separator=$'\x1f'
  local rows
  local requested_gids metrics_query
  # The projection SQL accepts its GID seed as bound JSON, so enumerate that
  # seed before opening the scrape transaction. A gallery inserted between seed
  # enumeration and BEGIN is reflected on the next scrape or temporarily falls
  # into residual classification. A same-connection transactional seed would
  # remove this window. From BEGIN through COMMIT, the revision snapshot, active
  # membership, and exported rows share one read view.
  requested_gids="$(db_query "SELECT COALESCE(json_group_array(gid),json('[]')) FROM galleries;")" || return 1
  metrics_query="$(metrics_sql)
COMMIT;"
  if ! rows="$(db_query \
    ".parameter set :requested_gids $(db_parameter_text "${requested_gids}")" \
    '.mode list' ".separator ${metrics_separator}" '.headers off' \
    'BEGIN;' \
    "$(metrics_request_snapshot_sql)" \
    "${metrics_query}")"; then
    return 1
  fi

  local sort metric label_one label_two label_three value
  local stale_after_components='' runtime_component
  local job_status_sample_count=0 job_outcome_sample_count=0
  local actionable_review_sample_count=0 blocked_publication_sample_count=0
  local -A job_status_samples=() job_outcome_samples=() job_error_samples=() actionable_review_samples=() blocked_publication_samples=()
  while IFS=$'\x1f' read -r sort metric label_one label_two label_three value; do
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
    yomiko_variant_unresolved_job_failures)
      metrics_job_type_is_valid "${label_one}" || return 1
      case "${label_two}" in
      transient | permanent | configuration | uncertain | unknown) ;;
      *) return 1 ;;
      esac
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" error_class "${label_two}" ;;
    yomiko_variant_runnable_jobs | yomiko_variant_high_attempt_jobs)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" ;;
    yomiko_variant_jobs_created_recent)
      metrics_append_sample "${metric}" "${value}" job_type "${label_one}" window "${label_two}" ;;
    yomiko_variant_actions)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" status "${label_two}" error_class "${label_three}" ;;
    yomiko_variant_unresolved_action_failures)
      case "${label_one}" in
      rating | favorite_move | favorite_remove | hath_request | archive_cleanup) ;;
      *) return 1 ;;
      esac
      case "${label_two}" in
      transient | permanent | configuration | uncertain | unknown) ;;
      *) return 1 ;;
      esac
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" error_class "${label_two}" ;;
    yomiko_variant_runnable_actions | yomiko_variant_high_attempt_actions)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" ;;
    yomiko_variant_action_max_attempts)
      metrics_append_sample "${metric}" "${value}" action_type "${label_one}" status "${label_two}" ;;
    yomiko_variant_expired_leases)
      metrics_append_sample "${metric}" "${value}" resource "${label_one}" ;;
    yomiko_variant_discovery_errors)
      metrics_append_sample "${metric}" "${value}" phase "${label_one}" error_class "${label_two}" ;;
    yomiko_uploader_revision_publication_blocked)
      case "${label_one}" in
      reference_incomplete | scope_incomplete | scoring_input_incomplete | \
      token_mismatch | relation_conflict | cycle | branch | multiple_terminals) ;;
      *) return 1 ;;
      esac
      metrics_nonnegative_integer_is_valid "${value}" || return 1
      local blocked_key="${label_one}"
      [[ -z "${blocked_publication_samples[${blocked_key}]+present}" ]] || return 1
      blocked_publication_samples["${blocked_key}"]=1
      blocked_publication_sample_count=$((blocked_publication_sample_count + 1))
      metrics_append_sample "${metric}" "${value}" reason "${label_one}" ;;
    yomiko_variant_actionable_reviews)
      case "${label_one}" in
      candidate_identity | winner) ;;
      *) return 1 ;;
      esac
      [[ "${label_two}" == '""' ]] && label_two=''
      [[ "${label_three}" == '""' ]] && label_three=''
      [[ -z "${label_two}" && -z "${label_three}" ]] || return 1
      metrics_nonnegative_integer_is_valid "${value}" || return 1
      local actionable_review_key="${label_one}"
      [[ -z "${actionable_review_samples[${actionable_review_key}]+present}" ]] || return 1
      actionable_review_samples["${actionable_review_key}"]=1
      actionable_review_sample_count=$((actionable_review_sample_count + 1))
      metrics_append_sample "${metric}" "${value}" review_type "${label_one}" ;;
    yomiko_variant_groups)
      [[ -z "${label_one}" && -z "${label_two}" && -z "${label_three}" ]] || return 1
      metrics_nonnegative_integer_is_valid "${value}" || return 1
      metrics_append_sample "${metric}" "${value}" ;;
    yomiko_variant_discovery_due_groups)
      metrics_append_sample "${metric}" "${value}" reason "${label_one}" ;;
    yomiko_variant_invariant_violations)
      metrics_append_sample "${metric}" "${value}" invariant "${label_one}" ;;
    yomiko_gallery_data_quality_records)
      metrics_append_sample "${metric}" "${value}" problem "${label_one}" ;;
    yomiko_gallery_status)
      metrics_append_sample "${metric}" "${value}" state "${label_one}" ;;
    yomiko_raw_galleries_rows | yomiko_galleries)
      metrics_append_sample "${metric}" "${value}" ;;
    *) return 1 ;;
    esac
  done <<<"${rows}"

  [[ "${job_status_sample_count}" -eq 25 ]] || return 1
  [[ "${job_outcome_sample_count}" -eq 30 ]] || return 1
  [[ "${actionable_review_sample_count}" -eq 2 ]] || return 1
  [[ -n "${actionable_review_samples[candidate_identity]+present}" ]] || return 1
  [[ -n "${actionable_review_samples[winner]+present}" ]] || return 1
  [[ "${blocked_publication_sample_count}" -eq 8 ]] || return 1
  local blocked_reason
  for blocked_reason in reference_incomplete scope_incomplete scoring_input_incomplete \
    token_mismatch relation_conflict cycle branch multiple_terminals; do
    [[ -n "${blocked_publication_samples[${blocked_reason}]+present}" ]] || return 1
  done
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

  for runtime_component in scheduler_tick variant_worker scan; do
    case ",${stale_after_components}," in
    *",${runtime_component},"*) ;;
    *) return 1 ;;
    esac
  done

  printf '%s' "${payload}"
}
