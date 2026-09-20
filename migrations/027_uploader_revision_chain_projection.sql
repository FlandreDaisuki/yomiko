-- Provider-authoritative uploader-revision projection.
--
-- Relation pairs remain facts on galleries.  The views below deliberately do
-- not cache a chain id or a terminal flag: a terminal is a projection of the
-- token-bearing provider relations and can therefore be re-derived after a
-- refresh.  The migration is intentionally local-only; no remote or
-- filesystem operation belongs here.

-- A half-populated identity pair is never a usable provider fact.  A target
-- row may be absent (the discovery staging table is allowed to hold that
-- reference), but a fetched target with a different token is corruption.
CREATE TEMP TABLE migration_027_relation_guard(
    valid INTEGER NOT NULL
);

INSERT INTO migration_027_relation_guard(valid)
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM galleries AS gallery
    WHERE (gallery.first_gid IS NULL) <> (gallery.first_token IS NULL)
       OR (gallery.parent_gid IS NULL) <> (gallery.parent_token IS NULL)
       OR (gallery.current_gid IS NULL) <> (gallery.current_token IS NULL)
       OR EXISTS (
         SELECT 1 FROM galleries AS target
          WHERE target.gid = gallery.first_gid
            AND target.token IS NOT NULL
            AND gallery.first_token IS NOT NULL
            AND target.token <> gallery.first_token)
       OR EXISTS (
         SELECT 1 FROM galleries AS target
          WHERE target.gid = gallery.parent_gid
            AND target.token IS NOT NULL
            AND gallery.parent_token IS NOT NULL
            AND target.token <> gallery.parent_token)
       OR EXISTS (
         SELECT 1 FROM galleries AS target
          WHERE target.gid = gallery.current_gid
            AND target.token IS NOT NULL
            AND gallery.current_token IS NOT NULL
            AND target.token <> gallery.current_token)
  ) THEN 0 ELSE 1 END;

-- Keep the migration failure actionable without allowing a malformed relation
-- to be partially normalized.  The guard is deliberately before any schema
-- rewrite; db_init wraps the whole migration in BEGIN IMMEDIATE, so an abort
-- restores the exact schema-26 projection.
SELECT printf('migration 027 relation guard: GID %d has an invalid relation pair', gallery.gid)
  FROM galleries AS gallery
 WHERE (gallery.first_gid IS NULL) <> (gallery.first_token IS NULL)
    OR (gallery.parent_gid IS NULL) <> (gallery.parent_token IS NULL)
    OR (gallery.current_gid IS NULL) <> (gallery.current_token IS NULL)
    OR EXISTS (
      SELECT 1 FROM galleries AS target
       WHERE target.gid IN (gallery.first_gid, gallery.parent_gid, gallery.current_gid)
         AND target.gid = gallery.first_gid
         AND target.token IS NOT gallery.first_token)
    OR EXISTS (
      SELECT 1 FROM galleries AS target
       WHERE target.gid = gallery.parent_gid
         AND target.token IS NOT gallery.parent_token)
    OR EXISTS (
      SELECT 1 FROM galleries AS target
      WHERE target.gid = gallery.current_gid
         AND target.token IS NOT gallery.current_token);

CREATE TEMP TRIGGER migration_027_abort_invalid_relation
BEFORE INSERT ON migration_027_relation_guard
WHEN NEW.valid <> 1
BEGIN
    SELECT RAISE(ABORT, 'migration 027 found an invalid uploader revision relation');
END;
INSERT INTO migration_027_relation_guard(valid)
SELECT valid FROM migration_027_relation_guard WHERE valid <> 1;

-- Keep the reason that made a staged publication retryable next to its run.
-- The bounded vocabulary is also the source used by the Prometheus exporter;
-- it prevents provider data from becoming an unbounded metric label.
ALTER TABLE variant_discovery_runs ADD COLUMN blocked_reason TEXT
    CHECK (blocked_reason IS NULL OR blocked_reason IN (
      'reference_incomplete', 'scope_incomplete',
      'scoring_input_incomplete', 'token_mismatch', 'relation_conflict',
      'cycle', 'branch', 'multiple_terminals'
    ));
ALTER TABLE variant_discovery_runs ADD COLUMN blocked_component_count INTEGER
    NOT NULL DEFAULT 0 CHECK (blocked_component_count >= 0);

-- The old views expose the pre-027 current projection.  They are recreated
-- after the mutable membership table is rebuilt below.
DROP VIEW IF EXISTS variant_identity_group_review_state;
DROP VIEW IF EXISTS variant_identity_actionable_review;
DROP VIEW IF EXISTS variant_identity_pending_candidate;
DROP VIEW IF EXISTS variant_identity_class_pair;
DROP VIEW IF EXISTS variant_identity_gid_class;
DROP VIEW IF EXISTS variant_identity_active_membership;
DROP VIEW IF EXISTS variant_identity_review_visibility;

DROP TRIGGER IF EXISTS gallery_variants_one_identity_group_insert;
DROP TRIGGER IF EXISTS gallery_variants_one_identity_group_update;
DROP TRIGGER IF EXISTS variant_groups_no_identity_conflict_on_activation;
DROP TRIGGER IF EXISTS gallery_variants_one_active_group_insert;
DROP TRIGGER IF EXISTS gallery_variants_one_active_group_update;
DROP TRIGGER IF EXISTS variant_groups_no_conflict_on_activation;
DROP TRIGGER IF EXISTS gallery_variants_preserve_canonical_update;
DROP TRIGGER IF EXISTS gallery_variants_preserve_canonical_delete;
DROP TRIGGER IF EXISTS variant_evaluations_validate_canonical_insert;
DROP TRIGGER IF EXISTS variant_canonical_decisions_validate_member_insert;
DROP TRIGGER IF EXISTS variant_groups_validate_canonical_insert;
DROP TRIGGER IF EXISTS variant_groups_validate_canonical_update;
DROP TRIGGER IF EXISTS variant_groups_validate_evaluation_insert;
DROP TRIGGER IF EXISTS variant_groups_validate_evaluation_update;
-- Candidate-identity rows are durable frozen evidence too.  Schema 27 uses
-- superseded_at for a pending row that no longer names a current terminal;
-- the schema-26 trigger rejected that legitimate projection transition.
DROP TRIGGER IF EXISTS variant_reviews_superseded_not_pending;

CREATE VIEW uploader_revision_edges AS
WITH relation_pairs(source_gid, relation, target_gid, target_token) AS (
    SELECT gid, 'first', first_gid, first_token FROM galleries
    UNION ALL
    SELECT gid, 'parent', parent_gid, parent_token FROM galleries
    UNION ALL
    SELECT gid, 'current', current_gid, current_token FROM galleries
), classified AS (
    SELECT pair.source_gid,
           pair.relation,
           pair.target_gid,
           pair.target_token,
           CASE WHEN pair.target_gid IS NULL AND pair.target_token IS NULL
                     THEN 1
                WHEN pair.target_gid IS NOT NULL AND pair.target_token IS NOT NULL
                     THEN 1 ELSE 0 END AS pair_complete,
           CASE WHEN pair.target_gid IS NULL THEN 1
                WHEN EXISTS (SELECT 1 FROM galleries AS target
                              WHERE target.gid = pair.target_gid)
                     THEN 1 ELSE 0 END AS target_fetched,
           CASE WHEN pair.target_gid IS NULL THEN 1
                WHEN EXISTS (SELECT 1 FROM galleries AS target
                              WHERE target.gid = pair.target_gid
                                AND target.token IS pair.target_token)
                     THEN 1 ELSE 0 END AS token_matched
      FROM relation_pairs AS pair
)
SELECT source_gid,
       relation,
       target_gid,
       target_token,
       pair_complete,
       target_fetched,
       token_matched,
       CASE
         WHEN pair_complete = 0 THEN 'relation_conflict'
         WHEN target_gid IS NOT NULL AND target_fetched = 0 THEN 'reference_incomplete'
         WHEN target_gid IS NOT NULL AND token_matched = 0 THEN 'token_mismatch'
         ELSE NULL
       END AS blocked_reason,
       CASE
         WHEN pair_complete = 1 AND target_gid IS NOT NULL
          AND target_fetched = 1 AND token_matched = 1 THEN 1
         ELSE 0
       END AS is_valid,
       CASE relation
         WHEN 'parent' THEN target_gid
         ELSE source_gid
       END AS from_gid,
       CASE relation
         WHEN 'parent' THEN source_gid
         ELSE target_gid
       END AS to_gid
  FROM classified
 WHERE target_gid IS NOT NULL OR target_token IS NOT NULL;

-- Map every fetched gallery to its provider component.  `parent` is stored on
-- the child and is consequently reversed when turned into an edge; `current`
-- already points from the old revision to the replacement.  `first` is never
-- included in this graph and therefore cannot manufacture a chain.
CREATE VIEW uploader_revision_members AS
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

CREATE VIEW eligible_galleries AS
SELECT member.gid AS revision_gid,
       member.terminal_gid AS gid,
       member.terminal_gid,
       member.component_gid,
       member.component_size,
       member.component_gids,
       member.edge_provenance,
       member.is_terminal
  FROM uploader_revision_members AS member
 WHERE member.ready = 1 AND member.is_terminal = 1;

CREATE VIEW uploader_revision_representatives AS
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
  FROM uploader_revision_members AS member;

CREATE VIEW available_galleries AS
WITH archive_rows AS (
    SELECT member.terminal_gid AS gid,
           member.component_gid,
           member.gid AS archive_gid,
           gallery.file_path,
           CASE WHEN member.is_terminal = 1 THEN 0 ELSE 1 END AS archive_rank
      FROM uploader_revision_members AS member
      JOIN galleries AS gallery ON gallery.gid = member.gid
     WHERE member.ready = 1
       AND length(COALESCE(gallery.file_path, '')) > 0
), ranked AS (
    SELECT archive_rows.*,
           ROW_NUMBER() OVER (
             PARTITION BY archive_rows.gid
             ORDER BY archive_rows.archive_rank, archive_rows.archive_gid DESC) AS rank
      FROM archive_rows
)
SELECT eligible.gid,
       eligible.terminal_gid,
       eligible.component_gid,
       ranked.archive_gid,
       ranked.file_path,
       CASE WHEN ranked.archive_gid = eligible.gid THEN 1 ELSE 0 END AS is_effective,
       COALESCE(ranked.rank, 0) AS archive_rank
  FROM eligible_galleries AS eligible
  LEFT JOIN ranked
    ON ranked.gid = eligible.gid AND ranked.rank = 1;

-- Existing schema-26 members may have been populated before the authoritative
-- views existed.  Use their snapshots only to fill missing live values, then
-- normalize current pointers from the live gallery rows.  The snapshots are
-- not carried into the rebuilt mutable table.
UPDATE galleries AS gallery
   SET title = COALESCE(gallery.title,
             (SELECT json_extract(member.metadata_snapshot_json, '$.title')
                FROM gallery_variants AS member
               WHERE member.gid = gallery.gid
               ORDER BY member.updated_at DESC LIMIT 1)),
       title_jpn = COALESCE(gallery.title_jpn,
             (SELECT json_extract(member.metadata_snapshot_json, '$.title_jpn')
                FROM gallery_variants AS member
               WHERE member.gid = gallery.gid
               ORDER BY member.updated_at DESC LIMIT 1)),
       file_count = COALESCE(gallery.file_count,
             (SELECT json_extract(member.metadata_snapshot_json, '$.filecount')
                FROM gallery_variants AS member
               WHERE member.gid = gallery.gid
               ORDER BY member.updated_at DESC LIMIT 1)),
       rating = COALESCE(gallery.rating,
             (SELECT json_extract(member.metadata_snapshot_json, '$.rating')
                FROM gallery_variants AS member
               WHERE member.gid = gallery.gid
               ORDER BY member.updated_at DESC LIMIT 1)),
       tags = COALESCE(gallery.tags,
             (SELECT json_extract(member.metadata_snapshot_json, '$.tags')
                FROM gallery_variants AS member
               WHERE member.gid = gallery.gid
               ORDER BY member.updated_at DESC LIMIT 1))
 WHERE EXISTS (SELECT 1 FROM gallery_variants AS member
                WHERE member.gid = gallery.gid);

-- Materialize only after the live-row backfill.  The graph classifier reads
-- current galleries, so taking this snapshot before filling schema-26 NULLs
-- would permanently misclassify an otherwise ready terminal as incomplete.
CREATE TEMP TABLE migration_027_members AS
SELECT * FROM uploader_revision_members;

-- Only components that actually promote a predecessor, merge groups, or
-- normalize a provider endpoint are affected by the schema-27 projection.
-- Singleton ready components are intentionally absent so unrelated pending
-- reviews retain their current visibility and exact evidence.
CREATE TEMP TABLE migration_027_affected_component(
    component_gid INTEGER PRIMARY KEY
);
INSERT INTO migration_027_affected_component(component_gid)
SELECT DISTINCT component_gid
  FROM migration_027_members
 WHERE component_size > 1 OR terminal_gid <> gid;
CREATE TEMP TABLE migration_027_affected_gid(
    gid INTEGER PRIMARY KEY
);
INSERT INTO migration_027_affected_gid(gid)
SELECT member.gid
  FROM migration_027_members AS member
 WHERE member.component_gid IN (SELECT component_gid
                                  FROM migration_027_affected_component);
CREATE TEMP TABLE migration_027_affected_group(
    group_id INTEGER PRIMARY KEY
);
INSERT INTO migration_027_affected_group(group_id)
SELECT DISTINCT member.group_id
  FROM gallery_variants AS member
  JOIN migration_027_affected_gid AS affected
    ON affected.gid = member.gid;

-- A fetched malformed component is never repaired by choosing MIN() or by
-- treating a raw current pointer as authoritative.  Emit a bounded diagnostic
-- and abort before any current projection is rewritten.  Incomplete external
-- references and missing scoring/scope inputs remain retryable components and
-- are handled by the high-priority discovery queue below.
CREATE TEMP TABLE migration_027_graph_blockers(
    component_gid INTEGER NOT NULL,
    reason TEXT NOT NULL,
    PRIMARY KEY(component_gid, reason)
);
INSERT INTO migration_027_graph_blockers(component_gid, reason)
SELECT component_gid, blocked_reason
  FROM migration_027_members
 WHERE blocked_reason IN (
   'token_mismatch', 'relation_conflict', 'cycle', 'branch',
   'multiple_terminals'
 )
 GROUP BY component_gid, blocked_reason;
SELECT printf('migration 027 graph guard: component %d blocked by %s',
              component_gid, reason)
  FROM migration_027_graph_blockers
 ORDER BY component_gid, reason;
CREATE TEMP TABLE migration_027_graph_guard(
    valid INTEGER NOT NULL CHECK(valid = 1)
);
CREATE TEMP TRIGGER migration_027_abort_invalid_graph
BEFORE INSERT ON migration_027_graph_guard
WHEN EXISTS (SELECT 1 FROM migration_027_graph_blockers)
BEGIN
    SELECT RAISE(ABORT, 'migration 027 found an invalid uploader revision component');
END;
INSERT INTO migration_027_graph_guard(valid) VALUES (1);

-- A provider component is one identity unit even when schema 26 happened to
-- place its revisions in separate identity-active groups.  Build the
-- connected group projection through ready component representatives first;
-- this also handles a cross-chain same-book group without splitting it.
CREATE TEMP TABLE migration_027_group_owner(
    group_id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL
);
WITH RECURSIVE component_groups(component_gid, group_id) AS (
    SELECT DISTINCT member.component_gid, current_member.group_id
      FROM migration_027_members AS member
      JOIN gallery_variants AS current_member
        ON current_member.gid = member.gid
       AND current_member.membership_state = 'confirmed'
     WHERE member.ready = 1
), group_links(group_id, other_group_id) AS (
    SELECT left_group.group_id, right_group.group_id
      FROM component_groups AS left_group
      JOIN component_groups AS right_group
        ON right_group.component_gid = left_group.component_gid
       AND right_group.group_id <> left_group.group_id
    UNION
    SELECT right_group.group_id, left_group.group_id
      FROM component_groups AS left_group
      JOIN component_groups AS right_group
        ON right_group.component_gid = left_group.component_gid
       AND right_group.group_id <> left_group.group_id
), reachable(root_group, group_id) AS (
    SELECT group_id, group_id FROM component_groups
    UNION
    SELECT reachable.root_group, links.other_group_id
      FROM reachable
      JOIN group_links AS links ON links.group_id = reachable.group_id
), group_components(group_id, root_group) AS (
    SELECT group_id, MIN(root_group)
      FROM reachable
     GROUP BY group_id
), owner_by_root(root_group, owner_id) AS (
    SELECT group_components.root_group,
           COALESCE(
             MIN(CASE WHEN grouped.identity_active = 1
                      THEN group_components.group_id END),
             MIN(group_components.group_id))
      FROM group_components
      JOIN variant_groups AS grouped
        ON grouped.id = group_components.group_id
     GROUP BY group_components.root_group
)
INSERT INTO migration_027_group_owner(group_id, owner_id)
SELECT group_components.group_id, owner.owner_id
  FROM group_components
  JOIN owner_by_root AS owner
    ON owner.root_group = group_components.root_group;

-- Merge current confirmed membership before the table rebuild.  Historical
-- rows stay in their original groups; only the current identity owner receives
-- the copied projection, and non-owner groups become inactive audit history.
INSERT OR IGNORE INTO gallery_variants(
    group_id, gid, membership_state, decision_source, match_score,
    evidence_json, metadata_snapshot_json, variant_score,
    variant_state, decided_at, created_at, updated_at)
SELECT owner.owner_id, member.gid, member.membership_state,
       member.decision_source, member.match_score, member.evidence_json,
       member.metadata_snapshot_json, member.variant_score,
       member.variant_state, member.decided_at,
       member.created_at, member.updated_at
  FROM migration_027_group_owner AS owner
  JOIN gallery_variants AS member ON member.group_id = owner.group_id
 WHERE member.membership_state = 'confirmed'
   AND owner.owner_id <> owner.group_id;

UPDATE variant_groups AS grouped
   SET identity_active = CASE WHEN grouped.id = owner.owner_id THEN 1 ELSE 0 END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM migration_027_group_owner AS owner
 WHERE grouped.id = owner.group_id;

CREATE TEMP TABLE migration_027_feedback_owner(
    owner_id INTEGER PRIMARY KEY,
    desired_rating INTEGER NOT NULL,
    latest_feedback_at TEXT NOT NULL
);
INSERT INTO migration_027_feedback_owner(owner_id, desired_rating, latest_feedback_at)
SELECT owner_id, desired_rating, latest_feedback_at
  FROM (
    SELECT owner.owner_id, grouped.desired_rating, grouped.latest_feedback_at,
           ROW_NUMBER() OVER (
             PARTITION BY owner.owner_id
             ORDER BY grouped.latest_feedback_at DESC, grouped.id DESC) AS rank
      FROM migration_027_group_owner AS owner
      JOIN variant_groups AS grouped ON grouped.id = owner.group_id
  ) AS ranked
 WHERE rank = 1;
UPDATE variant_groups AS grouped
   SET desired_rating = feedback.desired_rating,
       latest_feedback_at = feedback.latest_feedback_at,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM migration_027_feedback_owner AS feedback
 WHERE grouped.id = feedback.owner_id;

-- Keep one active manual decision for each merged owner.  The newest decision
-- wins; its source review/evaluation remains untouched historical evidence.
CREATE TEMP TABLE migration_027_decision_rank(
    decision_id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL,
    rank INTEGER NOT NULL
);
INSERT INTO migration_027_decision_rank(decision_id, owner_id, rank)
SELECT decision.id, owner.owner_id,
       ROW_NUMBER() OVER (
         PARTITION BY owner.owner_id
         ORDER BY decision.created_at DESC, decision.id DESC)
  FROM variant_canonical_decisions AS decision
  JOIN migration_027_group_owner AS owner
    ON owner.group_id = decision.group_id
 WHERE decision.status = 'active';
UPDATE variant_canonical_decisions AS decision
   SET status = 'reset',
       superseded_at = COALESCE(superseded_at,
                                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       supersede_reason = COALESCE(supersede_reason,
                                   'uploader_revision_group_merge')
 WHERE decision.id IN (
   SELECT decision_id FROM migration_027_decision_rank WHERE rank > 1
 );
UPDATE variant_canonical_decisions AS decision
   SET group_id = rank.owner_id
  FROM migration_027_decision_rank AS rank
 WHERE decision.id = rank.decision_id AND rank.rank = 1;

-- Pending candidate/winner rows refer to a stale group/evaluation boundary.
-- Preserve their exact evidence, but hide them from the current queue so the
-- owner publication can rebuild a fresh review against terminal GIDs.
UPDATE variant_reviews AS review
   SET superseded_at = COALESCE(review.superseded_at,
                                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       evidence_json = json_set(review.evidence_json,
         '$.internal_visibility', json_object(
           'reason', 'uploader_revision_projection'))
 WHERE review.status = 'pending'
   AND (
     review.group_id IN (SELECT group_id FROM migration_027_affected_group)
     OR review.candidate_gid IN (
       SELECT gid FROM migration_027_affected_gid
     )
   );

-- Rebuild current decisions after merged ownership.  Invalid decisions are
-- reset below once the rebuilt membership table exposes eligible terminals.

-- A valid replacement is current even when the predecessor was previously
-- selected.  Clear stale automatic state and move concrete current pointers;
-- immutable evaluations/reviews/actions remain untouched below.
UPDATE variant_groups AS grouped
   SET source_gid = COALESCE((SELECT representative.terminal_gid
                                FROM migration_027_members AS representative
                               WHERE representative.gid = grouped.source_gid
                                 AND representative.ready = 1), grouped.source_gid),
       canonical_gid = COALESCE(
                         (SELECT representative.terminal_gid
                            FROM migration_027_members AS representative
                           WHERE representative.gid = grouped.canonical_gid
                             AND representative.ready = 1),
                         CASE WHEN EXISTS (
                           SELECT 1 FROM migration_027_members AS blocked
                            WHERE blocked.gid = grouped.canonical_gid
                              AND blocked.ready = 0)
                              THEN grouped.canonical_gid END),
       active_evaluation_id = CASE WHEN grouped.canonical_gid IS NOT NULL
                                    AND grouped.canonical_gid <> (
                                      SELECT representative.terminal_gid
                                        FROM migration_027_members AS representative
                                       WHERE representative.gid = grouped.canonical_gid
                                         AND representative.ready = 1)
                                    THEN NULL ELSE grouped.active_evaluation_id END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

UPDATE variant_canonical_decisions AS decision
   SET canonical_gid = COALESCE((SELECT representative.terminal_gid
                                   FROM migration_027_members AS representative
                                  WHERE representative.gid = decision.canonical_gid
                                    AND representative.ready = 1), decision.canonical_gid)
 WHERE EXISTS (SELECT 1 FROM migration_027_members AS representative
                WHERE representative.gid = decision.canonical_gid
                  AND representative.ready = 1
                  AND representative.terminal_gid <> representative.gid);

CREATE TEMP TABLE migration_027_terminal_map(
    revision_gid INTEGER PRIMARY KEY,
    terminal_gid INTEGER NOT NULL,
    component_gid INTEGER NOT NULL
);
INSERT INTO migration_027_terminal_map(revision_gid, terminal_gid, component_gid)
SELECT gid, terminal_gid, component_gid
  FROM migration_027_members
 WHERE ready = 1;

-- A leased/queued job attached to a merged-away group cannot keep publishing
-- the old source.  Return its discovery run to a retryable boundary and let
-- the owner-group coalescing below create exactly one current job.
CREATE TEMP TABLE migration_027_obsolete_jobs(job_id INTEGER PRIMARY KEY);
INSERT INTO migration_027_obsolete_jobs(job_id)
SELECT job.id
  FROM variant_jobs AS job
  JOIN migration_027_group_owner AS owner ON owner.group_id = job.group_id
 WHERE owner.owner_id <> owner.group_id
   AND job.status IN ('queued', 'leased');
UPDATE variant_discovery_runs AS run
   SET status = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
       last_error_class = 'uncertain',
       last_error = 'schema 27 normalized uploader revision group owner',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE run.job_id IN (SELECT job_id FROM migration_027_obsolete_jobs)
   AND run.status IN ('running', 'retryable');
UPDATE variant_jobs AS job
   SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
       completed_at = COALESCE(job.completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       last_error_class = NULL,
       last_error = 'schema 27 normalized uploader revision group owner',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job.id IN (SELECT job_id FROM migration_027_obsolete_jobs);
UPDATE variant_jobs AS job
   SET source_gid = (SELECT grouped.source_gid
                       FROM variant_groups AS grouped
                      WHERE grouped.id = job.group_id),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job.status IN ('queued', 'leased')
   AND job.group_id IN (SELECT owner_id FROM migration_027_group_owner);

-- Current rating/favourite actions follow the terminal.  H@H and archive
-- cleanup remain exact-GID work: a predecessor archive may still be the
-- available fallback and a completed request must never be copied to a child.
UPDATE variant_actions
   SET status = 'retryable_error', lease_owner = NULL,
       lease_expires_at = NULL, lease_job_id = NULL,
       last_error_class = 'uncertain',
       last_error = COALESCE(last_error,
         'schema 27 reopened in-flight action for terminal normalization'),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'in_flight'
   AND action_type IN ('rating', 'favorite_move', 'favorite_remove')
   AND gid IN (SELECT revision_gid FROM migration_027_terminal_map);
CREATE TEMP TABLE migration_027_action_rank(
    action_id INTEGER PRIMARY KEY,
    terminal_gid INTEGER NOT NULL,
    owner_group_id INTEGER NOT NULL,
    rank INTEGER NOT NULL
);
INSERT INTO migration_027_action_rank(
    action_id, terminal_gid, owner_group_id, rank)
SELECT action.id, terminal.terminal_gid,
       COALESCE(owner.owner_id, action.group_id),
       ROW_NUMBER() OVER (
         PARTITION BY action.action_type, terminal.terminal_gid,
                      action.desired_value, action.policy_revision_id
         ORDER BY action.id DESC)
  FROM variant_actions AS action
  JOIN migration_027_terminal_map AS terminal
    ON terminal.revision_gid = action.gid
  LEFT JOIN migration_027_group_owner AS owner
    ON owner.group_id = action.group_id
 WHERE action.action_type IN ('rating', 'favorite_move', 'favorite_remove')
   AND action.status IN ('pending', 'retryable_error', 'configuration_error');
UPDATE variant_actions AS action
   SET status = 'superseded', lease_owner = NULL, lease_expires_at = NULL,
       lease_job_id = NULL,
       completed_at = COALESCE(action.completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE action.id IN (
   SELECT action_id FROM migration_027_action_rank WHERE rank > 1
 ) OR EXISTS (
   SELECT 1
     FROM migration_027_action_rank AS ranked
     JOIN variant_actions AS occupied
       ON occupied.id <> ranked.action_id
      AND occupied.action_type = action.action_type
      AND occupied.gid = ranked.terminal_gid
      AND occupied.desired_value = action.desired_value
      AND occupied.policy_revision_id = action.policy_revision_id
    WHERE ranked.action_id = action.id
      AND occupied.status <> 'superseded'
 );
UPDATE variant_actions AS action
   SET gid = ranked.terminal_gid,
       group_id = ranked.owner_group_id,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM migration_027_action_rank AS ranked
 WHERE ranked.action_id = action.id AND ranked.rank = 1
   AND action.status IN ('pending', 'retryable_error', 'configuration_error');

-- A pair is a current projection, not immutable evidence.  Rebuild the
-- endpoint table through a deterministic newest-review choice so an old and a
-- new endpoint cannot collide during replacement.
CREATE TEMP TABLE migration_027_pairs(
    low_gid INTEGER NOT NULL,
    high_gid INTEGER NOT NULL,
    current_review_id INTEGER NOT NULL,
    PRIMARY KEY(low_gid, high_gid)
);
WITH normalized AS (
    SELECT MIN(low_representative.terminal_gid, high_representative.terminal_gid) AS low_gid,
           MAX(low_representative.terminal_gid, high_representative.terminal_gid) AS high_gid,
           pair.current_review_id,
           ROW_NUMBER() OVER (
             PARTITION BY
               MIN(low_representative.terminal_gid, high_representative.terminal_gid),
               MAX(low_representative.terminal_gid, high_representative.terminal_gid)
             ORDER BY pair.current_review_id DESC) AS rank
      FROM gallery_identity_pairs AS pair
      JOIN migration_027_members AS low_representative
        ON low_representative.gid = pair.low_gid AND low_representative.ready = 1
      JOIN migration_027_members AS high_representative
        ON high_representative.gid = pair.high_gid AND high_representative.ready = 1
     WHERE low_representative.terminal_gid < high_representative.terminal_gid
)
INSERT INTO migration_027_pairs(low_gid, high_gid, current_review_id)
SELECT low_gid, high_gid, current_review_id
  FROM normalized
 WHERE rank = 1;

DELETE FROM gallery_identity_pairs;
INSERT INTO gallery_identity_pairs(low_gid, high_gid, current_review_id)
SELECT low_gid, high_gid, current_review_id
  FROM migration_027_pairs;

-- Current membership contains only ready terminals.  Keep predecessor rows as
-- rejected evidence until the mutable table is rebuilt; rows in galleries and
-- immutable evaluation/review/action tables remain exact-GID history.
INSERT OR IGNORE INTO gallery_variants(
    group_id, gid, membership_state, decision_source, match_score,
    evidence_json, metadata_snapshot_json, variant_score,
    variant_state, decided_at, created_at, updated_at)
SELECT member.group_id,
       representative.terminal_gid,
       'confirmed', 'automatic', member.match_score,
       json_object('kind', 'uploader_revision_terminal',
                   'predecessor_gid', member.gid),
       json_object(), NULL, 'undetermined', member.decided_at,
       member.created_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM gallery_variants AS member
  JOIN migration_027_members AS representative
    ON representative.gid = member.gid
   AND representative.ready = 1
   AND representative.terminal_gid <> representative.gid
 WHERE member.membership_state = 'confirmed';

 UPDATE gallery_variants AS member
   SET membership_state = 'rejected',
       variant_state = 'undetermined',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE member.membership_state = 'confirmed'
   AND EXISTS (SELECT 1 FROM migration_027_members AS representative
                WHERE representative.gid = member.gid
                  AND representative.ready = 1
                  AND representative.terminal_gid <> representative.gid);

UPDATE variant_actions
   SET status = 'superseded',
       lease_owner = NULL, lease_expires_at = NULL, lease_job_id = NULL,
       completed_at = COALESCE(completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status <> 'superseded'
   AND status <> 'succeeded'
   AND EXISTS (SELECT 1 FROM migration_027_members AS representative
                WHERE representative.gid = variant_actions.gid
                  AND representative.ready = 1
                  AND representative.terminal_gid <> representative.gid);

-- Rebuild gallery_variants without the mutable metadata duplicate.  Its
-- current score/evidence columns remain projections; immutable evaluation
-- snapshots retain their historical metadata independently.
CREATE TABLE gallery_variants_027(
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    gid INTEGER NOT NULL REFERENCES galleries(gid),
    membership_state TEXT NOT NULL
        CHECK (membership_state IN ('candidate', 'confirmed', 'rejected')),
    decision_source TEXT NOT NULL
        CHECK (decision_source IN ('automatic', 'manual')),
    match_score INTEGER NOT NULL DEFAULT 0,
    evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
    variant_score INTEGER,
    variant_state TEXT NOT NULL DEFAULT 'undetermined'
        CHECK (variant_state IN ('undetermined', 'canonical', 'alternate')),
    decided_at TEXT,
    matching_revision INTEGER NOT NULL DEFAULT 1 CHECK (matching_revision >= 1),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (group_id, gid)
);

INSERT INTO gallery_variants_027(
    group_id, gid, membership_state, decision_source, match_score,
    evidence_json, variant_score, variant_state,
    decided_at, matching_revision, created_at, updated_at)
SELECT group_id, gid, membership_state, decision_source, match_score,
       evidence_json, variant_score, variant_state,
       decided_at, matching_revision, created_at, updated_at
  FROM gallery_variants;

DROP TABLE gallery_variants;
ALTER TABLE gallery_variants_027 RENAME TO gallery_variants;

CREATE INDEX idx_gallery_variants_gid_state
ON gallery_variants(gid, membership_state, group_id);
CREATE INDEX idx_gallery_variants_group_state
ON gallery_variants(group_id, membership_state, variant_state, gid);
-- Recreate the schema-26 invariant that was lost with the table rebuild:
-- one current confirmed member may be the canonical output at most once per
-- group.  Keep this partial unique index alongside the existing lookup indexes.
CREATE UNIQUE INDEX idx_gallery_variants_one_canonical
ON gallery_variants(group_id)
WHERE membership_state = 'confirmed' AND variant_state = 'canonical';

-- A manual canonical choice follows a promoted terminal.  Recompute its
-- optimistic member fingerprint only after the rebuilt current membership is
-- visible, and restore the current canonical/alternate state on the new
-- terminal without changing immutable review/evaluation evidence.
UPDATE variant_canonical_decisions AS decision
   SET member_fingerprint = (
         SELECT json_group_array(member.gid)
           FROM gallery_variants AS member
          WHERE member.group_id = decision.group_id
            AND member.membership_state = 'confirmed'
          ORDER BY member.gid)
 WHERE decision.status = 'active';
UPDATE gallery_variants AS member
   SET variant_state = CASE
         WHEN member.gid = grouped.canonical_gid THEN 'canonical'
         ELSE 'alternate' END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM variant_groups AS grouped
 WHERE grouped.id = member.group_id
   AND member.membership_state = 'confirmed'
   AND grouped.canonical_gid IS NOT NULL;

-- The table rebuild above cannot run while the pre-rebuild view references
-- gallery_variants. Recreate the view now, after the live membership table is
-- final, and retain an exact-GID archive fallback for blocked replacements.
DROP VIEW available_galleries;
CREATE VIEW available_galleries AS
WITH archive_rows AS (
    SELECT member.terminal_gid AS gid,
           member.component_gid,
           member.gid AS archive_gid,
           gallery.file_path,
           CASE WHEN member.is_terminal = 1 THEN 0 ELSE 1 END AS archive_rank
      FROM uploader_revision_members AS member
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
           representative.component_gid,
           member.gid AS archive_gid,
           gallery.file_path,
           1 AS is_effective,
           0 AS archive_rank
      FROM gallery_variants AS member
      JOIN uploader_revision_representatives AS representative
        ON representative.revision_gid = member.gid
       AND representative.ready = 0
      JOIN galleries AS gallery ON gallery.gid = member.gid
     WHERE member.membership_state = 'confirmed'
       AND length(COALESCE(gallery.file_path, '')) > 0
)
SELECT eligible.gid,
       eligible.terminal_gid,
       eligible.component_gid,
       ranked.archive_gid,
       ranked.file_path,
       CASE WHEN ranked.archive_gid = eligible.gid THEN 1 ELSE 0 END AS is_effective,
       COALESCE(ranked.rank, 0) AS archive_rank
  FROM eligible_galleries AS eligible
  LEFT JOIN ranked
    ON ranked.gid = eligible.gid AND ranked.rank = 1
UNION ALL
SELECT blocked.gid,
       blocked.terminal_gid,
       blocked.component_gid,
       blocked.archive_gid,
       blocked.file_path,
       blocked.is_effective,
       blocked.archive_rank
  FROM blocked_archive_rows AS blocked;

-- A malformed or input-incomplete singleton is not a current member merely
-- because it was confirmed under schema 26.  Keep the exact row/evidence for
-- history and let the existing discovery scheduler retry its group.
UPDATE variant_groups
   SET canonical_gid = NULL,
       active_evaluation_id = NULL,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE canonical_gid IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                    WHERE eligible.gid = variant_groups.canonical_gid)
   AND NOT EXISTS (SELECT 1 FROM migration_027_members AS blocked
                    WHERE blocked.gid = variant_groups.canonical_gid
                      AND blocked.ready = 0);
UPDATE gallery_variants AS member
   SET membership_state = 'rejected',
       variant_state = 'undetermined',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE member.membership_state = 'confirmed'
   AND NOT EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                    WHERE eligible.gid = member.gid)
   AND NOT EXISTS (SELECT 1 FROM migration_027_members AS blocked
                    WHERE blocked.gid = member.gid
                      AND blocked.ready = 0);

-- A decision whose selected revision is no longer an eligible terminal is no
-- longer a current decision.  Reset the projection while retaining the source
-- review and its frozen evidence exactly as written.
UPDATE variant_canonical_decisions AS decision
   SET status = 'reset',
       superseded_at = COALESCE(decision.superseded_at,
                                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       supersede_reason = COALESCE(decision.supersede_reason,
                                   'uploader_revision_projection_incomplete')
 WHERE decision.status = 'active'
   AND NOT EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.group_id = decision.group_id
        AND member.gid = decision.canonical_gid
        AND member.membership_state = 'confirmed'
        AND EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                     WHERE eligible.gid = member.gid)
   )
   AND NOT EXISTS (
     SELECT 1 FROM migration_027_members AS blocked
      WHERE blocked.gid = decision.canonical_gid
        AND blocked.ready = 0
   );

CREATE TRIGGER gallery_variants_one_identity_group_insert
BEFORE INSERT ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups
              WHERE id = NEW.group_id AND identity_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.identity_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another identity group');
END;

CREATE TRIGGER gallery_variants_one_identity_group_update
BEFORE UPDATE OF group_id, gid, membership_state ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups
              WHERE id = NEW.group_id AND identity_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.identity_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another identity group');
END;

CREATE TRIGGER variant_groups_no_identity_conflict_on_activation
BEFORE UPDATE OF identity_active ON variant_groups
WHEN OLD.identity_active = 0 AND NEW.identity_active = 1
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN gallery_variants AS other ON other.gid = member.gid
       JOIN variant_groups AS other_group ON other_group.id = other.group_id
      WHERE member.group_id = NEW.id
        AND member.membership_state = 'confirmed'
        AND other.membership_state = 'confirmed'
        AND other.group_id <> NEW.id
        AND other_group.identity_active = 1
 )
BEGIN
    SELECT RAISE(ABORT, 'identity group has a member confirmed in another identity group');
END;

CREATE TRIGGER gallery_variants_preserve_canonical_update
BEFORE UPDATE OF group_id, gid, membership_state ON gallery_variants
WHEN EXISTS (SELECT 1 FROM variant_groups
              WHERE id = OLD.group_id AND canonical_gid = OLD.gid)
 AND (NEW.group_id <> OLD.group_id OR NEW.gid <> OLD.gid
      OR NEW.membership_state <> 'confirmed')
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must remain a confirmed group member');
END;

CREATE TRIGGER gallery_variants_preserve_canonical_delete
BEFORE DELETE ON gallery_variants
WHEN EXISTS (SELECT 1 FROM variant_groups
              WHERE id = OLD.group_id AND canonical_gid = OLD.gid)
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must remain a confirmed group member');
END;

CREATE TRIGGER variant_evaluations_validate_canonical_insert
BEFORE INSERT ON variant_evaluations
WHEN NEW.canonical_gid IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM gallery_variants
      WHERE group_id = NEW.group_id
        AND gid = NEW.canonical_gid
        AND membership_state = 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'evaluation canonical must be a confirmed group member');
END;

CREATE TRIGGER variant_canonical_decisions_validate_member_insert
BEFORE INSERT ON variant_canonical_decisions
WHEN NOT EXISTS (
    SELECT 1 FROM gallery_variants
     WHERE group_id = NEW.group_id
       AND gid = NEW.canonical_gid
       AND membership_state = 'confirmed'
)
BEGIN
    SELECT RAISE(ABORT, 'canonical decision must select a confirmed group member');
END;

CREATE TRIGGER variant_canonical_decisions_validate_member_update
BEFORE UPDATE OF group_id, canonical_gid, status ON variant_canonical_decisions
WHEN NEW.status = 'active'
 AND NOT EXISTS (
     SELECT 1 FROM gallery_variants
      WHERE group_id = NEW.group_id
        AND gid = NEW.canonical_gid
        AND membership_state = 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'canonical decision must select a confirmed group member');
END;

CREATE TRIGGER variant_groups_validate_canonical_insert
BEFORE INSERT ON variant_groups
WHEN NEW.canonical_gid IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM gallery_variants
      WHERE group_id = NEW.id AND gid = NEW.canonical_gid
        AND membership_state = 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must be a confirmed group member');
END;

CREATE TRIGGER variant_groups_validate_canonical_update
BEFORE UPDATE OF id, canonical_gid ON variant_groups
WHEN NEW.canonical_gid IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM gallery_variants
      WHERE group_id = NEW.id AND gid = NEW.canonical_gid
        AND membership_state = 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must be a confirmed group member');
END;

CREATE TRIGGER variant_groups_validate_evaluation_insert
BEFORE INSERT ON variant_groups
WHEN NEW.active_evaluation_id IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM variant_evaluations
      WHERE id = NEW.active_evaluation_id AND group_id = NEW.id
 )
BEGIN
    SELECT RAISE(ABORT, 'active evaluation must belong to the variant group');
END;

CREATE TRIGGER variant_groups_validate_evaluation_update
BEFORE UPDATE OF id, active_evaluation_id ON variant_groups
WHEN NEW.active_evaluation_id IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM variant_evaluations
      WHERE id = NEW.active_evaluation_id AND group_id = NEW.id
 )
BEGIN
    SELECT RAISE(ABORT, 'active evaluation must belong to the variant group');
END;

-- Relation-pair guards apply to every future metadata refresh.  Unfetched
-- targets are valid staging facts; a fetched target must retain the token that
-- was used to request it.
CREATE TRIGGER galleries_relation_pairs_insert
BEFORE INSERT ON galleries
WHEN (NEW.first_gid IS NULL) <> (NEW.first_token IS NULL)
  OR (NEW.parent_gid IS NULL) <> (NEW.parent_token IS NULL)
  OR (NEW.current_gid IS NULL) <> (NEW.current_token IS NULL)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.first_gid
                AND target.token IS NOT NEW.first_token)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.parent_gid
                AND target.token IS NOT NEW.parent_token)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.current_gid
                AND target.token IS NOT NEW.current_token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.first_gid = NEW.gid
                AND source.first_token IS NOT NEW.token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.parent_gid = NEW.gid
                AND source.parent_token IS NOT NEW.token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.current_gid = NEW.gid
                AND source.current_token IS NOT NEW.token)
BEGIN
    SELECT RAISE(ABORT, 'uploader revision relation has a token mismatch');
END;

CREATE TRIGGER galleries_relation_pairs_update
BEFORE UPDATE OF token, first_gid, first_token, parent_gid, parent_token,
                      current_gid, current_token ON galleries
WHEN (NEW.first_gid IS NULL) <> (NEW.first_token IS NULL)
  OR (NEW.parent_gid IS NULL) <> (NEW.parent_token IS NULL)
  OR (NEW.current_gid IS NULL) <> (NEW.current_token IS NULL)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.first_gid
                AND target.token IS NOT NEW.first_token)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.parent_gid
                AND target.token IS NOT NEW.parent_token)
  OR EXISTS (SELECT 1 FROM galleries AS target
              WHERE target.gid = NEW.current_gid
                AND target.token IS NOT NEW.current_token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.gid <> NEW.gid
                AND source.first_gid = NEW.gid
                AND source.first_token IS NOT NEW.token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.gid <> NEW.gid
                AND source.parent_gid = NEW.gid
                AND source.parent_token IS NOT NEW.token)
  OR EXISTS (SELECT 1 FROM galleries AS source
              WHERE source.gid <> NEW.gid
                AND source.current_gid = NEW.gid
                AND source.current_token IS NOT NEW.token)
BEGIN
    SELECT RAISE(ABORT, 'uploader revision relation has a token mismatch');
END;

-- Recreate the current identity views with uploader-revision representatives.
CREATE VIEW variant_identity_active_membership AS
SELECT member.gid,
       member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
 FROM gallery_variants AS member
 JOIN variant_groups AS grouped
   ON grouped.id = member.group_id AND grouped.identity_active = 1
 WHERE member.membership_state = 'confirmed'
   AND EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                WHERE eligible.gid = member.gid);

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
), representatives AS (
    SELECT representative.revision_gid,
           representative.gid AS terminal_gid
      FROM uploader_revision_representatives AS representative
)
SELECT relevant.gid,
       COALESCE(active.class_gid, representative.terminal_gid, relevant.gid) AS class_gid,
       active.active_group_id,
       COALESCE(active.class_size, 1) AS class_size,
       COALESCE(representative.terminal_gid, relevant.gid) AS terminal_gid
  FROM relevant
  LEFT JOIN representatives AS representative
    ON representative.revision_gid = relevant.gid
  LEFT JOIN variant_identity_active_membership AS active
    ON active.gid = COALESCE(representative.terminal_gid, relevant.gid);

CREATE VIEW variant_identity_review_visibility AS
SELECT review.id AS review_id,
       CASE WHEN EXISTS (
              SELECT 1 FROM variant_groups AS source_group
               WHERE source_group.id = review.group_id
                 AND NOT EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                                  WHERE eligible.gid = source_group.source_gid)
            )
             OR (review.candidate_gid IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM eligible_galleries AS eligible
               WHERE eligible.gid = review.candidate_gid
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
  LEFT JOIN uploader_revision_representatives AS low_rep
    ON low_rep.revision_gid = pair.low_gid
  LEFT JOIN uploader_revision_representatives AS high_rep
    ON high_rep.revision_gid = pair.high_gid
 WHERE review.status = 'resolved'
   AND review.decision = 'different_book'
   AND low_class.class_gid <> high_class.class_gid
   AND NOT (low_rep.component_gid IS NOT NULL
            AND low_rep.component_gid = high_rep.component_gid)
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

-- Refresh the current review-state and scheduling projections only after all
-- terminal membership/decision normalization is visible to the views.
UPDATE variant_groups AS grouped
   SET review_state = projected.review_state,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  FROM variant_identity_group_review_state AS projected
 WHERE projected.group_id = grouped.id;
UPDATE variant_groups AS grouped
   SET active_evaluation_id = NULL,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE grouped.id IN (SELECT owner_id FROM migration_027_group_owner)
   AND EXISTS (
     SELECT 1 FROM migration_027_group_owner AS owner
      JOIN migration_027_members AS member
        ON member.ready = 1 AND member.component_gid IN (
          SELECT component_gid FROM migration_027_members
           WHERE ready = 1 AND terminal_gid <> gid)
      JOIN gallery_variants AS current_member ON current_member.gid = member.gid
     WHERE owner.owner_id = grouped.id
       AND current_member.group_id = grouped.id
   );
UPDATE variant_jobs
   SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
       completed_at = COALESCE(completed_at,
                               strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       last_error = 'schema 27 invalidated automatic evaluation after terminal promotion',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'evaluate'
   AND status IN ('queued', 'leased')
   AND group_id IN (SELECT owner_id FROM migration_027_group_owner)
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_jobs.group_id
                  AND grouped.desired_rating < 11);
UPDATE variant_jobs
   SET priority = MAX(priority, 1000),
       source_gid = (SELECT source_gid FROM variant_groups
                      WHERE id = variant_jobs.group_id),
       expected_evaluation_id = NULL,
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'evaluate' AND status = 'queued'
   AND group_id IN (SELECT owner_id FROM migration_027_group_owner)
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_jobs.group_id
                  AND grouped.desired_rating = 11);
INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
SELECT 'evaluate', grouped.id, grouped.source_gid, 1000, 'queued'
  FROM variant_groups AS grouped
 WHERE grouped.identity_active = 1
   AND grouped.desired_rating = 11
   AND grouped.id IN (SELECT owner_id FROM migration_027_group_owner)
   AND NOT EXISTS (
     SELECT 1 FROM variant_identity_actionable_review AS actionable
      JOIN variant_identity_gid_class AS member_class
        ON member_class.class_gid IN (actionable.low_class_gid,
                                      actionable.high_class_gid)
     WHERE member_class.active_group_id = grouped.id
   );
UPDATE variant_jobs
   SET priority = MAX(priority, 1000),
       source_gid = (SELECT source_gid FROM variant_groups
                      WHERE id = variant_jobs.group_id),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'reconcile_actions' AND status = 'queued'
   AND group_id IN (SELECT owner_id FROM migration_027_group_owner)
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id = variant_jobs.group_id
                  AND grouped.desired_rating BETWEEN 1 AND 10);
INSERT OR IGNORE INTO variant_jobs(job_type, group_id, source_gid, priority, status)
SELECT 'reconcile_actions', grouped.id, grouped.source_gid, 1000, 'queued'
  FROM variant_groups AS grouped
 WHERE grouped.identity_active = 1
   AND grouped.desired_rating BETWEEN 1 AND 10
   AND grouped.id IN (SELECT owner_id FROM migration_027_group_owner);

-- Incomplete components stay retryable.  Do not silently make a malformed
-- schema-26 source disappear without leaving a high-priority refresh job.
UPDATE variant_jobs
   SET priority = MAX(priority, 500),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE job_type='discover' AND status='queued'
   AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.id=variant_jobs.group_id
                  AND grouped.identity_active=1
                  AND NOT EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                                   WHERE eligible.gid=grouped.source_gid));
INSERT OR IGNORE INTO variant_jobs(job_type,group_id,source_gid,priority,status)
SELECT 'discover', grouped.id, grouped.source_gid, 500, 'queued'
  FROM variant_groups AS grouped
 WHERE grouped.identity_active=1
   AND NOT EXISTS (SELECT 1 FROM eligible_galleries AS eligible
                    WHERE eligible.gid=grouped.source_gid)
   AND NOT EXISTS (SELECT 1 FROM variant_jobs AS job
                    WHERE job.group_id=grouped.id
                      AND job.job_type='discover'
                      AND job.status IN ('queued','leased'));

-- Publish the schema version only after all guards, views, and table rebuilds
-- have succeeded.  Temp guard rows/tables disappear at transaction end.
DROP TABLE migration_027_pairs;
DROP TABLE migration_027_action_rank;
DROP TABLE migration_027_obsolete_jobs;
DROP TABLE migration_027_terminal_map;
DROP TABLE migration_027_decision_rank;
DROP TABLE migration_027_feedback_owner;
DROP TABLE migration_027_group_owner;
DROP TABLE migration_027_graph_guard;
DROP TABLE migration_027_graph_blockers;
DROP TABLE migration_027_members;
DROP TABLE migration_027_affected_group;
DROP TABLE migration_027_affected_gid;
DROP TABLE migration_027_affected_component;
DROP TABLE migration_027_relation_guard;
