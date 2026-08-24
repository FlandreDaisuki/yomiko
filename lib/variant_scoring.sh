#!/usr/bin/env bash

# Deterministic, local-only variant scoring. Source after lib/db.sh (and,
# when available, lib/variant_policy.sh). Runtime dependencies: jq, python3.

VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS=4

variants_score_members_json() {
  # Input is one JSON object: {policy:{...expanded policy...},members:[...]},
  # where every member has gid, metadata, and metadata_raw.
  python3 -c '
import json, sys, unicodedata
from decimal import Decimal, ROUND_FLOOR

data = json.load(sys.stdin)
scoring = data["policy"]["scoring"]
tag_scores = scoring["tag_scores"]
title_scores = scoring["title_substring_scores"]
posted = scoring["posted_rank"]
favorite = scoring["favorite_popularity"]
rating_conf = scoring["rating_confidence"]
winner_review_gap = int(scoring["winner_review_score_gap_exclusive"])

def folded(value):
    return unicodedata.normalize("NFKC", value or "").casefold()

members = sorted(data["members"], key=lambda item: int(item["gid"]))
distinct_posted = sorted({m["metadata"].get("posted") for m in members
                          if m["metadata"].get("posted") is not None})
posted_ranks = {value: index + int(posted["oldest_rank"])
                for index, value in enumerate(distinct_posted)}
scores = []
snapshots = []
for member in members:
    gid = int(member["gid"])
    meta = member["metadata"]
    if not isinstance(meta, dict):
        raise ValueError("member metadata snapshot must be an object")
    tags = meta.get("tags")
    tags = [] if tags is None else tags
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise ValueError("metadata tags must be a string array or null")
    title = meta.get("title")
    title_jpn = meta.get("title_jpn")
    norm_title, norm_jpn = folded(title), folded(title_jpn)

    tag_matches = [{"tag": tag, "points": points} for tag, points in tag_scores.items()
                   if tag in tags]
    title_matches = []
    for substring, points in title_scores.items():
        needle = folded(substring)
        fields = []
        if needle in norm_title: fields.append("title")
        if needle in norm_jpn: fields.append("title_jpn")
        if fields:
            title_matches.append({"substring": substring,
                                  "normalized_substring": needle,
                                  "matched_fields": fields, "points": points})
    tag_points = sum(match["points"] for match in tag_matches)
    title_points = sum(match["points"] for match in title_matches)

    raw_posted = meta.get("posted")
    rank = posted_ranks.get(raw_posted)
    posted_points = 0 if rank is None else rank * int(posted["step"])

    favorite_count = meta.get("favorite_count")
    favorite_points = int(favorite["missing_count_points"])
    if favorite_count is not None:
        favorite_points = min(int(favorite["cap"]),
                              int(favorite_count) // int(favorite["divisor"]))

    rating = meta.get("rating")
    rating_count = meta.get("rating_count")
    rating_points = int(rating_conf["missing_count_points"])
    if rating_count is not None:
        raw = (Decimal(str(0 if rating is None else rating)) -
               Decimal(str(rating_conf["rating_baseline"])))
        raw *= Decimal(int(rating_count))
        raw /= Decimal(str(rating_conf["count_divisor"]))
        raw = max(Decimal(str(rating_conf["minimum"])), raw)
        raw = min(Decimal(str(rating_conf["cap"])), raw)
        rating_points = int(raw.to_integral_value(rounding=ROUND_FLOOR))

    total = tag_points + title_points + posted_points + favorite_points + rating_points
    raw = {key: meta.get(key) for key in
           ("title", "title_jpn", "tags", "posted", "favorite_count", "rating",
            "rating_count", "popularity_fetched_at", "expunged")}
    breakdown = {
        "gid": gid, "raw": raw,
        "normalization": {"form": "NFKC_Casefold", "title": norm_title,
                          "title_jpn": norm_jpn},
        "components": {
            "exact_tags": {"matches": tag_matches, "subtotal": tag_points},
            "title_substrings": {"matches": title_matches, "subtotal": title_points},
            "posted_rank": {"raw_posted": raw_posted, "rank": rank,
                            "step": int(posted["step"]), "points": posted_points},
            "favorite_popularity": {"raw_count": favorite_count,
                "formula": "floor(min(favorite_count/divisor,cap))",
                "divisor": int(favorite["divisor"]), "cap": int(favorite["cap"]),
                "points": favorite_points},
            "rating_confidence": {"raw_rating": rating, "raw_count": rating_count,
                "formula": "floor(min(max((rating-baseline)*count/divisor,minimum),cap))",
                "baseline": rating_conf["rating_baseline"],
                "divisor": rating_conf["count_divisor"], "minimum": rating_conf["minimum"],
                "cap": rating_conf["cap"], "points": rating_points},
            "expunged": {"raw": meta.get("expunged"),
                         "points": int(scoring["expunged_adjustment"])}},
        "score": total}
    scores.append(breakdown)
    snapshots.append({"gid": gid, "metadata": meta,
                      "metadata_raw": member["metadata_raw"]})

if not scores:
    raise ValueError("variant group has no confirmed members")
top = max(item["score"] for item in scores)
ranked = sorted(scores, key=lambda item: (-item["score"], item["gid"]))
runner_up_score = ranked[1]["score"] if len(ranked) > 1 else None
score_gap = top - runner_up_score if runner_up_score is not None else None
review_gids = [item["gid"] for item in ranked
               if top - item["score"] < winner_review_gap]
review_reason = None
if len(review_gids) > 1:
    review_reason = "exact_tie" if score_gap == 0 else "near_tie"
print(json.dumps({"metadata_snapshot": snapshots, "member_scores": scores,
                  "top_score": top, "tied_gids": review_gids,
                  "selected_canonical_gid": review_gids[0] if len(review_gids) == 1 else None,
                  "winner_review": {
                      "score_gap_exclusive": winner_review_gap,
                      "runner_up_score": runner_up_score,
                      "score_gap": score_gap,
                      "reason": review_reason,
                      "choices": review_gids}},
                 ensure_ascii=False, sort_keys=True, separators=(",", ":")))
'
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
