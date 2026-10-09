#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/health'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
apply_middleware_cli_in_api_mode
apply_middleware_cors

api_status_headers "200 OK"
echo ""
exit 0
