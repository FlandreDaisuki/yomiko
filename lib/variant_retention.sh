#!/usr/bin/env bash

# Local retention and H@H coordination primitives.  These helpers deliberately
# do not execute remote actions or delete archives on their own except for the
# explicitly guarded alternate-cleanup helper.  The worker owns action
# scheduling; archive completion calls the queue helpers after its final rename.

VARIANTS_HATH_LOCK_DIR="/tmp"
VARIANTS_RETENTION_PRIORITY=500
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
