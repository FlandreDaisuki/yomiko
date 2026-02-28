#!/usr/bin/env bash

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# Initialize database if not exists
db_init() {
  if ! [[ -f "${DB_PATH}" ]]; then
    mkdir -p "$(dirname "${DB_PATH}")"
    touch "${DB_PATH}"
  fi

  sqlite3 "${DB_PATH}" "CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER PRIMARY KEY, applied_at DATETIME DEFAULT current_timestamp);"

  local current_ver
  current_ver="$(db_query "SELECT MAX(version) FROM _schema_version;")"
  : "${current_ver:=0}"

  # Apply migration files in order (e.g., 001_init.sql, 002_add_token.sql)
  for script in "${MIGRATIONS_DIR}"/*.sql; do
    # Extract version number from filename (e.g., 001)
    local version_num
    version_num=$(basename "${script}" | cut -d'_' -f1 | sed 's/^0*//')

    if [[ "${version_num}" -gt "${current_ver}" ]]; then
      echo "Applying migration version ${version_num}: ${script}..."
      sqlite3 "${DB_PATH}" <"${script}"
      db_query "INSERT OR IGNORE INTO _schema_version (version) VALUES (${version_num});"
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
  # Remove the first line of wal output
  sqlite3 "${DB_PATH}" "PRAGMA journal_mode=WAL;" "$@" | sed '1d'
}

# doc: https://sqlite.org/cli.html#sql_parameters
# doc: https://sqlite.org/lang_expr.html#varparam
# usage:
#   db_query_json \
#   [...".parameter set :key ${value}"]
#   <sql statement>
db_query_json() {
  # Remove the first line of wal output
  sqlite3 "${DB_PATH}" --json "PRAGMA journal_mode=WAL;" "$@" | sed '1d'
}

# escape which file_path has single quote or double quote
# escape which token formed: `\d+e\d+`
db_escape() {
  local input="$1"
  printf \"\''%s'\'\" "${input//\'/\'\'}"
}
