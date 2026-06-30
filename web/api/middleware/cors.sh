#!/usr/bin/env bash

api_cors_headers() {
  local origin="${HTTP_ORIGIN:-}"
  local request_headers="${HTTP_ACCESS_CONTROL_REQUEST_HEADERS:-Content-Type, Authorization, X-Requested-With}"

  [[ -n "${origin}" ]] || return 0

  case "${origin}" in
    "https://exhentai.org" | "https://e-hentai.org")
      echo "Access-Control-Allow-Origin: ${origin}"
      echo "Vary: Origin"
      ;;
  esac

  echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
  echo "Access-Control-Allow-Headers: ${request_headers}"
  echo "Access-Control-Max-Age: 86400"
}

api_cors_middleware() {
  case "${HTTP_ORIGIN:-}" in
    "" | "https://exhentai.org" | "https://e-hentai.org") ;;
    *)
      echo "Status: 403 Forbidden"
      echo "Vary: Origin"
      echo ""
      exit 0
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
