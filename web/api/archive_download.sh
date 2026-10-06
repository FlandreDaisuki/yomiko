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

# BusyBox httpd only uses Status as the CGI response status when it is the
# first header. Keep this archive-specific gate here so common middleware keeps
# the same response behavior for other endpoints.
archive_download_cors_gate() {
  case "${HTTP_ORIGIN:-}" in
  "" | "https://exhentai.org" | "https://e-hentai.org") ;;
  *)
    if ! api_origin_matches_host "${HTTP_ORIGIN:-}"; then
      echo "Status: 403 Forbidden"
      api_security_headers
      echo "Vary: Origin"
      echo ""
      exit 0
    fi
    ;;
  esac

  if [[ "${REQUEST_METHOD:-GET}" == "OPTIONS" ]]; then
    echo "Status: 204 No Content"
    api_security_headers
    api_cors_headers
    echo ""
    exit 0
  fi
}

archive_download_cors_gate

archive_download_status_headers() {
  local status="$1"

  echo "Status: ${status}"
  api_security_headers
  api_cors_headers
}

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

  archive_download_status_headers "${status}"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${error}"
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  archive_download_status_headers "405 Method Not Allowed"
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

archive_download_status_headers "200 OK"
echo "Content-Type: application/x-7z-compressed"
echo "Content-Disposition: attachment; filename=\"${download_name}\""
echo ""
cat "${archive_file}"
