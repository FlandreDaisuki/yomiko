#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/yomiko.user.js'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd -- "${API_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

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
api_token="${YOMIKO_API_TOKEN:-}"
# The template uses a single-quoted JavaScript string so the unrendered
# userscript remains valid JavaScript. Keep JSON's escaping for backslashes and
# control characters, then escape the one quote that is special to this string.
api_token_json="$(jq -Rnr --arg token "${api_token}" '$token | @json')"
api_token_js="${api_token_json:1:${#api_token_json}-2}"
api_token_js="${api_token_js//\'/\\\'}"
userscript_name="${YOMIKO_USERSCRIPT_NAME:-Yomiko}"
build_version="${YOMIKO_BUILD_VERSION:-unknown}"

echo "Status: 200 OK"
echo "Content-Type: text/javascript"
echo ""

YOMIKO_USERSCRIPT_API_TOKEN="${api_token_js}" awk \
  -v connect_host="${connect_host}" \
  -v api_base="${api_base}" \
  -v userscript_name="${userscript_name}" \
  -v build_version="${build_version}" \
  '
    function replace_literal(text, needle, replacement, position) {
      while ((position = index(text, needle)) > 0) {
        text = substr(text, 1, position - 1) replacement substr(text, position + length(needle))
      }
      return text
    }

    {
      line = replace_literal($0, "__YOMIKO_USERSCRIPT_NAME__", userscript_name)
      line = replace_literal(line, "__YOMIKO_BUILD_VERSION__", build_version)
      line = replace_literal(line, "__YOMIKO_CONNECT_HOST__", connect_host)
      line = replace_literal(line, "__YOMIKO_API_BASE__", api_base)
      line = replace_literal(line, "__YOMIKO_API_TOKEN__", ENVIRON["YOMIKO_USERSCRIPT_API_TOKEN"])
      print line
    }
  ' "${WEB_DIR}/yomiko.user.js"
