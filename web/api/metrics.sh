#!/usr/bin/env bash

# This endpoint is intentionally independent of the browser mutation API. It
# has no CORS handling and never accepts a token through the query string.
API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  api_metrics_auth_error "405 Method Not Allowed" "Metrics endpoint only supports GET"
  exit 0
fi

api_require_metrics_auth || exit 0
middleware_cli_in_api_mode

yomiko_bin="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
stderr_file="$(mktemp "${TMPDIR:-/tmp}/yomiko-metrics.XXXXXX")"
metrics_output=""
metrics_status=0
metrics_output="$("${yomiko_bin}" metrics 2>"${stderr_file}")" || metrics_status=$?
if [[ "${metrics_status}" -ne 0 || -z "${metrics_output}" ]]; then
  api_log_command_failure "yomiko metrics" "$(<"${stderr_file}")"
  rm -f -- "${stderr_file}"
  api_metrics_auth_error "500 Internal Server Error" "Metrics collection failed"
  exit 0
fi
rm -f -- "${stderr_file}"

echo "Status: 200 OK"
echo "Content-Type: text/plain; version=0.0.4; charset=utf-8"
echo "Cache-Control: no-store"
echo ""
printf '%s\n' "${metrics_output}"
