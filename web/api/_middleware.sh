#!/usr/bin/env bash

API_CORS_ENABLED=0

# suppress yomiko cli output
apply_middleware_cli_in_api_mode() {
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

# Decode one CGI query component. Reject malformed percent escapes and
# control bytes before the caller captures the output in a shell variable.
# Building the result a byte at a time also keeps literal backslashes literal.
api_query_decode_component() {
  local input="$1"
  local output=""
  local character hex decoded_byte
  local index
  local LC_ALL=C

  for ((index = 0; index < ${#input}; index++)); do
    character="${input:index:1}"
    case "${character}" in
    '+')
      output+=" "
      ;;
    '%')
      if ((index + 2 >= ${#input})); then
        return 1
      fi
      hex="${input:index+1:2}"
      if [[ ! "${hex}" =~ ^[[:xdigit:]]{2}$ ]]; then
        return 1
      fi
      decoded_byte=$((16#${hex}))
      if ((decoded_byte == 0 || decoded_byte < 32 || decoded_byte == 127)); then
        return 1
      fi
      printf -v character '%b' "\\x${hex}"
      output+="${character}"
      index=$((index + 2))
      ;;
    *)
      case "${character}" in
      [[:cntrl:]]) return 1 ;;
      esac
      output+="${character}"
      ;;
    esac
  done

  printf '%s' "${output}"
}

# Parse the query once. Keys and values are decoded before route allowlists or
# scalar lookup. A field without '=' has an empty value; empty separators are
# ignored. Route helpers decide whether repeated keys represent arrays.
api_query_parse() {
  API_QUERY_KEYS=()
  API_QUERY_VALUES=()

  local remaining="${QUERY_STRING:-}"
  local pair key raw_value decoded_key decoded_value is_last

  while :; do
    if [[ "${remaining}" == *'&'* ]]; then
      pair="${remaining%%&*}"
      remaining="${remaining#*&}"
      is_last=0
    else
      pair="${remaining}"
      is_last=1
    fi

    if [[ -n "${pair}" ]]; then
      if [[ "${pair}" == *=* ]]; then
        key="${pair%%=*}"
        raw_value="${pair#*=}"
      else
        key="${pair}"
        raw_value=""
      fi

      if ! decoded_key="$(api_query_decode_component "${key}")" ||
        ! decoded_value="$(api_query_decode_component "${raw_value}")"; then
        return 1
      fi
      API_QUERY_KEYS+=("${decoded_key}")
      API_QUERY_VALUES+=("${decoded_value}")
    fi

    ((is_last)) && break
  done
}

# Return 0 for one matching scalar, 1 when absent, and 2 when repeated.
# Matching happens after decoding, so differently encoded spellings collide.
api_query_get_scalar() {
  local name="$1"
  local index

  API_QUERY_VALUE=""
  API_QUERY_COUNT=0
  for ((index = 0; index < ${#API_QUERY_KEYS[@]}; index++)); do
    if [[ "${API_QUERY_KEYS[index]}" == "${name}" ]]; then
      API_QUERY_COUNT=$((API_QUERY_COUNT + 1))
      # shellcheck disable=SC2034 # Callers read this shared output variable.
      API_QUERY_VALUE="${API_QUERY_VALUES[index]}"
    fi
  done

  if ((API_QUERY_COUNT > 1)); then
    return 2
  fi
  ((API_QUERY_COUNT == 1))
}

api_query_has_parameter() {
  local name="$1"
  local key

  for key in "${API_QUERY_KEYS[@]}"; do
    [[ "${key}" == "${name}" ]] && return 0
  done
  return 1
}

api_json_error_body() {
  local error="$1"
  local detail="${2:-}"

  jq -n \
    --arg error "${error}" \
    --arg detail "${detail}" \
    '{success: false, error: $error} + (if $detail == "" then {} else {detail: $detail} end)'
}

api_json_error_response() {
  local status="$1"
  local error="$2"
  local detail="${3:-}"

  api_status_headers "${status}"
  echo "Content-Type: application/json"
  echo ""
  api_json_error_body "${error}" "${detail}"
}

api_mutation_auth_error() {
  local status="$1"
  local error="$2"

  api_status_headers "${status}"
  if [[ "${status}" == "401 Unauthorized" ]]; then
    echo "WWW-Authenticate: Bearer"
  fi
  echo "Content-Type: application/json"
  echo ""
  api_json_error_body "${error}"
}

# Metrics use a separate file-backed secret so read-only scraping cannot reuse
# the browser mutation token. Keep this helper independent from CORS and the
# JSON mutation response shape.
api_metrics_auth_error() {
  local status="$1"
  local message="$2"

  api_status_headers "${status}"
  if [[ "${status}" == "401 Unauthorized" ]]; then
    echo "WWW-Authenticate: Bearer"
  fi
  if [[ "${status}" == "405 Method Not Allowed" ]]; then
    echo "Allow: GET"
  fi
  echo "Content-Type: text/plain; charset=utf-8"
  echo "Cache-Control: no-store"
  echo ""
  printf '%s\n' "${message}"
}

api_require_metrics_auth() {
  local token_file="${YOMIKO_METRICS_TOKEN_FILE:-}"
  local configured_token=""

  if [[ -z "${token_file}" || ! -f "${token_file}" || ! -r "${token_file}" ]]; then
    api_metrics_auth_error "503 Service Unavailable" "Metrics authentication is not configured"
    return 1
  fi
  if ! configured_token="$(<"${token_file}")" || [[ -z "${configured_token}" ]] ||
    [[ "${configured_token}" == *$'\n'* || "${configured_token}" == *$'\r'* ]]; then
    api_metrics_auth_error "503 Service Unavailable" "Metrics authentication is not configured"
    return 1
  fi

  if [[ "${HTTP_AUTHORIZATION:-}" != "Bearer ${configured_token}" ]]; then
    api_metrics_auth_error "401 Unauthorized" "Authentication required"
    return 1
  fi
}

# Mutation endpoints are disabled until an operator configures a token. This
# keeps an accidentally exposed or incompletely configured service fail-closed.
api_require_mutation_auth() {
  local configured_token="${YOMIKO_API_TOKEN:-}"
  local authorization="${HTTP_AUTHORIZATION:-}"

  if [[ -z "${configured_token}" ]]; then
    api_mutation_auth_error "503 Service Unavailable" "Mutation API is not configured"
    return 1
  fi

  if [[ "${authorization}" != "Bearer ${configured_token}" ]]; then
    api_mutation_auth_error "401 Unauthorized" "Authentication required"
    return 1
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

api_security_headers() {
  echo "Content-Security-Policy: default-src 'none'; base-uri 'none'; frame-ancestors 'none'"
  echo 'X-Content-Type-Options: nosniff'
  echo 'Referrer-Policy: no-referrer'
}

api_status_headers() {
  local status="$1"

  # BusyBox reads the CGI status only when it is the first response header.
  echo "Status: ${status}"
  api_security_headers
  if [[ "${API_CORS_ENABLED:-0}" == "1" ]]; then
    api_cors_headers
  fi
}

api_origin_matches_host() {
  local origin="$1"
  local host="${HTTP_HOST:-}"
  local origin_host="${origin#http://}"
  origin_host="${origin_host#https://}"

  [[ -n "${host}" && "${origin_host}" == "${host}" ]]
}

# Validate CORS before route work and enable headers for its response.
apply_middleware_cors() {
  case "${HTTP_ORIGIN:-}" in
  "" | "https://exhentai.org" | "https://e-hentai.org") ;;
  *)
    if ! api_origin_matches_host "${HTTP_ORIGIN:-}"; then
      api_status_headers "403 Forbidden"
      echo "Vary: Origin"
      echo ""
      exit 0
    fi
    ;;
  esac

  if [[ "${REQUEST_METHOD:-GET}" == "OPTIONS" ]]; then
    API_CORS_ENABLED=1
    api_status_headers "204 No Content"
    echo ""
    exit 0
  fi

  API_CORS_ENABLED=1
}
