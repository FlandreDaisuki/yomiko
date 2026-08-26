#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/reviews.sh?status=pending'

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
  local key
  local value
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    [[ -n "${pair}" ]] || continue
    key="${pair%%=*}"
    if [[ "${key}" == "${name}" ]]; then
      if [[ "${pair}" == *=* ]]; then
        value="${pair#*=}"
      else
        value=""
      fi
      url_decode "${value}"
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
  jq -n --arg error "${error}" '{success: false, error: $error}'
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Method not allowed"}'
  exit 0
fi

status="$(query_param status)"
if [[ -n "${status}" && "${status}" != "pending" && "${status}" != "resolved" ]]; then
  json_error "400 Bad Request" "Invalid status query parameter"
  exit 0
fi

cli_args=(variants reviews)
if [[ -n "${status}" ]]; then
  cli_args+=(--status "${status}")
fi

if output=$("${YOMIKO_BIN}" "${cli_args[@]}" 2>&1); then
  :
else
  api_log_command_failure "${cli_args[*]}" "${output}"
  # A read failure is an upstream/CLI failure. Never return its diagnostics.
  json_error "502 Bad Gateway" "Failed to list variant reviews"
  exit 0
fi

if ! jq -e '
	  type == "object" and
	  (.reviews | type == "array") and
	  (.actionable_count | type == "number" and . >= 0 and floor == .) and
  ([.. | objects | has("group_id")] | any | not) and
  all(.reviews[];
    (.id | type == "number") and
    (.review_type == "candidate_identity" or .review_type == "winner") and
    (.source_gid | type == "number") and
    (.status == "pending" or .status == "resolved") and
    (.evidence | type == "object") and
    (.source | type == "object") and
    (.choices | type == "array") and
	    (if .review_type == "candidate_identity"
	     then (.candidate | type == "object") and (.candidate_gid | type == "number") and
	          ((.covered_review_count == null) or
	           (.covered_review_count | type == "number" and . >= 1 and floor == .)) and
	          ((.source_class_size == null) or
	           (.source_class_size | type == "number" and . >= 1 and floor == .)) and
	          ((.candidate_class_size == null) or
	           (.candidate_class_size | type == "number" and . >= 1 and floor == .))
	     else .candidate == null and .candidate_gid == null
	     end))
' >/dev/null 2>&1 <<<"${output}"; then
  api_log_command_failure "${cli_args[*]}" "Invalid CLI result: ${output}"
  json_error "502 Bad Gateway" "Failed to list variant reviews"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq '{success: true, actionable_count, reviews}' <<<"${output}"
