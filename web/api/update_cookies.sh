#!/usr/bin/env bash

# usage:
# curl -X POST 'http://localhost:62080/api/update_cookies.sh' \
#   -d 'ipb_member_id=xxx; ipb_pass_hash=xxx; igneous=xxx'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAX_COOKIE_BODY_BYTES=65536
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
apply_middleware_cli_in_api_mode
apply_middleware_cors

if [[ "${REQUEST_METHOD}" != "POST" ]]; then
  api_status_headers "405 Method Not Allowed"
  echo "Allow: POST"
  echo ""
  exit 0
fi

api_require_mutation_auth || exit 0

content_length="${CONTENT_LENGTH:-}"
if [[ -z "${content_length}" ]]; then
  api_json_error_response "400 Bad Request" "Missing request body length"
  exit 0
fi
if [[ ! "${content_length}" =~ ^[0-9]+$ ]] || [[ "${#content_length}" -gt 5 ]]; then
  api_json_error_response "400 Bad Request" "Invalid request body length"
  exit 0
fi

content_length_number=$((10#${content_length}))
if ((content_length_number == 0)); then
  api_json_error_response "400 Bad Request" "Cookie body is required"
  exit 0
fi
if ((content_length_number > MAX_COOKIE_BODY_BYTES)); then
  api_status_headers "413 Payload Too Large"
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
  api_json_error_response "400 Bad Request" "Cookie body length does not match Content-Length"
  exit 0
fi

output=$("${HOME}/bin/yomiko" login --cookie "${PAYLOAD}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "login" "${output}"
  api_json_error_response "400 Bad Request" "Invalid cookie data"
  exit 0
fi

api_status_headers "200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  '{
    success: true,
    message: "Cookies updated successfully"
  }'
