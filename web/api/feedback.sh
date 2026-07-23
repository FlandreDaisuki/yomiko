#!/usr/bin/env bash

# usage:
# curl -X PUT 'http://localhost:62080/api/feedback.sh?gid=123456&rating=11'

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

  echo "Status: ${status}"
  echo "Content-Type: application/json"
  echo ""
  jq -n \
    --arg error "${error}" \
    '{
      success: false,
      error: $error
    }'
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
rating="$(query_param rating)"
favorite="$(query_param favorite)"

if [[ -z "${gid}" ]]; then
  json_error "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
  json_error "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

if [[ -z "${rating}" ]]; then
  json_error "400 Bad Request" "Missing rating query parameter"
  exit 0
fi

if [[ ! "${rating}" =~ ^([1-9]|10|11)$ ]]; then
  json_error "400 Bad Request" "Invalid rating query parameter"
  exit 0
fi

args=(feedback "${gid}" --rating "${rating}")

if [[ -n "${favorite}" ]]; then
  if [[ ! "${favorite}" =~ ^[0-9]$ ]]; then
    json_error "400 Bad Request" "Invalid favorite query parameter"
    exit 0
  fi
  args+=(--favorite "${favorite}")
fi

output=$("${HOME}/bin/yomiko" "${args[@]}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "feedback ${gid}" "${output}"
  json_error "502 Bad Gateway" "Failed to update feedback"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson gid "${gid}" \
  --argjson rating "${rating}" \
  '{
    success: true,
    gid: $gid,
    rating: $rating,
    message: "Feedback updated successfully"
  }'
