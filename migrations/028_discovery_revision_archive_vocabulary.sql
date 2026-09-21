-- Canonicalize the discovery, revision, and archive vocabulary after schema 27.
--
-- These views are internal current projections, so old names are removed rather
-- than retained as aliases. Historical migrations remain unchanged. The archive
-- source mapping is intentionally nullable: a NULL archive_gid means that no
-- committed local archive is safe for the scoreable terminal yet.

DROP VIEW IF EXISTS variant_identity_group_review_state;
DROP VIEW IF EXISTS variant_identity_actionable_review;
DROP VIEW IF EXISTS variant_identity_pending_candidate;
DROP VIEW IF EXISTS variant_identity_class_pair;
DROP VIEW IF EXISTS variant_identity_gid_class;
DROP VIEW IF EXISTS variant_identity_active_membership;
DROP VIEW IF EXISTS variant_identity_review_visibility;
DROP VIEW IF EXISTS archive_source_galleries;
DROP VIEW IF EXISTS available_galleries;
DROP VIEW IF EXISTS scoreable_revision_terminals;
DROP VIEW IF EXISTS eligible_galleries;
DROP VIEW IF EXISTS current_revision_projection;
DROP VIEW IF EXISTS uploader_revision_representatives;
DROP VIEW IF EXISTS revision_members;
DROP VIEW IF EXISTS uploader_revision_members;

CREATE VIEW revision_members AS
WITH RECURSIVE
valid_edges AS (
    SELECT from_gid, to_gid, relation
      FROM uploader_revision_edges
     WHERE is_valid = 1 AND relation IN ('parent', 'current')
),
undirected(from_gid, to_gid) AS (
    SELECT from_gid, to_gid FROM valid_edges
    UNION ALL
    SELECT to_gid, from_gid FROM valid_edges
),
walk(root_gid, gid) AS (
    SELECT gallery.gid, gallery.gid FROM galleries AS gallery
    UNION
    SELECT walk.root_gid, edge.to_gid
      FROM walk
      JOIN undirected AS edge ON edge.from_gid = walk.gid
),
component_map AS (
    SELECT gid, MIN(root_gid) AS component_gid
      FROM walk
     GROUP BY gid
),
component_members AS (
    SELECT map.component_gid, map.gid
      FROM component_map AS map
),
cycle_reach(start_gid, gid) AS (
    SELECT from_gid, to_gid FROM valid_edges
    UNION
    SELECT cycle.start_gid, edge.to_gid
      FROM cycle_reach AS cycle
      JOIN valid_edges AS edge ON edge.from_gid = cycle.gid
),
component_stats AS (
    SELECT members.component_gid,
           COUNT(*) AS component_size,
           SUM(CASE WHEN NOT EXISTS (
                 SELECT 1 FROM valid_edges AS outgoing
                  WHERE outgoing.from_gid = members.gid)
                    THEN 1 ELSE 0 END) AS terminal_count,
           MAX(CASE WHEN EXISTS (
                 SELECT 1 FROM uploader_revision_edges AS broken
                  WHERE broken.source_gid = members.gid
                    AND broken.blocked_reason IS NOT NULL)
                    THEN 1 ELSE 0 END) AS has_broken_relation,
           MAX(CASE WHEN EXISTS (
                 SELECT 1 FROM cycle_reach AS cycle
                  JOIN component_members AS cycle_member
                    ON cycle_member.component_gid = members.component_gid
                   AND cycle_member.gid = cycle.start_gid
                  WHERE cycle.start_gid = cycle.gid)
                    THEN 1 ELSE 0 END) AS has_cycle,
           MAX(CASE WHEN (
                 SELECT COUNT(*) FROM uploader_revision_edges AS parent_edge
                  WHERE parent_edge.relation = 'parent'
                    AND parent_edge.is_valid = 1
                    AND parent_edge.from_gid = members.gid) > 1
                    THEN 1 ELSE 0 END) AS has_parent_branch,
           MAX(CASE WHEN (
                 SELECT COUNT(*) FROM uploader_revision_edges AS current_edge
                  WHERE current_edge.relation = 'current'
                    AND current_edge.is_valid = 1
                    AND current_edge.from_gid = members.gid) > 1
                    THEN 1 ELSE 0 END) AS has_current_branch
      FROM component_members AS members
     GROUP BY members.component_gid
),
terminal_rows AS (
    SELECT members.component_gid,
           members.gid AS terminal_gid
      FROM component_members AS members
     WHERE NOT EXISTS (
             SELECT 1 FROM valid_edges AS outgoing
              WHERE outgoing.from_gid = members.gid)
),
terminal_projection AS (
    SELECT component_gid, MIN(terminal_gid) AS terminal_gid
      FROM terminal_rows
     GROUP BY component_gid
),
first_conflicts AS (
    SELECT members.component_gid
      FROM component_members AS members
      JOIN component_stats
        ON component_stats.component_gid = members.component_gid
      JOIN uploader_revision_edges AS first_edge
        ON first_edge.source_gid = members.gid
       AND first_edge.relation = 'first'
       AND first_edge.is_valid = 1
      LEFT JOIN component_members AS target_member
        ON target_member.component_gid = members.component_gid
       AND target_member.gid = first_edge.target_gid
     WHERE component_stats.component_size > 1
       AND target_member.gid IS NULL
     GROUP BY members.component_gid
),
component_classification AS (
    SELECT stats.component_gid,
           stats.component_size,
           stats.terminal_count,
           terminal.terminal_gid,
           CASE
             WHEN stats.has_broken_relation = 1
              AND EXISTS (SELECT 1 FROM uploader_revision_edges AS edge
                           JOIN component_members AS member
                             ON member.component_gid = stats.component_gid
                            AND member.gid = edge.source_gid
                          WHERE edge.blocked_reason = 'token_mismatch')
               THEN 'token_mismatch'
             WHEN stats.has_broken_relation = 1
              AND EXISTS (SELECT 1 FROM uploader_revision_edges AS edge
                           JOIN component_members AS member
                             ON member.component_gid = stats.component_gid
                            AND member.gid = edge.source_gid
                          WHERE edge.blocked_reason = 'reference_incomplete')
               THEN 'reference_incomplete'
             WHEN stats.has_broken_relation = 1 THEN 'relation_conflict'
             WHEN stats.has_cycle = 1 THEN 'cycle'
             WHEN stats.has_parent_branch = 1 THEN 'branch'
             WHEN stats.has_current_branch = 1 THEN 'branch'
             WHEN stats.terminal_count <> 1 THEN 'multiple_terminals'
             WHEN EXISTS (SELECT 1 FROM first_conflicts AS conflict
                           WHERE conflict.component_gid = stats.component_gid)
               THEN 'relation_conflict'
             WHEN NOT EXISTS (
               SELECT 1 FROM galleries AS terminal
                WHERE terminal.gid = component_terminal.terminal_gid
                  AND terminal.file_count IS NOT NULL
                  AND terminal.favorite_count IS NOT NULL
                  AND terminal.rating_count IS NOT NULL
                  AND json_valid(terminal.tags)
                  AND EXISTS (SELECT 1 FROM json_each(terminal.tags)
                               WHERE value = 'language:chinese')
                  AND EXISTS (SELECT 1 FROM json_each(terminal.tags)
                               WHERE value = 'other:tankoubon'))
               THEN CASE WHEN EXISTS (
                 SELECT 1 FROM galleries AS terminal
                  WHERE terminal.gid = component_terminal.terminal_gid
                    AND (terminal.file_count IS NULL
                      OR terminal.favorite_count IS NULL
                      OR terminal.rating_count IS NULL)
               ) THEN 'scoring_input_incomplete' ELSE 'scope_incomplete' END
             ELSE NULL
           END AS blocked_reason
      FROM component_stats AS stats
      LEFT JOIN terminal_projection AS terminal
        ON terminal.component_gid = stats.component_gid
      LEFT JOIN terminal_projection AS component_terminal
        ON component_terminal.component_gid = stats.component_gid
),
classified_members AS (
    SELECT members.gid,
           members.component_gid,
           classification.component_size,
           classification.terminal_gid,
           classification.blocked_reason,
           CASE WHEN classification.blocked_reason IS NULL THEN 1 ELSE 0 END AS ready,
           CASE WHEN members.gid = classification.terminal_gid THEN 1 ELSE 0 END AS is_terminal
      FROM component_members AS members
      JOIN component_classification AS classification
        ON classification.component_gid = members.component_gid
)
SELECT classified.gid,
       classified.component_gid,
       classified.component_size,
       classified.terminal_gid,
       classified.ready,
       classified.is_terminal,
       classified.blocked_reason,
       (SELECT json_group_array(member.gid)
          FROM classified_members AS member
         WHERE member.component_gid = classified.component_gid
         ORDER BY member.gid) AS component_gids,
       (SELECT json_group_array(json_object(
                 'from_gid', ordered_edge.from_gid,
                 'to_gid', ordered_edge.to_gid,
                 'relation', ordered_edge.relation))
          FROM (
            SELECT edge.from_gid, edge.to_gid, edge.relation
              FROM uploader_revision_edges AS edge
             WHERE edge.is_valid = 1
               AND edge.relation IN ('parent', 'current')
               AND (edge.from_gid = classified.gid OR edge.to_gid = classified.gid
                 OR edge.from_gid IN (SELECT member.gid FROM classified_members AS member
                                       WHERE member.component_gid = classified.component_gid))
             ORDER BY edge.from_gid, edge.to_gid, edge.relation
          ) AS ordered_edge) AS edge_provenance
  FROM classified_members AS classified;

CREATE VIEW scoreable_revision_terminals AS
SELECT member.gid AS revision_gid,
       member.terminal_gid AS gid,
       member.terminal_gid,
       member.component_gid,
       member.component_size,
       member.component_gids,
       member.edge_provenance,
       member.is_terminal
  FROM revision_members AS member
 WHERE member.ready = 1 AND member.is_terminal = 1;

CREATE VIEW current_revision_projection AS
SELECT member.gid AS revision_gid,
       member.terminal_gid AS gid,
       member.terminal_gid,
       member.component_gid,
       member.component_size,
       member.ready,
       member.is_terminal,
       member.blocked_reason,
       member.component_gids,
       member.edge_provenance
  FROM revision_members AS member;

CREATE VIEW archive_source_galleries AS
WITH archive_rows AS (
    SELECT member.terminal_gid AS gid,
           member.component_gid,
           member.gid AS archive_gid,
           gallery.file_path,
           CASE WHEN member.is_terminal = 1 THEN 0 ELSE 1 END AS archive_rank
      FROM revision_members AS member
      JOIN galleries AS gallery ON gallery.gid = member.gid
     WHERE member.ready = 1
       AND length(COALESCE(gallery.file_path, '')) > 0
), ranked AS (
    SELECT archive_rows.*,
           ROW_NUMBER() OVER (
             PARTITION BY archive_rows.gid
             ORDER BY archive_rows.archive_rank, archive_rows.archive_gid DESC) AS rank
      FROM archive_rows
), blocked_archive_rows AS (
    SELECT member.gid,
           member.gid AS terminal_gid,
           revision_projection.component_gid,
           member.gid AS archive_gid,
           gallery.file_path,
           1 AS is_effective,
           0 AS archive_rank
      FROM gallery_variants AS member
      JOIN current_revision_projection AS revision_projection
        ON revision_projection.revision_gid = member.gid
       AND revision_projection.ready = 0
      JOIN galleries AS gallery ON gallery.gid = member.gid
     WHERE member.membership_state = 'confirmed'
       AND length(COALESCE(gallery.file_path, '')) > 0
)
SELECT scoreable_terminal.gid,
       scoreable_terminal.terminal_gid,
       scoreable_terminal.component_gid,
       ranked.archive_gid,
       ranked.file_path,
       CASE WHEN ranked.archive_gid = scoreable_terminal.gid THEN 1 ELSE 0 END AS is_effective,
       COALESCE(ranked.rank, 0) AS archive_rank
  FROM scoreable_revision_terminals AS scoreable_terminal
  LEFT JOIN ranked
    ON ranked.gid = scoreable_terminal.gid AND ranked.rank = 1
UNION ALL
SELECT blocked.gid,
       blocked.terminal_gid,
       blocked.component_gid,
       blocked.archive_gid,
       blocked.file_path,
       blocked.is_effective,
       blocked.archive_rank
  FROM blocked_archive_rows AS blocked;

CREATE VIEW variant_identity_active_membership AS
SELECT member.gid,
       member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
 FROM gallery_variants AS member
 JOIN variant_groups AS grouped
   ON grouped.id = member.group_id AND grouped.identity_active = 1
 WHERE member.membership_state = 'confirmed'
   AND EXISTS (SELECT 1 FROM scoreable_revision_terminals AS scoreable_terminal
                WHERE scoreable_terminal.gid = member.gid);

CREATE VIEW variant_identity_gid_class AS
WITH relevant(gid) AS (
    SELECT gid FROM variant_identity_active_membership
    UNION
    SELECT grouped.source_gid
      FROM variant_reviews AS review
      JOIN variant_groups AS grouped ON grouped.id = review.group_id
     WHERE review.review_type = 'candidate_identity'
       AND review.status = 'pending'
    UNION
    SELECT candidate_gid FROM variant_reviews
     WHERE review_type = 'candidate_identity'
       AND status = 'pending'
    UNION
    SELECT low_gid FROM gallery_identity_pairs
    UNION
    SELECT high_gid FROM gallery_identity_pairs
), revision_projections AS (
    SELECT revision_projection.revision_gid,
           revision_projection.gid AS terminal_gid
      FROM current_revision_projection AS revision_projection
)
SELECT relevant.gid,
       COALESCE(active.class_gid, revision_projection.terminal_gid, relevant.gid) AS class_gid,
       active.active_group_id,
       COALESCE(active.class_size, 1) AS class_size,
       COALESCE(revision_projection.terminal_gid, relevant.gid) AS terminal_gid
  FROM relevant
  LEFT JOIN revision_projections AS revision_projection
    ON revision_projection.revision_gid = relevant.gid
  LEFT JOIN variant_identity_active_membership AS active
    ON active.gid = COALESCE(revision_projection.terminal_gid, relevant.gid);

CREATE VIEW variant_identity_review_visibility AS
SELECT review.id AS review_id,
       CASE WHEN EXISTS (
              SELECT 1 FROM variant_groups AS source_group
               WHERE source_group.id = review.group_id
                 AND NOT EXISTS (SELECT 1 FROM scoreable_revision_terminals AS scoreable_terminal
                                  WHERE scoreable_terminal.gid = source_group.source_gid)
            )
             OR (review.candidate_gid IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM scoreable_revision_terminals AS scoreable_terminal
               WHERE scoreable_terminal.gid = review.candidate_gid
            )) THEN 0 ELSE 1 END AS is_visible
  FROM variant_reviews AS review;

CREATE VIEW variant_identity_class_pair AS
SELECT MIN(low_class.class_gid, high_class.class_gid) AS low_class_gid,
       MAX(low_class.class_gid, high_class.class_gid) AS high_class_gid,
       'different_book' AS decision,
       MIN(pair.current_review_id) AS supporting_review_id
  FROM gallery_identity_pairs AS pair
  JOIN variant_reviews AS review ON review.id = pair.current_review_id
  JOIN variant_identity_gid_class AS low_class ON low_class.gid = pair.low_gid
  JOIN variant_identity_gid_class AS high_class ON high_class.gid = pair.high_gid
  LEFT JOIN current_revision_projection AS low_projection
    ON low_projection.revision_gid = pair.low_gid
  LEFT JOIN current_revision_projection AS high_projection
    ON high_projection.revision_gid = pair.high_gid
 WHERE review.status = 'resolved'
   AND review.decision = 'different_book'
   AND low_class.class_gid <> high_class.class_gid
   AND NOT (low_projection.component_gid IS NOT NULL
            AND low_projection.component_gid = high_projection.component_gid)
 GROUP BY 1, 2;

CREATE VIEW variant_identity_pending_candidate AS
WITH classified AS (
    SELECT review.id AS review_id,
           review.group_id,
           grouped.source_gid,
           review.candidate_gid,
           MIN(source_class.class_gid, candidate_class.class_gid) AS low_class_gid,
           MAX(source_class.class_gid, candidate_class.class_gid) AS high_class_gid,
           source_class.class_size AS source_class_size,
           candidate_class.class_size AS candidate_class_size,
           CASE WHEN owner.identity_active = 1 THEN 1 ELSE 0 END AS owner_is_active,
           visibility.is_visible,
           review.superseded_at,
           CASE
             WHEN source_class.class_gid = candidate_class.class_gid
               THEN 'same_book'
             WHEN class_pair.decision = 'different_book'
               THEN 'different_book'
             ELSE NULL
           END AS implied_decision,
           CASE WHEN class_pair.decision = 'different_book'
                THEN class_pair.supporting_review_id ELSE NULL END AS supporting_review_id
      FROM variant_reviews AS review
      JOIN variant_groups AS grouped ON grouped.id = review.group_id
      JOIN variant_groups AS owner ON owner.id = review.group_id
      JOIN variant_identity_gid_class AS source_class
        ON source_class.gid = grouped.source_gid
      JOIN variant_identity_gid_class AS candidate_class
        ON candidate_class.gid = review.candidate_gid
      JOIN variant_identity_review_visibility AS visibility
        ON visibility.review_id = review.id
      LEFT JOIN variant_identity_class_pair AS class_pair
        ON class_pair.low_class_gid = MIN(source_class.class_gid, candidate_class.class_gid)
       AND class_pair.high_class_gid = MAX(source_class.class_gid, candidate_class.class_gid)
     WHERE review.review_type = 'candidate_identity'
       AND review.status = 'pending'
)
SELECT classified.*,
       CASE WHEN classified.implied_decision IS NULL AND classified.is_visible = 1
            THEN ROW_NUMBER() OVER (
              PARTITION BY classified.low_class_gid, classified.high_class_gid
              ORDER BY classified.is_visible DESC,
                       classified.owner_is_active DESC, classified.review_id)
       END AS rank
  FROM classified;

CREATE VIEW variant_identity_actionable_review AS
SELECT review_id, group_id, source_gid, candidate_gid,
       low_class_gid, high_class_gid, source_class_size,
       candidate_class_size, owner_is_active
  FROM variant_identity_pending_candidate
 WHERE implied_decision IS NULL AND is_visible = 1 AND rank = 1
   AND superseded_at IS NULL;

CREATE VIEW variant_identity_group_review_state AS
WITH candidate_blocked(group_id) AS (
    SELECT actionable.group_id FROM variant_identity_actionable_review AS actionable
    UNION
    SELECT member_class.active_group_id
      FROM variant_identity_actionable_review AS actionable
      JOIN variant_identity_gid_class AS member_class
        ON member_class.class_gid IN (actionable.low_class_gid, actionable.high_class_gid)
     WHERE member_class.active_group_id IS NOT NULL
)
SELECT grouped.id AS group_id,
       CASE
         WHEN EXISTS (SELECT 1 FROM candidate_blocked
                       WHERE candidate_blocked.group_id = grouped.id)
           THEN 'candidate_pending'
         WHEN EXISTS (
           SELECT 1 FROM variant_reviews AS winner
           JOIN variant_identity_review_visibility AS visibility ON visibility.review_id = winner.id
          WHERE winner.group_id = grouped.id
            AND winner.review_type = 'winner'
            AND winner.status = 'pending'
            AND winner.superseded_at IS NULL
            AND grouped.desired_rating = 11
            AND visibility.is_visible = 1
         ) THEN 'winner_pending'
         ELSE 'none' END AS review_state
  FROM variant_groups AS grouped;

-- Migrate policy and persisted revision evidence in the same forward step as
-- the view vocabulary.  The old policy spelling was only a projection of the
-- provider terminal predicate; retaining it in an active or historical policy
-- would make the removed authority appear to remain supported.
CREATE TEMP TABLE migration_028_policy(
    id INTEGER PRIMARY KEY,
    policy_json TEXT NOT NULL,
    new_id INTEGER
);

INSERT INTO migration_028_policy(id, policy_json)
SELECT policy.id,
       json_set(
         json_remove(policy.policy_json,
           '$.matching.official_chain_visibility'),
         '$.matching.automatic_evidence_kinds',
         json(COALESCE((
           SELECT json_group_array(kind.value)
             FROM json_each(COALESCE(
                    json_extract(policy.policy_json,
                      '$.matching.automatic_evidence_kinds'), '[]')) AS kind
            WHERE kind.value <> 'official_chain'
         ), '[]')),
         '$.matching.visible_contradictions',
         json('[
           "title_volume_part_conflict",
           "disjoint_creator_sets",
           "missing_evidence",
           "uploader_revision_reference_incomplete",
           "uploader_revision_scope_incomplete",
           "uploader_revision_scoring_input_incomplete",
           "uploader_revision_token_mismatch",
           "uploader_revision_relation_conflict",
           "uploader_revision_cycle",
           "uploader_revision_branch",
           "uploader_revision_multiple_terminals"
         ]'))
  FROM variant_policy_revisions AS policy
 WHERE json_type(policy.policy_json,
                 '$.matching.official_chain_visibility') IS NOT NULL
    OR EXISTS (
         SELECT 1
           FROM json_each(COALESCE(
                  json_extract(policy.policy_json,
                    '$.matching.automatic_evidence_kinds'), '[]')) AS kind
          WHERE kind.value = 'official_chain'
       )
    OR EXISTS (
         SELECT 1
           FROM json_each(COALESCE(
                  json_extract(policy.policy_json,
                    '$.matching.visible_contradictions'), '[]')) AS contradiction
          WHERE contradiction.value IN (
            'chain_reference_invalid', 'chain_key_mismatch', 'chain_conflict',
            'chain_cycle', 'chain_branch', 'chain_multiple_terminals')
       );

-- Keep every old revision immutable for audit and for evaluation/action/review
-- foreign keys.  Only an affected active row gets a new canonical revision;
-- inactive historical rows retain their original JSON and hashes for
-- audit/reference only; they are never eligible to serve as active authority.
INSERT INTO variant_policy_revisions(
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash,
    is_active, activated_at)
SELECT context.policy_json,
       printf('%064d', context.id), printf('%064d', context.id),
       printf('%064d', context.id), printf('%064d', context.id),
       0, strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM migration_028_policy AS context
 WHERE EXISTS (SELECT 1 FROM variant_policy_revisions AS active
                WHERE active.id=context.id AND active.is_active=1);

UPDATE migration_028_policy
   SET new_id=last_insert_rowid()
 WHERE EXISTS (SELECT 1 FROM variant_policy_revisions AS active
                WHERE active.id=migration_028_policy.id
                  AND active.is_active=1);

UPDATE variant_policy_revisions
   SET is_active=0
 WHERE id IN (SELECT id FROM migration_028_policy WHERE new_id IS NOT NULL);
UPDATE variant_policy_revisions
   SET is_active=1,
       activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id IN (SELECT new_id FROM migration_028_policy WHERE new_id IS NOT NULL);

-- Retarget unfinished work to the canonical active revision.  Leased work is
-- returned to the queue so no worker can continue with stale policy bytes.
UPDATE variant_jobs
   SET target_policy_revision_id=(SELECT context.new_id
                                    FROM migration_028_policy AS context
                                   WHERE context.id=variant_jobs.target_policy_revision_id
                                     AND context.new_id IS NOT NULL),
       continuation_cursor_json=NULL,
       available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       lease_owner=NULL,
       lease_expires_at=NULL,
       last_error_class=CASE WHEN status='leased' THEN 'uncertain' ELSE last_error_class END,
       last_error=CASE WHEN status='leased' THEN 'policy revision changed' ELSE last_error END,
       status=CASE WHEN status='leased' THEN 'queued' ELSE status END,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE status IN ('queued','leased')
   AND target_policy_revision_id IN (SELECT id FROM migration_028_policy WHERE new_id IS NOT NULL);

DROP TABLE migration_028_policy;
