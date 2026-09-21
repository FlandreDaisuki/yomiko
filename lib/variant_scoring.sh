#!/usr/bin/env bash

# Deterministic, local-only variant scoring. Source after lib/db.sh (and,
# when available, lib/variant_policy.sh). Runtime dependencies: jq and the
# native yomiko-unicode helper.

VARIANTS_SCORING_LIB_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F variants_unicode_nfkc_casefold_array >/dev/null 2>&1; then
  # shellcheck source=lib/variant_unicode.sh
  source "${VARIANTS_SCORING_LIB_DIR}/variant_unicode.sh"
fi

VARIANTS_EVALUATION_STALE_STATUS=3
VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS=4
VARIANTS_EVALUATION_PERMANENT_STATUS=5
VARIANTS_EVALUATION_CONFIGURATION_STATUS=6
VARIANTS_EVALUATION_RETRYABLE_STATUS=7

variants_score_members_json() {
  # Input is one JSON object: {policy:{...expanded policy...},source_gid:...,members:[...]},
  # where metadata is the live galleries row and only the resulting evaluation
  # snapshot is frozen.
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
  # shellcheck disable=SC2034 # inherited dynamically by db_write
  local YOMIKO_DB_COMPONENT=variant_worker
  local group_id="$1"
  local expected_policy_revision_id="${2:-}"
  local expected_evaluation_id="${3:-}"
  local input_json score_json score_parameter expected_source_gid

  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Variant group ID must be a positive integer.\n' >&2
    return 2
  }
  [[ -z "${expected_policy_revision_id}" || "${expected_policy_revision_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Policy revision ID must be a positive integer.\n' >&2
    return 2
  }
  [[ -z "${expected_evaluation_id}" || "${expected_evaluation_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Expected evaluation ID must be a positive integer.\n' >&2
    return 2
  }

  if ! declare -F variants_policy_load_active >/dev/null 2>&1; then
    printf 'ERROR: Variant policy loader is unavailable.\n' >&2
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  fi
  if ! command -v jq >/dev/null 2>&1 || ! command -v yomiko-unicode >/dev/null 2>&1; then
    printf 'ERROR: Variant scoring dependencies are unavailable.\n' >&2
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  fi
  local group_exists desired_rating group_authority
  group_exists="$(db_query ".parameter set :group_id ${group_id}" \
    "SELECT count(*) FROM variant_groups WHERE id=:group_id;")" ||
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  if [[ "${group_exists}" != 1 ]]; then
    printf 'ERROR: Variant group does not exist.\n' >&2
    return "${VARIANTS_EVALUATION_PERMANENT_STATUS}"
  fi
  desired_rating="$(db_query ".parameter set :group_id ${group_id}" \
    "SELECT desired_rating FROM variant_groups WHERE id=:group_id;")" ||
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  group_authority="$(db_query ".parameter set :group_id ${group_id}" \
    "SELECT identity_active || char(9) || is_active FROM variant_groups WHERE id=:group_id;")" ||
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  if [[ "${desired_rating}" != 11 || "${group_authority}" != $'1\t1' ]]; then
    printf '{"evaluated":false,"skipped":true,"reason":"canonical_selection_requires_rating_11"}\n'
    return 0
  fi
  # Validate the expanded policy and its stored hashes before consuming it.
  # The transaction below independently guards the exact revision and member
  # snapshots so a concurrent activation cannot commit stale scores.
  variants_policy_load_active >/dev/null || return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"

  input_json="$(db_query ".parameter init" ".parameter set :group_id ${group_id}" \
    "$(variants_revision_projection_sql)
     SELECT json_object(
       'policy', json(policy.policy_json),
       'policy_revision_id', policy.id,
       'source_gid', (SELECT source_gid FROM variant_groups WHERE id=:group_id),
       'members', json(COALESCE((
           SELECT json_group_array(json(member_json)) FROM (
           SELECT json_object('gid', member.gid,
                              'evidence', json(member.evidence_json),
                              'metadata', json_object(
                                'title', gallery.title,
                                'title_jpn', gallery.title_jpn,
                                'tags', CASE WHEN json_valid(gallery.tags)
                                             THEN json(gallery.tags) ELSE json('[]') END,
                                'filecount', gallery.file_count,
                                'posted', gallery.posted,
                                'favorite_count', gallery.favorite_count,
                                'rating', gallery.rating,
                                'rating_count', gallery.rating_count,
                                'first_gid', gallery.first_gid,
                                'first_token', gallery.first_token,
                                'parent_gid', gallery.parent_gid,
                                'parent_token', gallery.parent_token,
                                'current_gid', gallery.current_gid,
                                'current_token', gallery.current_token,
                                'expunged', gallery.expunged),
                              'uploader_revision', json_object(
                                'revision_gid', gallery.gid,
                                'terminal_gid', revision_projection.terminal_gid,
                                'component_gid', revision_projection.component_gid,
                                'component_gids', json(revision_projection.component_gids),
                                'edge_provenance', json(revision_projection.edge_provenance)
                              ),
                              'uploader_revision_fingerprint', json_object(
                                'terminal_gid', revision_projection.terminal_gid,
                                'component_gid', revision_projection.component_gid,
                                'component_gids', json(revision_projection.component_gids),
                                'edge_provenance', json(revision_projection.edge_provenance)
                              )) AS member_json
             FROM gallery_variants AS member
             JOIN galleries AS gallery ON gallery.gid = member.gid
             JOIN evaluation_revision_projection AS revision_projection
               ON revision_projection.revision_gid = member.gid
              AND revision_projection.ready = 1
             JOIN evaluation_scoreable_revision_terminals AS scoreable_terminal
               ON scoreable_terminal.gid = member.gid
            WHERE member.group_id=:group_id AND member.membership_state='confirmed'
            ORDER BY member.gid
         )
       ), '[]')))
      FROM variant_policy_revisions AS policy
     WHERE policy.is_active=1
       AND EXISTS (SELECT 1 FROM variant_groups WHERE id=:group_id);" )" || return
  [[ -n "${input_json}" ]] || { printf 'ERROR: Group or active policy unavailable.\n' >&2; return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"; }
  expected_source_gid="$(jq -r '.source_gid' <<<"${input_json}")" || return
  [[ "${expected_source_gid}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: Group source GID is unavailable.\n' >&2
    return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  }
  if [[ -n "${expected_policy_revision_id}" && "$(jq -r '.policy_revision_id' <<<"${input_json}")" != "${expected_policy_revision_id}" ]]; then
    printf 'ERROR: Active policy revision changed before evaluation.\n' >&2
    return "${VARIANTS_EVALUATION_STALE_STATUS}"
  fi
  if ! jq -e '(.members | length > 0) and all(.members[];
      .metadata.filecount != null and
      .metadata.favorite_count != null and
      .metadata.rating_count != null)' \
      >/dev/null 2>&1 <<<"${input_json}"; then
    printf '{"evaluated":false,"retryable":true,"reason":"scoring_input_incomplete"}\n'
    return "${VARIANTS_EVALUATION_RETRYABLE_STATUS}"
  fi
  if ! score_json="$(printf '%s' "${input_json}" | variants_score_members_json)"; then
    printf 'ERROR: Invalid authoritative member scoring snapshot.\n' >&2
    return "${VARIANTS_EVALUATION_PERMANENT_STATUS}"
  fi
  score_json="$(jq -c --argjson policy_revision_id "$(jq '.policy_revision_id' <<<"${input_json}")" \
    '. + {policy_revision_id:$policy_revision_id}' <<<"${score_json}")" || return
  score_parameter="$(db_parameter_text "${score_json}")" || return

  local evaluation_result
  evaluation_result="$(db_write ".parameter init" ".parameter set :group_id ${group_id}" \
    ".parameter set :score_json ${score_parameter}" \
    ".parameter set :expected_evaluation_id ${expected_evaluation_id:-0}" \
    ".parameter set :expected_source_gid ${expected_source_gid}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_evaluation_revision_projection AS
       $(variants_revision_projection_sql)
       SELECT * FROM evaluation_revision_projection;
     CREATE TEMP TABLE variant_evaluation_scoreable_revision_terminals AS
       SELECT revision_gid, terminal_gid AS gid, terminal_gid, component_gid, component_size,
              component_gids, edge_provenance, is_terminal
         FROM variant_evaluation_revision_projection
        WHERE ready=1 AND is_terminal=1;
     -- Build only the identity classes and candidate-review pairs that can
     -- block this group.  Unlike durable reconciliation, this projection is
     -- transaction-local and never changes reviews, groups, or jobs.
     CREATE TEMP TABLE variant_evaluation_target_member(gid INTEGER PRIMARY KEY);
     INSERT INTO variant_evaluation_target_member(gid)
       SELECT gid FROM gallery_variants
        WHERE group_id=:group_id AND membership_state='confirmed';
     CREATE TEMP TABLE variant_evaluation_review_seed(review_id INTEGER PRIMARY KEY);
     INSERT INTO variant_evaluation_review_seed(review_id)
       SELECT DISTINCT review.id
         FROM variant_reviews AS review
         JOIN variant_groups AS owner ON owner.id=review.group_id
         LEFT JOIN variant_evaluation_revision_projection AS source_projection
           ON source_projection.revision_gid=owner.source_gid
         LEFT JOIN variant_evaluation_revision_projection AS candidate_projection
           ON candidate_projection.revision_gid=review.candidate_gid
        WHERE review.review_type='candidate_identity'
          AND review.status='pending'
          AND (review.group_id=:group_id
            OR COALESCE(source_projection.terminal_gid,owner.source_gid) IN
                 (SELECT gid FROM variant_evaluation_target_member)
            OR COALESCE(candidate_projection.terminal_gid,review.candidate_gid) IN
                 (SELECT gid FROM variant_evaluation_target_member)
            OR EXISTS (
                 SELECT 1 FROM gallery_variants AS reviewed_member
                  LEFT JOIN variant_evaluation_revision_projection AS reviewed_projection
                    ON reviewed_projection.revision_gid=reviewed_member.gid
                  WHERE reviewed_member.group_id=review.group_id
                    AND reviewed_member.membership_state='confirmed'
                    AND COALESCE(reviewed_projection.terminal_gid,reviewed_member.gid) IN (
                      SELECT gid FROM variant_evaluation_target_member)));
     CREATE TEMP TABLE variant_evaluation_related_group(group_id INTEGER PRIMARY KEY);
     INSERT INTO variant_evaluation_related_group(group_id) VALUES (:group_id);
     INSERT OR IGNORE INTO variant_evaluation_related_group(group_id)
       SELECT DISTINCT member.group_id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id=member.group_id
        WHERE grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND member.gid IN (SELECT gid FROM variant_evaluation_target_member)
          AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                       WHERE terminal.gid=member.gid);
     INSERT OR IGNORE INTO variant_evaluation_related_group(group_id)
       SELECT DISTINCT member.group_id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id=member.group_id
        WHERE grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND member.gid IN (
            SELECT owner.source_gid
              FROM variant_evaluation_review_seed AS seed
              JOIN variant_reviews AS review ON review.id=seed.review_id
              JOIN variant_groups AS owner ON owner.id=review.group_id
            UNION
            SELECT review.candidate_gid
              FROM variant_evaluation_review_seed AS seed
              JOIN variant_reviews AS review ON review.id=seed.review_id
            UNION
            SELECT source_projection.terminal_gid
              FROM variant_evaluation_review_seed AS seed
              JOIN variant_reviews AS review ON review.id=seed.review_id
              JOIN variant_groups AS owner ON owner.id=review.group_id
              JOIN variant_evaluation_revision_projection AS source_projection
                ON source_projection.revision_gid=owner.source_gid
            UNION
            SELECT candidate_projection.terminal_gid
              FROM variant_evaluation_review_seed AS seed
              JOIN variant_reviews AS review ON review.id=seed.review_id
              JOIN variant_evaluation_revision_projection AS candidate_projection
                ON candidate_projection.revision_gid=review.candidate_gid)
          AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                       WHERE terminal.gid=member.gid);
     INSERT OR IGNORE INTO variant_evaluation_related_group(group_id)
       SELECT DISTINCT member.group_id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id=member.group_id
        WHERE grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND member.gid IN (
            SELECT COALESCE(low_projection.terminal_gid,pair.low_gid)
              FROM gallery_identity_pairs AS pair
              LEFT JOIN variant_evaluation_revision_projection AS low_projection
                ON low_projection.revision_gid=pair.low_gid
              LEFT JOIN variant_evaluation_revision_projection AS high_projection
                ON high_projection.revision_gid=pair.high_gid
             WHERE COALESCE(low_projection.terminal_gid,pair.low_gid) IN
                       (SELECT gid FROM variant_evaluation_target_member)
                OR COALESCE(high_projection.terminal_gid,pair.high_gid) IN
                       (SELECT gid FROM variant_evaluation_target_member)
            UNION
            SELECT COALESCE(high_projection.terminal_gid,pair.high_gid)
              FROM gallery_identity_pairs AS pair
              LEFT JOIN variant_evaluation_revision_projection AS low_projection
                ON low_projection.revision_gid=pair.low_gid
              LEFT JOIN variant_evaluation_revision_projection AS high_projection
                ON high_projection.revision_gid=pair.high_gid
             WHERE COALESCE(low_projection.terminal_gid,pair.low_gid) IN
                       (SELECT gid FROM variant_evaluation_target_member)
                OR COALESCE(high_projection.terminal_gid,pair.high_gid) IN
                       (SELECT gid FROM variant_evaluation_target_member))
          AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                       WHERE terminal.gid=member.gid);
     CREATE TEMP TABLE variant_evaluation_class_member AS
       SELECT selected.gid,selected.class_gid,
              selected.active_group_id,selected.class_size
         FROM (
           SELECT member.gid,
                  MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
                  member.group_id AS active_group_id,
                  COUNT(*) OVER (PARTITION BY member.group_id) AS class_size,
                  ROW_NUMBER() OVER (
                    PARTITION BY member.gid ORDER BY grouped.id) AS gid_rank
             FROM gallery_variants AS member
             JOIN variant_groups AS grouped
               ON grouped.id=member.group_id AND grouped.identity_active=1
             JOIN variant_evaluation_related_group AS related
               ON related.group_id=member.group_id
            WHERE member.membership_state='confirmed'
              AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                           WHERE terminal.gid=member.gid)
         ) AS selected
        WHERE selected.gid_rank=1;
     CREATE TEMP TABLE variant_evaluation_target_class(class_gid INTEGER);
     INSERT INTO variant_evaluation_target_class(class_gid)
       SELECT MIN(class_gid)
         FROM variant_evaluation_class_member
        WHERE gid IN (SELECT gid FROM variant_evaluation_target_member);
     CREATE TEMP TABLE variant_evaluation_class_pair(
       low_class_gid INTEGER NOT NULL,
       high_class_gid INTEGER NOT NULL,
       supporting_review_id INTEGER NOT NULL,
       PRIMARY KEY(low_class_gid,high_class_gid));
     INSERT INTO variant_evaluation_class_pair(
       low_class_gid,high_class_gid,supporting_review_id)
       SELECT MIN(low_class.class_gid,high_class.class_gid),
              MAX(low_class.class_gid,high_class.class_gid),
              MIN(pair.current_review_id)
         FROM gallery_identity_pairs AS pair
         JOIN variant_reviews AS support ON support.id=pair.current_review_id
         LEFT JOIN variant_evaluation_revision_projection AS low_projection
           ON low_projection.revision_gid=pair.low_gid
         LEFT JOIN variant_evaluation_revision_projection AS high_projection
           ON high_projection.revision_gid=pair.high_gid
         LEFT JOIN variant_evaluation_class_member AS low_class
           ON low_class.gid=COALESCE(low_projection.terminal_gid,pair.low_gid)
         LEFT JOIN variant_evaluation_class_member AS high_class
           ON high_class.gid=COALESCE(high_projection.terminal_gid,pair.high_gid)
        WHERE support.status='resolved' AND support.decision='different_book'
          AND low_class.class_gid IS NOT NULL
          AND high_class.class_gid IS NOT NULL
          AND low_class.class_gid<>high_class.class_gid
          AND NOT (low_projection.component_gid IS NOT NULL
                   AND low_projection.component_gid=high_projection.component_gid)
          AND (low_class.class_gid=(SELECT class_gid FROM variant_evaluation_target_class)
            OR high_class.class_gid=(SELECT class_gid FROM variant_evaluation_target_class))
        GROUP BY 1,2;
     CREATE TEMP TABLE variant_evaluation_pending_candidate AS
       WITH base AS (
         SELECT review.id AS review_id, review.group_id,
                owner.source_gid, review.candidate_gid,
                COALESCE(source_class.class_gid,source_projection.terminal_gid,owner.source_gid)
                  AS source_class_gid,
                COALESCE(candidate_class.class_gid,candidate_projection.terminal_gid,review.candidate_gid)
                  AS candidate_class_gid,
                COALESCE(source_class.class_size,1) AS source_class_size,
                COALESCE(candidate_class.class_size,1) AS candidate_class_size,
                CASE WHEN owner.identity_active=1 THEN 1 ELSE 0 END AS owner_is_active,
                CASE WHEN EXISTS (
                       SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                        WHERE terminal.gid=owner.source_gid)
                       AND EXISTS (
                       SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                        WHERE terminal.gid=review.candidate_gid)
                     THEN 1 ELSE 0 END AS is_visible,
                review.superseded_at
           FROM variant_reviews AS review
           JOIN variant_groups AS owner ON owner.id=review.group_id
           LEFT JOIN variant_evaluation_revision_projection AS source_projection
             ON source_projection.revision_gid=owner.source_gid
           LEFT JOIN variant_evaluation_revision_projection AS candidate_projection
             ON candidate_projection.revision_gid=review.candidate_gid
           LEFT JOIN variant_evaluation_class_member AS source_class
             ON source_class.gid=COALESCE(source_projection.terminal_gid,owner.source_gid)
           LEFT JOIN variant_evaluation_class_member AS candidate_class
             ON candidate_class.gid=COALESCE(candidate_projection.terminal_gid,review.candidate_gid)
          WHERE review.review_type='candidate_identity'
            AND review.status='pending'
            AND (review.group_id=:group_id
              OR source_class.gid IS NOT NULL
              OR candidate_class.gid IS NOT NULL
              OR EXISTS (
                   SELECT 1 FROM gallery_variants AS reviewed_member
                   LEFT JOIN variant_evaluation_revision_projection AS reviewed_projection
                     ON reviewed_projection.revision_gid=reviewed_member.gid
                    WHERE reviewed_member.group_id=review.group_id
                      AND reviewed_member.membership_state='confirmed'
                      AND COALESCE(reviewed_projection.terminal_gid,reviewed_member.gid)
                            IN (SELECT gid FROM variant_evaluation_class_member)))
       ), classified AS (
         SELECT base.*,
                MIN(base.source_class_gid,base.candidate_class_gid) AS low_class_gid,
                MAX(base.source_class_gid,base.candidate_class_gid) AS high_class_gid,
                CASE
                  WHEN base.source_class_gid=base.candidate_class_gid THEN 'same_book'
                  WHEN pair.supporting_review_id IS NOT NULL THEN 'different_book'
                  ELSE NULL END AS implied_decision,
                pair.supporting_review_id
           FROM base
           LEFT JOIN variant_evaluation_class_pair AS pair
             ON pair.low_class_gid=MIN(base.source_class_gid,base.candidate_class_gid)
            AND pair.high_class_gid=MAX(base.source_class_gid,base.candidate_class_gid)
       )
       SELECT classified.*,
              CASE WHEN classified.implied_decision IS NULL
                         AND classified.is_visible=1
                   THEN ROW_NUMBER() OVER (
                     PARTITION BY classified.low_class_gid,classified.high_class_gid
                     ORDER BY classified.is_visible DESC,
                              classified.owner_is_active DESC,classified.review_id)
                   END AS rank
         FROM classified;
     CREATE TEMP TABLE variant_evaluation_actionable_review AS
       SELECT pending.review_id,pending.low_class_gid,pending.high_class_gid
         FROM variant_evaluation_pending_candidate AS pending
        WHERE pending.implied_decision IS NULL
          AND pending.is_visible=1
          AND pending.rank=1
          AND pending.superseded_at IS NULL
          AND (pending.low_class_gid=(SELECT class_gid FROM variant_evaluation_target_class)
            OR pending.high_class_gid=(SELECT class_gid FROM variant_evaluation_target_class));
     CREATE TEMP TABLE variant_manual_decision_context(
       decision_id INTEGER PRIMARY KEY,
       canonical_gid INTEGER NOT NULL,
       member_fingerprint TEXT NOT NULL,
       invalid_reason TEXT
     );
     INSERT INTO variant_manual_decision_context(
       decision_id, canonical_gid, member_fingerprint, invalid_reason)
       SELECT decision.id, decision.canonical_gid,
              (SELECT json_group_array(gid) FROM (
                 SELECT gid FROM gallery_variants
                  WHERE group_id=:group_id AND membership_state='confirmed'
                  ORDER BY gid
               )),
              CASE
                WHEN NOT EXISTS (
                  SELECT 1 FROM gallery_variants AS selected
                   WHERE selected.group_id=:group_id
                     AND selected.gid=decision.canonical_gid
                     AND selected.membership_state='confirmed'
                ) THEN 'selected_member_removed'
                WHEN decision.member_fingerprint <> (SELECT json_group_array(gid) FROM (
                       SELECT gid FROM gallery_variants
                        WHERE group_id=:group_id AND membership_state='confirmed'
                        ORDER BY gid
                     )) THEN 'member_set_changed'
                ELSE NULL
              END
         FROM variant_canonical_decisions AS decision
        WHERE decision.group_id=:group_id AND decision.status='active'
          AND (:expected_evaluation_id=0 OR
               COALESCE((SELECT active_evaluation_id FROM variant_groups WHERE id=:group_id),0)
                 = :expected_evaluation_id);
     CREATE TEMP TABLE variant_evaluation_context(
       evaluation_id INTEGER, score_json TEXT NOT NULL CHECK(json_valid(score_json))
     );
     CREATE TEMP TABLE variant_evaluation_guard(
       singleton INTEGER NOT NULL CHECK(singleton=1)
     );
     INSERT INTO variant_evaluation_context(score_json)
       SELECT json_set(
                :score_json,
                '$.canonical_gid',
                COALESCE((SELECT canonical_gid FROM variant_manual_decision_context
                           WHERE invalid_reason IS NULL),
                         json_extract(:score_json, '$.canonical_gid')),
                '$.tied_gids',
                CASE WHEN EXISTS (SELECT 1 FROM variant_manual_decision_context
                                    WHERE invalid_reason IS NULL)
                     THEN json_array((SELECT canonical_gid
                                        FROM variant_manual_decision_context
                                       WHERE invalid_reason IS NULL))
                     ELSE json_extract(:score_json, '$.tied_gids') END)
        WHERE json_extract(:score_json, '$.policy_revision_id') =
              (SELECT id FROM variant_policy_revisions WHERE is_active=1)
          AND EXISTS (
            SELECT 1 FROM variant_groups AS target
             WHERE target.id=:group_id
               AND target.source_gid=:expected_source_gid
               AND target.desired_rating=11
               AND target.is_active=1
               AND target.identity_active=1
               AND target.review_state='none')
          AND NOT EXISTS (SELECT 1 FROM variant_evaluation_actionable_review)
          AND NOT EXISTS (
            SELECT 1
              FROM variant_reviews AS winner
              JOIN variant_groups AS target ON target.id=winner.group_id
             WHERE winner.group_id=:group_id
               AND winner.review_type='winner'
               AND winner.status='pending'
               AND winner.superseded_at IS NULL
               AND target.desired_rating=11
               AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                            WHERE terminal.gid=target.source_gid))
          AND (SELECT count(*) FROM gallery_variants
                WHERE group_id=:group_id AND membership_state='confirmed') =
                json_array_length(:score_json, '$.scoring_snapshot')
          AND (:expected_evaluation_id=0 OR
               COALESCE((SELECT active_evaluation_id FROM variant_groups WHERE id=:group_id),0)
                 = :expected_evaluation_id)
          AND NOT EXISTS (
            SELECT 1 FROM gallery_variants AS member
             JOIN galleries AS gallery ON gallery.gid = member.gid
             JOIN variant_evaluation_revision_projection AS revision_projection
               ON revision_projection.revision_gid = member.gid
              AND revision_projection.ready = 1
             JOIN variant_evaluation_scoreable_revision_terminals AS scoreable_terminal
               ON scoreable_terminal.gid = member.gid
             WHERE member.group_id=:group_id AND member.membership_state='confirmed'
               AND NOT EXISTS (
                 SELECT 1 FROM json_each(:score_json, '$.scoring_snapshot') AS snap
                 WHERE json_extract(snap.value, '$.gid')=member.gid
                   AND json_extract(snap.value, '$.title') IS gallery.title
                   AND json_extract(snap.value, '$.title_jpn') IS gallery.title_jpn
                   AND json_extract(snap.value, '$.tags') IS json(CASE WHEN json_valid(gallery.tags)
                                                                      THEN gallery.tags ELSE '[]' END)
                   AND json_extract(snap.value, '$.filecount') IS gallery.file_count
                   AND json_extract(snap.value, '$.posted') IS gallery.posted
                   AND json_extract(snap.value, '$.favorite_count') IS gallery.favorite_count
                   AND json_extract(snap.value, '$.rating') IS gallery.rating
                   AND json_extract(snap.value, '$.rating_count') IS gallery.rating_count
                   AND json_extract(snap.value, '$.first_gid') IS gallery.first_gid
                   AND json_extract(snap.value, '$.first_token') IS gallery.first_token
                   AND json_extract(snap.value, '$.parent_gid') IS gallery.parent_gid
                   AND json_extract(snap.value, '$.parent_token') IS gallery.parent_token
                   AND json_extract(snap.value, '$.current_gid') IS gallery.current_gid
                   AND json_extract(snap.value, '$.current_token') IS gallery.current_token
                   AND json_extract(snap.value, '$.expunged') IS gallery.expunged
                   AND json_extract(snap.value, '$.uploader_revision.terminal_gid')
                         IS revision_projection.terminal_gid
                   AND json_extract(snap.value, '$.uploader_revision.component_gid')
                         IS revision_projection.component_gid
                   AND json_array_length(json_extract(
                         snap.value, '$.uploader_revision.component_gids')) =
                       json_array_length(json(revision_projection.component_gids))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json_extract(
                       snap.value, '$.uploader_revision.component_gids')) AS snap_gid
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json(revision_projection.component_gids)) AS live_gid
                         WHERE live_gid.value IS snap_gid.value))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json(revision_projection.component_gids)) AS live_gid
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(
                          snap.value, '$.uploader_revision.component_gids')) AS snap_gid
                         WHERE snap_gid.value IS live_gid.value))
                   AND json_array_length(json_extract(
                         snap.value, '$.uploader_revision.edge_provenance')) =
                       json_array_length(json(revision_projection.edge_provenance))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json_extract(
                       snap.value, '$.uploader_revision.edge_provenance')) AS snap_edge
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json(revision_projection.edge_provenance)) AS live_edge
                         WHERE json_extract(snap_edge.value, '$.from_gid') IS
                               json_extract(live_edge.value, '$.from_gid')
                           AND json_extract(snap_edge.value, '$.to_gid') IS
                               json_extract(live_edge.value, '$.to_gid')
                           AND json_extract(snap_edge.value, '$.relation') IS
                               json_extract(live_edge.value, '$.relation')))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json(revision_projection.edge_provenance)) AS live_edge
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(
                          snap.value, '$.uploader_revision.edge_provenance')) AS snap_edge
                         WHERE json_extract(snap_edge.value, '$.from_gid') IS
                               json_extract(live_edge.value, '$.from_gid')
                           AND json_extract(snap_edge.value, '$.to_gid') IS
                               json_extract(live_edge.value, '$.to_gid')
                           AND json_extract(snap_edge.value, '$.relation') IS
                               json_extract(live_edge.value, '$.relation')))
                   -- Compare the provenance fingerprint by value rather than
                   -- comparing JSON object text.  The scorer emits sorted
                   -- keys (jq -S), while SQLite's json_object preserves the
                   -- construction order; both representations are equivalent
                   -- but their raw text is intentionally different.
                   AND json_extract(snap.value,
                                    '$.uploader_revision_fingerprint.terminal_gid')
                         IS revision_projection.terminal_gid
                   AND json_extract(snap.value,
                                    '$.uploader_revision_fingerprint.component_gid')
                         IS revision_projection.component_gid
                   AND json_array_length(json_extract(
                         snap.value, '$.uploader_revision_fingerprint.component_gids')) =
                       json_array_length(json(revision_projection.component_gids))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json_extract(
                       snap.value, '$.uploader_revision_fingerprint.component_gids')) AS snap_gid
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json(revision_projection.component_gids)) AS live_gid
                         WHERE live_gid.value IS snap_gid.value))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json(revision_projection.component_gids)) AS live_gid
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(
                          snap.value, '$.uploader_revision_fingerprint.component_gids')) AS snap_gid
                         WHERE snap_gid.value IS live_gid.value))
                   AND json_array_length(json_extract(
                         snap.value, '$.uploader_revision_fingerprint.edge_provenance')) =
                       json_array_length(json(revision_projection.edge_provenance))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json_extract(
                       snap.value, '$.uploader_revision_fingerprint.edge_provenance')) AS snap_edge
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json(revision_projection.edge_provenance)) AS live_edge
                         WHERE json_extract(snap_edge.value, '$.from_gid') IS
                               json_extract(live_edge.value, '$.from_gid')
                           AND json_extract(snap_edge.value, '$.to_gid') IS
                               json_extract(live_edge.value, '$.to_gid')
                           AND json_extract(snap_edge.value, '$.relation') IS
                               json_extract(live_edge.value, '$.relation')))
                   AND NOT EXISTS (
                     SELECT 1 FROM json_each(json(revision_projection.edge_provenance)) AS live_edge
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(
                          snap.value, '$.uploader_revision_fingerprint.edge_provenance')) AS snap_edge
                         WHERE json_extract(snap_edge.value, '$.from_gid') IS
                               json_extract(live_edge.value, '$.from_gid')
                           AND json_extract(snap_edge.value, '$.relation') IS
                               json_extract(live_edge.value, '$.relation')
                           AND json_extract(snap_edge.value, '$.to_gid') IS
                               json_extract(live_edge.value, '$.to_gid')))));
     INSERT INTO variant_evaluation_guard(singleton)
       SELECT 1
        WHERE (SELECT count(*) FROM variant_evaluation_context)=1;
     UPDATE variant_canonical_decisions
        SET status='superseded',
            superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            supersede_reason=(SELECT invalid_reason
                                FROM variant_manual_decision_context
                               WHERE decision_id=variant_canonical_decisions.id)
      WHERE id IN (SELECT decision_id FROM variant_manual_decision_context
                    WHERE invalid_reason IS NOT NULL)
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     INSERT INTO variant_evaluations(
       group_id, policy_revision_id, supersedes_evaluation_id, state,
       metadata_snapshot_json, member_scores_json, canonical_gid,
       tied_gids_json, canonical_decision_id)
       SELECT :group_id, json_extract(score_json, '$.policy_revision_id'),
            (SELECT active_evaluation_id FROM variant_groups WHERE id=:group_id),
            CASE WHEN json_array_length(score_json, '$.tied_gids')=1 THEN 'completed' ELSE 'review_blocked' END,
            json_extract(score_json, '$.scoring_snapshot'),
            json_extract(score_json, '$.member_scores'),
            json_extract(score_json, '$.canonical_gid'),
            CASE WHEN json_array_length(score_json, '$.tied_gids')=1 THEN NULL
                 ELSE json_extract(score_json, '$.tied_gids') END,
            (SELECT decision_id FROM variant_manual_decision_context
              WHERE invalid_reason IS NULL)
       FROM variant_evaluation_context
      WHERE EXISTS (SELECT 1 FROM variant_evaluation_guard);
     UPDATE variant_evaluation_context SET evaluation_id=last_insert_rowid();
     UPDATE gallery_variants
        SET variant_score=(SELECT json_extract(item.value, '$.score')
                             FROM variant_evaluation_context, json_each(score_json, '$.member_scores') AS item
                            WHERE json_extract(item.value, '$.gid')=gallery_variants.gid),
            variant_state='undetermined', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=:group_id AND membership_state='confirmed'
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     UPDATE gallery_variants SET variant_state='alternate'
      WHERE group_id=:group_id AND membership_state='confirmed'
        AND (SELECT json_extract(score_json, '$.canonical_gid')
               FROM variant_evaluation_context) IS NOT NULL
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     UPDATE gallery_variants SET variant_state='canonical'
      WHERE group_id=:group_id AND gid=(SELECT json_extract(score_json, '$.canonical_gid')
                                         FROM variant_evaluation_context)
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     UPDATE variant_groups
        SET active_evaluation_id=(SELECT evaluation_id FROM variant_evaluation_context),
            canonical_gid=(SELECT json_extract(score_json, '$.canonical_gid') FROM variant_evaluation_context),
            last_evaluated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:group_id
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     INSERT INTO variant_reviews(review_type, group_id, evaluation_id, policy_revision_id,
                                 evidence_json, choices_json)
       SELECT 'winner', :group_id, evaluation_id,
              json_extract(score_json, '$.policy_revision_id'),
              json_object('top_score', json_extract(score_json, '$.top_score'),
                          'runner_up_score', json_extract(score_json, '$.winner_review.runner_up_score'),
                          'score_gap', json_extract(score_json, '$.winner_review.score_gap'),
                          'reason', json_extract(score_json, '$.winner_review.reason')),
              json_extract(score_json, '$.tied_gids')
         FROM variant_evaluation_context
        WHERE json_extract(score_json, '$.canonical_gid') IS NULL
          AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     UPDATE variant_groups
        SET review_state=CASE WHEN EXISTS (
              SELECT 1 FROM variant_reviews AS winner
               WHERE winner.group_id=:group_id
                 AND winner.review_type='winner'
                 AND winner.status='pending'
                 AND winner.superseded_at IS NULL
                 AND EXISTS (SELECT 1 FROM variant_evaluation_scoreable_revision_terminals AS terminal
                              WHERE terminal.gid=variant_groups.source_gid)
            ) THEN 'winner_pending' ELSE 'none' END
      WHERE id=:group_id
        AND EXISTS (SELECT 1 FROM variant_evaluation_guard);
     SELECT json_object('blocked_reason','candidate_review_pending','evaluated',json('false'))
       WHERE EXISTS (SELECT 1 FROM variant_evaluation_actionable_review)
     UNION ALL
     SELECT json_object('evaluated', json('true'), 'evaluation_id', evaluation_id,
                        'policy_revision_id', json_extract(score_json, '$.policy_revision_id'),
                        'state', CASE WHEN json_extract(score_json, '$.canonical_gid') IS NULL
                                      THEN 'review_blocked' ELSE 'completed' END,
                        'canonical_gid', json_extract(score_json, '$.canonical_gid'),
                        'canonical_decision_id', (SELECT decision_id
                                                   FROM variant_manual_decision_context
                                                  WHERE invalid_reason IS NULL),
                        'selection_source', CASE WHEN EXISTS (
                                                   SELECT 1 FROM variant_manual_decision_context
                                                    WHERE invalid_reason IS NULL)
                                                THEN 'manual' ELSE 'automatic' END,
                        'tied_gids', json_extract(score_json, '$.tied_gids'),
                        'automatic_canonical_gid', json_extract(score_json, '$.automatic_canonical_gid'),
                        'winner_review', json_extract(score_json, '$.winner_review'),
                        'top_score', json_extract(score_json, '$.top_score'),
                        'variant_score_breakdown', json_extract(score_json, '$.member_scores'),
                        'scoring_snapshot', json_extract(score_json, '$.scoring_snapshot'))
       FROM variant_evaluation_context;
     COMMIT;")" || return "${VARIANTS_EVALUATION_CONFIGURATION_STATUS}"
  if [[ -z "${evaluation_result}" ]]; then
    printf '{"evaluated":false,"stale":true,"reason":"authoritative snapshot or policy changed"}\n'
    return "${VARIANTS_EVALUATION_STALE_STATUS}"
  fi
  if [[ "$(jq -r '.blocked_reason // empty' <<<"${evaluation_result}")" == 'candidate_review_pending' ]]; then
    printf '%s\n' "${evaluation_result}"
    return "${VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS}"
  fi
  printf '%s\n' "${evaluation_result}"
}
