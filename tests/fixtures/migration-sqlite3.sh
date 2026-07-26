#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_SQLITE_STATE_DIR:?}"
trace_path="${MOCK_SQLITE_TRACE:?}"
mkdir -p "${state_dir}"

while [[ $# -gt 0 && "$1" == -* ]]; do
  shift
done

if [[ $# -lt 1 ]]; then
  printf 'mock sqlite3: missing database path\n' >&2
  exit 64
fi

database_path="$1"
shift
sql="$*"
if [[ -z "${sql}" ]]; then
  sql="$(command cat)"
fi

{
  printf 'DATABASE %s\n' "${database_path}"
  printf '%s\n' "${sql}"
  printf '%s\n' 'END SQL'
} >>"${trace_path}"

if [[ "${sql}" == *'MOCK_QUERY_FAILURE'* ]]; then
  printf 'mock sqlite3: simulated query failure\n' >&2
  exit 23
fi

if [[ "${sql}" == *'SELECT MAX(version) FROM _schema_version'* ]]; then
  if [[ -f "${state_dir}/version" ]]; then
    printf '%s\n' "$(<"${state_dir}/version")"
  fi
  exit 0
fi

if [[ "${sql}" == *'BEGIN IMMEDIATE;'* ]]; then
  if [[ "${sql}" != *'COMMIT;'* ]]; then
    printf 'mock sqlite3: migration is missing COMMIT\n' >&2
    exit 65
  fi

  version="$(sed -n 's/.*_schema_version (version) VALUES (\([0-9][0-9]*\)).*/\1/p' <<<"${sql}" | tail -n 1)"
  if [[ -z "${version}" ]]; then
    printf 'mock sqlite3: migration is missing its version insert\n' >&2
    exit 66
  fi

  if [[ "${sql}" == *'MOCK_MIGRATION_FAILURE'* ]]; then
    printf 'mock sqlite3: simulated migration failure\n' >&2
    exit 19
  fi

  effect="$(sed -n 's/^-- MOCK_EFFECT: \(.*\)$/\1/p' <<<"${sql}")"
  if [[ -n "${effect}" ]]; then
    printf '%s\n' "${effect}" >>"${state_dir}/effects"
  fi
  printf '%s\n' "${version}" >"${state_dir}/version"
fi
