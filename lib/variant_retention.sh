#!/usr/bin/env bash

# Local retention and H@H coordination primitives.  These helpers deliberately
# do not execute remote actions or delete archives on their own except for the
# explicitly guarded alternate-cleanup helper.  The worker owns action
# scheduling; archive completion calls the queue helpers after its final rename.

VARIANTS_HATH_LOCK_DIR="/tmp"
VARIANTS_RETENTION_PRIORITY=500
VARIANTS_HATH_RETRY_INTERVAL_SECONDS=43200
# shellcheck disable=SC2034 # Read by the action executor after this helper returns.
VARIANTS_RETENTION_DELETE_RESULT=""

variants_retention_validate_gid() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

# Return the stable lock pathname used by both manual and variant-worker H@H
# requests.  The lock is per GID so unrelated requests can proceed in parallel.
variants_hath_lock_path() {
  local gid="$1"
  variants_retention_validate_gid "${gid}" || return 1
  printf '%s/yomiko-hath-%s.lock\n' "${VARIANTS_HATH_LOCK_DIR}" "${gid}"
}

# Acquire a non-blocking per-GID H@H lock.  The second argument is the name of
# a caller-owned variable that receives the open file descriptor.  Status 75
# means another process already owns the lock, matching archive-lock behavior.
variants_hath_lock_acquire() {
  local gid="$1" fd_var="$2" lock_path fd
  variants_retention_validate_gid "${gid}" || return 1
  [[ "${fd_var}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  lock_path="$(variants_hath_lock_path "${gid}")" || return
  exec {fd}>"${lock_path}"
  if ! flock -n "${fd}"; then
    eval "exec ${fd}>&-"
    return 75
  fi
  printf -v "${fd_var}" '%s' "${fd}"
}

variants_hath_lock_release() {
  local fd="$1"
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 1
  eval "exec ${fd}>&-"
}

variants_archive_lock_path() {
  local gid="$1"
  variants_retention_validate_gid "${gid}" || return 1
  printf '%s/yomiko-archive-%s.lock\n' "${VARIANTS_HATH_LOCK_DIR}" "${gid}"
}

variants_archive_lock_acquire() {
  local gid="$1" fd_var="$2" lock_path fd
  variants_retention_validate_gid "${gid}" || return 1
  [[ "${fd_var}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  lock_path="$(variants_archive_lock_path "${gid}")" || return
  exec {fd}>"${lock_path}"
  if ! flock -n "${fd}"; then
    eval "exec ${fd}>&-"
    return 75
  fi
  printf -v "${fd_var}" '%s' "${fd}"
}

variants_archive_lock_release() {
  local fd="$1"
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 1
  eval "exec ${fd}>&-"
}

# Any parseable same-GID directory below HATH_DOWNLOAD_DIR is considered to be
# in progress or complete.  In particular, galleryinfo.txt is not required:
# the H@H client may have created the directory before the completion marker.
variants_retention_hath_tree_contains_gid() {
  local gid="$1" root="${2:-${HATH_DOWNLOAD_DIR}}" candidate parsed
  variants_retention_validate_gid "${gid}" || return 1
  [[ -d "${root}" ]] || return 1

  while IFS= read -r -d '' candidate; do
    if parsed="$(exh_parse_path_meta "${candidate}" 2>/dev/null)" &&
      [[ "$(jq -r '.gid // empty' <<<"${parsed}")" == "${gid}" ]]; then
      return 0
    fi
  done < <(find "${root}" -type d -print0 2>/dev/null)
  return 1
}

# Validate an archive filename and require a regular, non-symlink file beneath
# ARCHIVED_DIR.  Return 2 for an unsafe filename so callers can expose a
# configuration error rather than treating it as an ordinary missing file.
variants_retention_archive_is_regular() {
  local file_path="$1" archive_file
  archive_filename_is_safe "${file_path}" || return 2
  archive_file="${ARCHIVED_DIR}/${file_path}"
  [[ -f "${archive_file}" && ! -L "${archive_file}" ]]
}

# Recheck and, when safe, clear a stale canonical path while holding the same
# per-GID lock used by archive.  The result is a small diagnostic object so the
# worker and dry-run surfaces can distinguish waiting states.
variants_retention_recover_group() {
  local group_id="$1" snapshot group_gid file_path lock_fd='' lock_status=0
  local state deadline
  variants_validate_positive_integer "group ID" "${group_id}" || return 1

  snapshot="$(db_query \
    ".parameter set :group_id ${group_id}" \
    "SELECT grouped.canonical_gid || char(9) || COALESCE(canonical.file_path, '')
       FROM variant_groups AS grouped
       JOIN variant_evaluations AS evaluation
         ON evaluation.id=grouped.active_evaluation_id
        AND evaluation.state='completed'
       LEFT JOIN galleries AS canonical ON canonical.gid=grouped.canonical_gid
      WHERE grouped.id=:group_id AND grouped.is_active=1
        AND grouped.desired_rating=11 AND grouped.canonical_gid IS NOT NULL;")" || return
  [[ -n "${snapshot}" ]] || return 0
  IFS=$'\t' read -r group_gid file_path <<<"${snapshot}"

  variants_archive_lock_acquire "${group_gid}" lock_fd || lock_status=$?
  if [[ "${lock_status}" -eq 75 ]]; then
    jq -nc --argjson group_id "${group_id}" --argjson gid "${group_gid}" \
      '{group_id:$group_id,gid:$gid,state:"archive_lock_busy"}'
    return 0
  elif [[ "${lock_status}" -ne 0 ]]; then
    return "${lock_status}"
  fi

  # The archive lock closes the SQLite-update/final-rename race.  Re-read all
  # intent after acquiring it; the first snapshot is only a lock target.
  snapshot="$(db_query \
    ".parameter set :group_id ${group_id}" \
    "SELECT grouped.canonical_gid || char(9) || COALESCE(canonical.file_path, '')
       FROM variant_groups AS grouped
       JOIN variant_evaluations AS evaluation
         ON evaluation.id=grouped.active_evaluation_id
        AND evaluation.state='completed'
       LEFT JOIN galleries AS canonical ON canonical.gid=grouped.canonical_gid
      WHERE grouped.id=:group_id AND grouped.is_active=1
        AND grouped.desired_rating=11 AND grouped.canonical_gid IS NOT NULL;")" || {
    variants_archive_lock_release "${lock_fd}" || true
    return 1
  }
  if [[ -z "${snapshot}" ]]; then
    variants_archive_lock_release "${lock_fd}" || true
    return 0
  fi
  IFS=$'\t' read -r group_gid file_path <<<"${snapshot}"

  if [[ -n "${file_path}" ]] && ! archive_filename_is_safe "${file_path}"; then
    jq -nc --argjson group_id "${group_id}" --argjson gid "${group_gid}" \
      '{group_id:$group_id,gid:$gid,state:"unsafe_or_non_regular_archive_path"}'
    variants_archive_lock_release "${lock_fd}" || true
    return 0
  fi
  if [[ -n "${file_path}" ]] && [[ -e "${ARCHIVED_DIR}/${file_path}" ||
    -L "${ARCHIVED_DIR}/${file_path}" ]]; then
    if variants_retention_archive_is_regular "${file_path}"; then
      db_query \
        ".parameter set :gid ${group_gid}" \
        ".parameter set :file_path $(db_parameter_text "${file_path}")" \
        "UPDATE galleries
            SET rated_then_deleted_at = NULL,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
          WHERE gid=:gid AND file_path=:file_path
            AND rated_then_deleted_at IS NOT NULL;" || {
        variants_archive_lock_release "${lock_fd}" || true
        return 1
      }
      jq -nc --argjson group_id "${group_id}" --argjson gid "${group_gid}" \
        --arg file_path "${file_path}" \
        '{group_id:$group_id,gid:$gid,state:"canonical_archive_present",file_path:$file_path}'
      variants_archive_lock_release "${lock_fd}" || true
      return 0
    fi
    jq -nc --argjson group_id "${group_id}" --argjson gid "${group_gid}" \
      '{group_id:$group_id,gid:$gid,state:"unsafe_or_non_regular_archive_path"}'
    variants_archive_lock_release "${lock_fd}" || true
    return 0
  fi

  if [[ -n "${file_path}" ]]; then
    db_query \
      ".parameter set :group_id ${group_id}" \
      ".parameter set :gid ${group_gid}" \
      ".parameter set :file_path $(db_parameter_text "${file_path}")" \
      "BEGIN IMMEDIATE;
       UPDATE galleries
          SET file_path=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE gid=:gid AND file_path=:file_path
          AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                       JOIN variant_evaluations AS evaluation
                         ON evaluation.id=grouped.active_evaluation_id
                        AND evaluation.state='completed'
                      WHERE grouped.id=:group_id AND grouped.is_active=1
                        AND grouped.desired_rating=11
                        AND grouped.canonical_gid=:gid);
       COMMIT;" || {
      variants_archive_lock_release "${lock_fd}" || true
      return 1
    }
  fi

  if variants_retention_hath_tree_contains_gid "${group_gid}"; then
    state=hath_tree_present
    deadline="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    deadline="$(db_query \
      ".parameter set :gid ${group_gid}" \
      ".parameter set :interval ${VARIANTS_HATH_RETRY_INTERVAL_SECONDS}" \
      "SELECT CASE WHEN COALESCE(gallery.hath_last_attempted_at,'') = ''
             THEN strftime('%Y-%m-%dT%H:%M:%SZ','now')
             ELSE MAX(strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                      strftime('%Y-%m-%dT%H:%M:%SZ',gallery.hath_last_attempted_at,
                               '+' || :interval || ' seconds')) END
         FROM galleries AS gallery WHERE gallery.gid=:gid;")" || {
      variants_archive_lock_release "${lock_fd}" || true
      return 1
    }
    if [[ "$(db_query ".parameter set :deadline $(db_parameter_text "${deadline}")" \
      "SELECT CASE WHEN :deadline <= strftime('%Y-%m-%dT%H:%M:%SZ','now')
                    THEN 1 ELSE 0 END;")" == 1 ]]; then
      state=hath_request_due
    else
      state=hath_cooldown
    fi
  fi

  variants_retention_schedule_group "${group_id}" "${state}" "${deadline}" || {
    variants_archive_lock_release "${lock_fd}" || true
    return 1
  }
  jq -nc --argjson group_id "${group_id}" --argjson gid "${group_gid}" \
    --arg state "${state}" --arg available_at "${deadline}" \
    '{group_id:$group_id,gid:$gid,state:$state,available_at:$available_at}'
  variants_archive_lock_release "${lock_fd}" || true
}

variants_retention_schedule_group() {
  local group_id="$1" state="$2" available_at="$3"
  variants_validate_positive_integer "group ID" "${group_id}" || return 1
  [[ "${state}" == hath_tree_present || "${state}" == hath_cooldown ||
    "${state}" == hath_request_due ]] || return 1
  [[ "${available_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1

  db_query \
    ".parameter set :group_id ${group_id}" \
    ".parameter set :state $(db_parameter_text "${state}")" \
    ".parameter set :available_at $(db_parameter_text "${available_at}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_current_recovery AS
       SELECT grouped.id AS group_id, grouped.source_gid, grouped.canonical_gid,
              grouped.active_evaluation_id AS evaluation_id,
              evaluation.policy_revision_id AS revision_id
         FROM variant_groups AS grouped
         JOIN variant_evaluations AS evaluation
           ON evaluation.id=grouped.active_evaluation_id
          AND evaluation.state='completed'
        WHERE grouped.id=:group_id AND grouped.is_active=1
          AND grouped.desired_rating=11 AND grouped.canonical_gid IS NOT NULL;
     UPDATE variant_actions
        SET status='superseded', lease_owner=NULL, lease_expires_at=NULL,
            lease_job_id=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=:group_id AND action_type='archive_cleanup'
        AND status IN ('pending','retryable_error','configuration_error','in_flight')
        AND gid <> (SELECT canonical_gid FROM variant_current_recovery);
     INSERT INTO variant_actions(
       group_id,evaluation_id,gid,action_type,desired_value,
       decision_revision_id)
       SELECT group_id,evaluation_id,canonical_gid,'hath_request','request',revision_id
         FROM variant_current_recovery
        WHERE 1
     ON CONFLICT(action_type,gid,desired_value,decision_revision_id)
     DO UPDATE SET
       group_id=excluded.group_id, evaluation_id=excluded.evaluation_id,
       status=CASE
         WHEN variant_actions.status='in_flight' THEN variant_actions.status
         WHEN :state='hath_tree_present' AND variant_actions.status='succeeded'
           THEN variant_actions.status ELSE 'pending' END,
       available_at=:available_at,
       completed_at=CASE
         WHEN variant_actions.status='in_flight' THEN variant_actions.completed_at
         WHEN :state='hath_tree_present' AND variant_actions.status='succeeded'
           THEN variant_actions.completed_at ELSE NULL END,
       last_error_class=CASE
         WHEN variant_actions.status='in_flight' THEN variant_actions.last_error_class
         WHEN :state='hath_tree_present' AND variant_actions.status='succeeded'
           THEN variant_actions.last_error_class ELSE NULL END,
       last_error=CASE
         WHEN variant_actions.status='in_flight' THEN variant_actions.last_error
         WHEN :state='hath_tree_present' AND variant_actions.status='succeeded'
           THEN variant_actions.last_error ELSE NULL END,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');
     UPDATE variant_jobs
        SET priority=MAX(priority, ${VARIANTS_RETENTION_PRIORITY}),
            available_at=:available_at,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=:group_id AND job_type='reconcile_actions'
        AND status IN ('queued','leased');
     INSERT OR IGNORE INTO variant_jobs(
       job_type,group_id,source_gid,priority,status,available_at)
       SELECT 'reconcile_actions',group_id,source_gid,${VARIANTS_RETENTION_PRIORITY},
              'queued',:available_at FROM variant_current_recovery;
     COMMIT;"
}

variants_retention_schedule_recovery() {
  local groups group_id result count=0
  groups="$(db_query \
    "SELECT grouped.id FROM variant_groups AS grouped
      JOIN variant_evaluations AS evaluation
        ON evaluation.id=grouped.active_evaluation_id AND evaluation.state='completed'
     WHERE grouped.is_active=1 AND grouped.desired_rating=11
       AND grouped.canonical_gid IS NOT NULL ORDER BY grouped.id;")" || return
  while IFS= read -r group_id; do
    [[ -n "${group_id}" ]] || continue
    result="$(variants_retention_recover_group "${group_id}")" || return
    [[ -n "${result}" ]] && count=$((count + 1))
  done <<<"${groups}"
  printf '%s\n' "${count}"
}

# Delete one alternate only when a separately supplied canonical archive is
# currently present.  A missing alternate is an idempotent no-op.  Unsafe paths
# and an absent canonical are visible non-success results and must not mutate
# the database; the worker records the corresponding action outcome.
variants_retention_delete_alternate() {
  local canonical_path="$1" alternate_path="$2"
  local canonical_file alternate_file

  VARIANTS_RETENTION_DELETE_RESULT=""
  variants_retention_archive_is_regular "${canonical_path}" || return $?
  archive_filename_is_safe "${alternate_path}" || return 2
  canonical_file="${ARCHIVED_DIR}/${canonical_path}"
  alternate_file="${ARCHIVED_DIR}/${alternate_path}"
  [[ "${canonical_file}" != "${alternate_file}" ]] || return 2

  if [[ ! -e "${alternate_file}" ]]; then
    VARIANTS_RETENTION_DELETE_RESULT="missing"
    return 0
  fi
  [[ -f "${alternate_file}" && ! -L "${alternate_file}" ]] || return 2
  rm -- "${alternate_file}" || return 1
  # shellcheck disable=SC2034 # Read by the action executor.
  VARIANTS_RETENTION_DELETE_RESULT="deleted"
}

# Coalesce retention reconciliation after a successful archive rename.  The
# filesystem gate is intentionally checked before this transaction, while the
# SQL transaction rechecks that the GID is still the active rating-11
# canonical.  Existing queued/leased jobs are preserved and only their
# priority/availability are refreshed.
variants_retention_queue_for_gid() {
  local gid="$1" priority="${2:-${VARIANTS_RETENTION_PRIORITY}}"
  variants_retention_validate_gid "${gid}" || return 1
  [[ "${priority}" =~ ^[0-9]+$ ]] || return 1

  db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :priority ${priority}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_retention_queue(
       group_id INTEGER PRIMARY KEY,
       source_gid INTEGER NOT NULL
     );
     INSERT INTO variant_retention_queue(group_id, source_gid)
       SELECT grouped.id, grouped.source_gid
         FROM variant_groups AS grouped
        WHERE grouped.is_active = 1
          AND grouped.desired_rating = 11
          AND grouped.canonical_gid = :gid;
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job_type = 'reconcile_retention' AND status = 'queued'
        AND group_id IN (SELECT group_id FROM variant_retention_queue);
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     )
       SELECT 'reconcile_retention', group_id, source_gid, :priority, 'queued'
         FROM variant_retention_queue;
     SELECT count(*) FROM variant_retention_queue;
     COMMIT;"
}

# Startup self-heal for the unavoidable rename/database handoff window: the
# archive is already committed, but the process may have died before the
# post-rename queue call.  Only canonical paths that are safe regular files are
# queued; a stale database path never authorizes cleanup.
variants_retention_self_heal() {
  local group_id canonical_gid file_path queued=0
  local rows
  rows="$(db_query \
    "SELECT grouped.id || char(9) || grouped.source_gid || char(9) ||
            grouped.canonical_gid || char(9) || COALESCE(gallery.file_path, '')
      FROM variant_groups AS grouped
      JOIN galleries AS gallery ON gallery.gid = grouped.canonical_gid
      WHERE grouped.is_active = 1 AND grouped.desired_rating = 11
        AND grouped.canonical_gid IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM variant_jobs AS job
           WHERE job.group_id=grouped.id
             AND job.job_type='reconcile_retention'
             AND job.status='completed'
             AND job.completed_at>=gallery.updated_at
        );")" || return

  while IFS=$'\t' read -r group_id _ canonical_gid file_path; do
    [[ -n "${group_id}" ]] || continue
    if variants_retention_archive_is_regular "${file_path}"; then
      variants_retention_queue_for_gid "${canonical_gid}" >/dev/null || return
      queued=$((queued + 1))
    fi
  done <<<"${rows}"
  printf '%s\n' "${queued}"
}
