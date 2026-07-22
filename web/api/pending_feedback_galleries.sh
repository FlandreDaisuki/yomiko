#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/pending_feedback_galleries.sh?max_count=100'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
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

max_count="$(query_param max_count)"
: "${max_count:=100}"

if [[ ! "${max_count}" =~ ^[1-9][0-9]*$ ]]; then
  json_error "400 Bad Request" "Invalid max_count query parameter"
  exit 0
fi

output=$("${YOMIKO_BIN}" list --format json --pending-feedback --max-count "${max_count}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  json_error "500 Internal Server Error" "Failed to list pending feedback galleries" "${output}"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson galleries "${output}" \
  '{
    success: true,
    galleries: $galleries
  }'
