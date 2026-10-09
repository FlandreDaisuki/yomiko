#!/usr/bin/env bash

# usage:
# curl -OJ 'http://localhost:62080/api/archive_download.sh?gid=123456'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
# shellcheck disable=SC1091
source "${HOME}/lib/path.sh"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
apply_middleware_cli_in_api_mode

apply_middleware_cors

text_error() {
  local status="$1"
  local error="$2"

  api_status_headers "${status}"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${error}"
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  api_status_headers "405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "Method not allowed"
  exit 0
fi

if ! api_query_parse; then
  text_error "400 Bad Request" "Invalid query string"
  exit 0
fi

GID_STATUS=0
api_query_get_scalar gid || GID_STATUS=$?
gid="${API_QUERY_VALUE}"
if ((GID_STATUS == 2)); then
  text_error "400 Bad Request" "Repeated gid query parameter"
  exit 0
fi

if [[ -z "${gid}" ]]; then
  text_error "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
  text_error "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

record=$("${YOMIKO_BIN}" internal archive-paths "${gid}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  text_error "500 Internal Server Error" "Failed to load gallery record"
  exit 0
fi

if ! jq -e --arg gid "${gid}" \
  'type == "array" and length == 1
   and (.[0] | has("gid") and has("archive_path"))
   and ((.[0].gid | tonumber) == ($gid | tonumber))' \
  >/dev/null <<<"${record}"; then
  text_error "500 Internal Server Error" "Failed to load gallery record"
  exit 0
fi

file_path="$(jq -r '.[0].archive_path // empty' <<<"${record}")"

if [[ -z "${file_path}" ]]; then
  text_error "404 Not Found" "Archive not found"
  exit 0
fi

if ! archive_filename_is_safe "${file_path}"; then
  text_error "400 Bad Request" "Invalid archive path"
  exit 0
fi

archive_file="${ARCHIVED_DIR}/${file_path}"

if [[ ! -f "${archive_file}" || -L "${archive_file}" ]]; then
  text_error "404 Not Found" "Archive file is missing"
  exit 0
fi

download_name="${file_path//\"/}"
download_name="${download_name//\\/}"

api_status_headers "200 OK"
echo "Content-Type: application/x-7z-compressed"
echo "Content-Disposition: attachment; filename=\"${download_name}\""
echo ""
cat "${archive_file}"
