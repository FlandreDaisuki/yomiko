#!/usr/bin/env bash

# usage:
# curl -X POST 'http://localhost:62080/api/update_cookies.sh' \
#   -d 'ipb_member_id=xxx; ipb_pass_hash=xxx; igneous=xxx'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

if [[ "${REQUEST_METHOD}" != "POST" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: POST"
  echo ""
  exit 0
fi

PAYLOAD=""
if [[ "${CONTENT_LENGTH:-0}" -gt 0 ]]; then
  PAYLOAD=$(head -c "${CONTENT_LENGTH}")
fi

output=$("${HOME}/bin/yomiko" login --cookie "${PAYLOAD}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "login" "${output}"
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{
    success: false,
    error: "Invalid cookie data"
  }'
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  '{
    success: true,
    message: "Cookies updated successfully"
  }'
