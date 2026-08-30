#!/usr/bin/env bash

export ARCHIVED_DIR="${HOME}/archived"
export CRONJOB_DIR="${HOME}/cronjobs"
export HATH_DOWNLOAD_DIR="${HOME}/hath"
export LOG_DIR="${HOME}/logs"
export MIGRATIONS_DIR="${HOME}/migrations"
export DATA_DIR="${HOME}/data"

export DB_PATH="${DATA_DIR}/db.sqlite3"
export EXH_COOKIE_PATH="${DATA_DIR}/cookie-jar.txt"
export SCAN_LOG_PATH="${LOG_DIR}/yomiko-scan.log"
export VARIANTS_LOG_PATH="${LOG_DIR}/yomiko-variants.log"

archive_filename_is_safe() {
  local file_path="$1"

  [[ -n "${file_path}" ]] || return 1
  case "${file_path}" in
  # Embedded dots are valid; only traversal components are forbidden.
  */* | . | .. | *$'\n'* | *$'\r'*) return 1 ;;
  *) return 0 ;;
  esac
}

mkdir -p \
  "${ARCHIVED_DIR}" \
  "${CRONJOB_DIR}" \
  "${HATH_DOWNLOAD_DIR}" \
  "${LOG_DIR}" \
  "${MIGRATIONS_DIR}" \
  "${DATA_DIR}"

export PATH="${HOME}/bin:${PATH}"
