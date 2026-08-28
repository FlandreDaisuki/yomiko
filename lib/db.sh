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
