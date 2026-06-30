#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/yomiko.user.js'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd -- "${API_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/middleware/cors.sh"
api_cors_middleware

request_scheme() {
  if [[ -n "${HTTP_X_FORWARDED_PROTO:-}" ]]; then
    echo "${HTTP_X_FORWARDED_PROTO%%,*}"
  elif [[ "${HTTPS:-}" == "on" || "${HTTPS:-}" == "1" ]]; then
    echo "https"
  else
    echo "http"
  fi
}

request_host_without_port() {
  local host="${HTTP_HOST:-localhost}"

  if [[ "${host}" == \[*\]* ]]; then
    host="${host#\[}"
    echo "${host%%\]*}"
  else
    echo "${host%%:*}"
  fi
}

host="${HTTP_HOST:-localhost:62080}"
connect_host="$(request_host_without_port)"
api_base="$(request_scheme)://${host}"

echo "Status: 200 OK"
echo "Content-Type: text/javascript"
echo ""

awk \
  -v connect_host="${connect_host}" \
  -v api_base="${api_base}" \
  '
    {
      gsub(/__YOMIKO_CONNECT_HOST__/, connect_host)
      gsub(/__YOMIKO_API_BASE__/, api_base)
      print
    }
  ' "${WEB_DIR}/yomiko.user.js"
