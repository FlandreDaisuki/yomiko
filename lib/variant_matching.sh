#!/usr/bin/env bash
# Pure query planning and candidate identity evidence; JSON in, JSON out.

VARIANTS_MATCHING_LIB_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F variants_unicode_nfkc_casefold_array >/dev/null 2>&1; then
  # shellcheck source=lib/variant_unicode.sh
  source "${VARIANTS_MATCHING_LIB_DIR}/variant_unicode.sh"
fi

variants_matching_plan_queries() {
  local input normalized
  input="$(jq -ce '.' <&0)" || return
  normalized="$(jq -c '
      (if type == "array" then . else (.seeds // []) end | sort_by(.gid | tonumber))
      | [ .[] | ((.title // "") | tostring), ((.title_jpn // "") | tostring) ]
    ' <<<"${input}" | variants_unicode_nfkc_casefold_array)" || return
  jq -ceS -L "${VARIANTS_MATCHING_LIB_DIR}/jq" \
    --argjson normalized "${normalized}" \
    'include "variant_matching"; plan_variant_queries($normalized)' <<<"${input}"
}

variants_matching_scope_json() {
  jq -ceS '
    [(.tags // [])[] | select(type == "string")] | unique | sort as $tags
    | ["language:chinese", "other:tankoubon"] as $required
    | {in_scope:(($required - $tags | length) == 0), required:$required, tags:$tags}
  '
}

variants_matching_evidence_json() {
  local input normalized
  input="$(jq -ce '.' <&0)" || return
  normalized="$(jq -c '[
      ((.source.title // "") | tostring),
      ((.source.title_jpn // "") | tostring),
      ((.candidate.title // "") | tostring),
      ((.candidate.title_jpn // "") | tostring)
    ]' <<<"${input}" | variants_unicode_nfkc_casefold_array)" || return
  jq -ceS -L "${VARIANTS_MATCHING_LIB_DIR}/jq" \
    --argjson normalized "${normalized}" \
    'include "variant_matching"; variant_matching_evidence($normalized)' <<<"${input}"
}
