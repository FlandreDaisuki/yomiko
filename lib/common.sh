#!/usr/bin/env bash

: "${YOMIKO_CLI_IN_API_MODE:=}"

yomiko_in_api_mode() {
  [[ -n "${YOMIKO_CLI_IN_API_MODE:-}" ]]
}

log() {
  if ! yomiko_in_api_mode; then
    echo "$*"
  fi
}

log_err() {
  log "ERROR: $*" >&2
}

# Convert a memory limit to the KiB unit expected by `ulimit -v`.
# An empty limit succeeds without producing a value.
memory_limit_to_kb() {
  local memory_limit="$1"
  local memory_value memory_unit

  if [[ -z "${memory_limit}" ]]; then
    return 0
  fi

  if [[ ! "${memory_limit}" =~ ^([1-9][0-9]*)(KiB|MiB|GiB)$ ]]; then
    return 1
  fi

  memory_value="${BASH_REMATCH[1]}"
  memory_unit="${BASH_REMATCH[2]}"
  case "${memory_unit}" in
  KiB)
    printf '%s\n' "${memory_value}"
    ;;
  MiB)
    printf '%s\n' "$((memory_value * 1024))"
    ;;
  GiB)
    printf '%s\n' "$((memory_value * 1024 * 1024))"
    ;;
  esac
}

# Emit the target-seeded evaluator revision projection.  The evaluator keeps
# one fixed CTE prefix and target-member seed; callers cannot provide SQL or
# alter the projection shape.
variants_revision_projection_sql() {
  local projection_mode="${1:-evaluation}"
  case "${projection_mode}" in
  evaluation|review) ;;
  *) return 2 ;;
  esac
  cat <<SQL
WITH RECURSIVE
evaluation_projection_mode(mode) AS (
  SELECT '${projection_mode}'
),
review_selected_review(review_id) AS MATERIALIZED (
  SELECT review.id
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id=review.group_id
   WHERE (
          (:status='' AND (
             review.status='resolved'
             OR (review.review_type='candidate_identity' AND review.status='pending')
             OR (review.review_type='winner' AND review.status='pending'
                 AND review.superseded_at IS NULL
                 AND grouped.identity_active=1
                 AND grouped.desired_rating=11)))
       OR (:status='pending' AND review.status='pending'
           AND (review.review_type='candidate_identity'
             OR (review.review_type='winner' AND review.superseded_at IS NULL
                 AND grouped.identity_active=1
                 AND grouped.desired_rating=11)))
       OR (:status='resolved' AND review.status='resolved'))
),
review_seed_gid(gid) AS MATERIALIZED (
  SELECT grouped.source_gid
    FROM review_selected_review AS selected
    JOIN variant_reviews AS review ON review.id=selected.review_id
    JOIN variant_groups AS grouped ON grouped.id=review.group_id
   WHERE grouped.source_gid IS NOT NULL
  UNION
  SELECT review.candidate_gid
    FROM review_selected_review AS selected
    JOIN variant_reviews AS review ON review.id=selected.review_id
   WHERE review.candidate_gid IS NOT NULL
),
review_winner_choice_seed(gid) AS MATERIALIZED (
  SELECT CAST(choice.value AS INTEGER)
    FROM review_selected_review AS selected
    JOIN variant_reviews AS review ON review.id=selected.review_id
    JOIN json_each(review.choices_json) AS choice
   WHERE review.review_type='winner'
     AND json_type(choice.value)='integer'
),
evaluation_preliminary_seed(gid) AS MATERIALIZED (
  SELECT grouped.source_gid
    FROM variant_groups AS grouped
    JOIN evaluation_projection_mode AS mode
   WHERE mode.mode='evaluation'
     AND grouped.id=:group_id
  UNION
  SELECT member.gid
    FROM gallery_variants AS member
    JOIN evaluation_projection_mode AS mode
   WHERE member.group_id=:group_id
     AND member.membership_state='confirmed'
     AND mode.mode='evaluation'
  UNION
  SELECT owner.source_gid
    FROM variant_reviews AS review
    JOIN variant_groups AS owner ON owner.id=review.group_id
    JOIN evaluation_projection_mode AS mode
   WHERE mode.mode='evaluation'
     AND review.group_id=:group_id
     AND review.review_type='winner'
     AND review.status='pending'
     AND review.superseded_at IS NULL
     AND owner.source_gid IS NOT NULL
  UNION
  SELECT CAST(choice.value AS INTEGER)
    FROM variant_reviews AS review
    JOIN json_each(review.choices_json) AS choice
    JOIN evaluation_projection_mode AS mode
   WHERE mode.mode='evaluation'
     AND review.group_id=:group_id
     AND review.review_type='winner'
     AND review.status='pending'
     AND review.superseded_at IS NULL
     AND json_type(choice.value)='integer'
  UNION
  SELECT seed.gid
    FROM review_seed_gid AS seed
    JOIN evaluation_projection_mode AS mode
   WHERE mode.mode='review'
  UNION
  SELECT seed.gid
    FROM review_winner_choice_seed AS seed
    JOIN evaluation_projection_mode AS mode
   WHERE mode.mode='review'
),
evaluation_walk(root_gid,gid,phase) AS MATERIALIZED (
  SELECT seed.gid,seed.gid,0
    FROM evaluation_preliminary_seed AS seed
   WHERE seed.gid IS NOT NULL
  UNION
  SELECT walk.root_gid,target.gid,walk.phase
    FROM evaluation_walk AS walk
    JOIN galleries AS source ON source.gid=walk.gid
    JOIN galleries AS target
      ON target.gid=source.parent_gid
     AND target.token IS source.parent_token
   WHERE source.parent_gid IS NOT NULL
     AND source.parent_token IS NOT NULL
  UNION
  SELECT walk.root_gid,target.gid,walk.phase
    FROM evaluation_walk AS walk
    JOIN galleries AS source ON source.gid=walk.gid
    JOIN galleries AS target
      ON target.gid=source.current_gid
     AND target.token IS source.current_token
   WHERE source.current_gid IS NOT NULL
     AND source.current_token IS NOT NULL
  UNION
  SELECT walk.root_gid,source.gid,walk.phase
    FROM evaluation_walk AS walk
    JOIN galleries AS source ON source.parent_gid=walk.gid
    JOIN galleries AS target
      ON target.gid=walk.gid
     AND target.token IS source.parent_token
   WHERE source.parent_token IS NOT NULL
  UNION
  SELECT walk.root_gid,source.gid,walk.phase
    FROM evaluation_walk AS walk
    JOIN galleries AS source ON source.current_gid=walk.gid
    JOIN galleries AS target
      ON target.gid=walk.gid
     AND target.token IS source.current_token
   WHERE source.current_token IS NOT NULL
SQL
if [[ "${projection_mode}" == evaluation ]]; then
  cat <<SQL
  UNION
  SELECT owner.source_gid,owner.source_gid,1
    FROM evaluation_walk AS walk
    JOIN evaluation_projection_mode AS mode
    JOIN variant_reviews AS review
      ON review.review_type='candidate_identity'
     AND review.status='pending'
    JOIN variant_groups AS owner ON owner.id=review.group_id
   WHERE mode.mode='evaluation'
     AND walk.phase=0
     AND (review.group_id=:group_id
       OR owner.source_gid=walk.gid
       OR review.candidate_gid=walk.gid
       OR EXISTS (
            SELECT 1 FROM gallery_variants AS reviewed_member
             WHERE reviewed_member.group_id=review.group_id
               AND reviewed_member.membership_state='confirmed'
               AND reviewed_member.gid=walk.gid)
       OR EXISTS (
            SELECT 1 FROM gallery_identity_pairs AS pair
             WHERE (pair.low_gid=walk.gid OR pair.high_gid=walk.gid)
               AND (owner.source_gid IN (pair.low_gid,pair.high_gid)
                 OR review.candidate_gid IN (pair.low_gid,pair.high_gid))))
     AND owner.source_gid IS NOT NULL
  UNION
  SELECT review.candidate_gid,review.candidate_gid,1
    FROM evaluation_walk AS walk
    JOIN evaluation_projection_mode AS mode
    JOIN variant_reviews AS review
      ON review.review_type='candidate_identity'
     AND review.status='pending'
   WHERE mode.mode='evaluation'
     AND walk.phase=0
     AND review.candidate_gid IS NOT NULL
     AND (review.group_id=:group_id
       OR EXISTS (
            SELECT 1 FROM variant_groups AS owner
             WHERE owner.id=review.group_id
               AND owner.source_gid=walk.gid)
       OR review.candidate_gid=walk.gid
       OR EXISTS (
            SELECT 1 FROM gallery_variants AS reviewed_member
             WHERE reviewed_member.group_id=review.group_id
               AND reviewed_member.membership_state='confirmed'
               AND reviewed_member.gid=walk.gid)
       OR EXISTS (
            SELECT 1 FROM gallery_identity_pairs AS pair
             WHERE (pair.low_gid=walk.gid OR pair.high_gid=walk.gid)
               AND review.candidate_gid IN (pair.low_gid,pair.high_gid)))
SQL
fi
cat <<SQL
  UNION
  SELECT pair.low_gid,pair.low_gid,1
    FROM evaluation_walk AS walk
    JOIN gallery_identity_pairs AS pair
      ON pair.low_gid=walk.gid OR pair.high_gid=walk.gid
   WHERE walk.phase=0
  UNION
  SELECT pair.high_gid,pair.high_gid,1
    FROM evaluation_walk AS walk
    JOIN gallery_identity_pairs AS pair
      ON pair.low_gid=walk.gid OR pair.high_gid=walk.gid
   WHERE walk.phase=0
  UNION
  SELECT member.gid,member.gid,1
    FROM evaluation_walk AS walk
    JOIN gallery_variants AS endpoint
      ON endpoint.gid=walk.gid
     AND endpoint.membership_state='confirmed'
    JOIN variant_groups AS grouped
      ON grouped.id=endpoint.group_id
     AND grouped.identity_active=1
    JOIN gallery_variants AS member
      ON member.group_id=grouped.id
     AND member.membership_state='confirmed'
   WHERE walk.phase IN (0,1)
),
evaluation_local_node(gid) AS MATERIALIZED (
  SELECT DISTINCT gid FROM evaluation_walk
),
evaluation_component_map(gid,component_gid) AS MATERIALIZED (
  SELECT member.gid,MIN(peer.gid)
    FROM evaluation_walk AS member
    JOIN evaluation_walk AS peer ON peer.root_gid=member.root_gid
   GROUP BY member.gid
),
evaluation_component_member(component_gid,gid) AS (
  SELECT component_gid,gid
    FROM evaluation_component_map
),
evaluation_relation_pairs(source_gid,relation,target_gid,target_token) AS (
  SELECT gallery.gid,'first',gallery.first_gid,gallery.first_token
    FROM evaluation_local_node AS local
    CROSS JOIN galleries AS gallery
   WHERE gallery.gid=local.gid
  UNION ALL
  SELECT gallery.gid,'parent',gallery.parent_gid,gallery.parent_token
    FROM evaluation_local_node AS local
    CROSS JOIN galleries AS gallery
   WHERE gallery.gid=local.gid
  UNION ALL
  SELECT gallery.gid,'current',gallery.current_gid,gallery.current_token
    FROM evaluation_local_node AS local
    CROSS JOIN galleries AS gallery
   WHERE gallery.gid=local.gid
),
evaluation_classified_relation AS (
  SELECT pair.source_gid,pair.relation,pair.target_gid,pair.target_token,
         CASE WHEN pair.target_gid IS NULL AND pair.target_token IS NULL
                   THEN 1
              WHEN pair.target_gid IS NOT NULL AND pair.target_token IS NOT NULL
                   THEN 1 ELSE 0 END AS pair_complete,
         CASE WHEN pair.target_gid IS NULL THEN 1
              WHEN EXISTS (SELECT 1 FROM galleries AS target
                            WHERE target.gid=pair.target_gid)
                   THEN 1 ELSE 0 END AS target_fetched,
         CASE WHEN pair.target_gid IS NULL THEN 1
              WHEN EXISTS (SELECT 1 FROM galleries AS target
                            WHERE target.gid=pair.target_gid
                              AND target.token IS pair.target_token)
                   THEN 1 ELSE 0 END AS token_matched
    FROM evaluation_relation_pairs AS pair
),
evaluation_relation_edges AS (
  SELECT relation.source_gid,relation.relation,relation.target_gid,
         relation.target_token,relation.pair_complete,
         relation.target_fetched,relation.token_matched,
         CASE
           WHEN relation.pair_complete=0 THEN 'relation_conflict'
           WHEN relation.target_gid IS NOT NULL
            AND relation.target_fetched=0 THEN 'reference_incomplete'
           WHEN relation.target_gid IS NOT NULL
            AND relation.token_matched=0 THEN 'token_mismatch'
           ELSE NULL
         END AS blocked_reason,
         CASE
           WHEN relation.pair_complete=1
            AND relation.target_gid IS NOT NULL
            AND relation.target_fetched=1
            AND relation.token_matched=1 THEN 1
           ELSE 0
         END AS is_valid,
         CASE relation.relation
           WHEN 'parent' THEN relation.target_gid
           ELSE relation.source_gid
         END AS from_gid,
         CASE relation.relation
           WHEN 'parent' THEN relation.source_gid
           ELSE relation.target_gid
         END AS to_gid
    FROM evaluation_classified_relation AS relation
   WHERE relation.target_gid IS NOT NULL
      OR relation.target_token IS NOT NULL
),
evaluation_valid_edges AS (
  SELECT from_gid,to_gid,relation
    FROM evaluation_relation_edges
   WHERE is_valid=1 AND relation IN ('parent','current')
),
evaluation_cycle_reach(start_gid,gid) AS (
  SELECT edge.from_gid,edge.to_gid
    FROM evaluation_valid_edges AS edge
   UNION
  SELECT cycle.start_gid,edge.to_gid
    FROM evaluation_cycle_reach AS cycle
    JOIN evaluation_valid_edges AS edge ON edge.from_gid=cycle.gid
),
evaluation_component_stats AS (
  SELECT member.component_gid,
         COUNT(*) AS component_size,
         SUM(CASE WHEN NOT EXISTS (
               SELECT 1 FROM evaluation_valid_edges AS outgoing
                WHERE outgoing.from_gid=member.gid)
                  THEN 1 ELSE 0 END) AS terminal_count,
         MAX(CASE WHEN EXISTS (
               SELECT 1 FROM evaluation_relation_edges AS broken
                WHERE broken.source_gid=member.gid
                  AND broken.blocked_reason IS NOT NULL)
                  THEN 1 ELSE 0 END) AS has_broken_relation,
         MAX(CASE WHEN EXISTS (
               SELECT 1 FROM evaluation_cycle_reach AS cycle
               JOIN evaluation_component_member AS cycle_member
                 ON cycle_member.component_gid=member.component_gid
                AND cycle_member.gid=cycle.start_gid
                WHERE cycle.start_gid=cycle.gid)
                  THEN 1 ELSE 0 END) AS has_cycle,
         MAX(CASE WHEN (
               SELECT COUNT(*) FROM evaluation_relation_edges AS parent_edge
                WHERE parent_edge.relation='parent'
                  AND parent_edge.is_valid=1
                  AND parent_edge.from_gid=member.gid)>1
                  THEN 1 ELSE 0 END) AS has_parent_branch,
         MAX(CASE WHEN (
               SELECT COUNT(*) FROM evaluation_relation_edges AS current_edge
                WHERE current_edge.relation='current'
                  AND current_edge.is_valid=1
                  AND current_edge.from_gid=member.gid)>1
                  THEN 1 ELSE 0 END) AS has_current_branch
    FROM evaluation_component_member AS member
   GROUP BY member.component_gid
),
evaluation_terminal_rows AS (
  SELECT member.component_gid,member.gid AS terminal_gid
    FROM evaluation_component_member AS member
   WHERE NOT EXISTS (
           SELECT 1 FROM evaluation_valid_edges AS outgoing
            WHERE outgoing.from_gid=member.gid)
),
evaluation_terminal_projection AS (
  SELECT component_gid,MIN(terminal_gid) AS terminal_gid
    FROM evaluation_terminal_rows
   GROUP BY component_gid
),
evaluation_first_conflicts AS (
  SELECT member.component_gid
    FROM evaluation_component_member AS member
    JOIN evaluation_component_stats AS stats
      ON stats.component_gid=member.component_gid
    JOIN evaluation_relation_edges AS first_edge
      ON first_edge.source_gid=member.gid
     AND first_edge.relation='first'
     AND first_edge.is_valid=1
    LEFT JOIN evaluation_component_member AS target_member
      ON target_member.component_gid=member.component_gid
     AND target_member.gid=first_edge.target_gid
   WHERE stats.component_size>1
     AND target_member.gid IS NULL
   GROUP BY member.component_gid
),
evaluation_component_classification AS (
  SELECT stats.component_gid,stats.component_size,stats.terminal_count,
         terminal.terminal_gid,
         CASE
           WHEN stats.has_broken_relation=1
            AND EXISTS (SELECT 1
                         FROM evaluation_relation_edges AS edge
                         JOIN evaluation_component_member AS member
                           ON member.component_gid=stats.component_gid
                          AND member.gid=edge.source_gid
                        WHERE edge.blocked_reason='token_mismatch')
             THEN 'token_mismatch'
           WHEN stats.has_broken_relation=1
            AND EXISTS (SELECT 1
                         FROM evaluation_relation_edges AS edge
                         JOIN evaluation_component_member AS member
                           ON member.component_gid=stats.component_gid
                          AND member.gid=edge.source_gid
                        WHERE edge.blocked_reason='reference_incomplete')
             THEN 'reference_incomplete'
           WHEN stats.has_broken_relation=1 THEN 'relation_conflict'
           WHEN stats.has_cycle=1 THEN 'cycle'
           WHEN stats.has_parent_branch=1 THEN 'branch'
           WHEN stats.has_current_branch=1 THEN 'branch'
           WHEN stats.terminal_count<>1 THEN 'multiple_terminals'
           WHEN EXISTS (SELECT 1
                         FROM evaluation_first_conflicts AS conflict
                        WHERE conflict.component_gid=stats.component_gid)
             THEN 'relation_conflict'
           WHEN NOT EXISTS (
             SELECT 1 FROM galleries AS gallery
              WHERE gallery.gid=terminal.terminal_gid
                AND gallery.file_count IS NOT NULL
                AND gallery.favorite_count IS NOT NULL
                AND gallery.rating_count IS NOT NULL
                AND json_valid(gallery.tags)
                AND EXISTS (SELECT 1 FROM json_each(gallery.tags)
                             WHERE value='language:chinese')
                AND EXISTS (SELECT 1 FROM json_each(gallery.tags)
                             WHERE value='other:tankoubon'))
             THEN CASE WHEN EXISTS (
               SELECT 1 FROM galleries AS gallery
                WHERE gallery.gid=terminal.terminal_gid
                  AND (gallery.file_count IS NULL
                    OR gallery.favorite_count IS NULL
                    OR gallery.rating_count IS NULL)
             ) THEN 'scoring_input_incomplete' ELSE 'scope_incomplete' END
           ELSE NULL
         END AS blocked_reason
    FROM evaluation_component_stats AS stats
    LEFT JOIN evaluation_terminal_projection AS terminal
      ON terminal.component_gid=stats.component_gid
),
evaluation_classified_member AS (
  SELECT member.gid,member.component_gid,
         classification.component_size,classification.terminal_gid,
         classification.blocked_reason,
         CASE WHEN classification.blocked_reason IS NULL THEN 1 ELSE 0 END AS ready,
         CASE WHEN member.gid=classification.terminal_gid THEN 1 ELSE 0 END AS is_terminal
    FROM evaluation_component_member AS member
    JOIN evaluation_component_classification AS classification
      ON classification.component_gid=member.component_gid
),
evaluation_revision_projection AS MATERIALIZED (
  SELECT classified.gid AS revision_gid,
         classified.terminal_gid,classified.component_gid,
         classified.component_size,classified.ready,
         classified.is_terminal,classified.blocked_reason,
         (SELECT json_group_array(member.gid)
            FROM evaluation_classified_member AS member
           WHERE member.component_gid=classified.component_gid
           ORDER BY member.gid) AS component_gids,
         (SELECT json_group_array(json_object(
                    'from_gid',ordered_edge.from_gid,
                    'to_gid',ordered_edge.to_gid,
                    'relation',ordered_edge.relation))
            FROM (
              SELECT edge.from_gid,edge.to_gid,edge.relation
                FROM evaluation_relation_edges AS edge
               WHERE edge.is_valid=1
                 AND edge.relation IN ('parent','current')
                 AND (edge.from_gid=classified.gid
                   OR edge.to_gid=classified.gid
                   OR edge.from_gid IN (
                        SELECT member.gid
                          FROM evaluation_classified_member AS member
                         WHERE member.component_gid=classified.component_gid))
               ORDER BY edge.from_gid,edge.to_gid,edge.relation
            ) AS ordered_edge) AS edge_provenance
    FROM evaluation_classified_member AS classified
),
evaluation_scoreable_revision_terminals AS MATERIALIZED (
  SELECT member.revision_gid,member.terminal_gid AS gid,
         member.terminal_gid,member.component_gid,member.component_size,
         member.component_gids,member.edge_provenance,member.is_terminal
   FROM evaluation_revision_projection AS member
   WHERE member.ready=1 AND member.is_terminal=1
),
revision_projection AS MATERIALIZED (
  SELECT revision_gid,terminal_gid,component_gid,component_size,ready,
         is_terminal,blocked_reason,component_gids,edge_provenance
    FROM evaluation_revision_projection
),
scoreable_revision_terminals AS MATERIALIZED (
  SELECT revision_gid,gid,terminal_gid,component_gid,component_size,
         component_gids,edge_provenance,is_terminal
    FROM evaluation_scoreable_revision_terminals
)
SQL
}

# Emit the non-recursive identity/review projection after a caller has
# materialized target-seeded revision_projection and
# scoreable_revision_terminals TEMP views.
variants_review_identity_projection_sql() {
  cat <<SQL
WITH
review_selected_review(review_id) AS MATERIALIZED (
  SELECT review.id
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id=review.group_id
   WHERE (
          (:status='' AND (
             review.status='resolved'
             OR (review.review_type='candidate_identity' AND review.status='pending')
             OR (review.review_type='winner' AND review.status='pending'
                 AND review.superseded_at IS NULL
                 AND grouped.identity_active=1
                 AND grouped.desired_rating=11)))
       OR (:status='pending' AND review.status='pending'
           AND (review.review_type='candidate_identity'
             OR (review.review_type='winner' AND review.status='pending'
                 AND review.superseded_at IS NULL
                 AND grouped.identity_active=1
                 AND grouped.desired_rating=11)))
       OR (:status='resolved' AND review.status='resolved'))
),
identity_active_membership AS MATERIALIZED (
  SELECT member.gid,member.group_id AS active_group_id,
         MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
         COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
    FROM gallery_variants AS member
    JOIN variant_groups AS grouped
      ON grouped.id=member.group_id AND grouped.identity_active=1
   WHERE member.membership_state='confirmed'
     AND EXISTS (SELECT 1 FROM scoreable_revision_terminals AS scoreable
                  WHERE scoreable.gid=member.gid)
),
identity_relevant_gid(gid) AS MATERIALIZED (
  SELECT revision_gid AS gid FROM revision_projection
  UNION
  SELECT gid FROM identity_active_membership
),
identity_gid_class AS MATERIALIZED (
  SELECT relevant.gid,
         COALESCE(active.class_gid,projection.terminal_gid,relevant.gid) AS class_gid,
         active.active_group_id,
         COALESCE(active.class_size,1) AS class_size,
         COALESCE(projection.terminal_gid,relevant.gid) AS terminal_gid
    FROM identity_relevant_gid AS relevant
    LEFT JOIN revision_projection AS projection
      ON projection.revision_gid=relevant.gid
    LEFT JOIN identity_active_membership AS active
      ON active.gid=COALESCE(projection.terminal_gid,relevant.gid)
),
identity_review_visibility AS MATERIALIZED (
  SELECT review.id AS review_id,
         CASE WHEN NOT EXISTS (
                SELECT 1 FROM scoreable_revision_terminals AS scoreable
                 WHERE scoreable.gid=grouped.source_gid)
               OR (review.candidate_gid IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM scoreable_revision_terminals AS scoreable
                 WHERE scoreable.gid=review.candidate_gid))
               OR (review.review_type='winner' AND EXISTS (
                SELECT 1 FROM json_each(review.choices_json) AS choice
                 WHERE json_type(choice.value)<>'integer'
                    OR NOT EXISTS (
                   SELECT 1 FROM scoreable_revision_terminals AS scoreable
                    WHERE scoreable.gid=CAST(choice.value AS INTEGER))))
              THEN 0 ELSE 1 END AS is_visible
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id=review.group_id
   WHERE review.id IN (SELECT review_id FROM review_selected_review)
),
identity_class_pair AS MATERIALIZED (
  SELECT MIN(low_class.class_gid,high_class.class_gid) AS low_class_gid,
         MAX(low_class.class_gid,high_class.class_gid) AS high_class_gid,
         'different_book' AS decision,
         MIN(pair.current_review_id) AS supporting_review_id
    FROM gallery_identity_pairs AS pair
    JOIN variant_reviews AS review ON review.id=pair.current_review_id
    JOIN identity_gid_class AS low_class ON low_class.gid=pair.low_gid
    JOIN identity_gid_class AS high_class ON high_class.gid=pair.high_gid
    LEFT JOIN revision_projection AS low_projection
      ON low_projection.revision_gid=pair.low_gid
    LEFT JOIN revision_projection AS high_projection
      ON high_projection.revision_gid=pair.high_gid
   WHERE review.status='resolved' AND review.decision='different_book'
     AND low_class.class_gid<>high_class.class_gid
     AND NOT (low_projection.component_gid IS NOT NULL
              AND low_projection.component_gid=high_projection.component_gid)
   GROUP BY 1,2
),
identity_pending_candidate AS MATERIALIZED (
  SELECT classified.*,
         CASE WHEN classified.implied_decision IS NULL
                    AND classified.is_visible=1 THEN
           ROW_NUMBER() OVER (
             PARTITION BY classified.low_class_gid,classified.high_class_gid
             ORDER BY classified.is_visible DESC,
                      classified.owner_is_active DESC,classified.review_id)
         END AS rank
    FROM (
      SELECT review.id AS review_id,review.group_id,
             grouped.source_gid,review.candidate_gid,
             MIN(source_class.class_gid,candidate_class.class_gid) AS low_class_gid,
             MAX(source_class.class_gid,candidate_class.class_gid) AS high_class_gid,
             source_class.class_size AS source_class_size,
             candidate_class.class_size AS candidate_class_size,
             CASE WHEN owner.identity_active=1 THEN 1 ELSE 0 END AS owner_is_active,
             visibility.is_visible,review.superseded_at,
             CASE WHEN source_class.class_gid=candidate_class.class_gid
                    THEN 'same_book'
                  WHEN class_pair.decision='different_book'
                    THEN 'different_book'
                  ELSE NULL END AS implied_decision,
             CASE WHEN source_class.class_gid=candidate_class.class_gid THEN (
               SELECT MIN(same_pair.current_review_id)
                 FROM gallery_identity_pairs AS same_pair
                 JOIN variant_reviews AS support
                   ON support.id=same_pair.current_review_id
                 JOIN identity_gid_class AS support_low
                   ON support_low.gid=same_pair.low_gid
                 JOIN identity_gid_class AS support_high
                   ON support_high.gid=same_pair.high_gid
                WHERE support.decision='same_book'
                  AND support_low.class_gid=source_class.class_gid
                  AND support_high.class_gid=source_class.class_gid)
                  ELSE class_pair.supporting_review_id END AS supporting_review_id
        FROM variant_reviews AS review
        JOIN review_selected_review AS selected
          ON selected.review_id=review.id
        JOIN variant_groups AS grouped ON grouped.id=review.group_id
        JOIN variant_groups AS owner ON owner.id=review.group_id
        JOIN identity_gid_class AS source_class
          ON source_class.gid=grouped.source_gid
        JOIN identity_gid_class AS candidate_class
          ON candidate_class.gid=review.candidate_gid
        JOIN identity_review_visibility AS visibility
          ON visibility.review_id=review.id
        LEFT JOIN identity_class_pair AS class_pair
          ON class_pair.low_class_gid=MIN(source_class.class_gid,candidate_class.class_gid)
         AND class_pair.high_class_gid=MAX(source_class.class_gid,candidate_class.class_gid)
       WHERE review.review_type='candidate_identity'
         AND review.status='pending'
    ) AS classified
),
identity_actionable_review AS MATERIALIZED (
  SELECT review_id,low_class_gid,high_class_gid
    FROM identity_pending_candidate
   WHERE implied_decision IS NULL AND is_visible=1 AND rank=1
     AND superseded_at IS NULL
)
SELECT 'visibility',review_id,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       is_visible,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
  FROM identity_review_visibility
UNION ALL
SELECT 'pending',review_id,group_id,source_gid,candidate_gid,low_class_gid,
       high_class_gid,source_class_size,candidate_class_size,owner_is_active,
       is_visible,superseded_at,implied_decision,supporting_review_id,rank,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
  FROM identity_pending_candidate
UNION ALL
SELECT 'actionable',review_id,NULL,NULL,NULL,low_class_gid,high_class_gid,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
  FROM identity_actionable_review
SQL
}
