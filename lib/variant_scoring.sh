#!/usr/bin/env bash

# Deterministic, local-only variant scoring. Source after lib/db.sh (and,
# when available, lib/variant_policy.sh). Runtime dependencies: jq and the
# native yomiko-unicode helper.

VARIANTS_SCORING_LIB_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F variants_unicode_nfkc_casefold_array >/dev/null 2>&1; then
  # shellcheck source=lib/variant_unicode.sh
  source "${VARIANTS_SCORING_LIB_DIR}/variant_unicode.sh"
fi

VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS=4

variants_score_members_json() {
  # Input is one JSON object: {policy:{...expanded policy...},members:[...]},
  # where every member has gid, metadata, and metadata_raw.
  local input normalized
  input="$(jq -ce '.' <&0)" || return
  normalized="$(jq -c '
      (.policy.scoring.title_substring_scores | keys) as $title_keys
      | (.members | sort_by(.gid | tonumber)) as $members
      | [$title_keys[], $members[] |
          if type == "string" then .
          else ((.metadata.title // "") | tostring),
               ((.metadata.title_jpn // "") | tostring)
          end]
    ' <<<"${input}" | variants_unicode_nfkc_casefold_array)" || return
  jq -ceS -L "${VARIANTS_SCORING_LIB_DIR}/jq" \
    --argjson normalized "${normalized}" \
    'include "variant_scoring"; score_variant_members($normalized)' <<<"${input}"
}

variants_evaluate_group() {
  local group_id="$1"
  local expected_policy_revision_id="${2:-}"
  local input_json score_json score_parameter

  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Variant group ID must be a positive integer.\n' >&2
    return 2
  }
  [[ -z "${expected_policy_revision_id}" || "${expected_policy_revision_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Policy revision ID must be a positive integer.\n' >&2
    return 2
  }

  if ! declare -F variants_policy_load_active >/dev/null 2>&1; then
    printf 'ERROR: Variant policy loader is unavailable.\n' >&2
    return 1
  fi
  # Validate the expanded policy and its stored hashes before consuming it.
  # The transaction below independently guards the exact revision and member
  # snapshots so a concurrent activation cannot commit stale scores.
  variants_policy_load_active >/dev/null || return

  if [[ "$(db_query ".parameter init" ".parameter set :group_id ${group_id}" \
    "SELECT count(*)
       FROM variant_reviews AS review
      WHERE review.review_type='candidate_identity'
        AND review.status='pending'
        AND (review.group_id=:group_id OR EXISTS (
          SELECT 1
            FROM gallery_variants AS reviewed_member
            JOIN gallery_variants AS target_member
              ON target_member.gid=reviewed_member.gid
             AND target_member.membership_state='confirmed'
           WHERE reviewed_member.group_id=review.group_id
             AND reviewed_member.membership_state='confirmed'
             AND target_member.group_id=:group_id
        ));")" != 0 ]]; then
    printf '{"blocked_reason":"candidate_review_pending","evaluated":false}\n'
    return "${VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS}"
  fi

  input_json="$(db_query ".parameter init" ".parameter set :group_id ${group_id}" \
    "SELECT json_object(
       'policy', json(policy.policy_json),
       'policy_revision_id', policy.id,
       'members', json(COALESCE((
         SELECT json_group_array(json(member_json)) FROM (
           SELECT json_object('gid', member.gid,
                              'metadata', json(member.metadata_snapshot_json),
                              'metadata_raw', member.metadata_snapshot_json) AS member_json
             FROM gallery_variants AS member
            WHERE member.group_id=:group_id AND member.membership_state='confirmed'
            ORDER BY member.gid
         )
       ), '[]')))
      FROM variant_policy_revisions AS policy
     WHERE policy.is_active=1
       AND EXISTS (SELECT 1 FROM variant_groups WHERE id=:group_id);" )" || return
  [[ -n "${input_json}" ]] || { printf 'ERROR: Group or active policy unavailable.\n' >&2; return 1; }
  if [[ -n "${expected_policy_revision_id}" && "$(jq -r '.policy_revision_id' <<<"${input_json}")" != "${expected_policy_revision_id}" ]]; then
    printf 'ERROR: Active policy revision changed before evaluation.\n' >&2
    return 1
  fi
  score_json="$(printf '%s' "${input_json}" | variants_score_members_json)" || return
  score_json="$(jq -c --argjson policy_revision_id "$(jq '.policy_revision_id' <<<"${input_json}")" \
    '. + {policy_revision_id:$policy_revision_id}' <<<"${score_json}")" || return
  score_parameter="$(db_parameter_text "${score_json}")" || return

  db_query ".parameter init" ".parameter set :group_id ${group_id}" \
    ".parameter set :score_json ${score_parameter}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_evaluation_context(
       evaluation_id INTEGER, score_json TEXT NOT NULL CHECK(json_valid(score_json))
     );
     CREATE TEMP TABLE variant_evaluation_guard(
       singleton INTEGER NOT NULL CHECK(singleton=1)
     );
     INSERT INTO variant_evaluation_context(score_json)
       SELECT :score_json
        WHERE json_extract(:score_json, '$.policy_revision_id') =
              (SELECT id FROM variant_policy_revisions WHERE is_active=1)
          AND NOT EXISTS (
            SELECT 1
              FROM variant_reviews AS review
             WHERE review.review_type='candidate_identity'
               AND review.status='pending'
               AND (review.group_id=:group_id OR EXISTS (
                 SELECT 1
                   FROM gallery_variants AS reviewed_member
                   JOIN gallery_variants AS target_member
                     ON target_member.gid=reviewed_member.gid
                    AND target_member.membership_state='confirmed'
                  WHERE reviewed_member.group_id=review.group_id
                    AND reviewed_member.membership_state='confirmed'
                    AND target_member.group_id=:group_id
               )))
          AND (SELECT count(*) FROM gallery_variants
                WHERE group_id=:group_id AND membership_state='confirmed') =
              json_array_length(:score_json, '$.metadata_snapshot')
          AND NOT EXISTS (
            SELECT 1 FROM gallery_variants AS member
             WHERE member.group_id=:group_id AND member.membership_state='confirmed'
               AND NOT EXISTS (
                 SELECT 1 FROM json_each(:score_json, '$.metadata_snapshot') AS snap
                  WHERE json_extract(snap.value, '$.gid')=member.gid
                    AND json_extract(snap.value, '$.metadata_raw')=member.metadata_snapshot_json));
     INSERT INTO variant_evaluation_guard(singleton)
       SELECT count(*) FROM variant_evaluation_context;
     INSERT INTO variant_evaluations(
       group_id, policy_revision_id, supersedes_evaluation_id, state,
       metadata_snapshot_json, member_scores_json, selected_canonical_gid, tied_gids_json)
     SELECT :group_id, json_extract(score_json, '$.policy_revision_id'),
            (SELECT active_evaluation_id FROM variant_groups WHERE id=:group_id),
            CASE WHEN json_array_length(score_json, '$.tied_gids')=1 THEN 'completed' ELSE 'review_blocked' END,
            json_extract(score_json, '$.metadata_snapshot'),
            json_extract(score_json, '$.member_scores'),
            json_extract(score_json, '$.selected_canonical_gid'),
            CASE WHEN json_array_length(score_json, '$.tied_gids')=1 THEN NULL
                 ELSE json_extract(score_json, '$.tied_gids') END
       FROM variant_evaluation_context;
     UPDATE variant_evaluation_context SET evaluation_id=last_insert_rowid();
     UPDATE variant_groups SET canonical_gid=NULL WHERE id=:group_id;
     UPDATE gallery_variants
        SET variant_score=(SELECT json_extract(item.value, '$.score')
                             FROM variant_evaluation_context, json_each(score_json, '$.member_scores') AS item
                            WHERE json_extract(item.value, '$.gid')=gallery_variants.gid),
            variant_score_json=(SELECT item.value
                                  FROM variant_evaluation_context, json_each(score_json, '$.member_scores') AS item
                                 WHERE json_extract(item.value, '$.gid')=gallery_variants.gid),
            variant_state='undetermined', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=:group_id AND membership_state='confirmed';
     UPDATE gallery_variants SET variant_state='alternate'
      WHERE group_id=:group_id AND membership_state='confirmed'
        AND (SELECT json_extract(score_json, '$.selected_canonical_gid')
               FROM variant_evaluation_context) IS NOT NULL;
     UPDATE gallery_variants SET variant_state='canonical'
      WHERE group_id=:group_id AND gid=(SELECT json_extract(score_json, '$.selected_canonical_gid')
                                         FROM variant_evaluation_context);
     UPDATE variant_groups
        SET active_evaluation_id=(SELECT evaluation_id FROM variant_evaluation_context),
            canonical_gid=(SELECT json_extract(score_json, '$.selected_canonical_gid') FROM variant_evaluation_context),
            review_state=CASE WHEN (SELECT json_extract(score_json, '$.selected_canonical_gid')
                                      FROM variant_evaluation_context) IS NULL
                              THEN 'winner_pending' ELSE 'none' END,
            last_evaluated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:group_id;
     INSERT INTO variant_reviews(review_type, group_id, evaluation_id, policy_revision_id,
                                 evidence_json, choices_json)
       SELECT 'winner', :group_id, evaluation_id,
              json_extract(score_json, '$.policy_revision_id'),
              json_object('top_score', json_extract(score_json, '$.top_score'),
                          'runner_up_score', json_extract(score_json, '$.winner_review.runner_up_score'),
                          'score_gap', json_extract(score_json, '$.winner_review.score_gap'),
                          'score_gap_exclusive', json_extract(score_json, '$.winner_review.score_gap_exclusive'),
                          'reason', json_extract(score_json, '$.winner_review.reason'),
                          'member_scores', json_extract(score_json, '$.member_scores')),
              json_extract(score_json, '$.tied_gids')
         FROM variant_evaluation_context
        WHERE json_extract(score_json, '$.selected_canonical_gid') IS NULL;
     SELECT json_object('evaluated', json('true'), 'evaluation_id', evaluation_id,
                        'policy_revision_id', json_extract(score_json, '$.policy_revision_id'),
                        'state', CASE WHEN json_extract(score_json, '$.selected_canonical_gid') IS NULL
                                      THEN 'review_blocked' ELSE 'completed' END,
                        'selected_canonical_gid', json_extract(score_json, '$.selected_canonical_gid'),
                        'tied_gids', json_extract(score_json, '$.tied_gids'),
                        'winner_review', json_extract(score_json, '$.winner_review'),
                        'top_score', json_extract(score_json, '$.top_score'))
       FROM variant_evaluation_context;
     COMMIT;"
}
