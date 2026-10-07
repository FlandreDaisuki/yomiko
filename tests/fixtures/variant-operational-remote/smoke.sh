#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"

MOCK_MODE=success
MOCK_TRACE=''
MOCK_CURL_TRACE="$(mktemp)"
MOCK_MUTATION_TRACE="${MOCK_CURL_TRACE}.mutation"
MOCK_STDERR_PATH="${MOCK_CURL_TRACE}.stderr"
SLOW_SERVER_PID=''
trap '[[ -z "${SLOW_SERVER_PID}" ]] || kill "${SLOW_SERVER_PID}" 2>/dev/null || true; rm -f -- "${MOCK_CURL_TRACE}" "${MOCK_MUTATION_TRACE}" "${MOCK_STDERR_PATH}"' EXIT

assert_eq() {
  [[ "$1" == "$2" ]] || {
    printf 'expected %s, got %s\n' "$1" "$2" >&2
    return 1
  }
}

assert_contains() {
  [[ "$2" == *"$1"* ]] || {
    printf 'expected text to contain %s\n' "$1" >&2
    return 1
  }
}

assert_not_contains() {
  [[ "$2" != *"$1"* ]] || {
    printf 'expected text not to contain %s\n' "$1" >&2
    return 1
  }
}

# The fixture replaces curl in-process. It returns the same final-status
# trailer consumed by exh_action_http_response and never touches a cookie jar.
curl() {
  local joined="$*" write_marker='' body='' status=200
  local previous=''
  for argument in "$@"; do
    if [[ "${previous}" == -w ]]; then
      write_marker="${argument}"
    fi
    previous="${argument}"
  done
  MOCK_TRACE+="${joined}"$'\n'
  printf '%s\n' "${joined}" >>"${MOCK_CURL_TRACE}"
  [[ "${joined}" == *'--connect-timeout 10 --max-time 10'* ]] || return 97

  case "${joined}" in
  *'https://exhentai.org/mytags'*)
    if [[ "${MOCK_MODE}" == credential-timeout ]]; then
      return 28
    fi
    if [[ "${MOCK_MODE}" == credentials-login ]]; then
      body='<form action="login.php"><input name="UserName"></form>'
    else
      body='var apiuid = 123; var apikey = "abcdef";'
    fi
    ;;
  *'https://s.exhentai.org/api.php'*)
    case "${MOCK_MODE}" in
    post-timeout-after-mutation)
      printf 'rating POST may have reached provider\n' >>"${MOCK_MUTATION_TRACE}"
      return 28
      ;;
    rate-error) body='{"error":"Could not rate gallery."}' ;;
    rate-invalid-json) body='<html>not json</html>' ;;
    rate-mismatched) body='{"rating_avg":4.5,"rating_cnt":10,"rating_usr":4.5}' ;;
    rate-half-star) body='{"rating_avg":4.5,"rating_cnt":10,"rating_usr":0.5}' ;;
    *) body='{"rating_avg":4.5,"rating_cnt":10,"rating_usr":5}' ;;
    esac
    ;;
  *'gallerypopups.php'*)
    case "${MOCK_MODE}" in
    favorite-login) body='<form action="login.php"><input name="UserName"></form>' ;;
    *)
      if [[ "${joined}" == *'favcat=favdel'* ]]; then
        body='<html><p>favdel updated</p></html>'
      else
        body='<html><p>favorite updated</p></html>'
      fi
      ;;
    esac
    ;;
  *'archiver.php'*)
    case "${MOCK_MODE}" in
    hath-login) body='<form action="login.php"><input name="Password"></form>' ;;
    hath-rate-limit) status=429; body='rate limited' ;;
    *) body='<html><p>request accepted</p></html>' ;;
    esac
    ;;
  *) status=500; body='unexpected fixture request' ;;
  esac

  if [[ -n "${write_marker}" ]]; then
    write_marker="${write_marker//%\{http_code\}/${status}}"
    printf '%s%s' "${body}" "${write_marker}"
  else
    printf '%s' "${body}"
  fi
}

assert_outcome() {
  local expected_outcome="$1" expected_status="$2" output status=0
  shift 2
  output="$("$@")" || status=$?
  jq -e --arg expected "${expected_outcome}" \
    '.outcome == $expected and (.gid == 123 or .gid == null) and
     (.mutation_sent | type == "boolean") and
     (.message | type == "string") and (.remote_error | type == "string" or .remote_error == null)' \
    <<<"${output}" >/dev/null
  [[ "${status}" -eq "${expected_status}" ]] || {
    printf 'expected exit %s, got %s: %s\n' "${expected_status}" "${status}" "${output}" >&2
    return 1
  }
  printf '%s\n' "${output}"
}

# A credentials timeout happens before the mutation POST. It stays transient
# and the diagnostic includes only a fixed operation, error category, and curl
# exit code.
: >"${MOCK_CURL_TRACE}"
MOCK_MODE=credential-timeout
status=0
output="$(exh_action_rate 123 hidden-token 10 2>"${MOCK_STDERR_PATH}")" || status=$?
assert_eq 70 "${status}"
jq -e '.outcome == "transient" and .mutation_sent == false' <<<"${output}" >/dev/null
assert_eq 1 "$(wc -l <"${MOCK_CURL_TRACE}")"
assert_contains 'Provider curl timeout (operation=action_credentials, curl_exit=28).' "$(<"${MOCK_STDERR_PATH}")"
assert_not_contains 'hidden-token' "$(<"${MOCK_STDERR_PATH}")"

# API mode keeps diagnostics off stderr while preserving the structured result.
YOMIKO_CLI_IN_API_MODE=1
export YOMIKO_CLI_IN_API_MODE
status=0
output="$(exh_action_rate 123 hidden-token 10 2>"${MOCK_STDERR_PATH}")" || status=$?
assert_eq 70 "${status}"
jq -e '.outcome == "transient" and .mutation_sent == false' <<<"${output}" >/dev/null
assert_eq '' "$(<"${MOCK_STDERR_PATH}")"
unset YOMIKO_CLI_IN_API_MODE

# A POST timeout after a possible provider commit stays uncertain, counts as a
# sent mutation, and does not cause curl to retry the side effect.
: >"${MOCK_CURL_TRACE}"
: >"${MOCK_MUTATION_TRACE}"
MOCK_MODE=post-timeout-after-mutation
status=0
output="$(exh_action_rate 123 hidden-token 10 2>"${MOCK_STDERR_PATH}")" || status=$?
assert_eq "${EXH_ACTION_UNCERTAIN_STATUS}" "${status}"
jq -e '.outcome == "uncertain" and .mutation_sent == true' <<<"${output}" >/dev/null
assert_eq 1 "$(awk '/https:\/\/s\.exhentai\.org\/api\.php/ { count++ } END { print count+0 }' "${MOCK_CURL_TRACE}")"
assert_eq 1 "$(wc -l <"${MOCK_MUTATION_TRACE}")"
assert_contains 'Provider curl timeout (operation=rating, curl_exit=28).' "$(<"${MOCK_STDERR_PATH}")"
assert_not_contains 'hidden-token' "$(<"${MOCK_STDERR_PATH}")"

MOCK_MODE=success
output=$(assert_outcome succeeded 0 exh_action_rate 123 hidden-token 10)
jq -e '.operation == "rating" and .desired_value == "10" and .http_status == 200 and .mutation_sent == true and
  (. | tostring | contains("hidden-token") | not)' <<<"${output}" >/dev/null

MOCK_MODE=rate-half-star
assert_outcome succeeded 0 exh_action_rate 123 hidden-token 1 >/dev/null
MOCK_MODE=rate-mismatched
assert_outcome uncertain "${EXH_ACTION_UNCERTAIN_STATUS}" exh_action_rate 123 hidden-token 10 >/dev/null

MOCK_MODE='credentials-login'
output=$(assert_outcome configuration "${EXH_ACTION_CONFIGURATION_STATUS}" exh_action_rate 123 hidden-token 10)
jq -e '.mutation_sent == false' <<<"${output}" >/dev/null

MOCK_MODE=rate-error
assert_outcome permanent "${EXH_ACTION_PERMANENT_STATUS}" exh_action_rate 123 hidden-token 10 >/dev/null
MOCK_MODE=rate-invalid-json
assert_outcome uncertain "${EXH_ACTION_UNCERTAIN_STATUS}" exh_action_rate 123 hidden-token 10 >/dev/null

assert_outcome succeeded 0 exh_action_favorite 123 hidden-token 4 >/dev/null
assert_outcome succeeded 0 exh_action_favorite 123 hidden-token favdel >/dev/null

MOCK_MODE=favorite-login
assert_outcome configuration "${EXH_ACTION_CONFIGURATION_STATUS}" exh_action_favorite 123 hidden-token 4 >/dev/null

MOCK_MODE=success
assert_outcome succeeded 0 exh_action_hath 123 hidden-token >/dev/null
MOCK_MODE=hath-login
assert_outcome configuration "${EXH_ACTION_CONFIGURATION_STATUS}" exh_action_hath 123 hidden-token >/dev/null
MOCK_MODE=hath-rate-limit
assert_outcome transient "${EXH_ACTION_TRANSIENT_STATUS}" exh_action_hath 123 hidden-token >/dev/null

# Use a loopback server that stalls before headers and during a body. Real curl
# must stop at the supplied total timeout, return 28, and keep its raw URL and
# response text out of the diagnostic.
command -v nc >/dev/null
unset -f curl
slow_port=$((30000 + $$ % 19000))
for slow_mode in slow_headers slow_body; do
  if [[ "${slow_mode}" == slow_headers ]]; then
    { sleep 2; printf 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nslow'; } |
      nc -l -p "${slow_port}" >/dev/null 2>&1 &
  else
    { printf 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ns'; sleep 2; printf 'low'; } |
      nc -l -p "${slow_port}" >/dev/null 2>&1 &
  fi
  SLOW_SERVER_PID=$!
  sleep 0.1
  status=0
  exh_provider_curl "${slow_mode}" 1 -sS "http://127.0.0.1:${slow_port}/private-query" \
    2>"${MOCK_STDERR_PATH}" >/dev/null || status=$?
  wait "${SLOW_SERVER_PID}" || true
  SLOW_SERVER_PID=''
  assert_eq 28 "${status}"
  assert_contains "Provider curl timeout (operation=${slow_mode}, curl_exit=28)." \
    "$(<"${MOCK_STDERR_PATH}")"
  assert_not_contains 'private-query' "$(<"${MOCK_STDERR_PATH}")"
  slow_port=$((slow_port + 1))
done

printf 'variant operational remote smoke: ok\n'
