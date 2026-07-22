#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/galleries.sh?gids=1,2,3&fields=gid,self_rating'
# curl 'http://localhost:62080/api/galleries.sh?gids=1&gids=2&gids=3&fields=gid&fields=self_rating'
# curl 'http://localhost:62080/api/galleries.sh?gids=%5B1%2C2%2C3%5D&fields=%5Bgid%2Cself_rating%5D'
# curl 'http://localhost:62080/api/galleries.sh?gids%5B%5D=1&gids%5B%5D=2&fields%5B%5D=gid&fields%5B%5D=self_rating'
# curl --globoff 'http://localhost:62080/api/galleries.sh?gids=[1,2,3]&fields[]=gid&fields[]=self_rating'

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

mapfile -t gids < <(query_array_values gids)
mapfile -t fields < <(query_array_values fields)

if [[ "${#gids[@]}" -eq 0 ]]; then
  json_error "400 Bad Request" "Missing gids query parameter"
  exit 0
fi

for gid in "${gids[@]}"; do
  if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
    json_error "400 Bad Request" "Invalid gids query parameter" "All gids must be unsigned integers."
    exit 0
  fi
done

allowed_fields=(
  gid
  is_found
  token
  title
  title_jpn
  file_count
  expunged
  tags
  rating
  file_path
  self_rating
  created_at
  updated_at
  rated_then_deleted_at
  feedbacked_at
)

if [[ "${#fields[@]}" -eq 0 ]]; then
  fields=("${allowed_fields[@]}")
fi

for field in "${fields[@]}"; do
  field_allowed=0
  for allowed_field in "${allowed_fields[@]}"; do
    if [[ "${field}" == "${allowed_field}" ]]; then
      field_allowed=1
      break
    fi
  done

  if [[ "${field_allowed}" -ne 1 ]]; then
    json_error "400 Bad Request" "Invalid fields query parameter" "Unsupported field: ${field}"
    exit 0
  fi
done

gids_json=$(printf '%s\n' "${gids[@]}" | jq -R 'tonumber' | jq -s '.')
fields_json=$(printf '%s\n' "${fields[@]}" | jq -R '.' | jq -s 'reduce .[] as $field ([]; if index($field) then . else . + [$field] end)')

output=$("${YOMIKO_BIN}" list --format json --max-count "${#gids[@]}" "${gids[@]}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  json_error "500 Internal Server Error" "Failed to list galleries" "${output}"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson requested_gids "${gids_json}" \
  --argjson requested_fields "${fields_json}" \
  --argjson rows "${output}" \
  '
  def missing_value($gid; $field):
    if $field == "gid" then $gid
    elif $field == "is_found" then false
    elif ["file_count", "expunged", "rating", "self_rating"] | index($field) then 0
    else "" end;

  def found_value($row; $field):
    if $field == "is_found" then true
    else $row[$field] end;

  def project($gid; $row):
    ($row != null) as $found |
    reduce $requested_fields[] as $field (
      {gid: $gid, is_found: $found};
      if $field == "gid" or $field == "is_found" then
        .
      elif $found then
        . + {($field): found_value($row; $field)}
      else
        . + {($field): missing_value($gid; $field)}
      end
    );

  {
    success: true,
    galleries: [
      $requested_gids[] as $gid |
      ($rows | map(select(.gid == $gid)) | first) as $row |
      project($gid; $row)
    ]
  }'
