#!/usr/bin/env bash

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

db_log() {
  if [[ -z "${YOMIKO_CLI_IN_API_MODE:-}" ]]; then
    printf '%s\n' "$*"
  fi
}

# Initialize database if not exists
db_init() {
  local db_status

  mkdir -p "$(dirname "${DB_PATH}")"
  if sqlite3 -bail "${DB_PATH}" \
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
      if sqlite3 -bail "${DB_PATH}" < <(
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
  sqlite3 -bail "${DB_PATH}" "$@"
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query_json \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query_json() {
  sqlite3 -bail --json "${DB_PATH}" "$@"
}

# escape which file_path has single quote or double quote
# escape which token formed: `\d+e\d+`
db_escape() {
  local input="$1"
  printf \"\''%s'\'\" "${input//\'/\'\'}"
}
