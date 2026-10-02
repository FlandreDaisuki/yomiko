#!/usr/bin/env bash

# usage:
# curl -X POST 'http://localhost:62080/api/update_cookies.sh' \
#   -d 'ipb_member_id=xxx; ipb_pass_hash=xxx; igneous=xxx'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAX_COOKIE_BODY_BYTES=65536
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

api_require_mutation_auth || exit 0

content_length="${CONTENT_LENGTH:-}"
if [[ -z "${content_length}" ]]; then
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Missing request body length"}'
  exit 0
fi
if [[ ! "${content_length}" =~ ^[0-9]+$ ]] || [[ "${#content_length}" -gt 5 ]]; then
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Invalid request body length"}'
  exit 0
fi

content_length_number=$((10#${content_length}))
if ((content_length_number == 0)); then
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Cookie body is required"}'
  exit 0
fi
if ((content_length_number > MAX_COOKIE_BODY_BYTES)); then
  echo "Status: 413 Payload Too Large"
  echo "Content-Type: application/json"
  echo ""
  jq -n --argjson max_bytes "${MAX_COOKIE_BODY_BYTES}" \
    '{success: false, error: "Cookie body is too large", max_bytes: $max_bytes}'
  exit 0
fi

PAYLOAD="$(head -c "${content_length_number}"; printf '.')"
PAYLOAD="${PAYLOAD%.}"
payload_bytes="$(printf '%s' "${PAYLOAD}" | wc -c | tr -d '[:space:]')"
if [[ ! "${payload_bytes}" =~ ^[0-9]+$ ]] || ((payload_bytes != content_length_number)); then
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Cookie body length does not match Content-Length"}'
  exit 0
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
