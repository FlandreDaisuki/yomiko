#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/pending_feedback_galleries.sh?max_count=50'
# curl 'http://localhost:62080/api/pending_feedback_galleries.sh?order_by=hath_requested_at,asc'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
MAX_COUNT_LIMIT=50
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

query_param() {
  local name="$1"
  local pair
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    if [[ "${pair%%=*}" == "${name}" ]]; then
      url_decode "${pair#*=}"
      return 0
    fi
  done
}

json_error() {
  local status="$1"
  local error="$2"
  local detail="${3:-}"

  echo "Status: ${status}"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    --arg error "${error}" \
    --arg detail "${detail}" \
    '{
      success: false,
      error: $error
    } + (if $detail == "" then {} else {detail: $detail} end)'
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    '{
      success: false,
      error: "Method not allowed"
    }'
  exit 0
fi

MAX_COUNT="$(query_param max_count)"
: "${MAX_COUNT:=${MAX_COUNT_LIMIT}}"
ORDER_BY="$(query_param order_by)"
: "${ORDER_BY:=hath_requested_at,asc}"

if [[ ! "${MAX_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  json_error "400 Bad Request" "Invalid max_count query parameter"
  exit 0
fi

if [[ "${#MAX_COUNT}" -gt "${#MAX_COUNT_LIMIT}" ]] ||
  ((10#${MAX_COUNT} > MAX_COUNT_LIMIT)); then
  json_error "400 Bad Request" "Invalid max_count query parameter" "Maximum allowed value is ${MAX_COUNT_LIMIT}."
  exit 0
fi

IFS=',' read -r ORDER_FIELD ORDER_DIRECTION ORDER_EXTRA <<<"${ORDER_BY}"

if [[ -z "${ORDER_FIELD}" || -z "${ORDER_DIRECTION}" || -n "${ORDER_EXTRA}" ]]; then
  json_error "400 Bad Request" "Invalid order_by query parameter" "Expected <field>,<asc|desc>."
  exit 0
fi

case "${ORDER_FIELD}" in
gid | hath_requested_at) ;;
*)
  json_error "400 Bad Request" "Invalid order_by query parameter" "Unsupported field: ${ORDER_FIELD}"
  exit 0
  ;;
esac

case "${ORDER_DIRECTION,,}" in
asc | desc)
  ORDER_BY="${ORDER_FIELD},${ORDER_DIRECTION,,}"
  ;;
*)
  json_error "400 Bad Request" "Invalid order_by query parameter" "Direction must be asc or desc."
  exit 0
  ;;
esac

OUTPUT=$("${YOMIKO_BIN}" list --format json --pending-feedback --max-count "${MAX_COUNT}" \
  --artist-sorting --order-by "${ORDER_BY}" 2>&1)
EXIT_CODE="$?"

if [[ "${EXIT_CODE}" -ne 0 ]]; then
  api_log_command_failure "list pending feedback galleries" "${OUTPUT}"
  json_error "500 Internal Server Error" "Failed to list pending feedback galleries"
  exit 0
fi

if ! jq -e 'type == "array" and all(.[]; has("gid") and ((.gid | type) == "number" or (.gid | type) == "string"))' \
  >/dev/null <<<"${OUTPUT}"; then
  api_log_command_failure "list pending feedback galleries" "CLI returned invalid gallery JSON"
  json_error "500 Internal Server Error" "Failed to list pending feedback galleries"
  exit 0
fi

GIDS=()
mapfile -t GIDS < <(jq -r '.[].gid | tostring' <<<"${OUTPUT}")
ARCHIVE_PATHS='[]'
if [[ ${#GIDS[@]} -gt 0 ]]; then
  ARCHIVE_PATHS=$("${YOMIKO_BIN}" internal archive-paths "${GIDS[@]}" 2>&1)
  EXIT_CODE="$?"
  if [[ "${EXIT_CODE}" -ne 0 ]]; then
    api_log_command_failure "resolve pending feedback archive paths" "${ARCHIVE_PATHS}"
    json_error "500 Internal Server Error" "Failed to list pending feedback galleries"
    exit 0
  fi

  if ! jq -e -n \
    --argjson galleries "${OUTPUT}" \
    --argjson archive_paths "${ARCHIVE_PATHS}" \
    '($archive_paths | type == "array")
     and (($galleries | map(.gid | tostring) | sort) as $expected
     | ($archive_paths | map(.gid | tostring) | sort) as $actual
     | $actual == $expected
       and ($archive_paths | all(.[]; has("gid") and has("archive_path"))))' \
    >/dev/null; then
    api_log_command_failure "resolve pending feedback archive paths" "CLI returned invalid archive path JSON"
    json_error "500 Internal Server Error" "Failed to list pending feedback galleries"
    exit 0
  fi
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson galleries "${OUTPUT}" \
  --argjson archive_paths "${ARCHIVE_PATHS}" \
  '{
    success: true,
    galleries: (
      ($archive_paths | map({key: (.gid | tostring), value: .archive_path}) | from_entries) as $paths
      | $galleries
      | map((.gid | tostring) as $gid | {
          gid,
          title,
          title_jpn,
          file_count,
          file_path: ($paths[$gid] // null)
        })
    )
  }'
