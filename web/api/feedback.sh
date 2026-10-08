#!/usr/bin/env bash

# usage:
# curl -X PUT 'http://localhost:62080/api/feedback.sh?gid=123456&rating=11'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

if [[ "${REQUEST_METHOD:-GET}" != "PUT" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: PUT"
  echo "Content-Type: application/json"
  echo ""
  api_json_error_body "Method not allowed"
  exit 0
fi

api_require_mutation_auth || exit 0

if ! api_query_parse; then
  api_json_error_response "400 Bad Request" "Invalid query string"
  exit 0
fi

GID_STATUS=0
api_query_get_scalar gid || GID_STATUS=$?
gid="${API_QUERY_VALUE}"
if ((GID_STATUS == 2)); then
  api_json_error_response "400 Bad Request" "Repeated gid query parameter"
  exit 0
fi

RATING_STATUS=0
api_query_get_scalar rating || RATING_STATUS=$?
rating="${API_QUERY_VALUE}"
if ((RATING_STATUS == 2)); then
  api_json_error_response "400 Bad Request" "Repeated rating query parameter"
  exit 0
fi

if api_query_has_parameter favorite; then
  api_json_error_response "400 Bad Request" "The favorite query parameter is no longer supported"
  exit 0
fi

if [[ -z "${gid}" ]]; then
  api_json_error_response "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[1-9][0-9]*$ ]]; then
  api_json_error_response "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

if [[ -z "${rating}" ]]; then
  api_json_error_response "400 Bad Request" "Missing rating query parameter"
  exit 0
fi

if [[ ! "${rating}" =~ ^([1-9]|10|11)$ ]]; then
  api_json_error_response "400 Bad Request" "Invalid rating query parameter"
  exit 0
fi

args=(feedback "${gid}" --rating "${rating}")

output=$("${YOMIKO_BIN}" "${args[@]}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "feedback ${gid}" "${output}"
  api_json_error_response "502 Bad Gateway" "Failed to update feedback"
  exit 0
fi

if ! jq -e '
  type == "object" and
  keys == ["variant_queued"] and
  (.variant_queued | type == "boolean")
' >/dev/null 2>&1 <<<"${output}"; then
  api_log_command_failure "feedback ${gid}" "Invalid CLI result: ${output}"
  api_json_error_response "502 Bad Gateway" "Failed to update feedback"
  exit 0
fi

variant_queued="$(jq -r '.variant_queued' <<<"${output}")"

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson gid "${gid}" \
  --argjson rating "${rating}" \
  --argjson variant_queued "${variant_queued}" \
  '{
    success: true,
    gid: $gid,
    rating: $rating,
    variant_queued: $variant_queued,
    message: "Feedback updated successfully"
  }'
