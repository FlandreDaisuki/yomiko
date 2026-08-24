#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"

MOCK_MODE=success
MOCK_TRACE=''

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

  case "${joined}" in
  *'https://exhentai.org/mytags'*)
    if [[ "${MOCK_MODE}" == credentials-login ]]; then
      body='<form action="login.php"><input name="UserName"></form>'
    else
      body='var apiuid = 123; var apikey = "abcdef";'
    fi
    ;;
  *'https://s.exhentai.org/api.php'*)
    case "${MOCK_MODE}" in
    rate-error) body='{"error":"Could not rate gallery."}' ;;
    rate-invalid-json) body='<html>not json</html>' ;;
    *) body='{"rating_avg":4.5,"rating_cnt":10,"rating_usr":10}' ;;
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

output=$(assert_outcome succeeded 0 exh_action_rate 123 hidden-token 10)
jq -e '.operation == "rating" and .desired_value == "10" and .http_status == 200 and .mutation_sent == true and
  (. | tostring | contains("hidden-token") | not)' <<<"${output}" >/dev/null

MOCK_MODE='credentials-login'
output=$(assert_outcome configuration "${EXH_ACTION_CONFIGURATION_STATUS}" exh_action_rate 123 hidden-token 10)
jq -e '.mutation_sent == false' <<<"${output}" >/dev/null

MOCK_MODE=rate-error
assert_outcome permanent "${EXH_ACTION_PERMANENT_STATUS}" exh_action_rate 123 hidden-token 10 >/dev/null
MOCK_MODE=rate-invalid-json
assert_outcome uncertain "${EXH_ACTION_UNCERTAIN_STATUS}" exh_action_rate 123 hidden-token 10 >/dev/null

MOCK_MODE=success
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

printf 'variant operational remote smoke: ok\n'
