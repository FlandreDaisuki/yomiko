#!/usr/bin/env bash

# Independent durable worker primitives for gallery variant discovery and local
# evaluation. The caller sources common.sh, db.sh, exh.sh, variants.sh,
# variant_policy.sh, variant_scoring.sh, and variant_matching.sh first.

VARIANTS_MATCHING_REVISION=1
VARIANTS_MATCHING_REVISION_PRIORITY=500
VARIANTS_ANNUAL_DISCOVERY_PRIORITY=100
VARIANTS_POLICY_WORK_PRIORITY=500
VARIANTS_WORK_LEASE_MINUTES=15

variants_worker_cancel_inactive_discovery() {
  db_query \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_inactive_discovery_jobs(id INTEGER PRIMARY KEY);
     INSERT INTO variant_inactive_discovery_jobs(id)
       SELECT job.id FROM variant_jobs AS job
       JOIN variant_groups AS grouped ON grouped.id = job.group_id
        WHERE job.job_type = 'discover' AND job.status = 'queued'
          AND grouped.is_active = 0;
     UPDATE variant_discovery_runs
        SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = 'group is inactive'
      WHERE job_id IN (SELECT id FROM variant_inactive_discovery_jobs)
        AND status IN ('running', 'retryable');
     UPDATE variant_jobs
        SET status = 'cancelled', completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = 'group is inactive'
      WHERE id IN (SELECT id FROM variant_inactive_discovery_jobs);
     SELECT count(*) FROM variant_inactive_discovery_jobs;
     COMMIT;"
}

variants_worker_cancel_discovery_job() {
  local job_id="$1" owner="$2" cancelled
  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  cancelled="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_cancelled_discovery(id INTEGER PRIMARY KEY);
     INSERT INTO variant_cancelled_discovery(id)
       SELECT job.id FROM variant_jobs AS job
       JOIN variant_groups AS grouped ON grouped.id = job.group_id
        WHERE job.id = :job_id AND job.job_type = 'discover'
          AND job.status = 'leased' AND job.lease_owner = :owner
          AND grouped.is_active = 0;
     UPDATE variant_discovery_runs
        SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = 'group became inactive'
      WHERE job_id IN (SELECT id FROM variant_cancelled_discovery)
        AND status = 'running';
     UPDATE variant_jobs
        SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = 'group became inactive'
      WHERE id IN (SELECT id FROM variant_cancelled_discovery);
     SELECT count(*) FROM variant_cancelled_discovery;
     COMMIT;")" || return
  [[ "${cancelled}" == 1 ]]
}

variants_worker_schedule_discovery() {
  db_query \
    ".parameter set :matching_revision ${VARIANTS_MATCHING_REVISION}" \
    ".parameter set :revision_priority ${VARIANTS_MATCHING_REVISION_PRIORITY}" \
    ".parameter set :annual_priority ${VARIANTS_ANNUAL_DISCOVERY_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_due_discovery(
       group_id INTEGER PRIMARY KEY,
       source_gid INTEGER NOT NULL,
       priority INTEGER NOT NULL
     );
     INSERT INTO variant_due_discovery(group_id, source_gid, priority)
       SELECT grouped.id, grouped.source_gid,
              CASE WHEN COALESCE(grouped.completed_matching_revision, 0)
                              <> :matching_revision
                   THEN :revision_priority ELSE :annual_priority END
        FROM variant_groups AS grouped
       WHERE grouped.is_active = 1
          AND NOT EXISTS (
            SELECT 1 FROM variant_discovery_runs AS failed_run
             WHERE failed_run.group_id = grouped.id
               AND failed_run.matching_revision = :matching_revision
               AND failed_run.status = 'failed'
          )
          AND (COALESCE(grouped.completed_matching_revision, 0)
                 <> :matching_revision
            OR (grouped.next_discovery_at IS NOT NULL
                AND grouped.next_discovery_at <=
                    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')));
     UPDATE variant_jobs
        SET priority = MAX(priority, COALESCE((
              SELECT due.priority FROM variant_due_discovery AS due
               WHERE due.group_id = variant_jobs.group_id), priority)),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_type = 'discover' AND status = 'queued'
        AND group_id IN (SELECT group_id FROM variant_due_discovery);
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     )
       SELECT 'discover', due.group_id, due.source_gid, due.priority, 'queued'
         FROM variant_due_discovery AS due;
     SELECT json_object(
       'due_groups', (SELECT count(*) FROM variant_due_discovery),
       'runnable_jobs', (SELECT count(*) FROM variant_jobs AS job
                          JOIN variant_due_discovery AS due
                            ON due.group_id = job.group_id
                         WHERE job.job_type = 'discover'
                           AND job.status IN ('queued', 'leased'))
     );
     COMMIT;"
}

variants_worker_requeue_expired_leases() {
  db_query \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_expired_jobs(id INTEGER PRIMARY KEY);
     INSERT INTO variant_expired_jobs(id)
       SELECT id FROM variant_jobs
        WHERE job_type IN ('discover', 'evaluate', 'policy_scoring_sweep',
                           'reconcile_actions', 'reconcile_retention')
          AND status = 'leased'
          AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     UPDATE variant_discovery_runs
        SET status = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = 'transient',
            last_error = 'worker lease expired'
      WHERE job_id IN (SELECT id FROM variant_expired_jobs)
        AND status = 'running';
     UPDATE variant_jobs
        SET status = 'queued', lease_owner = NULL, lease_expires_at = NULL,
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = 'transient',
            last_error = 'worker lease expired'
      WHERE id IN (SELECT id FROM variant_expired_jobs);
     UPDATE variant_actions
        SET status = 'retryable_error', lease_owner = NULL,
            lease_expires_at = NULL, lease_job_id = NULL,
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = 'uncertain',
            last_error = 'action lease expired; remote result is uncertain',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE status = 'in_flight'
        AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     SELECT count(*) FROM variant_expired_jobs;
     COMMIT;"
}

# Atomically lease the highest-priority supported job. The returned internal
# JSON contains group_id; callers must remove it from public output.
variants_worker_claim_job() {
  local owner="$1"
  local allow_discover="${2:-1}"

  [[ -n "${owner}" ]] || return 1
  [[ "${allow_discover}" == 0 || "${allow_discover}" == 1 ]] || return 1
  db_query \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :allow_discover ${allow_discover}" \
    ".parameter set :matching_revision ${VARIANTS_MATCHING_REVISION}" \
    ".parameter set :lease_minutes ${VARIANTS_WORK_LEASE_MINUTES}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_claimed_job(id INTEGER PRIMARY KEY);
     INSERT INTO variant_claimed_job(id)
       SELECT job.id
         FROM variant_jobs AS job
         LEFT JOIN variant_groups AS grouped ON grouped.id = job.group_id
        WHERE job.job_type IN ('discover', 'evaluate', 'policy_scoring_sweep',
                               'reconcile_actions', 'reconcile_retention')
          AND (:allow_discover = 1 OR job.job_type <> 'discover')
          AND job.status = 'queued'
          AND job.available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          AND (job.job_type <> 'discover' OR grouped.is_active = 1)
        ORDER BY job.priority DESC, job.id
        LIMIT 1;
     UPDATE variant_jobs
        SET status = 'leased', attempt_count = attempt_count + 1,
            lease_owner = :owner,
            lease_expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now',
              '+' || :lease_minutes || ' minutes'),
            last_error_class = NULL, last_error = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT id FROM variant_claimed_job);
     INSERT OR IGNORE INTO variant_discovery_runs(
       group_id, job_id, matching_revision, phase, status,
       lease_owner, lease_expires_at
     )
       SELECT job.group_id, job.id, :matching_revision, 'seed_refresh',
              'running', job.lease_owner, job.lease_expires_at
         FROM variant_jobs AS job
        WHERE job.id = (SELECT id FROM variant_claimed_job)
          AND job.job_type = 'discover';
     UPDATE variant_discovery_runs
        SET status = 'running', lease_owner = :owner,
            lease_expires_at = (SELECT lease_expires_at FROM variant_jobs
                                  WHERE id = variant_discovery_runs.job_id),
            attempt_count = attempt_count + 1,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_id = (SELECT id FROM variant_claimed_job)
        AND status IN ('running', 'retryable')
        AND lease_owner IS NULL;
     SELECT json_object(
       'id', job.id, 'job_type', job.job_type, 'group_id', job.group_id,
       'source_gid', job.source_gid, 'priority', job.priority,
       'attempt_count', job.attempt_count, 'lease_owner', job.lease_owner,
       'scoring_revision_id', job.scoring_revision_id,
       'lease_expires_at', job.lease_expires_at,
       'run_id', (SELECT run.id FROM variant_discovery_runs AS run
                   WHERE run.job_id = job.id
                     AND run.status IN ('running', 'retryable')
                   ORDER BY run.id DESC LIMIT 1)
     )
       FROM variant_jobs AS job
      WHERE job.id = (SELECT id FROM variant_claimed_job);
     COMMIT;"
}

variants_worker_continue_job() {
  local job_id="$1" owner="$2" cursor_json="${3:-null}"

  variants_worker_continue_job_at "${job_id}" "${owner}" "${cursor_json}" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# Requeue a leased job with an explicit continuation time.  The timestamp is
# supplied by the caller so a sweep can preserve a durable backoff/continuation
# decision without weakening the lease-owner guard.
# Called indirectly by the operational action dispatcher after all libraries
# have been sourced.
# shellcheck disable=SC2317
variants_worker_continue_job_at() {
  local job_id="$1" owner="$2" cursor_json="${3:-null}" available_at="$4"

  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  [[ "${available_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  jq -e 'type == "object" or type == "null"' >/dev/null <<<"${cursor_json}" || return 1
  local continued
  continued="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :cursor $(db_parameter_text "${cursor_json}")" \
    ".parameter set :available_at $(db_parameter_text "${available_at}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_continued_job(id INTEGER PRIMARY KEY);
     INSERT INTO variant_continued_job(id)
       SELECT id FROM variant_jobs
        WHERE id = :job_id AND status = 'leased' AND lease_owner = :owner;
     UPDATE variant_discovery_runs
        SET cursor_json = CASE WHEN :cursor = 'null' THEN NULL ELSE json(:cursor) END,
            status = 'running', lease_owner = NULL, lease_expires_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_id IN (SELECT id FROM variant_continued_job)
        AND status = 'running';
     UPDATE variant_jobs
        SET status = 'queued', lease_owner = NULL, lease_expires_at = NULL,
            continuation_cursor_json = CASE WHEN :cursor = 'null' THEN NULL ELSE json(:cursor) END,
            available_at = :available_at,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT id FROM variant_continued_job);
     SELECT count(*) FROM variant_continued_job;
     COMMIT;")" || return
  [[ "${continued}" == 1 ]] || return 1
  printf '%s\n' "${continued}"
}

variants_worker_complete_job() {
  local job_id="$1" owner="$2"
  local result_json="${3:-null}"

  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  jq empty >/dev/null 2>&1 <<<"${result_json}" || return 1
  local completed
  completed="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_completed_job(id INTEGER PRIMARY KEY);
     INSERT INTO variant_completed_job(id)
       SELECT id FROM variant_jobs
        WHERE id = :job_id AND status = 'leased' AND lease_owner = :owner;
     UPDATE variant_jobs
        SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
            last_error_class = NULL, last_error = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT id FROM variant_completed_job);
     SELECT count(*) FROM variant_completed_job;
     COMMIT;")" || return
  [[ "${completed}" == 1 ]] || return 1
  printf '%s\n' "${completed}"
}

variants_worker_retry_job() {
  local job_id="$1" owner="$2" error_class="$3" error_message="$4"

  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  case "${error_class}" in
  transient | uncertain) ;;
  *) return 1 ;;
  esac
  local delay
  delay="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :error_class $(db_parameter_text "${error_class}")" \
    ".parameter set :error_message $(db_parameter_text "${error_message}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_retry_job(id INTEGER PRIMARY KEY, delay_seconds INTEGER);
     INSERT INTO variant_retry_job(id, delay_seconds)
       SELECT id, CASE attempt_count
         WHEN 1 THEN 300 WHEN 2 THEN 900 WHEN 3 THEN 3600
         WHEN 4 THEN 21600 ELSE 86400 END
         FROM variant_jobs
        WHERE id = :job_id AND status = 'leased' AND lease_owner = :owner;
     UPDATE variant_discovery_runs
        SET status = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
            last_error_class = :error_class, last_error = :error_message,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_id IN (SELECT id FROM variant_retry_job)
        AND status = 'running';
     UPDATE variant_jobs
        SET status = 'queued', lease_owner = NULL, lease_expires_at = NULL,
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now',
              '+' || (SELECT delay_seconds FROM variant_retry_job) || ' seconds'),
            last_error_class = :error_class, last_error = :error_message,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT id FROM variant_retry_job);
     SELECT COALESCE((SELECT delay_seconds FROM variant_retry_job), 0);
     COMMIT;")" || return
  [[ "${delay}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${delay}"
}

variants_worker_fail_job() {
  local job_id="$1" owner="$2" error_class="$3" error_message="$4"

  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  case "${error_class}" in
  permanent | configuration) ;;
  *) return 1 ;;
  esac
  local failed
  failed="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :error_class $(db_parameter_text "${error_class}")" \
    ".parameter set :error_message $(db_parameter_text "${error_message}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_failed_job(id INTEGER PRIMARY KEY);
     INSERT INTO variant_failed_job(id)
       SELECT id FROM variant_jobs
        WHERE id = :job_id AND status = 'leased' AND lease_owner = :owner;
     UPDATE variant_discovery_runs
        SET status = 'failed', lease_owner = NULL, lease_expires_at = NULL,
            last_error_class = :error_class, last_error = :error_message,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_id IN (SELECT id FROM variant_failed_job)
        AND status IN ('running', 'retryable');
     UPDATE variant_jobs
        SET status = 'failed', lease_owner = NULL, lease_expires_at = NULL,
            last_error_class = :error_class, last_error = :error_message,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT id FROM variant_failed_job);
     SELECT count(*) FROM variant_failed_job;
     COMMIT;")" || return
  [[ "${failed}" == 1 ]] || return 1
  printf '%s\n' "${failed}"
}

variants_worker_queue_action_reconciliation() {
  local group_id="$1" source_gid="$2" priority="$3"

  db_query \
    ".parameter set :group_id ${group_id}" \
    ".parameter set :source_gid ${source_gid}" \
    ".parameter set :priority ${priority}" \
    "BEGIN IMMEDIATE;
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = :group_id AND job_type = 'reconcile_actions'
        AND status = 'queued';
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     ) VALUES ('reconcile_actions', :group_id, :source_gid, :priority, 'queued');
     COMMIT;"
}

variants_worker_handle_evaluate() {
  local job_json="$1" owner="$2"
  local job_id group_id source_gid priority expected_revision active_revision
  local evaluation_json status=0

  job_id="$(jq -r '.id' <<<"${job_json}")"
  group_id="$(jq -r '.group_id' <<<"${job_json}")"
  source_gid="$(jq -r '.source_gid' <<<"${job_json}")"
  priority="$(jq -r '.priority' <<<"${job_json}")"
  expected_revision="$(jq -r '.scoring_revision_id // empty' <<<"${job_json}")"
  active_revision="$(db_query "SELECT id FROM variant_policy_revisions WHERE is_active=1;")" || return
  if [[ ! "${expected_revision}" =~ ^[1-9][0-9]*$ ||
    "${expected_revision}" != "${active_revision}" ]]; then
    db_query \
      ".parameter set :job_id ${job_id}" \
      ".parameter set :owner $(db_parameter_text "${owner}")" \
      ".parameter set :active_revision ${active_revision}" \
      "BEGIN IMMEDIATE;
       UPDATE variant_jobs
          SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
              scoring_revision_id=:active_revision,
              available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
              last_error_class='uncertain',
              last_error='scoring revision changed before evaluation',
              updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id=:job_id AND status='leased' AND lease_owner=:owner;
       SELECT changes();
       COMMIT;" | rg -qx '1' || return 1
    jq -nc --argjson source_gid "${source_gid}" \
      '{job_type:"evaluate",source_gid:$source_gid,status:"stale_revision"}'
    return 0
  fi

  evaluation_json="$(variants_evaluate_group "${group_id}" "${expected_revision}" 2>/dev/null)" || status=$?
  if [[ "${status}" -eq "${VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS}" ]]; then
    variants_worker_complete_job "${job_id}" "${owner}" "${evaluation_json:-null}" >/dev/null || return
    jq -nc --argjson source_gid "${source_gid}" --argjson result "${evaluation_json:-null}" \
      '{job_type:"evaluate",source_gid:$source_gid,status:"review_blocked",result:$result}'
    return 0
  fi
  if [[ "${status}" -ne 0 || -z "${evaluation_json}" ]] ||
    ! jq -e . >/dev/null 2>&1 <<<"${evaluation_json}"; then
    local delay
    delay="$(variants_worker_retry_job "${job_id}" "${owner}" transient \
      "local evaluation failed with status ${status}")" || return
    jq -nc --argjson source_gid "${source_gid}" --argjson delay "${delay}" \
      '{job_type:"evaluate",source_gid:$source_gid,status:"retryable_error",retry_in_seconds:$delay}'
    return 0
  fi

  if [[ "$(jq -r '.state // empty' <<<"${evaluation_json}")" == completed ]]; then
    variants_worker_queue_action_reconciliation "${group_id}" "${source_gid}" "${priority}" || return
  fi
  variants_worker_complete_job "${job_id}" "${owner}" "${evaluation_json}" >/dev/null || return
  jq -nc --argjson source_gid "${source_gid}" --argjson result "${evaluation_json}" \
    '{job_type:"evaluate",source_gid:$source_gid,status:"completed",result:$result}'
}

# Consume one global scoring sweep batch.  The cursor is intentionally a
# snapshot: groups created after the sweep starts are left for the next sweep,
# while the target policy revision prevents mixing scores across activation.
variants_worker_handle_policy_scoring_sweep() {
  local job_json="$1" owner="$2"
  local job_id target_revision cursor max_group last_group batch_json next_cursor
  job_id="$(jq -r '.id' <<<"${job_json}")"
  target_revision="$(jq -r '.scoring_revision_id // empty' <<<"${job_json}")"
  [[ "${target_revision}" =~ ^[1-9][0-9]*$ ]] || return 1

  cursor="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "SELECT COALESCE(continuation_cursor_json, json_object(
       'sweep_max_group_id', COALESCE((SELECT MAX(id) FROM variant_groups), 0),
       'last_group_id', 0,
       'target_revision_id', scoring_revision_id))
       FROM variant_jobs
      WHERE id=:job_id AND status='leased' AND lease_owner=:owner;")" || return
  [[ -n "${cursor}" ]] || return 1
  max_group="$(jq -r '.sweep_max_group_id' <<<"${cursor}")"
  last_group="$(jq -r '.last_group_id' <<<"${cursor}")"
  [[ "${max_group}" =~ ^[0-9]+$ && "${last_group}" =~ ^[0-9]+$ ]] || return 1

  # The revision check and all coalesced evaluate inserts are one transaction.
  # If activation raced this batch, put the sweep back at the new revision and
  # discard its old cursor before any evaluate job is committed.
  batch_json="$(db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :target_revision ${target_revision}" \
    ".parameter set :max_group ${max_group}" \
    ".parameter set :last_group ${last_group}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_sweep_batch(
       id INTEGER PRIMARY KEY, source_gid INTEGER NOT NULL);
     INSERT INTO variant_sweep_batch(id, source_gid)
       SELECT id, source_gid FROM variant_groups
        WHERE is_active=1 AND id > :last_group AND id <= :max_group
        ORDER BY id LIMIT 100;
     CREATE TEMP TABLE variant_sweep_state(
       valid INTEGER NOT NULL, new_revision INTEGER, processed INTEGER NOT NULL,
       next_last INTEGER NOT NULL);
     INSERT INTO variant_sweep_state(valid,new_revision,processed,next_last)
       SELECT CASE WHEN job.scoring_revision_id = active.id THEN 1 ELSE 0 END,
              active.id, (SELECT count(*) FROM variant_sweep_batch),
              COALESCE((SELECT max(id) FROM variant_sweep_batch), :last_group)
         FROM variant_jobs AS job
         JOIN variant_policy_revisions AS active ON active.is_active=1
        WHERE job.id=:job_id AND job.status='leased' AND job.lease_owner=:owner;
     UPDATE variant_jobs
        SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
            scoring_revision_id=(SELECT new_revision FROM variant_sweep_state),
            continuation_cursor_json=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class='uncertain',
            last_error='scoring revision changed during sweep',
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:job_id AND (SELECT valid FROM variant_sweep_state)=0;
     INSERT OR IGNORE INTO variant_jobs(
       job_type,group_id,source_gid,priority,status,scoring_revision_id)
       SELECT 'evaluate',batch.id,batch.source_gid,${VARIANTS_POLICY_WORK_PRIORITY},'queued',:target_revision
         FROM variant_sweep_batch AS batch
        WHERE (SELECT valid FROM variant_sweep_state)=1;
     UPDATE variant_jobs
        SET scoring_revision_id=:target_revision,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE job_type='evaluate' AND status='queued'
        AND group_id IN (SELECT id FROM variant_sweep_batch)
        AND (SELECT valid FROM variant_sweep_state)=1;
     SELECT json_object(
       'valid',json(CASE WHEN (SELECT valid FROM variant_sweep_state)=1
                         THEN 'true' ELSE 'false' END),
       'new_revision', (SELECT new_revision FROM variant_sweep_state),
       'processed', (SELECT processed FROM variant_sweep_state),
       'next_last', (SELECT next_last FROM variant_sweep_state));
     COMMIT;")" || return

  if [[ "$(jq -r '.valid' <<<"${batch_json}")" != true ]]; then
    jq -nc --argjson source_gid "$(jq -r '.source_gid // null' <<<"${job_json}")" \
      '{job_type:"policy_scoring_sweep",source_gid:$source_gid,status:"stale_revision"}'
    return 0
  fi

  local processed next_last
  processed="$(jq -r '.processed' <<<"${batch_json}")"
  next_last="$(jq -r '.next_last' <<<"${batch_json}")"
  next_cursor="$(jq -cn --argjson max "${max_group}" --argjson last "${next_last}" \
    --argjson target "${target_revision}" \
    '{sweep_max_group_id:$max,last_group_id:$last,target_revision_id:$target}')"
  if (( processed < 100 )); then
    variants_worker_complete_job "${job_id}" "${owner}" "${next_cursor}" >/dev/null || return
    jq -nc --argjson processed "${processed}" \
      '{job_type:"policy_scoring_sweep",source_gid:null,status:"completed",processed_groups:$processed}'
  else
    variants_worker_continue_job "${job_id}" "${owner}" "${next_cursor}" >/dev/null || return
    jq -nc --argjson processed "${processed}" \
      '{job_type:"policy_scoring_sweep",source_gid:null,status:"continued",processed_groups:$processed}'
  fi
}
