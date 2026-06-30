#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/health'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${API_DIR}/middleware/cors.sh"
api_cors_middleware

echo "Status: 200 OK"
echo ""
exit 0
