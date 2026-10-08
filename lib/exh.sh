#!/usr/bin/env bash

EXH_PROVIDER_CONNECT_TIMEOUT_SECONDS=10
EXH_PROVIDER_MAX_TIME_SECONDS=10
EXH_PROVIDER_COOKIE_VALIDATION_MAX_TIME_SECONDS=30
EXH_JQ_LIB_DIR="${BASH_SOURCE[0]%/*}/jq"

exh_provider_curl_error_category() {
  case "$1" in
  5) printf '%s\n' proxy_resolution ;;
  6) printf '%s\n' host_resolution ;;
  7) printf '%s\n' connection ;;
  18) printf '%s\n' partial_transfer ;;
  22) printf '%s\n' http_error ;;
  23) printf '%s\n' local_write ;;
  28) printf '%s\n' timeout ;;
  35 | 51 | 58 | 59 | 60 | 77) printf '%s\n' tls ;;
  47) printf '%s\n' redirect ;;
  52) printf '%s\n' empty_response ;;
  55) printf '%s\n' send ;;
  56) printf '%s\n' receive ;;
  127) printf '%s\n' curl_unavailable ;;
  *) printf '%s\n' curl_error ;;
  esac
}

# Run one bounded provider request. The operation name is fixed at each call
# site; never include a URL, query, cookie, credential, or response body in its
# diagnostic.
exh_provider_curl() {
  local operation="$1" max_time="$2" status=0 category
  shift 2
  [[ "${operation}" =~ ^[a-z_]+$ && "${max_time}" =~ ^[1-9][0-9]*$ ]] || return 2

  curl --connect-timeout "${EXH_PROVIDER_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${max_time}" "$@" 2>/dev/null || status=$?
  ((status == 0)) && return 0

  category="$(exh_provider_curl_error_category "${status}")"
  log_err "Provider curl ${category} (operation=${operation}, curl_exit=${status})."
  return "${status}"
}
set -euo pipefail

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/common.sh" ]] && source "${HOME}/lib/common.sh"

exh_remote_writes_enabled() {
  case "${YOMIKO_REMOTE_WRITES_ENABLED:-true}" in
  true | TRUE | 1 | yes | YES | on | ON) return 0 ;;
  *) return 1 ;;
  esac
}

# usage: cookie_str_to_cookie_jar <cookie-string>
cookie_str_to_cookie_jar() {
  local cookie_string="$1"
  local domain='.exhentai.org'
  local expiry='2147483647' # Ends in year 2038 (Unix limit)
  local cookie_entries cookie_jar_tmp

  if [[ "${cookie_string}" =~ [[:cntrl:]] ]]; then
    return 1
  fi

  if ! cookie_entries=$(
    printf '%s' "${cookie_string}" |
      awk -v domain="${domain}" -v expiry="${expiry}" '
        {
          if (NR != 1) {
            invalid = 1
            exit
          }
          remaining = $0
          while (1) {
            separator = index(remaining, ";")
            if (separator == 0) {
              entry = remaining
            } else {
              entry = substr(remaining, 1, separator - 1)
              remaining = substr(remaining, separator + 1)
            }
            sub(/^ +/, "", entry)
            equals = index(entry, "=")
            if (entry == "" || equals <= 1) {
              invalid = 1
              exit
            }
            name = substr(entry, 1, equals - 1)
            value = substr(entry, equals + 1)
            if (name ~ /[[:space:]]/) {
              invalid = 1
              exit
            }
            # Split at the first equals sign; the complete value is preserved.
            printf "%s\tTRUE\t/\tFALSE\t%s\t%s\t%s\n", domain, expiry, name, value
            count++
            if (separator == 0) {
              break
            }
          }
        }
        END {
          if (invalid || count == 0) {
            exit 1
          }
        }
      '
  ); then
    return 1
  fi

  if ! cookie_jar_tmp="$(mktemp "${EXH_COOKIE_PATH}.XXXXXX")"; then
    return 1
  fi
  if ! chmod 600 "${cookie_jar_tmp}"; then
    rm -f -- "${cookie_jar_tmp}"
    return 1
  fi
  if ! {
    printf '%s\n' '# Netscape HTTP Cookie File'
    printf '%s\n' "${cookie_entries}"
  } >"${cookie_jar_tmp}"; then
    rm -f -- "${cookie_jar_tmp}"
    return 1
  fi
  if ! chmod 600 "${cookie_jar_tmp}"; then
    rm -f -- "${cookie_jar_tmp}"
    return 1
  fi
  if ! mv -f -- "${cookie_jar_tmp}" "${EXH_COOKIE_PATH}"; then
    rm -f -- "${cookie_jar_tmp}"
    return 1
  fi

  printf '%s\n' '# Netscape HTTP Cookie File'
}

# Keep cookie jars private when curl rewrites an existing jar. Curl truncates
# and rewrites its cookie-jar output in place, preserving this mode.
exh_secure_cookie_jar() {
  if [[ -L "${EXH_COOKIE_PATH}" || (-e "${EXH_COOKIE_PATH}" && ! -f "${EXH_COOKIE_PATH}") ]]; then
    log_err "ExHentai cookie jar must be a regular file: ${EXH_COOKIE_PATH}"
    return 1
  fi
  if [[ ! -e "${EXH_COOKIE_PATH}" ]]; then
    (umask 077; : >"${EXH_COOKIE_PATH}") || return 1
  fi
  chmod 600 "${EXH_COOKIE_PATH}"
}

# usage: exh_refresh_cookies
exh_refresh_cookies() {
  if [[ -e "${EXH_COOKIE_PATH}" || -L "${EXH_COOKIE_PATH}" ]]; then
    exh_secure_cookie_jar || return 1
  fi
  cookie_str_to_cookie_jar "$1" >/dev/null || return 1
  exh_secure_cookie_jar || return 1

  local status_code
  status_code="$(
    exh_provider_curl cookie_validation "${EXH_PROVIDER_COOKIE_VALIDATION_MAX_TIME_SECONDS}" \
      -fsSL -I 'https://exhentai.org/uconfig.php' \
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

# Parse the basename fields without starting external commands. The caller
# supplies a GID output variable and may also supply a title output variable.
exh_parse_path_meta_fields() {
  [[ "$#" -eq 2 || "$#" -eq 3 ]] || return 2
  local gallery_path="$1" gid_var="$2" title_var="${3:-}"
  local target_dir parsed_title parsed_gid

  [[ "${gid_var}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
  if [[ "$#" -eq 3 ]]; then
    [[ "${title_var}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
  fi

  if [[ -z "${gallery_path}" ]]; then
    target_dir=''
  elif [[ "${gallery_path}" != *[^/]* ]]; then
    target_dir='/'
  else
    target_dir="${gallery_path}"
    while [[ "${target_dir}" == */ ]]; do
      target_dir="${target_dir%/}"
    done
    target_dir="${target_dir##*/}"
  fi

  # Match command substitution around basename: it removes trailing newlines
  # from the basename output. Keep this behavior for existing directory names.
  while [[ "${target_dir}" == *$'\n' ]]; do
    target_dir="${target_dir%$'\n'}"
  done

  # Regex breakdown:
  # ^(.*)         : Group 1 - The title (everything from the start)
  # [[:space:]]\[ : A space followed by a literal [
  # ([0-9]+)      : The GID (one or more digits)
  # (-.*)?        : An optional resolution suffix
  # \]            : The closing literal ]

  if [[ "$target_dir" =~ ^(.*)\ \[([0-9]+)(-.*)?\]$ ]]; then
    parsed_gid="${BASH_REMATCH[2]}"
    if [[ -n "${title_var}" ]]; then
      parsed_title="${BASH_REMATCH[1]}"
      printf -v "${title_var}" '%s' "${parsed_title}"
    fi
    printf -v "${gid_var}" '%s' "${parsed_gid}"
  else
    log_err "Error: Could not parse '${target_dir}'" >&2
    return 1
  fi
}

# usage: exh_parse_path_meta <gallery_dir>
# output: { fs_compatible_title, gid }
# example:
#   exh_parse_path_meta '[xyz] foobar [123456]'
#     => { "fs_compatible_title": "[xyz] foobar", "gid": 123456 }
#   exh_parse_path_meta '[xyz] foobar [123456-1280x]'
#     => { "fs_compatible_title": "[xyz] foobar", "gid": 123456 }
exh_parse_path_meta() {
  local fs_compatible_title gid
  if ! exh_parse_path_meta_fields "$1" gid fs_compatible_title; then
    return 1
  fi

  jq -nc \
    --argjson GID "$gid" \
    --arg TITLE "$fs_compatible_title" \
    '{gid: $GID, fs_compatible_title: $TITLE}'
}

# usage: exh_get_token_by_gid <gid>
exh_get_token_by_gid() {
  local gid="$1"
  local html matched
  local base_params="f_sft=on&f_sfu=on&f_sfl=on&next=$((gid + 1))"

  exh_secure_cookie_jar

  # 1st Attempt: Standard search
  # NOTE: Store HTML in a variable to prevent "Failed writing body" pipe errors
  html=$(exh_provider_curl token_search "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL "https://exhentai.org/?${base_params}" \
    -b "${EXH_COOKIE_PATH}" \
    -c "${EXH_COOKIE_PATH}")

  matched=$(echo "$html" | rg -m 1 -o "${gid}/[a-z0-9]+" | head -n 1)

  if [[ -n "$matched" ]]; then
    echo "${matched#*/}"
    return 0
  fi

  # 2nd Attempt: Search expunged galleries
  html=$(exh_provider_curl token_search "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL "https://exhentai.org/?${base_params}&f_sh=on" \
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

  exh_secure_cookie_jar

  html=$(exh_provider_curl api_credentials "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL 'https://exhentai.org/mytags' \
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
# usage: exh_normalize_gallery_metadata <expected_gid> <metadata-json>
# output: normalized metadata for the galleries table
#
# Required remote fields:
#   gid: unsigned integer matching expected_gid
#   token: non-empty string
#   title: non-empty string
#   filecount: unsigned integer (JSON number or decimal integer string)
#   expunged: boolean
#   tags: array of strings
#   rating: number from 0 through 5 (JSON number or decimal string)
#   category: exactly the string Manga (validated as an ingestion invariant)
#   uploader: non-empty string
#   posted: unsigned integer (JSON number or decimal integer string)
#   filesize: unsigned integer (JSON number or decimal integer string)
#   thumb: non-empty string
# Optional remote fields:
#   title_jpn: string or null; a missing value is normalized to null
#   first_gid, parent_gid, current_gid: unsigned integers or null
#   first_token, parent_token, current_token: non-empty strings or null
exh_normalize_gallery_metadata() {
  local expected_gid="$1"
  local metadata="$2"

  jq -ce -L "${EXH_JQ_LIB_DIR}" --arg expected_gid "${expected_gid}" \
    'include "exh_metadata"; normalize_gallery_metadata($expected_gid)' \
    <<<"${metadata}"
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
    exh_provider_curl gallery_metadata "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
      -fsSL -X POST 'https://api.e-hentai.org/api.php' \
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

  local api_meta
  if ! api_meta=$(jq -ce '
    if (.gmetadata | type) == "array" and (.gmetadata | length) == 1
    then .gmetadata[0]
    else error("gmetadata must contain exactly one gallery")
    end
  ' <<<"${resp}" 2>/dev/null); then
    log_err "Invalid gallery metadata response for GID: ${gid}"
    return 3
  fi

  if ! exh_normalize_gallery_metadata "${gid}" "${api_meta}" 2>/dev/null; then
    log_err "Invalid gallery metadata response for GID: ${gid}"
    return 3
  fi
}

# usage: exh_parse_search_response <html> <normal|expunged> [current-page]
# output: {mode,results:[{gid,token}],terminal,next_page}
#
# This parser deliberately has no network or persistence side effects.  The
# search adapter accepts only the two explicit modes and strips all other
# result-page details down to the stable GID/token identity.
exh_parse_search_response() {
  local html="$1"
  local mode="$2"
  local current_page="${3:-0}"
  [[ "${mode}" == normal || "${mode}" == expunged ]] || {
    log_err "invalid ExHentai search mode: ${mode}"
    return 2
  }

  local rows next
  rows=$(printf '%s' "${html}" | { rg -o 'href=[^>]+/g/[0-9]+/[A-Za-z0-9]+' || true; } \
    | sed -E 's#.*/g/([0-9]+)/([A-Za-z0-9]+).*#\1\t\2#' \
    | awk -F '\t' '!seen[$1 FS $2]++ { printf "{\"gid\":%s,\"token\":\"%s\"}\n", $1, $2 }' \
    | jq -sc '.')
  next=$(printf '%s' "${html}" | rg -o 'href=[^>]*(page|next)=[0-9]+[^>]*' \
    | sed -nE 's/.*(page|next)=([0-9]+).*/\2/p' | awk -v current="${current_page}" '$1 > current' | sort -n | head -n 1 || true)
  if [[ -n "${next}" ]]; then
    jq -nc --arg mode "${mode}" --argjson results "${rows:-[]}" --argjson page "${next}" \
      '{mode:$mode,results:$results,terminal:false,next_page:$page}'
  else
    jq -nc --arg mode "${mode}" --argjson results "${rows:-[]}" \
      '{mode:$mode,results:$results,terminal:true,next_page:null}'
  fi
}

# usage: exh_search_gallery <query> <normal|expunged> [page]
# output: same normalized object as exh_parse_search_response
exh_search_gallery() {
  local query="$1" mode="$2" page="${3:-0}" html
  [[ "${mode}" == normal || "${mode}" == expunged ]] || return 2
  [[ "${page}" =~ ^[0-9]+$ ]] || return 2
  exh_secure_cookie_jar
  local url='https://exhentai.org/'
  local -a mode_args=()
  [[ "${mode}" == expunged ]] && mode_args+=(--data-urlencode 'f_sh=on')
  html=$(exh_provider_curl variant_search "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -fsSL --get "${url}" -b "${EXH_COOKIE_PATH}" -c "${EXH_COOKIE_PATH}" \
    --data-urlencode "f_search=${query}" --data-urlencode 'f_sft=on' \
    --data-urlencode 'f_sfu=on' --data-urlencode 'f_sfl=on' \
    --data-urlencode 'f_cats=1019' \
    --data-urlencode "page=${page}" "${mode_args[@]}")
  exh_parse_search_response "${html}" "${mode}" "${page}"
}

# usage: exh_normalize_gallery_data_batch <requested-json> <response-json>
# output: {entries:[{gid,token,status,metadata?,error?}]}
exh_normalize_gallery_data_batch() {
  local requested="$1" response="$2"
  jq -e '
    . as $items
    | ($items | type == "array" and length <= 25)
    and all(.[];
      type == "array" and length == 2
      and (.[0] | type == "number" and . == floor and . >= 1 and . <= 2147483647)
      and (.[1] | type == "string" and length > 0)
    )
    and (($items | map(tojson) | unique | length) == ($items | length))
  ' <<<"${requested}" >/dev/null 2>&1 || {
    log_err 'invalid gdata batch: expected <=25 unique [positive gid, nonempty token] pairs'
    return 2
  }
  jq -e '.gmetadata? | type == "array"' <<<"${response}" >/dev/null 2>&1 || {
    log_err 'gdata response has no metadata array'
    return 3
  }
  jq -cn -L "${EXH_JQ_LIB_DIR}" --argjson requested "${requested}" \
    --argjson response "${response}" '
      include "exh_metadata";
      ($response.gmetadata
       | reduce .[] as $item ({ };
           if ($item | type) == "object" then
             ($item.gid | tostring) as $gid
             | .[$gid] = ((.[$gid] // []) + [$item])
           else . end)) as $items_by_gid
      | [$requested[] as $request
         | $request[0] as $gid
         | $request[1] as $token
         | ($items_by_gid[($gid | tostring)] // []) as $gid_items
         | (([$gid_items[] | select((.gtoken // "") == $token)] | .[0])
            // $gid_items[0]
            // null) as $item
         | if $item == null then
             {gid:$gid,token:$token,status:"error",error:"missing or invalid gdata entry"}
           else
             ($item.error // "") as $api_error
             | if ($api_error | tostring) != "" then
                 {gid:$gid,token:$token,status:"error",error:($api_error | tostring)}
               else
                 (try ($item + {token:($item.token // $item.gtoken)}
                       | normalize_gallery_metadata($gid)) catch null) as $metadata
                 | if $metadata == null then
                     {gid:$gid,token:$token,status:"error",error:"missing or invalid gdata entry"}
                   else
                     {gid:$metadata.gid,token:$token,status:"ok",metadata:$metadata}
                   end
               end
           end]
      | {entries:.}
    '
}

# usage: exh_api_get_gallery_data_batch <requested-json>
exh_api_get_gallery_data_batch() {
  local requested="$1" payload response
  jq -e '
    . as $items
    | ($items | type == "array" and length <= 25)
    and all(.[]; type == "array" and length == 2
      and (.[0] | type == "number" and . == floor and . >= 1 and . <= 2147483647)
      and (.[1] | type == "string" and length > 0))
    and (($items | map(tojson) | unique | length) == ($items | length))
  ' <<<"${requested}" >/dev/null || return 2
  payload=$(jq -nc --argjson gidlist "${requested}" '{method:"gdata",gidlist:$gidlist,namespace:1}')
  response=$(exh_provider_curl gallery_metadata_batch "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -fsSL -X POST 'https://api.e-hentai.org/api.php' \
    -H 'Content-Type: application/json' --data "${payload}")
  exh_normalize_gallery_data_batch "${requested}" "${response}"
}

# usage: exh_parse_gallery_popularity <html> [fetched-at]
# output: {favorite_count,rating_count,popularity_fetched_at,error?}
exh_parse_gallery_popularity() {
  local html="$1" fetched_at="${2:-}" fav rating errors=()
  fav=$(printf '%s' "${html}" | rg -o -m1 '(favcount|favorite_count|favorite-count|Favorites?:)[^>]*>?[[:space:]]*[0-9,]+' | rg -o '[0-9,]+' | tr -d ',' || true)
  rating=$(printf '%s' "${html}" | rg -o -m1 '(rating_count|rating-count|ratingcount|Ratings?:)[^>]*>?[[:space:]]*[0-9,]+' | rg -o '[0-9,]+' | tr -d ',' || true)
  [[ -n "${fav}" ]] || errors+=("favorite_count unavailable")
  [[ -n "${rating}" ]] || errors+=("rating_count unavailable")
  local error_json='null'
  ((${#errors[@]})) && error_json=$(printf '%s\n' "${errors[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | join("; ")')
  jq -nc --argjson fav "${fav:-null}" --argjson rating "${rating:-null}" \
    --arg fetched_at "${fetched_at}" --argjson error "${error_json}" \
    '{favorite_count:$fav,rating_count:$rating,popularity_fetched_at:(if $fetched_at == "" then null else $fetched_at end),error:$error}'
}

# usage: exh_get_gallery_popularity <gid> <token> [fetched-at]
exh_get_gallery_popularity() {
  local gid="$1" token="$2" fetched_at="${3:-}" html
  exh_secure_cookie_jar
  html=$(exh_provider_curl variant_popularity "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -fsSL "https://exhentai.org/g/${gid}/${token}/" \
    -b "${EXH_COOKIE_PATH}" -c "${EXH_COOKIE_PATH}")
  exh_parse_gallery_popularity "${html}" "${fetched_at}"
}

# usage: exh_request_hath_download <gid> <token>
exh_request_hath_download() {
  local gid="$1"
  local token="$2"

  if ! exh_remote_writes_enabled; then
    log_err "Remote writes are disabled in this environment."
    return 1
  fi

  exh_secure_cookie_jar

  local resp_code
  resp_code=$(exh_provider_curl hath_request "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL -w "%{http_code}" -X POST "https://exhentai.org/archiver.php?gid=${gid}&token=${token}" \
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

  if ! exh_remote_writes_enabled; then
    log_err "Remote writes are disabled in this environment."
    return 1
  fi

  exh_secure_cookie_jar

  local resp_code
  resp_code=$(exh_provider_curl favorite "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL -w "%{http_code}" -X POST "https://exhentai.org/gallerypopups.php?gid=${gid}&t=${token}&act=addfav" \
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

  if ! exh_remote_writes_enabled; then
    log_err "Remote writes are disabled in this environment."
    return 1
  fi

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

  exh_secure_cookie_jar

  local resp_code
  resp_code=$(exh_provider_curl rating "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sL -w "%{http_code}" -X POST 'https://s.exhentai.org/api.php' \
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

# Durable variant-action adapters intentionally live below the legacy CLI
# wrappers above. They perform one remote request and emit one small JSON
# outcome; they do not read SQLite, inspect archive paths, or write local
# state. The worker owns all persistence and retry decisions.
EXH_ACTION_SUCCESS_STATUS=0
EXH_ACTION_TRANSIENT_STATUS=70
EXH_ACTION_UNCERTAIN_STATUS=71
EXH_ACTION_PERMANENT_STATUS=72
EXH_ACTION_CONFIGURATION_STATUS=73

exh_action_result_status() {
  case "$1" in
  succeeded) return "${EXH_ACTION_SUCCESS_STATUS}" ;;
  transient) return "${EXH_ACTION_TRANSIENT_STATUS}" ;;
  uncertain) return "${EXH_ACTION_UNCERTAIN_STATUS}" ;;
  permanent) return "${EXH_ACTION_PERMANENT_STATUS}" ;;
  configuration) return "${EXH_ACTION_CONFIGURATION_STATUS}" ;;
  *) return 1 ;;
  esac
}

# usage: exh_action_emit_result <operation> <gid> <desired> <http-status|null>
#   <outcome> <message> [remote-error] [mutation-sent]
# stdout: one stable JSON result; no token, cookie, or response body is kept.
exh_action_emit_result() {
  local operation="$1"
  local gid="$2"
  local desired="$3"
  local http_status="$4"
  local outcome="$5"
  local message="$6"
  local remote_error="${7:-}"
  local mutation_sent="${8:-false}"
  local http_json='null'

  [[ "${mutation_sent}" == true || "${mutation_sent}" == false ]] || return 1

  if [[ "${http_status}" =~ ^[0-9]{3}$ ]]; then
    http_json="${http_status}"
  fi

  jq -nc \
    --arg operation "${operation}" \
    --arg gid "${gid}" \
    --arg desired "${desired}" \
    --arg outcome "${outcome}" \
    --arg message "${message}" \
    --arg remote_error "${remote_error}" \
    --argjson http_status "${http_json}" \
    --argjson mutation_sent "${mutation_sent}" \
    ' {
        operation: $operation,
        gid: (if ($gid | test("^[1-9][0-9]*$")) then ($gid | tonumber) else null end),
        desired_value: $desired,
        http_status: $http_status,
        mutation_sent: $mutation_sent,
        outcome: $outcome,
        message: $message,
        remote_error: (if $remote_error == "" then null else $remote_error end)
      }'
  exh_action_result_status "${outcome}"
}

# usage: exh_action_http_response <operation> <curl-arguments...>
# stdout: {http_status,body}; return nonzero when curl cannot provide a final
# HTTP response. Callers classify POST transport failures as uncertain.
exh_action_http_response() {
  local operation="$1"
  local marker=$'\n__YOMIKO_ACTION_HTTP_STATUS__'
  local output body http_status
  shift

  if ! output=$(exh_provider_curl "${operation}" "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sS -L "$@" -w "${marker}%{http_code}"); then
    return "${EXH_ACTION_TRANSIENT_STATUS}"
  fi
  [[ "${output}" == *"${marker}"* ]] || return "${EXH_ACTION_UNCERTAIN_STATUS}"
  http_status="${output##*"${marker}"}"
  body="${output%"${marker}"*}"
  [[ "${http_status}" =~ ^[0-9]{3}$ ]] || return "${EXH_ACTION_UNCERTAIN_STATUS}"
  jq -nc --arg body "${body}" --argjson http_status "${http_status}" \
    '{http_status:$http_status,body:$body}'
}

exh_action_http_outcome() {
  local http_status="$1"
  case "${http_status}" in
  401 | 403) printf '%s\n' configuration ;;
  408 | 425 | 429 | 500 | 501 | 502 | 503 | 504 | 505 | 506 | 507 | 508 | 509 | 510 | 511)
    printf '%s\n' transient
    ;;
  200) printf '%s\n' succeeded ;;
  *) printf '%s\n' permanent ;;
  esac
}

exh_action_error_outcome() {
  local message="${1,,}"
  if [[ "${message}" =~ (login|logged[[:space:]]+out|authentication|apiuid|apikey|invalid[[:space:]]+user) ]]; then
    printf '%s\n' configuration
  elif [[ "${message}" =~ (rate[[:space:]]*limit|too[[:space:]]+many|temporar|try[[:space:]]+again|busy|timeout) ]]; then
    printf '%s\n' transient
  else
    printf '%s\n' permanent
  fi
}

exh_action_get_api_credentials() {
  local html apiuid apikey
  local -a cookie_args=()
  if [[ -n "${EXH_COOKIE_PATH:-}" ]]; then
    exh_secure_cookie_jar || return "${EXH_ACTION_CONFIGURATION_STATUS}"
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi

  if ! html=$(exh_provider_curl action_credentials "${EXH_PROVIDER_MAX_TIME_SECONDS}" \
    -sS -L "${cookie_args[@]}" \
    'https://exhentai.org/mytags'); then
    return "${EXH_ACTION_TRANSIENT_STATUS}"
  fi
  apiuid=$(printf '%s' "${html}" | rg -o 'var apiuid = ([0-9]+);' -r '$1' | head -n 1 || true)
  apikey=$(printf '%s' "${html}" | rg -o 'var apikey = "([a-f0-9]+)";' -r '$1' | head -n 1 || true)
  if [[ -z "${apiuid}" || -z "${apikey}" ]]; then
    return "${EXH_ACTION_CONFIGURATION_STATUS}"
  fi
  jq -nc --argjson apiuid "${apiuid}" --arg apikey "${apikey}" \
    '{apiuid:$apiuid,apikey:$apikey}'
}

# usage: exh_action_rate <gid> <token> <rating 1~10>
# Rating responses are JSON. HTTP 200 is accepted only when the body is a
# valid object with no explicit error; when rating_usr is present it must agree
# with the requested value after converting the API's 0.5~5 star scale to the
# request's 1~10 half-star scale.
exh_action_rate() {
  local gid="$1" token="$2" rating="$3"
  local credentials credentials_status=0 response response_status=0
  local http_status body remote_error outcome parsed
  local -a cookie_args=()

  if ! exh_remote_writes_enabled; then
    exh_action_emit_result rating "${gid}" "${rating}" null configuration \
      'remote writes are disabled in this environment'
    return
  fi

  if [[ ! "${gid}" =~ ^[1-9][0-9]*$ || -z "${token}" || ! "${rating}" =~ ^([1-9]|10)$ ]]; then
    exh_action_emit_result rating "${gid}" "${rating}" null configuration \
      'invalid rating adapter input'
    return
  fi

  credentials=$(exh_action_get_api_credentials) || credentials_status=$?
  if ((credentials_status != 0)); then
    case "${credentials_status}" in
    "${EXH_ACTION_CONFIGURATION_STATUS}")
      exh_action_emit_result rating "${gid}" "${rating}" null configuration \
        'ExHentai API credentials unavailable'
      ;;
    *)
      exh_action_emit_result rating "${gid}" "${rating}" null transient \
        'credential request failed'
      ;;
    esac
    return
  fi

  local apiuid apikey payload
  apiuid=$(jq -r '.apiuid' <<<"${credentials}")
  apikey=$(jq -r '.apikey' <<<"${credentials}")
  payload=$(jq -nc \
    --argjson apiuid "${apiuid}" --arg apikey "${apikey}" \
    --argjson gid "${gid}" --arg token "${token}" --argjson rating "${rating}" \
    '{method:"rategallery",apiuid:$apiuid,apikey:$apikey,gid:$gid,token:$token,rating:$rating}')
  cookie_args=()
  if [[ -n "${EXH_COOKIE_PATH:-}" ]]; then
    exh_secure_cookie_jar || {
      exh_action_emit_result rating "${gid}" "${rating}" null configuration \
        'ExHentai cookie jar is unavailable'
      return
    }
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response rating "${cookie_args[@]}" -X POST \
    'https://s.exhentai.org/api.php' -H 'Content-Type: application/json' \
    --data "${payload}") || response_status=$?
  if ((response_status != 0)); then
    exh_action_emit_result rating "${gid}" "${rating}" null uncertain \
      'rating request outcome is unknown' '' true
    return
  fi

  http_status=$(jq -r '.http_status' <<<"${response}")
  body=$(jq -r '.body' <<<"${response}")
  outcome=$(exh_action_http_outcome "${http_status}")
  if [[ "${outcome}" != succeeded ]]; then
    if [[ "${outcome}" == permanent || "${outcome}" == configuration ]] &&
      remote_error=$(jq -r 'if type == "object" and (.error? // "") != "" then (.error|tostring) else empty end' <<<"${body}" 2>/dev/null); then
      [[ -n "${remote_error}" ]] || remote_error="HTTP ${http_status}"
    else
      remote_error="HTTP ${http_status}"
    fi
    exh_action_emit_result rating "${gid}" "${rating}" "${http_status}" \
      "${outcome}" 'rating request was not accepted' "${remote_error}" true
    return
  fi

  if ! parsed=$(jq -ce 'if type == "object" then . else error("response must be an object") end' <<<"${body}" 2>/dev/null); then
    exh_action_emit_result rating "${gid}" "${rating}" "${http_status}" uncertain \
      'rating response was not valid JSON' '' true
    return
  fi
  remote_error=$(jq -r 'if (.error? // "") == "" then empty else (.error|tostring) end' <<<"${parsed}")
  if [[ -n "${remote_error}" ]]; then
    outcome=$(exh_action_error_outcome "${remote_error}")
    exh_action_emit_result rating "${gid}" "${rating}" "${http_status}" \
      "${outcome}" 'ExHentai rejected the rating' "${remote_error}" true
    return
  fi
  if ! jq -e --argjson expected "${rating}" '
    (.rating_usr? // null) as $actual
    | ($actual == null or
       (($actual|type) == "number" and $actual == ($expected / 2)) or
       (($actual|type) == "string" and
        ($actual|test("^(0|[0-9]+(\\.[0-9]+)?)$") and tonumber == ($expected / 2))))
  ' <<<"${parsed}" >/dev/null; then
    exh_action_emit_result rating "${gid}" "${rating}" "${http_status}" uncertain \
      'rating response did not confirm the requested value' '' true
    return
  fi
  exh_action_emit_result rating "${gid}" "${rating}" "${http_status}" succeeded \
    'rating request accepted' '' true
}

# usage: exh_action_favorite <gid> <token> <0~9|favdel>
# The site historically treats a 200 non-login response as compatible with
# both category moves and favdel. We therefore validate authentication only and
# leave desired-state interpretation to the next worker reconciliation.
exh_action_favorite() {
  local gid="$1" token="$2" favcat="$3"
  local response response_status=0 http_status body outcome
  local -a cookie_args=()

  if ! exh_remote_writes_enabled; then
    exh_action_emit_result favorite "${gid}" "${favcat}" null configuration \
      'remote writes are disabled in this environment'
    return
  fi

  if [[ ! "${gid}" =~ ^[1-9][0-9]*$ || -z "${token}" ||
    ! "${favcat}" =~ ^([0-9]|favdel)$ ]]; then
    exh_action_emit_result favorite "${gid}" "${favcat}" null configuration \
      'invalid favorite adapter input'
    return
  fi
  if [[ -n "${EXH_COOKIE_PATH:-}" ]]; then
    exh_secure_cookie_jar || {
      exh_action_emit_result favorite "${gid}" "${favcat}" null configuration \
        'ExHentai cookie jar is unavailable'
      return
    }
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response favorite "${cookie_args[@]}" -X POST \
    "https://exhentai.org/gallerypopups.php?gid=${gid}&t=${token}&act=addfav" \
    --data-urlencode "favcat=${favcat}" \
    --data-urlencode 'favnote=' \
    --data-urlencode 'apply=Add to Favorites' \
    --data-urlencode 'update=1') || response_status=$?
  if ((response_status != 0)); then
    exh_action_emit_result favorite "${gid}" "${favcat}" null uncertain \
      'favorite request outcome is unknown' '' true
    return
  fi
  http_status=$(jq -r '.http_status' <<<"${response}")
  body=$(jq -r '.body' <<<"${response}")
  outcome=$(exh_action_http_outcome "${http_status}")
  if [[ "${outcome}" == succeeded ]]; then
    if printf '%s' "${body}" | rg -qi '<form[^>]+(login|Login)|<(input|form)[^>]+(UserName|Password)|please[[:space:]]+log[[:space:]]+in'; then
      exh_action_emit_result favorite "${gid}" "${favcat}" "${http_status}" configuration \
        'ExHentai returned a login form' '' true
    else
      exh_action_emit_result favorite "${gid}" "${favcat}" "${http_status}" succeeded \
        'favorite request accepted' '' true
    fi
  else
    exh_action_emit_result favorite "${gid}" "${favcat}" "${http_status}" \
      "${outcome}" 'favorite request was not accepted' "HTTP ${http_status}" true
  fi
}

# usage: exh_action_hath <gid> <token>
# H@H has no documented HTML success marker. For compatibility, HTTP 200 with
# no explicit login form is accepted; the worker records hath_requested_at.
exh_action_hath() {
  local gid="$1" token="$2"
  local response response_status=0 http_status body outcome
  local -a cookie_args=()

  if ! exh_remote_writes_enabled; then
    exh_action_emit_result hath_request "${gid}" org null configuration \
      'remote writes are disabled in this environment'
    return
  fi

  if [[ ! "${gid}" =~ ^[1-9][0-9]*$ || -z "${token}" ]]; then
    exh_action_emit_result hath_request "${gid}" org null configuration \
      'invalid H@H adapter input'
    return
  fi
  if [[ -n "${EXH_COOKIE_PATH:-}" ]]; then
    exh_secure_cookie_jar || {
      exh_action_emit_result hath_request "${gid}" org null configuration \
        'ExHentai cookie jar is unavailable'
      return
    }
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response hath_request "${cookie_args[@]}" -X POST \
    "https://exhentai.org/archiver.php?gid=${gid}&token=${token}" \
    --data-urlencode 'hathdl_xres=org') || response_status=$?
  if ((response_status != 0)); then
    exh_action_emit_result hath_request "${gid}" org null uncertain \
      'H@H request outcome is unknown' '' true
    return
  fi
  http_status=$(jq -r '.http_status' <<<"${response}")
  body=$(jq -r '.body' <<<"${response}")
  outcome=$(exh_action_http_outcome "${http_status}")
  if [[ "${outcome}" == succeeded ]]; then
    if printf '%s' "${body}" | rg -qi '<form[^>]+(login|Login)|<(input|form)[^>]+(UserName|Password)|please[[:space:]]+log[[:space:]]+in'; then
      exh_action_emit_result hath_request "${gid}" org "${http_status}" configuration \
        'ExHentai returned a login form' '' true
    else
      exh_action_emit_result hath_request "${gid}" org "${http_status}" succeeded \
        'H@H request accepted' '' true
    fi
  else
    exh_action_emit_result hath_request "${gid}" org "${http_status}" \
      "${outcome}" 'H@H request was not accepted' "HTTP ${http_status}" true
  fi
}
