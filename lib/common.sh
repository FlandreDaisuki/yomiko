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
