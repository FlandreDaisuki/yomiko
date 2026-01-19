#!/usr/bin/env bash

# Collect Headers (CGI prefixes headers with HTTP_)
HEADERS_JSON=$(env | grep '^HTTP_' | jq -R -n '
  [ inputs | split("=") | {(.[0]): (.[1:] | join("="))} ] | add
')

# Collect ALL Environment Variables
# Note: split("=") | .[1:] | join("=") handles values that contain "="
ALL_ENV_JSON=$(env | jq -R -n '
  [ inputs | split("=") | {(.[0]): (.[1:] | join("="))} ] | add
')

# Collect Query Parameters and URL info
URL_INFO=$(jq -n \
  --arg method "${REQUEST_METHOD}" \
  --arg uri "${REQUEST_URI}" \
  --arg query "${QUERY_STRING}" \
  '{method: $method, uri: $uri, query_params: $query}')

# Read Request Body (Payload)
PAYLOAD=""
if [ "${CONTENT_LENGTH:-0}" -gt 0 ]; then
  PAYLOAD=$(head -c "${CONTENT_LENGTH}")
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
jq -n \
  --argjson headers "${HEADERS_JSON}" \
  --argjson info "${URL_INFO}" \
  --argjson env "${ALL_ENV_JSON}" \
  --arg payload "${PAYLOAD}" \
  '{
    request_info: $info,
    headers: $headers,
    env: $env,
    body: (try ($payload | fromjson) catch $payload)
  }'
