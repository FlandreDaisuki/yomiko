#!/usr/bin/env bash

# usage:
# curl -X POST 'http://localhost:62080/api/update_cookies.sh' \
#   -d 'ipb_member_id=xxx; ipb_pass_hash=xxx; igneous=xxx'

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

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/exh.sh" ]] && source "${HOME}/lib/exh.sh"

output=$(exh_refresh_cookies "${PAYLOAD}" 2>&1 >/dev/null)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  echo "Status: 400 Bad Request"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    --argjson output "${output}" \
    '{
      success: false,
      error: "Invalid cookie data",
      debug: $output
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
