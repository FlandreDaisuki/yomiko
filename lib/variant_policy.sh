#!/usr/bin/env bash

# Compact scoring policy validation and immutable expanded-policy lifecycle.
# Callers are expected to source lib/common.sh and lib/db.sh first.

VARIANTS_POLICY_LIB_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F variants_unicode_nfkc_casefold_array >/dev/null 2>&1; then
  # shellcheck source=lib/variant_unicode.sh
  source "${VARIANTS_POLICY_LIB_DIR}/variant_unicode.sh"
fi

variants_policy_err() {
  if declare -F log_err >/dev/null 2>&1; then
    log_err "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
}

variants_policy_sha256() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

variants_policy_canonicalize() {
  jq -ceS '.'
}

variants_policy_validate_title_keys() {
  local input normalized
  input="$(jq -ceS '.' <&0)" || return
  normalized="$(jq -c '.title_substring_scores | keys' <<<"${input}" |
    variants_unicode_nfkc_casefold_array)" || return
  jq -ceS --argjson normalized "${normalized}" '
    if any($normalized[]; length == 0) then
      error("title substring is empty after normalization")
    elif ($normalized | unique | length) != ($normalized | length) then
      error("title substring keys collide after NFKC case folding")
    else . end
  ' <<<"${input}" 2>/dev/null
}

# Read, strictly validate, check normalized title-key uniqueness, and print
# canonical compact JSON while preserving the operator's original key text.
variants_policy_validate_compact() {
  local input="$1"
  local normalized

  if ! jq -e '
      type == "object" and
      (["format_version", "posted_rank_step", "tag_scores", "title_substring_scores"] - keys | length == 0) and
      ((keys - ["expunged_adjustment", "favorite_popularity_cap", "format_version",
               "page_count", "posted_rank_step", "rating_confidence_cap",
               "tag_scores", "title_substring_scores"]) | length == 0) and
      (.format_version | type == "number" and . == 1) and
      ((has("page_count") | not) or
       (.page_count | type == "object" and keys == ["cap", "offset"] and
        (.cap | type == "number" and floor == . and . >= 0 and . <= 1000) and
        (.offset | type == "number" and floor == . and . >= 0 and . <= 1000))) and
      (.posted_rank_step | type == "number" and floor == . and . >= 0) and
      ((has("expunged_adjustment") | not) or
       (.expunged_adjustment | type == "number" and floor == . and . >= -10000 and . <= 10000)) and
      ((has("favorite_popularity_cap") | not) or
       (.favorite_popularity_cap | type == "number" and floor == . and . >= 0 and . <= 10000)) and
      ((has("rating_confidence_cap") | not) or
       (.rating_confidence_cap | type == "number" and floor == . and . >= 0 and . <= 10000)) and
      (.tag_scores | type == "object") and
      (.title_substring_scores | type == "object") and
      ([.tag_scores | to_entries[] |
        (.key | test("^[a-z][a-z0-9_ -]*:[^:[:cntrl:]]+$")) and
        (.key | split(":")[0] | endswith(" ") | not) and
        (.key | test(":\\s|\\s$") | not) and
        (.value | type == "number" and floor == . and . >= -1000 and . <= 1000)] | all) and
      ([.title_substring_scores | to_entries[] |
        (.key | length > 0) and
        (.value | type == "number" and floor == . and . >= -1000 and . <= 1000)] | all)
    ' >/dev/null 2>&1 <<<"${input}"; then
    variants_policy_err 'invalid compact variant policy'
    return 1
  fi

  if ! normalized="$(printf '%s' "${input}" | variants_policy_validate_title_keys)"; then
    variants_policy_err 'title substring keys must be nonempty and unique after NFKC case folding'
    return 1
  fi
  printf '%s' "${normalized}" | variants_policy_canonicalize
}

variants_policy_fixed_matching() {
  printf '%s' '{"automatic_evidence_kinds":["exact_file","official_chain"],"independent_metadata_requires_review":true,"manual_decision_adjustments":{"different_book":-9999,"same_book":9999},"metadata_score":{"content_tags":{"max_points":20,"namespaces":["parody","character","male","female","mixed"],"similarity":"jaccard"},"creator_overlap":{"disjoint_nonempty_is_contradiction":true,"match":"exact_artist_or_group","max_points":30},"page_count":{"formula":"round(10*min(filecount)/max(filecount))","max_points":10},"title":{"english_romaji_similarity":"token","japanese_similarity":"character_bigram","max_points":40,"selection":"maximum"},"total_max":100},"required_category":"Manga","required_scope_tags":["language:chinese","other:tankoubon"],"search":{"category_exclusion_mask":1019,"disable_filters":["user_language","uploader","tags"],"expunged_separate":true},"title_normalization":{"preserve":["volume","part"],"remove":["creator","language","translator","digital","edition","punctuation"]},"official_chain_visibility":{"eligible":"current_gid_is_null_or_equals_gid","replaced":"current_gid_is_non_null_and_differs_from_gid","validate_references_as_pairs":true,"retain_replaced_history":true},"visible_contradictions":["title_volume_part_conflict","disjoint_creator_sets","missing_evidence","chain_reference_invalid","chain_key_mismatch","chain_conflict","chain_cycle","chain_branch","chain_multiple_terminals"]}'
}

variants_policy_fixed_operations() {
  printf '%s' '{"annual_rediscovery_days":365,"discovery_groups_per_run":1,"gdata_batch_size":25,"gdata_batches_per_continuation":4,"job_priority":["explicit_feedback","policy_work","annual_stale_discovery"],"lease_minutes":15,"policy_sweep_batch_size":100,"retry_delays_seconds":[300,900,3600,21600,86400],"search_requests_per_continuation":8,"search_throttle_seconds":3}'
}

# Input is already validated canonical compact JSON.
variants_policy_expand() {
  local compact="$1"
  local matching operations
  matching="$(variants_policy_fixed_matching)"
  operations="$(variants_policy_fixed_operations)"
  jq -cnS \
    --argjson compact "${compact}" \
    --argjson matching "${matching}" \
    --argjson operations "${operations}" '
      {
        format_version: 1,
        matching: $matching,
        operations: $operations,
        scoring: ({
          expunged_adjustment: ($compact.expunged_adjustment // -1000),
          favorite_popularity: {
            cap: ($compact.favorite_popularity_cap // 500),
            divisor: 10, missing_count_points: 0, rounding: "floor"
          },
          manual_winner_override: 9999,
          posted_rank: {
            equal_timestamps_share_rank: true,
            oldest_rank: 1,
            step: $compact.posted_rank_step
          },
          rating_confidence: {
            cap: ($compact.rating_confidence_cap // 500), count_divisor: 2, minimum: 0,
            missing_count_points: 0, rating_baseline: 3, rounding: "floor"
          },
          tag_scores: $compact.tag_scores,
          title_normalization: "NFKC_Casefold",
          title_substring_scores: $compact.title_substring_scores,
          winner_review_score_gap_exclusive: 30
        } + (if $compact.page_count then {
          page_count: {
            cap: $compact.page_count.cap,
            formula: "min(cap,filecount-offset)",
            missing_count_points: 0,
            offset: $compact.page_count.offset
          }
        } else {} end))
      }'
}

variants_policy_compact_from_expanded() {
  jq -ceS '
    if .format_version != 1 or
       (.scoring.tag_scores | type) != "object" or
       (.scoring.title_substring_scores | type) != "object" or
       (.scoring.posted_rank.step | type) != "number"
    then error("unsupported expanded variant policy")
    else ({
      format_version: 1,
      expunged_adjustment: (.scoring.expunged_adjustment // -1000),
      favorite_popularity_cap: (.scoring.favorite_popularity.cap // 500),
      tag_scores: .scoring.tag_scores,
      title_substring_scores: .scoring.title_substring_scores,
      posted_rank_step: .scoring.posted_rank.step,
      rating_confidence_cap: (.scoring.rating_confidence.cap // 500)
    } + (if .scoring.page_count then {
      page_count: {
        cap: .scoring.page_count.cap,
        offset: .scoring.page_count.offset
      }
    } else {} end)) end'
}

variants_policy_document() {
  local source="$1"
  if [[ "${source}" == '-' ]]; then
    jq -c '.'
  elif [[ -f "${source}" ]]; then
    jq -c '.' "${source}"
  else
    variants_policy_err "policy file not found: ${source}"
    return 1
  fi
}

# Prints one canonical JSON object containing both documents and all hashes.
variants_policy_prepare() {
  local source="$1"
  local input compact expanded compact_hash content_hash matching_hash scoring_hash operations_hash
  if ! input="$(variants_policy_document "${source}" 2>/dev/null)"; then
    variants_policy_err 'unable to parse compact variant policy JSON'
    return 1
  fi
  compact="$(variants_policy_validate_compact "${input}")" || return
  expanded="$(variants_policy_expand "${compact}")" || return
  compact_hash="$(variants_policy_sha256 "${compact}")"
  content_hash="$(variants_policy_sha256 "${expanded}")"
  matching_hash="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${expanded}")")"
  scoring_hash="$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"${expanded}")")"
  operations_hash="$(variants_policy_sha256 "$(jq -cS '.operations' <<<"${expanded}")")"
  jq -cnS \
    --arg compact_hash "${compact_hash}" --arg content_hash "${content_hash}" \
    --arg matching_hash "${matching_hash}" --arg scoring_hash "${scoring_hash}" \
    --arg operations_hash "${operations_hash}" --argjson compact "${compact}" \
    --argjson expanded "${expanded}" \
    '{compact_hash:$compact_hash,compact_policy:$compact,content_hash:$content_hash,
      expanded_policy:$expanded,matching_hash:$matching_hash,operations_hash:$operations_hash,
      scoring_hash:$scoring_hash,valid:true}'
}

variants_policy_check() {
  [[ "$#" -eq 1 ]] || { variants_policy_err 'usage: variants policy-check <path|->'; return 2; }
  local prepared active
  prepared="$(variants_policy_prepare "$1")" || return
  active="$(db_query "SELECT json_object(
      'content_hash',content_hash,'matching_hash',matching_hash,
      'scoring_hash',scoring_hash,'operations_hash',operations_hash,
      'sweep_exists',json(CASE WHEN EXISTS(
        SELECT 1 FROM variant_jobs WHERE job_type='policy_scoring_sweep'
          AND group_id IS NULL AND status IN ('queued','leased')
      ) THEN 'true' ELSE 'false' END))
    FROM variant_policy_revisions WHERE is_active=1;")" || return
  [[ -n "${active}" ]] || { variants_policy_err 'no active variant policy'; return 1; }
  jq -cS --argjson active "${active}" '
    . + {
      changed: (.content_hash != $active.content_hash),
      matching_changed: (.matching_hash != $active.matching_hash),
      scoring_changed: (.scoring_hash != $active.scoring_hash),
      operations_changed: (.operations_hash != $active.operations_hash),
      scoring_sweep_would_queue:
        ((.scoring_hash != $active.scoring_hash) and ($active.sweep_exists | not)),
      scoring_sweep_would_coalesce:
        ((.scoring_hash != $active.scoring_hash) and $active.sweep_exists)
    }' <<<"${prepared}"
}

# Load and validate exactly one active expanded revision. Legacy migration-005
# rows remain auditable but are not executable; migration 006 activates format 1.
variants_policy_load_active() {
  local row policy compact expected actual_content actual_matching actual_scoring actual_operations
  row="$(db_query "SELECT json_object('revision_id',id,'content_hash',content_hash,'matching_hash',matching_hash,'scoring_hash',scoring_hash,'operations_hash',operations_hash,'policy',json(policy_json)) FROM variant_policy_revisions WHERE is_active=1;")" || return
  [[ -n "${row}" ]] || { variants_policy_err 'no active variant policy'; return 1; }
  policy="$(jq -ce '.policy | select(.format_version == 1)' <<<"${row}")" || {
    variants_policy_err 'active variant policy has an unsupported format'
    return 1
  }
  compact="$(printf '%s' "${policy}" | variants_policy_compact_from_expanded 2>/dev/null)" || {
    variants_policy_err 'active variant policy has an invalid scoring projection'
    return 1
  }
  compact="$(variants_policy_validate_compact "${compact}")" || return
  expected="$(variants_policy_expand "${compact}")" || return
  if [[ "$(jq -cS '.' <<<"${policy}")" != "${expected}" ]]; then
    variants_policy_err 'active variant policy contains unsupported fixed behavior'
    return 1
  fi
  actual_content="$(variants_policy_sha256 "$(jq -cS '.' <<<"${policy}")")"
  actual_matching="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${policy}")")"
  actual_scoring="$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"${policy}")")"
  actual_operations="$(variants_policy_sha256 "$(jq -cS '.operations' <<<"${policy}")")"
  if ! jq -e --arg content "${actual_content}" --arg matching "${actual_matching}" \
      --arg scoring "${actual_scoring}" --arg operations "${actual_operations}" \
      '.content_hash==$content and .matching_hash==$matching and .scoring_hash==$scoring and .operations_hash==$operations' \
      >/dev/null <<<"${row}"; then
    variants_policy_err 'active variant policy hashes do not match its content'
    return 1
  fi
  jq -cS '.' <<<"${row}"
}

variants_policy_show() {
  local pretty=0 expanded=0 loaded output
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --pretty) pretty=1 ;;
    --expanded) expanded=1 ;;
    *) variants_policy_err 'usage: variants policy-show [--pretty] [--expanded]'; return 2 ;;
    esac
    shift
  done
  loaded="$(variants_policy_load_active)" || return
  if ((expanded)); then
    output="$(jq -cS '.policy' <<<"${loaded}")"
  else
    output="$(jq -c '.policy' <<<"${loaded}" | variants_policy_compact_from_expanded)" || {
      variants_policy_err 'active variant policy cannot be exported as compact format'
      return 1
    }
  fi
  if ((pretty)); then jq -S '.' <<<"${output}"; else printf '%s\n' "${output}"; fi
}

variants_policy_activate() {
  [[ "$#" -eq 1 ]] || { variants_policy_err 'usage: variants policy-activate <path|->'; return 2; }
  local prepared compact_hash content_hash matching_hash scoring_hash operations_hash expanded result
  prepared="$(variants_policy_prepare "$1")" || return
  compact_hash="$(jq -r '.compact_hash' <<<"${prepared}")"
  content_hash="$(jq -r '.content_hash' <<<"${prepared}")"
  matching_hash="$(jq -r '.matching_hash' <<<"${prepared}")"
  scoring_hash="$(jq -r '.scoring_hash' <<<"${prepared}")"
  operations_hash="$(jq -r '.operations_hash' <<<"${prepared}")"
  expanded="$(jq -cS '.expanded_policy' <<<"${prepared}")"

  result="$(db_query \
    '.parameter init' \
    ".parameter set :policy_json $(db_parameter_text "${expanded}")" \
    ".parameter set :content_hash $(db_parameter_text "${content_hash}")" \
    ".parameter set :matching_hash $(db_parameter_text "${matching_hash}")" \
    ".parameter set :scoring_hash $(db_parameter_text "${scoring_hash}")" \
    ".parameter set :operations_hash $(db_parameter_text "${operations_hash}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE _variant_policy_activation AS
       SELECT id AS old_id, content_hash AS old_content_hash,
              matching_hash AS old_matching_hash, scoring_hash AS old_scoring_hash,
              operations_hash AS old_operations_hash
         FROM variant_policy_revisions WHERE is_active=1;
     INSERT OR IGNORE INTO variant_policy_revisions
       (policy_json,content_hash,matching_hash,scoring_hash,operations_hash)
       VALUES (:policy_json,:content_hash,:matching_hash,:scoring_hash,:operations_hash);
     ALTER TABLE _variant_policy_activation ADD COLUMN target_id INTEGER;
     ALTER TABLE _variant_policy_activation ADD COLUMN sweep_queued INTEGER DEFAULT 0;
     UPDATE _variant_policy_activation SET target_id=
       (SELECT id FROM variant_policy_revisions WHERE content_hash=:content_hash);
     UPDATE variant_policy_revisions SET is_active=0
      WHERE is_active=1 AND id<>(SELECT target_id FROM _variant_policy_activation);
     UPDATE variant_policy_revisions
        SET is_active=1,activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=(SELECT target_id FROM _variant_policy_activation)
        AND is_active=0;
     INSERT OR IGNORE INTO variant_jobs(job_type,priority,scoring_revision_id)
       SELECT 'policy_scoring_sweep',500,target_id FROM _variant_policy_activation
        WHERE old_content_hash<>:content_hash AND old_scoring_hash<>:scoring_hash;
     UPDATE _variant_policy_activation SET sweep_queued=changes();
     UPDATE variant_jobs
        SET priority=MAX(priority,500),
            scoring_revision_id=(SELECT target_id FROM _variant_policy_activation),
            continuation_cursor_json=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE job_type='policy_scoring_sweep' AND status IN ('queued','leased')
        AND EXISTS (SELECT 1 FROM _variant_policy_activation
                     WHERE old_content_hash<>:content_hash
                       AND old_scoring_hash<>:scoring_hash);
     COMMIT;
     SELECT json_object(
       'revision_id',target_id,'compact_hash','${compact_hash}',
       'content_hash',:content_hash,'matching_hash',:matching_hash,
       'scoring_hash',:scoring_hash,'operations_hash',:operations_hash,
       'changed',json(CASE WHEN old_content_hash<>:content_hash THEN 'true' ELSE 'false' END),
       'matching_changed',json(CASE WHEN old_matching_hash<>:matching_hash THEN 'true' ELSE 'false' END),
       'scoring_changed',json(CASE WHEN old_scoring_hash<>:scoring_hash THEN 'true' ELSE 'false' END),
       'operations_changed',json(CASE WHEN old_operations_hash<>:operations_hash THEN 'true' ELSE 'false' END),
       'scoring_sweep_queued',json(CASE WHEN sweep_queued<>0 THEN 'true' ELSE 'false' END),
       'scoring_sweep_coalesced',json(CASE
         WHEN old_scoring_hash<>:scoring_hash AND sweep_queued=0 THEN 'true'
         ELSE 'false' END))
       FROM _variant_policy_activation;")" || return
  jq -cS '.' <<<"${result}"
}
