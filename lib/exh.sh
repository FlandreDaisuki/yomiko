#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/common.sh" ]] && source "${HOME}/lib/common.sh"

# usage: cookie_str_to_cookie_jar <cookie-string>
cookie_str_to_cookie_jar() {
  local cookie_string="$1"
  local domain='.exhentai.org'
  local expiry='2147483647' # Ends in year 2038 (Unix limit)

  echo "# Netscape HTTP Cookie File"
  echo "${cookie_string}" | awk -v domain="${domain}" -v expiry="${expiry}" -F'; *' '{
      for (i=1; i<=NF; i++) {
          split($i, kv, "=")
          if (kv[1] != "") {
              # Format: domain, flag, path, secure, expiration, name, value
              printf "%s\tTRUE\t/\tFALSE\t%s\t%s\t%s\n", domain, expiry, kv[1], kv[2]
          }
      }
  }' >"${EXH_COOKIE_PATH}"
}

# usage: exh_refresh_cookies
exh_refresh_cookies() {
  cookie_str_to_cookie_jar "$1"

  local status_code
  status_code="$(
    curl -fsSL -I 'https://exhentai.org/uconfig.php' \
      -b "${EXH_COOKIE_PATH}" \
      -c "${EXH_COOKIE_PATH}" \
      -o /dev/null \
      -w '%{http_code}'
  )"

  echo "${status_code}"

  [[ "${status_code}" -eq 200 ]]
}

# usage: exh_whoami
# output: { authenticated, apiuid }
exh_whoami() {
  local creds apiuid

  if ! creds=$(exh_get_api_credentials); then
    jq -nc '{authenticated: false}'
    return 1
  fi

  apiuid=$(jq -r '.apiuid' <<<"${creds}")

  jq -nc \
    --argjson APIUID "${apiuid}" \
    '{authenticated: true, apiuid: $APIUID}'
}

# usage: exh_parse_path_meta <gallery_dir>
# output: { fs_compatible_title, gid }
# example:
#   exh_parse_path_meta '[xyz] foobar [123456]'
#     => { "fs_compatible_title": "[xyz] foobar", "gid": 123456 }
#   exh_parse_path_meta '[xyz] foobar [123456-1280x]'
#     => { "fs_compatible_title": "[xyz] foobar", "gid": 123456 }
exh_parse_path_meta() {
  local target_dir
  target_dir="$(basename "$1")"

  # Regex breakdown:
  # ^(.*)         : Group 1 - The title (everything from the start)
  # [[:space:]]\[ : A space followed by a literal [
  # ([0-9]+)      : Group 2 - The GID (one or more digits)
  # (?:-[^]]+)?   : Non-capturing group for optional resolution (e.g., -1280x)
  # \]            : The closing literal ]

  if [[ "$target_dir" =~ ^(.*)\ \[([0-9]+)(-.*)?\]$ ]]; then
    local title="${BASH_REMATCH[1]}"
    local gid="${BASH_REMATCH[2]}"

    jq -nc \
      --argjson GID "$gid" \
      --arg TITLE "$title" \
      '{gid: $GID, fs_compatible_title: $TITLE}'
  else
    log_err "Error: Could not parse '$target_dir'" >&2
    return 1
  fi
}

# usage: exh_get_token_by_gid <gid>
exh_get_token_by_gid() {
  local gid="$1"
  local html matched
  local base_params="f_sft=on&f_sfu=on&f_sfl=on&next=$((gid + 1))"

  # 1st Attempt: Standard search
  # NOTE: Store HTML in a variable to prevent "Failed writing body" pipe errors
  html=$(curl -sL "https://exhentai.org/?${base_params}" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}")

  matched=$(echo "$html" | rg -m 1 -o "${gid}/[a-z0-9]+" | head -n 1)

  if [[ -n "$matched" ]]; then
    echo "${matched#*/}"
    return 0
  fi

  # 2nd Attempt: Search expunged galleries
  html=$(curl -sL "https://exhentai.org/?${base_params}&f_sh=on" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}")

  matched=$(echo "$html" | rg -m 1 -o "${gid}/[a-z0-9]+" | head -n 1)

  if [[ -n "$matched" ]]; then
    echo "${matched#*/}"
    return 0
  fi

  log_err "Could not retrieve token for GID: ${gid}"
  return 1
}

# usage: exh_get_api_credentials
# output: { apiuid, apikey }
# description: Fetches the apiuid and apikey from the /mytags page.
exh_get_api_credentials() {
  local html apiuid apikey

  html=$(curl -sL "https://exhentai.org/mytags" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}")

  apiuid=$(echo "${html}" | rg -o 'var apiuid = ([0-9]+);' -r '$1')
  apikey=$(echo "${html}" | rg -o 'var apikey = "([a-f0-9]+)";' -r '$1')

  if [[ -z "${apiuid}" || -z "${apikey}" ]]; then
    log_err "Failed to extract apiuid or apikey from /mytags"
    return 1
  fi

  jq -nc \
    --argjson APIUID "${apiuid}" \
    --arg APIKEY "${apikey}" \
    '{apiuid: $APIUID, apikey: $APIKEY}'
}

# doc: https://ehwiki.org/wiki/API
# usage: exh_api_get_gallery_data <gid> <token>
exh_api_get_gallery_data() {
  local gid="$1"
  local token="$2"
  local payload
  payload=$(
    jq -nc \
      --argjson GID "${gid}" \
      --arg TOKEN "${token}" \
      '{
        method: "gdata",
        gidlist:[[$GID, $TOKEN]],
        namespace: 1
      }'
  )

  local resp
  resp="$(
    curl -fsSL -X POST 'https://api.e-hentai.org/api.php' \
      -H 'Content-Type: application/json' \
      --data "${payload}"
  )"

  if [[ -z "${resp}" ]]; then
    log_err "No response from API for GID: ${gid}"
    return 1
  fi

  local resp_error
  resp_error=$(jq -r '.error // empty' <<<"${resp}")

  if [[ -n "${resp_error}" ]]; then
    log_err "API Error: ${resp_error}"
    return 2
  fi

  jq -c '.gmetadata[0]' <<<"${resp}"
}

# usage: exh_request_hath_download <gid> <token>
exh_request_hath_download() {
  local gid="$1"
  local token="$2"

  local resp_code
  resp_code=$(curl -sL -w "%{http_code}" -X POST "https://exhentai.org/archiver.php?gid=${gid}&token=${token}" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}" \
    -d "hathdl_xres=org" -o /dev/null)

  if [[ "${resp_code}" -ne 200 ]]; then
    log_err "Download request failed with HTTP ${resp_code}."
    return 1
  fi

  return 0
}

# usage: exh_add_favorite <gid> <token> <favcat>
# param favcat: 0~9
exh_add_favorite() {
  local gid="$1"
  local token="$2"
  local favcat="$3"

  local resp_code
  resp_code=$(curl -sL -w "%{http_code}" -X POST "https://exhentai.org/gallerypopups.php?gid=${gid}&t=${token}&act=addfav" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}" \
    -d "favcat=${favcat}&favnote=&apply=Add+to+Favorites&update=1" -o /dev/null)

  if [[ "${resp_code}" -ne 200 ]]; then
    log_err "Add favorite request failed with HTTP ${resp_code}."
    return 1
  fi

  return 0
}

# usage: exh_rate <gid> <token> <rating>
# param rating: 1~10
exh_rate() {
  local gid="$1"
  local token="$2"
  local rating="$3"

  local creds apiuid apikey
  if ! creds=$(exh_get_api_credentials); then
    return 1
  fi

  apiuid=$(jq -r '.apiuid' <<<"${creds}")
  apikey=$(jq -r '.apikey' <<<"${creds}")

  local payload
  payload=$(jq -nc \
    --argjson APIUID "${apiuid}" \
    --arg APIKEY "${apikey}" \
    --argjson GID "${gid}" \
    --arg TOKEN "${token}" \
    --argjson RATING "${rating}" \
    '{
      method: "rategallery",
      apiuid: $APIUID,
      apikey: $APIKEY,
      gid: $GID,
      token: $TOKEN,
      rating: $RATING
    }')

  local resp_code
  resp_code=$(curl -sL -w "%{http_code}" -X POST 'https://s.exhentai.org/api.php' \
    -H 'Content-Type: application/json' \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}" \
    -d "${payload}" -o /dev/null)

  if [[ "${resp_code}" -ne 200 ]]; then
    log_err "Rate gallery request failed with HTTP ${resp_code}."
    return 2
  fi

  return 0
}
