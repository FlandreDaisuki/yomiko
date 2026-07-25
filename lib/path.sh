#!/usr/bin/env bash

export ARCHIVED_DIR="${HOME}/archived"
export CRONJOB_DIR="${HOME}/cronjobs"
export HATH_DOWNLOAD_DIR="${HOME}/hath"
export LOG_DIR="${HOME}/logs"
export MIGRATIONS_DIR="${HOME}/migrations"
export DATA_DIR="${HOME}/data"

export DB_PATH="${DATA_DIR}/db.sqlite3"
export EXH_COOKIE_PATH="${DATA_DIR}/cookie-jar.txt"

mkdir -p \
  "${ARCHIVED_DIR}" \
  "${CRONJOB_DIR}" \
  "${HATH_DOWNLOAD_DIR}" \
  "${LOG_DIR}" \
  "${MIGRATIONS_DIR}" \
  "${DATA_DIR}"

export PATH="${HOME}/bin:${PATH}"
