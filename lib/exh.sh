#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

cookie_str_to_cookie_jar() {
  COOKIE_STRING="$1"
  DOMAIN=".exhentai.org"
  EXPIRY="2147483647" # Ends in year 2038 (Unix limit)

  echo "# Netscape HTTP Cookie File"
  echo "${COOKIE_STRING}" | awk -v domain="${DOMAIN}" -v expiry="${EXPIRY}" -F'; *' '{
      for (i=1; i<=NF; i++) {
          split($i, kv, "=")
          if (kv[1] != "") {
              # Format: domain, flag, path, secure, expiration, name, value
              printf "%s\tTRUE\t/\tFALSE\t%s\t%s\t%s\n", domain, expiry, kv[1], kv[2]
          }
      }
  }' > "${EXH_COOKIE_PATH}"
}

exh_refresh_cookies() {
  cookie_str_to_cookie_jar "$1"

  local status_code
  status_code="$(
    curl -fsS -I 'https://exhentai.org/uconfig.php' \
      -b "${EXH_COOKIE_PATH}" \
      -c "${EXH_COOKIE_PATH}" \
      -o /dev/null \
      -w '%{http_code}'
    )"

  echo "${status_code}"

  [[ "${status_code}" -eq 200 ]]
}
