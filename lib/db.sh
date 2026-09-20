#!/usr/bin/env bash

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

db_log() {
  if [[ -z "${YOMIKO_CLI_IN_API_MODE:-}" ]]; then
    printf '%s\n' "$*"
  fi
}

# SQLite's busy handler and Yomiko's cooperative writer gate are deliberately
# bounded independently.  Keep the limits conservative: a caller should not
# hold a shell process open for an unbounded amount of time just because a
# different process is writing the database.
DB_TIMEOUT_MAX_MS=60000
DB_TIMEOUT_DEFAULT_MS=5000
DB_WRITER_LOCK_DIR='/tmp'
DB_WRITER_LOCK_PREFIX='yomiko-sqlite-writer-'
DB_WRITER_LOCK_SUFFIX='.writer.lock'
DB_WRITER_OWNER_SUFFIX='.owner'

db_error() {
  # Keep helper diagnostics on stderr even in API mode. API middleware captures
  # command stderr for the server log and emits only its stable public error;
  # suppressing this here would discard the component context entirely.
  printf 'ERROR: %s\n' "$*" >&2
}

db_timeout_setting() {
  local name="$1"
  local value invalid=0
  case "${name}" in
  sqlite)
    value="${YOMIKO_SQLITE_BUSY_TIMEOUT_MS:-${YOMIKO_DB_BUSY_TIMEOUT_MS:-${YOMIKO_SQLITE_TIMEOUT_MS:-${DB_TIMEOUT_DEFAULT_MS}}}}"
    ;;
  writer)
    value="${YOMIKO_DB_WRITER_GATE_TIMEOUT_MS:-${YOMIKO_DB_WRITER_TIMEOUT_MS:-${DB_TIMEOUT_DEFAULT_MS}}}"
    ;;
  *)
    return 2
    ;;
  esac

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    invalid=1
  elif (( ${#value} > ${#DB_TIMEOUT_MAX_MS} )); then
    invalid=1
  elif (( ${#value} == ${#DB_TIMEOUT_MAX_MS} && 10#${value} > 10#${DB_TIMEOUT_MAX_MS} )); then
    invalid=1
  fi
  if ((invalid)); then
    db_error "Invalid ${name} timeout; expected a positive integer of at most ${DB_TIMEOUT_MAX_MS} milliseconds."
    return 2
  fi
  printf '%s\n' "$((10#${value}))"
}

db_component_is_valid() {
  case "${1:-}" in
  startup | unknown | test | variant_worker | scan | archive) return 0 ;;
  runtime:scheduler_tick | runtime:variant_worker | runtime:scan) return 0 ;;
  cli:login | cli:whoami | cli:scan | cli:metrics | cli:archive | cli:rate | \
  cli:hath | cli:gallery-status | cli:favorite | cli:feedback | cli:variants | \
  cli:repair-tags | cli:list) return 0 ;;
  api:login | api:whoami | api:scan | api:metrics | api:archive | api:rate | \
  api:hath | api:gallery-status | api:favorite | api:feedback | api:variants | \
  api:repair-tags | api:list) return 0 ;;
  *) return 1 ;;
  esac
}

db_component_context() {
  local component="$1"
  db_component_is_valid "${component}" || {
    db_error "Invalid database component context."
    return 2
  }
  YOMIKO_DB_COMPONENT="${component}"
  export YOMIKO_DB_COMPONENT
}

db_sqlite_run() {
  local query_only="$1"
  local json_output="$2"
  shift 2

  local sqlite_timeout
  sqlite_timeout="$(db_timeout_setting sqlite)" || return
  local sqlite_args=(-bail)
  [[ "${json_output}" == 1 ]] && sqlite_args+=(--json)

  {
    # .timeout is silent, unlike PRAGMA busy_timeout, so it does not alter
    # plain or JSON query output.
    printf '.timeout %s\n' "${sqlite_timeout}"
    printf 'PRAGMA foreign_keys=ON;\n'
    if [[ "${query_only}" == 1 && "$#" -gt 0 ]]; then
      # The SQLite CLI implements .parameter set using a temporary table. It
      # must run before query_only is enabled, while the application SQL (the
      # final stream argument by contract) must run after it.
      local argument index=0
      for argument in "$@"; do
        index=$((index + 1))
        ((index == $#)) && break
        printf '%s\n' "${argument}"
      done
      printf 'PRAGMA query_only=ON;\n'
      printf '%s\n' "${!#}"
    else
      [[ "${query_only}" == 1 ]] && printf 'PRAGMA query_only=ON;\n'
      printf '%s\n' "$@"
    fi
  } | sqlite3 "${sqlite_args[@]}" "${DB_PATH}"
}

db_writer_lock_path() {
  local db_path_hash
  [[ -n "${DB_PATH:-}" ]] || return 1

  db_path_hash="$(printf '%s' "${DB_PATH}" | sha256sum | cut -c1-16)" || return 1
  [[ "${db_path_hash}" =~ ^[[:xdigit:]]{16}$ ]] || return 1
  printf '%s/%s%s%s\n' \
    "${DB_WRITER_LOCK_DIR}" \
    "${DB_WRITER_LOCK_PREFIX}" \
    "${db_path_hash}" \
    "${DB_WRITER_LOCK_SUFFIX}"
}

db_write_cleanup() {
  local owner_path="${1:-}" lock_fd="${2:-}"
  [[ -n "${owner_path}" ]] && rm -f -- "${owner_path}"
  if [[ -n "${lock_fd}" ]]; then
    flock -u "${lock_fd}" 2>/dev/null || true
    eval "exec ${lock_fd}>&-"
  fi
}

db_write() (
  local component="${YOMIKO_DB_COMPONENT:-unknown}"
  db_component_is_valid "${component}" || {
    db_error "Invalid database component context."
    exit 2
  }
  local gate_timeout
  db_timeout_setting sqlite >/dev/null || exit $?
  gate_timeout="$(db_timeout_setting writer)" || exit $?

  local lock_path
  lock_path="$(db_writer_lock_path)" || {
    db_error "Could not determine the SQLite writer gate path."
    exit 1
  }
  local owner_path="${lock_path}${DB_WRITER_OWNER_SUFFIX}"
  local lock_fd
  mkdir -p "$(dirname -- "${lock_path}")" || exit 1
  exec {lock_fd}>>"${lock_path}" || {
    db_error "Could not open the SQLite writer gate."
    exit 1
  }
  chmod 600 "${lock_path}" 2>/dev/null || true

  local gate_attempts=$(((gate_timeout + 9) / 10))
  local gate_acquired=0
  while ((gate_attempts > 0)); do
    if flock -n "${lock_fd}"; then
      gate_acquired=1
      break
    fi
    gate_attempts=$((gate_attempts - 1))
    ((gate_attempts > 0)) && sleep 0.01
  done
  if ((gate_acquired == 0)); then
    local observed_owner='unknown'
    if [[ -f "${owner_path}" ]]; then
      observed_owner="$(<"${owner_path}")"
      [[ "${observed_owner}" =~ ^component=[a-z_:-]+[[:space:]]pid=[0-9]+[[:space:]]started=[0-9TZ:+.-]+$ ]] || observed_owner='unknown'
    fi
    db_error "SQLite writer gate timeout for component ${component}; owner=${observed_owner}"
    eval "exec ${lock_fd}>&-"
    exit 75
  fi

  trap 'db_write_cleanup "${owner_path}" "${lock_fd}"' EXIT HUP INT TERM
  local started_at
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || started_at='unknown'
  if ! printf 'component=%s pid=%s started=%s\n' "${component}" "$$" "${started_at}" >"${owner_path}"; then
    db_error "Could not record the SQLite writer gate owner."
    exit 1
  fi

  # This function invokes SQLite exactly once.  In particular, do not wrap it
  # in a shell retry loop: a stream may contain autocommitted statements,
  # triggers, or changes()-based decisions that are not safe to replay.
  if db_sqlite_run 0 0 "$@"; then
    exit 0
  else
    local sqlite_status=$?
    db_error "SQLite write failed for component ${component} (status ${sqlite_status})."
    exit "${sqlite_status}"
  fi
)

# Keep an explicit component override convenient for narrow library entry
# points without mutating the caller's context.
db_write_as() {
  local component="$1"
  shift
  YOMIKO_DB_COMPONENT="${component}" db_write "$@"
}

db_backup_before_migration() {
  local version="$1"
  local backup_path
  local temporary_path
  local sqlite_backup_path
  backup_path="$(dirname "${DB_PATH}")/before-${version}.sqlite3"
  temporary_path="${backup_path}.tmp.$$"
  sqlite_backup_path="${temporary_path//\\/\\\\}"
  sqlite_backup_path="${sqlite_backup_path//\"/\\\"}"

  db_log "Backing up database before migration ${version}: ${backup_path}"
  local backup_status
  if db_sqlite_run 1 0 ".backup \"${sqlite_backup_path}\""; then
    :
  else
    backup_status=$?
    rm -f -- "${temporary_path}"
    printf 'ERROR: Failed to back up database before migration %s.\n' "${version}" >&2
    return "${backup_status}"
  fi

  if mv -f -- "${temporary_path}" "${backup_path}"; then
    :
  else
    backup_status=$?
    rm -f -- "${temporary_path}"
    printf 'ERROR: Failed to finalize database backup before migration %s.\n' "${version}" >&2
    return "${backup_status}"
  fi
}

# Initialize database if not exists
db_init() {
  local YOMIKO_DB_COMPONENT=startup
  local db_status
  local database_existed=0

  if [[ -f "${DB_PATH}" ]]; then
    database_existed=1
  fi

  mkdir -p "$(dirname "${DB_PATH}")"
  if db_write \
    "PRAGMA journal_mode=WAL;
     CREATE TABLE IF NOT EXISTS _schema_version (
       version INTEGER PRIMARY KEY,
       applied_at DATETIME DEFAULT current_timestamp
     );" >/dev/null; then
    :
  else
    db_status=$?
    printf 'ERROR: Failed to initialize database schema.\n' >&2
    return "${db_status}"
  fi

  local current_ver
  if current_ver="$(db_query "SELECT MAX(version) FROM _schema_version;")"; then
    :
  else
    db_status=$?
    printf 'ERROR: Failed to read the current database schema version.\n' >&2
    return "${db_status}"
  fi
  : "${current_ver:=0}"
  if [[ ! "${current_ver}" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: Invalid database schema version: %s\n' "${current_ver}" >&2
    return 1
  fi

  # Apply migration files in order (e.g., 001_init.sql, 002_add_token.sql)
  for script in "${MIGRATIONS_DIR}"/*.sql; do
    [[ -f "${script}" ]] || continue

    # Extract version number from filename (e.g., 001)
    local migration_name="${script##*/}"
    local version_num
    if [[ ! "${migration_name}" =~ ^([0-9]+)_.+\.sql$ ]]; then
      printf 'ERROR: Invalid migration filename: %s\n' "${migration_name}" >&2
      return 1
    fi
    version_num=$((10#${BASH_REMATCH[1]}))

    if [[ "${version_num}" -gt "${current_ver}" ]]; then
      local migration_sql
      if migration_sql="$(<"${script}")"; then
        :
      else
        db_status=$?
        printf 'ERROR: Failed to read migration: %s\n' "${migration_name}" >&2
        return "${db_status}"
      fi

      db_log "Applying migration version ${version_num}: ${migration_name}..."
      if [[ "${database_existed}" -eq 1 ]]; then
        db_backup_before_migration "${version_num}" || return $?
      fi
      if db_write "BEGIN IMMEDIATE;
${migration_sql}
INSERT OR IGNORE INTO _schema_version (version) VALUES (${version_num});
COMMIT;"; then
        current_ver="${version_num}"
      else
        db_status=$?
        printf 'ERROR: Migration %s failed; changes were rolled back.\n' "${migration_name}" >&2
        return "${db_status}"
      fi
    fi
  done

  db_finalize_gallery_chain_policy || return
  db_finalize_variant_scoring_policy || return
  db_finalize_manga_scope_policy || return
  db_finalize_priority_1_policy || return

  db_run_schema_maintenance || return
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query() {
	db_sqlite_run 1 0 "$@"
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query_json \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query_json() {
	db_sqlite_run 1 1 "$@"
}

db_run_schema_maintenance() {
	local maintenance_name maintenance_table
	maintenance_table="$(db_query \
		"SELECT name FROM sqlite_schema WHERE type='table' AND name='schema_maintenance';")" || return
	[[ "${maintenance_table}" == schema_maintenance ]] || return 0
	while IFS= read -r maintenance_name; do
		[[ -n "${maintenance_name}" ]] || continue
		db_log "Running schema maintenance: ${maintenance_name}..."
		case "${maintenance_name}" in
		vacuum_after_012 | vacuum_after_020)
			local maintenance_status
			if db_write 'VACUUM;' >/dev/null; then
				:
			else
				maintenance_status=$?
				printf 'ERROR: Schema maintenance %s failed.\n' "${maintenance_name}" >&2
				return "${maintenance_status}"
			fi
			if ! db_write \
				".parameter set :maintenance_name $(db_parameter_text "${maintenance_name}")" \
				"UPDATE schema_maintenance
				    SET status='completed', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
				  WHERE name=:maintenance_name AND status='pending';" >/dev/null; then
				printf 'ERROR: Could not record completed schema maintenance %s.\n' "${maintenance_name}" >&2
				return 1
			fi
			;;
		*)
			printf 'ERROR: Unknown pending schema maintenance: %s\n' "${maintenance_name}" >&2
			return 1
			;;
		esac
	done < <(db_query "SELECT name FROM schema_maintenance WHERE status='pending' ORDER BY name;") || return
}

# Migration 020 changes only the fixed matching document. Keep the scoring and
# operations sections byte-for-byte equivalent so existing evaluations and
# operational scheduling do not receive a policy sweep. SQLite has no SHA-256
# primitive, so finalize this immutable policy row with the same canonical
# bytes used by the policy runtime.
db_finalize_manga_scope_policy() {
  local schema_version policy_table row policy matching scoring operations
  local group_activity_predicate="is_active=1"
  local content_hash matching_hash scoring_hash operations_hash
  schema_version="$(db_query "SELECT COALESCE(MAX(version),0) FROM _schema_version;")" || return
  [[ "${schema_version}" =~ ^[0-9]+$ && "${schema_version}" -ge 20 ]] || return 0
  if [[ "${schema_version}" -ge 26 ]]; then
    group_activity_predicate="identity_active=1 AND EXISTS (
      SELECT 1 FROM galleries AS feedback_source
       WHERE feedback_source.gid=variant_groups.source_gid
         AND (feedback_source.feedbacked_at IS NOT NULL
              OR feedback_source.self_rating BETWEEN 1 AND 11))"
  fi
  policy_table="$(db_query "SELECT name FROM sqlite_schema
                              WHERE type='table' AND name='variant_policy_revisions';")" || return
  [[ "${policy_table}" == variant_policy_revisions ]] || return 0
  row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json),
                                      'matching_hash',matching_hash)
                    FROM variant_policy_revisions WHERE is_active=1;")" || return
  [[ -n "${row}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  policy="$(jq -cS '.policy
    | .matching.required_category = "Manga"
    | .matching.search.category_exclusion_mask = 1019
    | .matching.visible_contradictions =
        ((.matching.visible_contradictions // []) - ["category_mismatch"])' <<<"${row}")" || return
  matching="$(jq -cS '.matching' <<<"${policy}")" || return
  [[ "$(printf '%s' "${matching}" | sha256sum | awk '{print $1}')" != "$(jq -r '.matching_hash' <<<"${row}")" ]] || return 0
  scoring="$(jq -cS '.scoring' <<<"${policy}")" || return
  operations="$(jq -cS '.operations' <<<"${policy}")" || return
  content_hash="$(printf '%s' "${policy}" | sha256sum | awk '{print $1}')"
  matching_hash="$(printf '%s' "${matching}" | sha256sum | awk '{print $1}')"
  scoring_hash="$(printf '%s' "${scoring}" | sha256sum | awk '{print $1}')"
  operations_hash="$(printf '%s' "${operations}" | sha256sum | awk '{print $1}')"

  db_write \
    ".parameter set :policy $(db_parameter_text "${policy}")" \
    ".parameter set :content $(db_parameter_text "${content_hash}")" \
    ".parameter set :matching $(db_parameter_text "${matching_hash}")" \
    ".parameter set :scoring $(db_parameter_text "${scoring_hash}")" \
    ".parameter set :operations $(db_parameter_text "${operations_hash}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE migration_manga_policy_context AS
       SELECT id AS old_id, matching_hash AS old_matching_hash,
              scoring_hash AS old_scoring_hash, operations_hash AS old_operations_hash
         FROM variant_policy_revisions WHERE is_active=1;
     INSERT OR IGNORE INTO variant_policy_revisions(
       policy_json, content_hash, matching_hash, scoring_hash, operations_hash)
       VALUES (json(:policy), :content, :matching, :scoring, :operations);
     UPDATE variant_policy_revisions SET is_active=0
      WHERE is_active=1 AND id <> (
        SELECT id FROM variant_policy_revisions WHERE content_hash=:content);
     UPDATE variant_policy_revisions
        SET is_active=1, activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE content_hash=:content;

     CREATE TEMP TABLE migration_manga_cancel_jobs(id INTEGER PRIMARY KEY);
     INSERT INTO migration_manga_cancel_jobs(id)
       SELECT job.id FROM variant_jobs AS job
        JOIN variant_discovery_runs AS run ON run.job_id=job.id
       WHERE run.matching_revision <> 6
         AND run.status IN ('running','retryable');
     UPDATE variant_discovery_runs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL, last_error='matching policy revision changed'
      WHERE job_id IN (SELECT id FROM migration_manga_cancel_jobs)
        AND status IN ('running','retryable');
     UPDATE variant_jobs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL, last_error='matching policy revision changed'
      WHERE id IN (SELECT id FROM migration_manga_cancel_jobs);

     UPDATE variant_jobs
        SET priority=MAX(priority,500), continuation_cursor_json=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE job_type='discover' AND status='queued'
        AND group_id IN (SELECT id FROM variant_groups WHERE ${group_activity_predicate});
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status)
       SELECT 'discover', id, source_gid, 500, 'queued'
         FROM variant_groups WHERE ${group_activity_predicate};
     COMMIT;"
}

# Migration 021 changes the code-owned matching vocabulary and therefore
# advances the matching algorithm independently of operator scoring and
# operations settings. Create a fresh immutable policy revision while copying
# those two sections byte-for-byte in their canonical JSON form. Discovery
# work from earlier matching revisions is cancelled and active groups are
# coalesced into revision-5 rediscovery only when that fresh revision is
# created; no scoring sweep is queued. db_init calls finalizers on every
# startup, so the one-time queue transition must remain transaction-local and
# durable through the policy row itself.
db_finalize_priority_1_policy() {
  local schema_version policy_table row policy matching scoring operations
  local group_activity_predicate="is_active=1"
  local content_hash matching_hash scoring_hash operations_hash
  schema_version="$(db_query "SELECT COALESCE(MAX(version),0) FROM _schema_version;")" || return
  [[ "${schema_version}" =~ ^[0-9]+$ && "${schema_version}" -ge 21 ]] || return 0
  if [[ "${schema_version}" -ge 26 ]]; then
    group_activity_predicate="identity_active=1 AND EXISTS (
      SELECT 1 FROM galleries AS feedback_source
       WHERE feedback_source.gid=variant_groups.source_gid
         AND (feedback_source.feedbacked_at IS NOT NULL
              OR feedback_source.self_rating BETWEEN 1 AND 11))"
  fi
  policy_table="$(db_query "SELECT name FROM sqlite_schema
                              WHERE type='table' AND name='variant_policy_revisions';")" || return
  [[ "${policy_table}" == variant_policy_revisions ]] || return 0
  row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json))
                    FROM variant_policy_revisions WHERE is_active=1;")" || return
  [[ -n "${row}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  policy="$(jq -cS '.policy
    | .matching.visible_contradictions =
        ((.matching.visible_contradictions // []) |
         map(if . == "chain_key_mismatch" then "chain_token_mismatch" else . end))' <<<"${row}")" || return
  matching="$(jq -cS '.matching' <<<"${policy}")" || return
  scoring="$(jq -cS '.scoring' <<<"${policy}")" || return
  operations="$(jq -cS '.operations' <<<"${policy}")" || return
  content_hash="$(printf '%s' "${policy}" | sha256sum | awk '{print $1}')"
  matching_hash="$(printf '%s' "${matching}" | sha256sum | awk '{print $1}')"
  scoring_hash="$(printf '%s' "${scoring}" | sha256sum | awk '{print $1}')"
  operations_hash="$(printf '%s' "${operations}" | sha256sum | awk '{print $1}')"

  db_write \
    ".parameter set :policy $(db_parameter_text "${policy}")" \
    ".parameter set :content $(db_parameter_text "${content_hash}")" \
    ".parameter set :matching $(db_parameter_text "${matching_hash}")" \
    ".parameter set :scoring $(db_parameter_text "${scoring_hash}")" \
    ".parameter set :operations $(db_parameter_text "${operations_hash}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE migration_021_policy_context(
       new_revision INTEGER NOT NULL CHECK (new_revision IN (0, 1))
     );
     INSERT OR IGNORE INTO variant_policy_revisions(
       policy_json, content_hash, matching_hash, scoring_hash, operations_hash)
       VALUES (json(:policy), :content, :matching, :scoring, :operations);
     INSERT INTO migration_021_policy_context(new_revision) VALUES (changes());
     UPDATE variant_policy_revisions SET is_active=0
      WHERE is_active=1 AND content_hash<>:content;
     UPDATE variant_policy_revisions
        SET is_active=1,
            activated_at=CASE WHEN activated_at IS NOT NULL THEN activated_at
                              ELSE strftime('%Y-%m-%dT%H:%M:%SZ','now') END
      WHERE content_hash=:content
        AND (is_active=0 OR activated_at IS NULL);

     CREATE TEMP TABLE migration_021_cancel_discovery(id INTEGER PRIMARY KEY);
     INSERT INTO migration_021_cancel_discovery(id)
       SELECT job.id FROM variant_jobs AS job
        JOIN variant_discovery_runs AS run ON run.job_id=job.id
       WHERE job.job_type='discover'
         AND EXISTS (SELECT 1 FROM migration_021_policy_context
                      WHERE new_revision=1)
         AND run.matching_revision<>6
         AND run.status IN ('running','retryable');
     UPDATE variant_discovery_runs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL, last_error='matching revision changed'
      WHERE job_id IN (SELECT id FROM migration_021_cancel_discovery)
        AND status IN ('running','retryable');
     UPDATE variant_jobs
        SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
            completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL, last_error='matching revision changed'
      WHERE id IN (SELECT id FROM migration_021_cancel_discovery);

     UPDATE variant_jobs
        SET priority=MAX(priority,500), continuation_cursor_json=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE job_type='discover' AND status='queued'
        AND EXISTS (SELECT 1 FROM migration_021_policy_context
                     WHERE new_revision=1)
        AND group_id IN (SELECT id FROM variant_groups WHERE ${group_activity_predicate});
     INSERT OR IGNORE INTO variant_jobs(job_type,group_id,source_gid,priority,status)
       SELECT 'discover',id,source_gid,500,'queued'
         FROM variant_groups
        WHERE ${group_activity_predicate}
          AND EXISTS (SELECT 1 FROM migration_021_policy_context
                       WHERE new_revision=1);
     COMMIT;"
}

# Legacy startup finalizer retained for databases initialized before schema 27.
# Uploader-revision authority now lives in provider projection views; mutable
# policy must not retain official_chain visibility or evidence authority.
db_finalize_gallery_chain_policy() {
	local policy_table row matching policy content_hash matching_hash schema_version
	schema_version="$(db_query "SELECT COALESCE(MAX(version),0) FROM _schema_version;")" || return 0
	[[ "${schema_version}" =~ ^[0-9]+$ ]] || schema_version=0
	policy_table="$(db_query "SELECT name FROM sqlite_schema
	                            WHERE type='table' AND name='variant_policy_revisions';")" || return
	[[ "${policy_table}" == variant_policy_revisions ]] || return 0
	if ((schema_version < 27)); then
		row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json))
		                  FROM variant_policy_revisions
		                 WHERE is_active=1
		                   AND json_type(policy_json,'$.matching.official_chain_visibility')='object';")" || return
	else
		row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json))
		                  FROM variant_policy_revisions
		                 WHERE is_active=1
		                   AND (json_type(policy_json,'$.matching.official_chain_visibility')='object'
		                        OR json_extract(policy_json,'$.matching.automatic_evidence_kinds') LIKE '%official_chain%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_reference_invalid%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_token_mismatch%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_conflict%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_cycle%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_branch%'
		                        OR json_extract(policy_json,'$.matching.visible_contradictions') LIKE '%chain_multiple_terminals%');")" || return
	fi
	[[ -n "${row}" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	if ((schema_version < 27)); then
		matching="$(jq -cS '.policy.matching | .official_chain_visibility = {
		  eligible:"current_gid_is_null_or_equals_gid",
		  replaced:"current_gid_is_non_null_and_differs_from_gid",
		  retain_replaced_history:true,
		  validate_references_as_pairs:true
	}' <<<"${row}")" || return
	else
		matching="$(jq -cS '.policy.matching
		  | del(.official_chain_visibility)
		  | if (.automatic_evidence_kinds | type) == "array"
		    then .automatic_evidence_kinds |= map(select(. != "official_chain"))
		    else . end
		  | .visible_contradictions = [
		      "title_volume_part_conflict",
		      "disjoint_creator_sets",
		      "missing_evidence",
		      "uploader_revision_reference_incomplete",
		      "uploader_revision_scope_incomplete",
		      "uploader_revision_scoring_input_incomplete",
		      "uploader_revision_token_mismatch",
		      "uploader_revision_relation_conflict",
		      "uploader_revision_cycle",
		      "uploader_revision_branch",
		      "uploader_revision_multiple_terminals"
		    ]' <<<"${row}")" || return
	fi
	policy="$(jq -cS --argjson matching "${matching}" '.policy | .matching=$matching' <<<"${row}")" || return
	content_hash="$(printf '%s' "${policy}" | sha256sum | awk '{print $1}')"
	matching_hash="$(printf '%s' "${matching}" | sha256sum | awk '{print $1}')"
	db_write \
		".parameter set :id $(jq -r '.id' <<<"${row}")" \
		".parameter set :policy $(db_parameter_text "${policy}")" \
		".parameter set :content $(db_parameter_text "${content_hash}")" \
		".parameter set :matching $(db_parameter_text "${matching_hash}")" \
		"BEGIN IMMEDIATE;
		 DROP TRIGGER variant_policy_revisions_immutable_content;
		 UPDATE variant_policy_revisions
		    SET policy_json=json(:policy), content_hash=:content,
		        matching_hash=:matching
		  WHERE id=:id;
		 CREATE TRIGGER variant_policy_revisions_immutable_content
		 BEFORE UPDATE OF policy_json, content_hash, matching_hash, scoring_hash,
		                  operations_hash, created_at ON variant_policy_revisions
		 BEGIN
		     SELECT RAISE(ABORT, 'variant policy revision content is immutable');
		 END;
		 COMMIT;"
}

# Migration 015 changes code-owned scoring defaults while preserving the
# operator's tag/title/page/rank choices. SQLite has no portable SHA-256
# primitive, so finalize the new active row's placeholder hashes with the same
# canonical bytes used by the policy runtime.
db_finalize_variant_scoring_policy() {
  local policy_table row policy matching scoring operations
  local content_hash matching_hash scoring_hash operations_hash
  local placeholder
  policy_table="$(db_query "SELECT name FROM sqlite_schema
                              WHERE type='table' AND name='variant_policy_revisions';")" || return
  [[ "${policy_table}" == variant_policy_revisions ]] || return 0
  placeholder="$(printf '%064d' 0)"
  row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json))
                    FROM variant_policy_revisions
                   WHERE is_active=1 AND scoring_hash='$placeholder';")" || return
  [[ -n "$row" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  policy="$(jq -cS '.policy' <<<"$row")" || return
  matching="$(jq -cS '.matching' <<<"$policy")" || return
  scoring="$(jq -cS '.scoring' <<<"$policy")" || return
  operations="$(jq -cS '.operations' <<<"$policy")" || return
  content_hash="$(printf '%s' "$policy" | sha256sum | awk '{print $1}')"
  matching_hash="$(printf '%s' "$matching" | sha256sum | awk '{print $1}')"
  scoring_hash="$(printf '%s' "$scoring" | sha256sum | awk '{print $1}')"
  operations_hash="$(printf '%s' "$operations" | sha256sum | awk '{print $1}')"
  db_write \
    ".parameter set :id $(jq -r '.id' <<<"$row")" \
    ".parameter set :policy $(db_parameter_text "$policy")" \
    ".parameter set :content $(db_parameter_text "$content_hash")" \
    ".parameter set :matching $(db_parameter_text "$matching_hash")" \
    ".parameter set :scoring $(db_parameter_text "$scoring_hash")" \
    ".parameter set :operations $(db_parameter_text "$operations_hash")" \
    "BEGIN IMMEDIATE;
     DROP TRIGGER variant_policy_revisions_immutable_content;
     UPDATE variant_policy_revisions
        SET policy_json=json(:policy), content_hash=:content,
            matching_hash=:matching, scoring_hash=:scoring,
            operations_hash=:operations
      WHERE id=:id;
     CREATE TRIGGER variant_policy_revisions_immutable_content
     BEFORE UPDATE OF policy_json, content_hash, matching_hash, scoring_hash,
                      operations_hash, created_at ON variant_policy_revisions
     BEGIN
         SELECT RAISE(ABORT, 'variant policy revision content is immutable');
     END;
     COMMIT;"
}

# Encode arbitrary UTF-8 text as a SQLite expression that is safe to pass
# through the CLI's dot-command tokenizer. The surrounding double quotes keep
# the CAST expression together as one `.parameter set` value; user content is
# represented only by hexadecimal digits.
db_parameter_text() {
  local input="$1"
  local hex
  hex="$(printf '%s' "${input}" | od -An -v -tx1 | tr -d '[:space:]')"
  printf '"CAST(X'\''%s'\'' AS TEXT)"' "${hex}"
}
