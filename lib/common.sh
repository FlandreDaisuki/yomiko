#!/usr/bin/env bash

: "${YOMIKO_CLI_IN_API_MODE:=}"

yomiko_in_api_mode() {
  [[ -n "${YOMIKO_CLI_IN_API_MODE:-}" ]]
}

log() {
  if ! yomiko_in_api_mode; then
    echo "$*"
  fi
}

log_err() {
  log "ERROR: $*" >&2
}

# Convert a memory limit to the KiB unit expected by `ulimit -v`.
# An empty limit succeeds without producing a value.
memory_limit_to_kb() {
  local memory_limit="$1"
  local memory_value memory_unit

  if [[ -z "${memory_limit}" ]]; then
    return 0
  fi

  if [[ ! "${memory_limit}" =~ ^([1-9][0-9]*)(KiB|MiB|GiB)$ ]]; then
    return 1
  fi

  memory_value="${BASH_REMATCH[1]}"
  memory_unit="${BASH_REMATCH[2]}"
  case "${memory_unit}" in
  KiB)
    printf '%s\n' "${memory_value}"
    ;;
  MiB)
    printf '%s\n' "$((memory_value * 1024))"
    ;;
  GiB)
    printf '%s\n' "$((memory_value * 1024 * 1024))"
    ;;
  esac
}
