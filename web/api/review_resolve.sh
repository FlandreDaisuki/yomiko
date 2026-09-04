#!/usr/bin/env bash

# usage:
# curl -X PUT -H 'Authorization: Bearer ...' \
#   'http://localhost:62080/api/review_resolve.sh?review_id=123&decision=winner&gid=456'

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

if [[ "${REQUEST_METHOD:-GET}" != "PUT" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: PUT"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Method not allowed"}'
  exit 0
fi

api_require_mutation_auth || exit 0

review_id="$(query_param review_id)"
decision="$(query_param decision)"
winner_gid="$(query_param gid)"

if [[ -z "${review_id}" ]]; then
  json_error "400 Bad Request" "Missing review_id query parameter"
  exit 0
fi
if [[ ! "${review_id}" =~ ^[1-9][0-9]*$ ]]; then
  json_error "400 Bad Request" "Invalid review_id query parameter"
  exit 0
fi

case "${decision}" in
same-book | different-book | winner) ;;
*)
  json_error "400 Bad Request" "Invalid decision query parameter"
  exit 0
  ;;
esac

if [[ "${decision}" == "winner" ]]; then
  if [[ -z "${winner_gid}" ]]; then
    json_error "400 Bad Request" "Missing gid query parameter for winner decision"
    exit 0
  fi
  if [[ ! "${winner_gid}" =~ ^[1-9][0-9]*$ ]]; then
    json_error "400 Bad Request" "Invalid gid query parameter"
    exit 0
  fi
elif [[ -n "${winner_gid}" ]]; then
  json_error "400 Bad Request" "gid is only valid for winner decisions"
  exit 0
fi

cli_args=(variants resolve "${review_id}" --decision "${decision}")
if [[ "${decision}" == "winner" ]]; then
  cli_args+=(--gid "${winner_gid}")
fi

if output=$("${YOMIKO_BIN}" "${cli_args[@]}" 2>&1); then
  :
else
  exit_code="$?"
  api_log_command_failure "${cli_args[*]}" "${output}"
  # The CLI may reject a review after another request resolved it. A stable
  # conflict response lets clients refresh without exposing CLI diagnostics.
  if [[ "${exit_code}" -eq 4 ]]; then
    json_error "409 Conflict" "Identity decision conflicts with an existing same-book group"
  elif [[ "${exit_code}" -eq 3 ]] ||
    grep -Eiq 'stale|already[[:space:]]+resolved|review[[:space:]]+not[[:space:]]+pending' <<<"${output}"; then
    json_error "409 Conflict" "Review is stale or already resolved"
  else
    json_error "502 Bad Gateway" "Failed to resolve variant review"
  fi
  exit 0
fi

if ! jq -e \
  --argjson review_id "${review_id}" \
  --arg decision "${decision//-/_}" \
  --argjson winner_gid "${winner_gid:-null}" '
  type == "object" and
  .resolved == true and
  .review_id == $review_id and
  (.review_type == "candidate_identity" or .review_type == "winner") and
  .decision == $decision and
  (.source_gid | type == "number") and
  (.candidate_gid == null or (.candidate_gid | type == "number")) and
  has("canonical_gid") and
  (.canonical_gid == null or (.canonical_gid | type == "number")) and
  (.evaluation_created | type == "boolean") and
	  (.reevaluation_queued | type == "boolean") and
	  (.merged_group | type == "boolean") and
	  (.reviews_collapsed | type == "number" and . >= 0 and floor == .) and
	  (.groups_unblocked | type == "number" and . >= 0 and floor == .) and
  ([.. | objects | (has("group_id") or has("selected_gid") or has("selected_canonical_gid") or has("first_key") or has("parent_key") or has("current_key") or has("chain_key_mismatch"))] | any | not) and
  (if $decision == "winner"
   then .review_type == "winner" and .canonical_gid == $winner_gid
   else .review_type == "candidate_identity" and .canonical_gid == null
   end)
' >/dev/null 2>&1 <<<"${output}"; then
  api_log_command_failure "${cli_args[*]}" "Invalid CLI result: ${output}"
  json_error "502 Bad Gateway" "Failed to resolve variant review"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n --argjson result "${output}" '{success: true} + $result'
