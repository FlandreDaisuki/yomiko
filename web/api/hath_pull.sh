#!/usr/bin/env bash

# usage:
# curl -X PUT 'http://localhost:62080/api/hath_pull.sh?gid=123456'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

query_param() {
  local name="$1"
  local pair
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    if [[ "${pair%%=*}" == "${name}" ]]; then
      echo "${pair#*=}"
      return 0
    fi
  done
}

json_error() {
  local status="$1"
  local error="$2"
  local debug="${3:-}"

  echo "Status: ${status}"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    --arg error "${error}" \
    --arg debug "${debug}" \
    '{
      success: false,
      error: $error
    } + (if $debug == "" then {} else {debug: $debug} end)'
}

if [[ "${REQUEST_METHOD:-GET}" != "PUT" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: PUT"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    '{
      success: false,
      error: "Method not allowed"
    }'
  exit 0
fi

gid="$(query_param gid)"

if [[ -z "${gid}" ]]; then
  json_error "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
  json_error "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

output=$("${HOME}/bin/yomiko" pull "${gid}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  json_error "502 Bad Gateway" "Failed to request download" "${output}"
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
