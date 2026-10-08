#!/usr/bin/env bash

# usage:
# curl -X PUT 'http://localhost:62080/api/hath_download.sh?gid=123456'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

if [[ -z "${gid}" ]]; then
  api_json_error_response "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
  api_json_error_response "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

output=$("${HOME}/bin/yomiko" hath "${gid}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "hath ${gid}" "${output}"
  api_json_error_response "502 Bad Gateway" "Failed to request download"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson gid "${gid}" \
  '{
    success: true,
    gid: $gid,
    message: "Download requested successfully"
  }'
