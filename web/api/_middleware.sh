#!/usr/bin/env bash

# suppress yomiko cli output
middleware_cli_in_api_mode() {
  export YOMIKO_CLI_IN_API_MODE=1
}

# Keep implementation diagnostics in the web server's error log without
# returning them as part of the public API response.
api_log_command_failure() {
  local command="$1"
  local output="${2:-}"

  printf 'Yomiko API command failed: %s\n' "${command}" >&2
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
  fi
}

api_cors_headers() {
  local origin="${HTTP_ORIGIN:-}"
  local request_headers="${HTTP_ACCESS_CONTROL_REQUEST_HEADERS:-Content-Type, Authorization, X-Requested-With}"

  [[ -n "${origin}" ]] || return 0

  case "${origin}" in
  "https://exhentai.org" | "https://e-hentai.org")
    echo "Access-Control-Allow-Origin: ${origin}"
    echo "Vary: Origin"
    ;;
  *)
    if api_origin_matches_host "${origin}"; then
      echo "Access-Control-Allow-Origin: ${origin}"
      echo "Vary: Origin"
    fi
    ;;
  esac

  echo "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS"
  echo "Access-Control-Allow-Headers: ${request_headers}"
  echo "Access-Control-Max-Age: 86400"
}

api_origin_matches_host() {
  local origin="$1"
  local host="${HTTP_HOST:-}"
  local origin_host="${origin#http://}"
  origin_host="${origin_host#https://}"

  [[ -n "${host}" && "${origin_host}" == "${host}" ]]
}

# support CORS
middleware_cors() {
  case "${HTTP_ORIGIN:-}" in
  "" | "https://exhentai.org" | "https://e-hentai.org") ;;
  *)
    if ! api_origin_matches_host "${HTTP_ORIGIN:-}"; then
      echo "Status: 403 Forbidden"
      echo "Vary: Origin"
      echo ""
      exit 0
    fi
    ;;
  esac

  if [[ "${REQUEST_METHOD:-GET}" == "OPTIONS" ]]; then
    echo "Status: 204 No Content"
    api_cors_headers
    echo ""
    exit 0
  fi

  api_cors_headers
}
