#!/usr/bin/env bash

# usage:
# curl -X PUT 'http://localhost:62080/api/feedback.sh?gid=123456&rating=11'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

query_param() {
  local name="$1"
  local pair
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    if [[ "${pair%%=*}" == "${name}" ]]; then
      url_decode "${pair#*=}"
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

api_require_mutation_auth || exit 0

gid="$(query_param gid)"
rating="$(query_param rating)"
favorite="$(query_param favorite)"

if [[ -z "${gid}" ]]; then
  json_error "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[1-9][0-9]*$ ]]; then
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

output=$("${YOMIKO_BIN}" "${args[@]}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "feedback ${gid}" "${output}"
  json_error "502 Bad Gateway" "Failed to update feedback"
  exit 0
fi

if ! jq -e '
  type == "object" and
  (.variant_queued | type == "boolean") and
  ((.variant_group_id | type == "number") or .variant_group_id == null) and
  (if .variant_queued then (.variant_group_id | type == "number") else .variant_group_id == null end)
' >/dev/null 2>&1 <<<"${output}"; then
  api_log_command_failure "feedback ${gid}" "Invalid CLI result: ${output}"
  json_error "502 Bad Gateway" "Failed to update feedback"
  exit 0
fi

variant_queued="$(jq -r '.variant_queued' <<<"${output}")"
variant_group_id="$(jq -c '.variant_group_id' <<<"${output}")"

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson gid "${gid}" \
  --argjson rating "${rating}" \
  --argjson variant_queued "${variant_queued}" \
  --argjson variant_group_id "${variant_group_id}" \
  '{
    success: true,
    gid: $gid,
    rating: $rating,
    variant_queued: $variant_queued,
    variant_group_id: $variant_group_id,
    message: "Feedback updated successfully"
  }'
