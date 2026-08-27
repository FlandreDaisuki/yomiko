#!/usr/bin/env bash
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
#   category: non-empty string
#   uploader: non-empty string
#   posted: unsigned integer (JSON number or decimal integer string)
#   filesize: unsigned integer (JSON number or decimal integer string)
#   thumb: non-empty string
# Optional remote fields:
#   title_jpn: string or null; a missing value is normalized to null
#   first_gid, parent_gid, current_gid: unsigned integers or null
#   first_key, parent_key, current_key: non-empty strings or null
exh_normalize_gallery_metadata() {
  local expected_gid="$1"
  local metadata="$2"

  jq -ce --arg expected_gid "${expected_gid}" '
    def invalid($message):
      error("invalid gallery metadata: " + $message);
    def required($name):
      if has($name) and .[$name] != null then .[$name]
      else invalid("missing required field " + $name)
      end;
    def unsigned_integer($name; $maximum):
      (if type == "number" then .
       elif type == "string" and test("^(0|[1-9][0-9]*)$") then tonumber
       else invalid($name + " must be an unsigned integer")
       end)
      | if . >= 0 and . <= $maximum and . == floor then .
        else invalid($name + " must be an unsigned integer")
        end;
    def decimal($name; $minimum; $maximum):
      (if type == "number" then .
       elif type == "string" and test("^(0|[1-9][0-9]*)([.][0-9]+)?$") then tonumber
       else invalid($name + " must be numeric")
       end)
      | if . >= $minimum and . <= $maximum then .
        else invalid($name + " is outside the allowed range")
        end;
    def optional_unsigned_integer($name; $maximum):
      if . == null then null else unsigned_integer($name; $maximum) end;
    def optional_nonempty_string($name):
      if . == null then null
      elif type == "string" and length > 0 then .
      else invalid($name + " must be a non-empty string or null")
      end;

    if type != "object" then invalid("root must be an object") else . end
    | . as $metadata
    | ($metadata | required("gid") | unsigned_integer("gid"; 2147483647)) as $gid
    | if ($gid | tostring) != ($expected_gid | tonumber | tostring)
      then invalid("gid does not match the requested gallery")
      else .
      end
    | ($metadata | required("token")) as $token
    | ($metadata | required("title")) as $title
    | ($metadata | required("filecount") | unsigned_integer("filecount"; 2147483647)) as $filecount
    | ($metadata | required("expunged")) as $expunged
    | ($metadata | required("tags")) as $tags
    | ($metadata | required("rating") | decimal("rating"; 0; 5)) as $rating
    | ($metadata | required("category")) as $category
    | ($metadata | required("uploader")) as $uploader
    | ($metadata | required("posted") | unsigned_integer("posted"; 9007199254740991)) as $posted
    | ($metadata | required("filesize") | unsigned_integer("filesize"; 9007199254740991)) as $filesize
    | ($metadata | required("thumb")) as $thumb
    | (($metadata.first_gid? // null) | optional_unsigned_integer("first_gid"; 2147483647)) as $first_gid
    | (($metadata.parent_gid? // null) | optional_unsigned_integer("parent_gid"; 2147483647)) as $parent_gid
    | (($metadata.current_gid? // null) | optional_unsigned_integer("current_gid"; 2147483647)) as $current_gid
    | (($metadata.first_key? // null) | optional_nonempty_string("first_key")) as $first_key
    | (($metadata.parent_key? // null) | optional_nonempty_string("parent_key")) as $parent_key
    | (($metadata.current_key? // null) | optional_nonempty_string("current_key")) as $current_key
    | if ($token | type) != "string" or ($token | length) == 0
      then invalid("token must be a non-empty string") else . end
    | if ($title | type) != "string" or ($title | length) == 0
      then invalid("title must be a non-empty string") else . end
    | if ($category | type) != "string" or ($category | length) == 0
      then invalid("category must be a non-empty string") else . end
    | if ($uploader | type) != "string" or ($uploader | length) == 0
      then invalid("uploader must be a non-empty string") else . end
    | if ($thumb | type) != "string" or ($thumb | length) == 0
      then invalid("thumb must be a non-empty string") else . end
    | if (($metadata.title_jpn? // null) | type) != "null"
        and (($metadata.title_jpn? // null) | type) != "string"
      then invalid("title_jpn must be a string or null") else . end
    | if ($expunged | type) != "boolean"
      then invalid("expunged must be boolean") else . end
    | if ($tags | type) != "array" or any($tags[]; type != "string")
      then invalid("tags must be an array of strings") else . end
    | {
        gid: $gid,
        token: $token,
        title: $title,
        title_jpn: ($metadata.title_jpn? // null),
        filecount: $filecount,
        expunged: $expunged,
        tags: $tags,
        rating: $rating,
        category: $category,
        uploader: $uploader,
        posted: $posted,
        filesize: $filesize,
        thumb: $thumb,
        first_gid: $first_gid,
        first_key: $first_key,
        parent_gid: $parent_gid,
        parent_key: $parent_key,
        current_gid: $current_gid,
        current_key: $current_key
      }
  ' <<<"${metadata}"
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
  local url='https://exhentai.org/'
  local -a mode_args=()
  [[ "${mode}" == expunged ]] && mode_args+=(--data-urlencode 'f_sh=on')
  html=$(curl -fsSL --get "${url}" -b "${EXH_COOKIE_PATH}" -c "${EXH_COOKIE_PATH}" \
    --data-urlencode "f_search=${query}" --data-urlencode 'f_sft=on' \
    --data-urlencode 'f_sfu=on' --data-urlencode 'f_sfl=on' \
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
  # Do row normalization in shell so a
  # malformed individual entry remains visible instead of aborting the batch.
  local out='[]' gid token item normalized api_error
  while IFS= read -r row; do
    gid=$(jq -r '.[0]' <<<"${row}"); token=$(jq -r '.[1]' <<<"${row}")
    item=$(jq -c --argjson gid "${gid}" --arg token "${token}" \
      '.gmetadata[]? | select((.gid|tostring) == ($gid|tostring) and (.gtoken // "") == $token)' <<<"${response}" | head -n1 || true)
    if [[ -z "${item}" ]]; then
      item=$(jq -c --argjson gid "${gid}" '.gmetadata[]? | select((.gid|tostring) == ($gid|tostring))' <<<"${response}" | head -n1 || true)
    fi
    if [[ -n "${item}" ]]; then
      api_error=$(jq -r '.error // empty' <<<"${item}")
    else
      api_error=''
    fi
    if [[ -n "${api_error}" ]]; then
      normalized=$(jq -nc --argjson gid "${gid}" --arg token "${token}" --arg error "${api_error}" \
        '{gid:$gid,token:$token,status:"error",error:$error}')
    elif [[ -n "${item}" ]] && normalized=$(exh_normalize_gallery_metadata "${gid}" "$(jq -c '. + {token:(.token // .gtoken)}' <<<"${item}")" 2>/dev/null); then
      normalized=$(jq -nc --arg token "${token}" --argjson metadata "${normalized}" \
        '{gid:$metadata.gid,token:$token,status:"ok",metadata:$metadata}')
    else
      normalized=$(jq -nc --argjson gid "${gid}" --arg token "${token}" \
        '{gid:$gid,token:$token,status:"error",error:"missing or invalid gdata entry"}')
    fi
    out=$(jq -c --argjson row "${normalized}" '. + [$row]' <<<"${out}")
  done < <(jq -c '.[]' <<<"${requested}")
  jq -nc --argjson entries "${out}" '{entries:$entries}'
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
  response=$(curl -fsSL -X POST 'https://api.e-hentai.org/api.php' -H 'Content-Type: application/json' --data "${payload}")
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
  html=$(curl -fsSL "https://exhentai.org/g/${gid}/${token}/" -b "${EXH_COOKIE_PATH}" -c "${EXH_COOKIE_PATH}")
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

  if ! exh_remote_writes_enabled; then
    log_err "Remote writes are disabled in this environment."
    return 1
  fi

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

# This helper deliberately does not use curl -c. Cookie refresh and all
# durable state changes belong to the login/worker flows, not pure adapters.
exh_action_cookie_args() {
  if [[ -n "${EXH_COOKIE_PATH:-}" ]]; then
    printf '%s\n' '-b' "${EXH_COOKIE_PATH}"
  fi
}

# usage: exh_action_http_response <curl-arguments...>
# stdout: {http_status,body}; return nonzero when curl cannot provide a final
# HTTP response. Callers classify POST transport failures as uncertain.
exh_action_http_response() {
  local marker=$'\n__YOMIKO_ACTION_HTTP_STATUS__'
  local output body http_status

  if ! output=$(curl -sS -L "$@" -w "${marker}%{http_code}" 2>/dev/null); then
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
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi

  if ! html=$(curl -sS -L "${cookie_args[@]}" \
    'https://exhentai.org/mytags' 2>/dev/null); then
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
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response "${cookie_args[@]}" -X POST \
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
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response "${cookie_args[@]}" -X POST \
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
    cookie_args=(-b "${EXH_COOKIE_PATH}")
  fi
  response=$(exh_action_http_response "${cookie_args[@]}" -X POST \
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
