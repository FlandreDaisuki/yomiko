#!/usr/bin/env bash

DB_PATH="${HOME}/data/db.sqlite3"
MIGRATIONS_DIR="${HOME}/migrations"

# Initialize database if not exists
db_init() {
  if ! [[ -f "${DB_PATH}" ]]; then
    mkdir -p "$(dirname "${DB_PATH}")"
    touch "${DB_PATH}"
  fi

  sqlite3 "${DB_PATH}" "CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER PRIMARY KEY, applied_at DATETIME DEFAULT current_timestamp);"

  CURRENT_VER="$(db_query "SELECT MAX(version) FROM _schema_version;")"
  : "${CURRENT_VER:=0}"

  # Apply migration files in order (e.g., 001_init.sql, 002_add_token.sql)
  for script in "${MIGRATIONS_DIR}"/*.sql; do
    # Extract version number from filename (e.g., 001)
    VERSION_NUM=$(basename "${script}" | cut -d'_' -f1 | sed 's/^0*//')

    if [[ "${VERSION_NUM}" -gt "${CURRENT_VER}" ]]; then
      echo "Applying migration version ${VERSION_NUM}: ${script}..."
      sqlite3 "${DB_PATH}" < "${script}"
      db_query "INSERT OR IGNORE INTO _schema_version (version) VALUES (${VERSION_NUM});"
    fi
  done
}

db_query() {
  # Remove the first line of wal output
  sqlite3 "${DB_PATH}" "PRAGMA journal_mode=WAL; $1" | sed '1d'
}
