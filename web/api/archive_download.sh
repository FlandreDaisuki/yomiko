#!/usr/bin/env bash

# usage:
# curl -OJ 'http://localhost:62080/api/archive_download.sh?gid=123456'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
# shellcheck disable=SC1091
source "${HOME}/lib/path.sh"
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

text_error() {
  local status="$1"
  local error="$2"

  echo "Status: ${status}"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${error}"
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "Method not allowed"
  exit 0
fi

gid="$(query_param gid)"

if [[ -z "${gid}" ]]; then
  text_error "400 Bad Request" "Missing gid query parameter"
  exit 0
fi

if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
  text_error "400 Bad Request" "Invalid gid query parameter"
  exit 0
fi

record=$("${YOMIKO_BIN}" list --format json --max-count 1 "${gid}" 2>&1)
exit_code="$?"

if [[ "${exit_code}" -ne 0 ]]; then
  text_error "500 Internal Server Error" "Failed to load gallery record"
  exit 0
fi

file_path="$(jq -r '.[0].file_path // empty' <<<"${record}")"

if [[ -z "${file_path}" ]]; then
  text_error "404 Not Found" "Archive not found"
  exit 0
fi

if ! archive_filename_is_safe "${file_path}"; then
  text_error "400 Bad Request" "Invalid archive path"
  exit 0
fi

archive_file="${ARCHIVED_DIR}/${file_path}"

if [[ ! -f "${archive_file}" ]]; then
  text_error "404 Not Found" "Archive file is missing"
  exit 0
fi

download_name="${file_path//\"/}"
download_name="${download_name//\\/}"

echo "Status: 200 OK"
echo "Content-Type: application/x-7z-compressed"
echo "Content-Disposition: attachment; filename=\"${download_name}\""
echo ""
cat "${archive_file}"
