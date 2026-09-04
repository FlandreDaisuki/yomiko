#!/usr/bin/env bash

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

db_log() {
  if [[ -z "${YOMIKO_CLI_IN_API_MODE:-}" ]]; then
    printf '%s\n' "$*"
  fi
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
  if sqlite3 -bail "${DB_PATH}" ".backup \"${sqlite_backup_path}\""; then
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
  local db_status
  local database_existed=0

  if [[ -f "${DB_PATH}" ]]; then
    database_existed=1
  fi

  mkdir -p "$(dirname "${DB_PATH}")"
  if sqlite3 -bail "${DB_PATH}" \
    "PRAGMA foreign_keys=ON;
     PRAGMA journal_mode=WAL;
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
      if sqlite3 -bail "${DB_PATH}" < <(
        printf 'PRAGMA foreign_keys=ON;\n'
        printf 'BEGIN IMMEDIATE;\n%s\n' "${migration_sql}"
        printf 'INSERT OR IGNORE INTO _schema_version (version) VALUES (%s);\n' "${version_num}"
        printf 'COMMIT;\n'
      ); then
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

  db_run_schema_maintenance || return
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query() {
	printf '%s\n' 'PRAGMA foreign_keys=ON;' "$@" | sqlite3 -bail "${DB_PATH}"
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query_json \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query_json() {
	printf '%s\n' 'PRAGMA foreign_keys=ON;' "$@" | sqlite3 -bail --json "${DB_PATH}"
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
			if printf '%s\n' 'VACUUM;' | sqlite3 -bail "${DB_PATH}" >/dev/null; then
				:
			else
				maintenance_status=$?
				printf 'ERROR: Schema maintenance %s failed.\n' "${maintenance_name}" >&2
				return "${maintenance_status}"
			fi
			if ! db_query \
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
  local content_hash matching_hash scoring_hash operations_hash
  schema_version="$(db_query "SELECT COALESCE(MAX(version),0) FROM _schema_version;")" || return
  [[ "${schema_version}" =~ ^[0-9]+$ && "${schema_version}" -ge 20 ]] || return 0
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

  db_query \
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
       WHERE run.matching_revision <> 4
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
        AND group_id IN (SELECT id FROM variant_groups WHERE is_active=1);
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status)
       SELECT 'discover', id, source_gid, 500, 'queued'
         FROM variant_groups WHERE is_active=1;
     COMMIT;"
}

# Migration 014 has to preserve arbitrary operator scoring JSON while changing
# the code-owned matching document. SQLite has no portable SHA-256 primitive,
# so finalize the new immutable row's content and matching hashes with the same
# canonical bytes used by the policy runtime. Scoring and operations hashes are
# copied from the prior revision by the SQL migration and must remain stable.
db_finalize_gallery_chain_policy() {
	local policy_table row matching policy content_hash matching_hash
	policy_table="$(db_query "SELECT name FROM sqlite_schema
	                            WHERE type='table' AND name='variant_policy_revisions';")" || return
	[[ "${policy_table}" == variant_policy_revisions ]] || return 0
	row="$(db_query "SELECT json_object('id',id,'policy',json(policy_json))
	                  FROM variant_policy_revisions
	                 WHERE is_active=1
	                   AND json_type(policy_json,'$.matching.official_chain_visibility')='object';")" || return
	[[ -n "${row}" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	matching="$(jq -cS '.policy.matching | .official_chain_visibility = {
	  eligible:"current_gid_is_null_or_equals_gid",
	  replaced:"current_gid_is_non_null_and_differs_from_gid",
	  retain_replaced_history:true,
	  validate_references_as_pairs:true
}' <<<"${row}")" || return
	policy="$(jq -cS --argjson matching "${matching}" '.policy | .matching=$matching' <<<"${row}")" || return
	content_hash="$(printf '%s' "${policy}" | sha256sum | awk '{print $1}')"
	matching_hash="$(printf '%s' "${matching}" | sha256sum | awk '{print $1}')"
	db_query \
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
  db_query \
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
