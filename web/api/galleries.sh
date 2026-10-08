#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/galleries.sh?gids=1,2,3'
# curl 'http://localhost:62080/api/galleries.sh?gids=1&gids=2&gids=3'
# curl 'http://localhost:62080/api/galleries.sh?gids=%5B1%2C2%2C3%5D'
# curl 'http://localhost:62080/api/galleries.sh?gids%5B%5D=1&gids%5B%5D=2&gids%5B%5D=3'
# curl --globoff 'http://localhost:62080/api/galleries.sh?gids=[1,2,3]'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
MAX_GIDS=50
MAX_QUERY_BYTES=4096
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "${value}"
}

emit_array_values() {
  local raw
  raw="$(trim "$(url_decode "$1")")"

  if [[ "${raw}" == \[*\] ]]; then
    raw="${raw:1:${#raw}-2}"
  fi

  local part
  local -a parts
  IFS=',' read -ra parts <<<"${raw}"
  for part in "${parts[@]}"; do
    part="$(trim "${part}")"
    part="${part%\"}"
    part="${part#\"}"
    part="${part%\'}"
    part="${part#\'}"
    [[ -n "${part}" ]] && echo "${part}"
  done
}

query_array_values() {
  local name="$1"
  local pair key value
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    [[ -n "${pair}" ]] || continue
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ "${pair}" != *=* ]]; then
      value=""
    fi

    key="$(url_decode "${key}")"
    if [[ "${key}" == "${name}" || "${key}" == "${name}[]" ]]; then
      emit_array_values "${value}"
    fi
  done
}

query_has_parameter() {
  local name="$1"
  local pair key
  local -a pairs

  IFS='&' read -ra pairs <<<"${QUERY_STRING:-}"
  for pair in "${pairs[@]}"; do
    [[ -n "${pair}" ]] || continue
    key="${pair%%=*}"
    key="$(url_decode "${key}")"
    if [[ "${key}" == "${name}" || "${key}" == "${name}[]" ]]; then
      return 0
    fi
  done
  return 1
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

query_bytes="$(LC_ALL=C printf '%s' "${QUERY_STRING:-}" | wc -c | tr -d '[:space:]')"
if ((query_bytes > MAX_QUERY_BYTES)); then
  json_error "414 URI Too Long" "Query string is too large" \
    "The maximum query string size is ${MAX_QUERY_BYTES} bytes."
  exit 0
fi

mapfile -t gids < <(query_array_values gids)

if query_has_parameter fields; then
  json_error "400 Bad Request" "Unsupported fields query parameter" \
    "The fields parameter is no longer supported; gallery states are always returned."
  exit 0
fi

if [[ "${#gids[@]}" -eq 0 ]]; then
  json_error "400 Bad Request" "Missing gids query parameter"
  exit 0
fi

if ((${#gids[@]} > MAX_GIDS)); then
  json_error "400 Bad Request" "Too many gids query values" \
    "A maximum of ${MAX_GIDS} GIDs is accepted per request."
  exit 0
fi

for gid in "${gids[@]}"; do
  if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
    json_error "400 Bad Request" "Invalid gids query parameter" "All gids must be unsigned integers."
    exit 0
  fi
done

output=$("${YOMIKO_BIN}" gallery-status "${gids[@]}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  api_log_command_failure "gallery statuses" "${output}"
  json_error "500 Internal Server Error" "Failed to read gallery statuses"
  exit 0
fi

if ! RESPONSE="$(jq -n --argjson galleries "${output}" \
  'if ($galleries | type) == "array" then
     {success: true, projection_version: 2, galleries: $galleries}
   else
     error("gallery statuses must be an array")
   end' 2>/dev/null)"; then
  api_log_command_failure "gallery status response" "CLI returned invalid gallery JSON"
  json_error "500 Internal Server Error" "Failed to read gallery statuses"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
printf '%s\n' "${RESPONSE}"
