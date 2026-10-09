#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/pending_feedback_galleries.sh?max_count=50'
# curl 'http://localhost:62080/api/pending_feedback_galleries.sh?order_by=hath_requested_at,asc'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
MAX_COUNT_LIMIT=50
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
apply_middleware_cli_in_api_mode
apply_middleware_cors

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  api_status_headers "405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: application/json"
  echo ""
  api_json_error_body "Method not allowed"
  exit 0
fi

if ! api_query_parse; then
  api_json_error_response "400 Bad Request" "Invalid query string"
  exit 0
fi

MAX_COUNT_STATUS=0
api_query_get_scalar max_count || MAX_COUNT_STATUS=$?
if ((MAX_COUNT_STATUS == 2)); then
  api_json_error_response "400 Bad Request" "Repeated max_count query parameter"
  exit 0
elif ((MAX_COUNT_STATUS == 1)); then
  MAX_COUNT="${MAX_COUNT_LIMIT}"
else
  MAX_COUNT="${API_QUERY_VALUE}"
fi

ORDER_BY_STATUS=0
api_query_get_scalar order_by || ORDER_BY_STATUS=$?
if ((ORDER_BY_STATUS == 2)); then
  api_json_error_response "400 Bad Request" "Repeated order_by query parameter"
  exit 0
elif ((ORDER_BY_STATUS == 1)); then
  ORDER_BY='hath_requested_at,asc'
else
  ORDER_BY="${API_QUERY_VALUE}"
fi

if [[ ! "${MAX_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  api_json_error_response "400 Bad Request" "Invalid max_count query parameter"
  exit 0
fi

if [[ "${#MAX_COUNT}" -gt "${#MAX_COUNT_LIMIT}" ]] ||
  ((10#${MAX_COUNT} > MAX_COUNT_LIMIT)); then
  api_json_error_response "400 Bad Request" "Invalid max_count query parameter" "Maximum allowed value is ${MAX_COUNT_LIMIT}."
  exit 0
fi

IFS=',' read -r ORDER_FIELD ORDER_DIRECTION ORDER_EXTRA <<<"${ORDER_BY}"

if [[ -z "${ORDER_FIELD}" || -z "${ORDER_DIRECTION}" || -n "${ORDER_EXTRA}" ]]; then
  api_json_error_response "400 Bad Request" "Invalid order_by query parameter" "Expected <field>,<asc|desc>."
  exit 0
fi

case "${ORDER_FIELD}" in
gid | hath_requested_at) ;;
*)
  api_json_error_response "400 Bad Request" "Invalid order_by query parameter" "Unsupported field: ${ORDER_FIELD}"
  exit 0
  ;;
esac

case "${ORDER_DIRECTION,,}" in
asc | desc)
  ORDER_BY="${ORDER_FIELD},${ORDER_DIRECTION,,}"
  ;;
*)
  api_json_error_response "400 Bad Request" "Invalid order_by query parameter" "Direction must be asc or desc."
  exit 0
  ;;
esac

OUTPUT=$("${YOMIKO_BIN}" list --format json --pending-feedback --max-count "${MAX_COUNT}" \
  --artist-sorting --order-by "${ORDER_BY}" 2>&1)
EXIT_CODE="$?"

if [[ "${EXIT_CODE}" -ne 0 ]]; then
  api_log_command_failure "list pending feedback galleries" "${OUTPUT}"
  api_json_error_response "500 Internal Server Error" "Failed to list pending feedback galleries"
  exit 0
fi

if ! jq -e 'type == "array" and all(.[]; has("gid") and ((.gid | type) == "number" or (.gid | type) == "string"))' \
  >/dev/null <<<"${OUTPUT}"; then
  api_log_command_failure "list pending feedback galleries" "CLI returned invalid gallery JSON"
  api_json_error_response "500 Internal Server Error" "Failed to list pending feedback galleries"
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
    api_json_error_response "500 Internal Server Error" "Failed to list pending feedback galleries"
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
    api_json_error_response "500 Internal Server Error" "Failed to list pending feedback galleries"
    exit 0
  fi
fi

api_status_headers "200 OK"
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
