#!/usr/bin/env bash

# NFKC normalization followed by full Unicode case folding. The native helper
# deliberately keeps those as two passes to match Python's former behavior.

# Read a JSON array of strings and emit the corresponding normalized array.
# Base64 frames each value so titles containing newlines remain lossless.
variants_unicode_nfkc_casefold_array() {
  local input
  if ! command -v utf8proc-nfkc >/dev/null 2>&1; then
    printf 'ERROR: utf8proc-nfkc is unavailable.\n' >&2
    return 1
  fi
  input="$(jq -ce '
      if type != "array" or any(.[]; type != "string") then
        error("Unicode normalization input must be a string array")
      else . end
    ' <&0)" || return

  (
    set -o pipefail
    jq -r '.[] | @base64' <<<"${input}" | while IFS= read -r encoded; do
        if ! printf '%s' "${encoded}" | base64 -d | utf8proc-nfkc | base64 | tr -d '\n'; then
          return 1
        fi
        printf '\n'
      done | jq -Rsc 'split("\n")[:-1] | map(@base64d)'
  )
}
