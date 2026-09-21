-- Migrate every durable revision-terminal evidence projection to the canonical
-- vocabulary introduced by the discovery/revision/archive refactor.
--
-- 028 contains a temporary copy of this work while the policy migration is
-- being integrated.  This migration is deliberately self-contained so that
-- the evidence rewrite remains correct when that temporary block is removed.
-- Historical migrations are not edited, and no row identity or foreign-key
-- relationship is changed here.

-- A database can contain both spellings after a partially applied/manual
-- rollout.  Equal values are safe to collapse; different values are
-- ambiguous and must abort the whole migration before any durable update.
CREATE TEMP TABLE migration_029_evidence_conflicts(
    source TEXT NOT NULL,
    row_id TEXT NOT NULL,
    field TEXT NOT NULL,
    PRIMARY KEY(source, row_id, field)
);

INSERT INTO migration_029_evidence_conflicts(source, row_id, field)
SELECT 'gallery_variants.evidence', group_id || ':' || gid, 'is_revision_terminal'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
   AND json_type(evidence_json, '$.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.eligible') IS
            json_extract(evidence_json, '$.is_revision_terminal'))
UNION ALL
SELECT 'gallery_variants.evidence', group_id || ':' || gid,
       'uploader_revision.candidate_is_revision_terminal'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(evidence_json, '$.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.uploader_revision.candidate_eligible') IS
            json_extract(evidence_json, '$.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'gallery_variants.latest_discovery', group_id || ':' || gid,
       'is_revision_terminal'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.latest_discovery') = 'object'
   AND json_type(evidence_json, '$.latest_discovery.eligible') IS NOT NULL
   AND json_type(evidence_json, '$.latest_discovery.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.latest_discovery.eligible') IS
            json_extract(evidence_json, '$.latest_discovery.is_revision_terminal'))
UNION ALL
SELECT 'gallery_variants.latest_discovery', group_id || ':' || gid,
       'uploader_revision.candidate_is_revision_terminal'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.latest_discovery') = 'object'
   AND json_type(evidence_json, '$.latest_discovery.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(evidence_json, '$.latest_discovery.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json,
                         '$.latest_discovery.uploader_revision.candidate_eligible') IS
            json_extract(evidence_json,
                         '$.latest_discovery.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_discovery_candidates.evidence', run_id || ':' || gid || ':' || token,
       'is_revision_terminal'
  FROM variant_discovery_candidates
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
   AND json_type(evidence_json, '$.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.eligible') IS
            json_extract(evidence_json, '$.is_revision_terminal'))
UNION ALL
SELECT 'variant_discovery_candidates.evidence', run_id || ':' || gid || ':' || token,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_discovery_candidates
 WHERE json_type(evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(evidence_json, '$.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(evidence_json, '$.uploader_revision.candidate_eligible') IS
            json_extract(evidence_json, '$.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_reviews.evidence', review.id, 'is_revision_terminal'
  FROM variant_reviews AS review
 WHERE json_type(review.evidence_json, '$.eligible') IS NOT NULL
   AND json_type(review.evidence_json, '$.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(review.evidence_json, '$.eligible') IS
            json_extract(review.evidence_json, '$.is_revision_terminal'))
UNION ALL
SELECT 'variant_reviews.evidence', review.id,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_reviews AS review
 WHERE json_type(review.evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(review.evidence_json, '$.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(review.evidence_json, '$.uploader_revision.candidate_eligible') IS
            json_extract(review.evidence_json, '$.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key,
       'is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.eligible') IS NOT NULL
   AND json_type(item.value, '$.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.eligible') IS
            json_extract(item.value, '$.is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(item.value, '$.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.uploader_revision.candidate_eligible') IS
            json_extract(item.value, '$.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot.evidence', evaluation.id || ':' || item.key,
       'is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.evidence') = 'object'
   AND json_type(item.value, '$.evidence.eligible') IS NOT NULL
   AND json_type(item.value, '$.evidence.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.evidence.eligible') IS
            json_extract(item.value, '$.evidence.is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot.evidence', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.evidence') = 'object'
   AND json_type(item.value, '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(item.value, '$.evidence.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.evidence.uploader_revision.candidate_eligible') IS
            json_extract(item.value, '$.evidence.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.member_scores', evaluation.id || ':' || item.key,
       'is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.eligible') IS NOT NULL
   AND json_type(item.value, '$.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.eligible') IS
            json_extract(item.value, '$.is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.member_scores', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(item.value, '$.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.uploader_revision.candidate_eligible') IS
            json_extract(item.value, '$.uploader_revision.candidate_is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.member_scores.evidence', evaluation.id || ':' || item.key,
       'is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.evidence') = 'object'
   AND json_type(item.value, '$.evidence.eligible') IS NOT NULL
   AND json_type(item.value, '$.evidence.is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.evidence.eligible') IS
            json_extract(item.value, '$.evidence.is_revision_terminal'))
UNION ALL
SELECT 'variant_evaluations.member_scores.evidence', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_is_revision_terminal'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.evidence') = 'object'
   AND json_type(item.value, '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL
   AND json_type(item.value, '$.evidence.uploader_revision.candidate_is_revision_terminal') IS NOT NULL
   AND NOT (json_extract(item.value, '$.evidence.uploader_revision.candidate_eligible') IS
            json_extract(item.value, '$.evidence.uploader_revision.candidate_is_revision_terminal'));

CREATE TEMP TABLE migration_029_abort_conflicts(value INTEGER NOT NULL CHECK(value = 0));
CREATE TEMP TRIGGER migration_029_abort_conflicting_evidence
BEFORE INSERT ON migration_029_abort_conflicts
WHEN EXISTS (SELECT 1 FROM migration_029_evidence_conflicts)
BEGIN
    SELECT RAISE(ABORT, 'migration 029 found conflicting legacy and canonical evidence names');
END;
INSERT INTO migration_029_abort_conflicts(value) VALUES (0);

-- Root evidence objects, including the nested latest discovery snapshot.
UPDATE gallery_variants
   SET evidence_json = json_remove(
     CASE
       WHEN json_type(evidence_json,
                      '$.uploader_revision.candidate_eligible') IS NOT NULL
        AND json_type(evidence_json,
                      '$.uploader_revision.candidate_is_revision_terminal') IS NULL
       THEN json_set(
         CASE
           WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
            AND json_type(evidence_json, '$.eligible') IS NOT NULL
           THEN json_set(evidence_json, '$.is_revision_terminal',
                         json_extract(evidence_json, '$.eligible'))
           ELSE evidence_json
         END,
         '$.uploader_revision.candidate_is_revision_terminal',
         json_extract(evidence_json, '$.uploader_revision.candidate_eligible'))
       WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
        AND json_type(evidence_json, '$.eligible') IS NOT NULL
       THEN json_set(evidence_json, '$.is_revision_terminal',
                     json_extract(evidence_json, '$.eligible'))
       ELSE evidence_json
     END,
     '$.eligible', '$.uploader_revision.candidate_eligible')
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
    OR json_type(evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL;

UPDATE gallery_variants
   SET evidence_json = json_set(
     evidence_json,
     '$.latest_discovery',
     json(json_remove(
       CASE
         WHEN json_type(evidence_json,
                        '$.latest_discovery.uploader_revision.candidate_eligible') IS NOT NULL
          AND json_type(evidence_json,
                        '$.latest_discovery.uploader_revision.candidate_is_revision_terminal') IS NULL
         THEN json_set(
           CASE
             WHEN json_type(evidence_json, '$.latest_discovery.is_revision_terminal') IS NULL
              AND json_type(evidence_json, '$.latest_discovery.eligible') IS NOT NULL
             THEN json_set(json_extract(evidence_json, '$.latest_discovery'),
                           '$.is_revision_terminal',
                           json_extract(evidence_json, '$.latest_discovery.eligible'))
             ELSE json_extract(evidence_json, '$.latest_discovery')
           END,
           '$.uploader_revision.candidate_is_revision_terminal',
           json_extract(evidence_json,
                        '$.latest_discovery.uploader_revision.candidate_eligible'))
         WHEN json_type(evidence_json, '$.latest_discovery.is_revision_terminal') IS NULL
          AND json_type(evidence_json, '$.latest_discovery.eligible') IS NOT NULL
         THEN json_set(json_extract(evidence_json, '$.latest_discovery'),
                       '$.is_revision_terminal',
                       json_extract(evidence_json, '$.latest_discovery.eligible'))
         ELSE json_extract(evidence_json, '$.latest_discovery')
       END,
       '$.eligible', '$.uploader_revision.candidate_eligible')))
 WHERE json_type(evidence_json, '$.latest_discovery') = 'object'
   AND (json_type(evidence_json, '$.latest_discovery.eligible') IS NOT NULL
     OR json_type(evidence_json,
                  '$.latest_discovery.uploader_revision.candidate_eligible') IS NOT NULL);

UPDATE variant_discovery_candidates
   SET evidence_json = json_remove(
     CASE
       WHEN json_type(evidence_json,
                      '$.uploader_revision.candidate_eligible') IS NOT NULL
        AND json_type(evidence_json,
                      '$.uploader_revision.candidate_is_revision_terminal') IS NULL
       THEN json_set(
         CASE
           WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
            AND json_type(evidence_json, '$.eligible') IS NOT NULL
           THEN json_set(evidence_json, '$.is_revision_terminal',
                         json_extract(evidence_json, '$.eligible'))
           ELSE evidence_json
         END,
         '$.uploader_revision.candidate_is_revision_terminal',
         json_extract(evidence_json, '$.uploader_revision.candidate_eligible'))
       WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
        AND json_type(evidence_json, '$.eligible') IS NOT NULL
       THEN json_set(evidence_json, '$.is_revision_terminal',
                     json_extract(evidence_json, '$.eligible'))
       ELSE evidence_json
     END,
     '$.eligible', '$.uploader_revision.candidate_eligible')
 WHERE evidence_json IS NOT NULL
   AND (json_type(evidence_json, '$.eligible') IS NOT NULL
     OR json_type(evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL);

UPDATE variant_reviews
   SET evidence_json = json_remove(
     CASE
       WHEN json_type(evidence_json,
                      '$.uploader_revision.candidate_eligible') IS NOT NULL
        AND json_type(evidence_json,
                      '$.uploader_revision.candidate_is_revision_terminal') IS NULL
       THEN json_set(
         CASE
           WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
            AND json_type(evidence_json, '$.eligible') IS NOT NULL
           THEN json_set(evidence_json, '$.is_revision_terminal',
                         json_extract(evidence_json, '$.eligible'))
           ELSE evidence_json
         END,
         '$.uploader_revision.candidate_is_revision_terminal',
         json_extract(evidence_json, '$.uploader_revision.candidate_eligible'))
       WHEN json_type(evidence_json, '$.is_revision_terminal') IS NULL
        AND json_type(evidence_json, '$.eligible') IS NOT NULL
       THEN json_set(evidence_json, '$.is_revision_terminal',
                     json_extract(evidence_json, '$.eligible'))
       ELSE evidence_json
     END,
     '$.eligible', '$.uploader_revision.candidate_eligible')
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
    OR json_type(evidence_json, '$.uploader_revision.candidate_eligible') IS NOT NULL;

-- Evaluation rows are immutable audit records.  Temporarily remove only the
-- update guard, rewrite both JSON arrays in their original order, and restore
-- the guard before the migration commits.  The member-score rewrite is
-- intentionally included even though current producers normally keep evidence
-- in metadata_snapshot_json; it protects older snapshots with that shape.
DROP TRIGGER IF EXISTS variant_evaluations_no_update;

UPDATE variant_evaluations
   SET metadata_snapshot_json = (
     WITH item_roots AS (
       SELECT CAST(item.key AS INTEGER) AS item_order,
              CASE
                WHEN json_type(item.value) IS NOT 'object' THEN item.value
                ELSE json_remove(
                  CASE
                    WHEN json_type(item.value,
                                   '$.uploader_revision.candidate_eligible') IS NOT NULL
                     AND json_type(item.value,
                                   '$.uploader_revision.candidate_is_revision_terminal') IS NULL
                    THEN json_set(
                      CASE
                        WHEN json_type(item.value, '$.is_revision_terminal') IS NULL
                         AND json_type(item.value, '$.eligible') IS NOT NULL
                        THEN json_set(item.value, '$.is_revision_terminal',
                                      json_extract(item.value, '$.eligible'))
                        ELSE item.value
                      END,
                      '$.uploader_revision.candidate_is_revision_terminal',
                      json_extract(item.value, '$.uploader_revision.candidate_eligible'))
                    WHEN json_type(item.value, '$.is_revision_terminal') IS NULL
                     AND json_type(item.value, '$.eligible') IS NOT NULL
                    THEN json_set(item.value, '$.is_revision_terminal',
                                  json_extract(item.value, '$.eligible'))
                    ELSE item.value
                  END,
                  '$.eligible', '$.uploader_revision.candidate_eligible')
              END AS item_json
         FROM json_each(variant_evaluations.metadata_snapshot_json) AS item
     ),
     item_evidence AS (
       SELECT item_order,
              CASE
                WHEN json_type(item_json, '$.evidence') IS NOT 'object' THEN item_json
                ELSE json_set(
                  item_json,
                  '$.evidence',
                  json(json_remove(
                    CASE
                      WHEN json_type(item_json,
                                     '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL
                       AND json_type(item_json,
                                     '$.evidence.uploader_revision.candidate_is_revision_terminal') IS NULL
                      THEN json_set(
                        CASE
                          WHEN json_type(item_json, '$.evidence.is_revision_terminal') IS NULL
                           AND json_type(item_json, '$.evidence.eligible') IS NOT NULL
                          THEN json_set(json_extract(item_json, '$.evidence'),
                                        '$.is_revision_terminal',
                                        json_extract(item_json, '$.evidence.eligible'))
                          ELSE json_extract(item_json, '$.evidence')
                        END,
                        '$.uploader_revision.candidate_is_revision_terminal',
                        json_extract(item_json,
                                     '$.evidence.uploader_revision.candidate_eligible'))
                      WHEN json_type(item_json, '$.evidence.is_revision_terminal') IS NULL
                       AND json_type(item_json, '$.evidence.eligible') IS NOT NULL
                      THEN json_set(json_extract(item_json, '$.evidence'),
                                    '$.is_revision_terminal',
                                    json_extract(item_json, '$.evidence.eligible'))
                      ELSE json_extract(item_json, '$.evidence')
                    END,
                    '$.eligible', '$.uploader_revision.candidate_eligible')))
              END AS item_json
         FROM item_roots
     )
     SELECT COALESCE(json_group_array(json(item_json)), json('[]'))
       FROM (SELECT item_json FROM item_evidence ORDER BY item_order)
   )
 WHERE json_type(metadata_snapshot_json) = 'array';

UPDATE variant_evaluations
   SET member_scores_json = (
     WITH item_roots AS (
       SELECT CAST(item.key AS INTEGER) AS item_order,
              CASE
                WHEN json_type(item.value) IS NOT 'object' THEN item.value
                ELSE json_remove(
                  CASE
                    WHEN json_type(item.value,
                                   '$.uploader_revision.candidate_eligible') IS NOT NULL
                     AND json_type(item.value,
                                   '$.uploader_revision.candidate_is_revision_terminal') IS NULL
                    THEN json_set(
                      CASE
                        WHEN json_type(item.value, '$.is_revision_terminal') IS NULL
                         AND json_type(item.value, '$.eligible') IS NOT NULL
                        THEN json_set(item.value, '$.is_revision_terminal',
                                      json_extract(item.value, '$.eligible'))
                        ELSE item.value
                      END,
                      '$.uploader_revision.candidate_is_revision_terminal',
                      json_extract(item.value, '$.uploader_revision.candidate_eligible'))
                    WHEN json_type(item.value, '$.is_revision_terminal') IS NULL
                     AND json_type(item.value, '$.eligible') IS NOT NULL
                    THEN json_set(item.value, '$.is_revision_terminal',
                                  json_extract(item.value, '$.eligible'))
                    ELSE item.value
                  END,
                  '$.eligible', '$.uploader_revision.candidate_eligible')
              END AS item_json
         FROM json_each(variant_evaluations.member_scores_json) AS item
     ),
     item_evidence AS (
       SELECT item_order,
              CASE
                WHEN json_type(item_json, '$.evidence') IS NOT 'object' THEN item_json
                ELSE json_set(
                  item_json,
                  '$.evidence',
                  json(json_remove(
                    CASE
                      WHEN json_type(item_json,
                                     '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL
                       AND json_type(item_json,
                                     '$.evidence.uploader_revision.candidate_is_revision_terminal') IS NULL
                      THEN json_set(
                        CASE
                          WHEN json_type(item_json, '$.evidence.is_revision_terminal') IS NULL
                           AND json_type(item_json, '$.evidence.eligible') IS NOT NULL
                          THEN json_set(json_extract(item_json, '$.evidence'),
                                        '$.is_revision_terminal',
                                        json_extract(item_json, '$.evidence.eligible'))
                          ELSE json_extract(item_json, '$.evidence')
                        END,
                        '$.uploader_revision.candidate_is_revision_terminal',
                        json_extract(item_json,
                                     '$.evidence.uploader_revision.candidate_eligible'))
                      WHEN json_type(item_json, '$.evidence.is_revision_terminal') IS NULL
                       AND json_type(item_json, '$.evidence.eligible') IS NOT NULL
                      THEN json_set(json_extract(item_json, '$.evidence'),
                                    '$.is_revision_terminal',
                                    json_extract(item_json, '$.evidence.eligible'))
                      ELSE json_extract(item_json, '$.evidence')
                    END,
                    '$.eligible', '$.uploader_revision.candidate_eligible')))
              END AS item_json
         FROM item_roots
     )
     SELECT COALESCE(json_group_array(json(item_json)), json('[]'))
       FROM (SELECT item_json FROM item_evidence ORDER BY item_order)
   )
 WHERE json_type(member_scores_json) = 'array';

CREATE TRIGGER variant_evaluations_no_update
BEFORE UPDATE ON variant_evaluations
BEGIN
    SELECT RAISE(ABORT, 'variant evaluations are immutable');
END;

-- Verify only the revision-evidence paths owned by this migration.  Do not
-- scan every JSON key: a future evidence extension may legitimately contain
-- an unrelated business field named `eligible`.
CREATE TEMP TABLE migration_029_remaining_legacy(
    source TEXT NOT NULL,
    row_id TEXT NOT NULL,
    field TEXT NOT NULL,
    PRIMARY KEY(source, row_id, field)
);
INSERT INTO migration_029_remaining_legacy(source, row_id, field)
SELECT 'gallery_variants.evidence', group_id || ':' || gid, 'eligible'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
UNION ALL
SELECT 'gallery_variants.evidence', group_id || ':' || gid,
       'uploader_revision.candidate_eligible'
  FROM gallery_variants
 WHERE json_type(evidence_json,
                 '$.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'gallery_variants.latest_discovery', group_id || ':' || gid, 'eligible'
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.latest_discovery.eligible') IS NOT NULL
UNION ALL
SELECT 'gallery_variants.latest_discovery', group_id || ':' || gid,
       'uploader_revision.candidate_eligible'
  FROM gallery_variants
 WHERE json_type(evidence_json,
                 '$.latest_discovery.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_discovery_candidates.evidence', run_id || ':' || gid || ':' || token,
       'eligible'
  FROM variant_discovery_candidates
 WHERE json_type(evidence_json, '$.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_discovery_candidates.evidence', run_id || ':' || gid || ':' || token,
       'uploader_revision.candidate_eligible'
  FROM variant_discovery_candidates
 WHERE json_type(evidence_json,
                 '$.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_reviews.evidence', review.id, 'eligible'
  FROM variant_reviews AS review
 WHERE json_type(review.evidence_json, '$.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_reviews.evidence', review.id,
       'uploader_revision.candidate_eligible'
  FROM variant_reviews AS review
 WHERE json_type(review.evidence_json,
                 '$.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key, 'eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value,
                 '$.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot.evidence', evaluation.id || ':' || item.key, 'eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value, '$.evidence.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.metadata_snapshot.evidence', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.metadata_snapshot_json) AS item
 WHERE json_type(item.value,
                 '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.member_scores', evaluation.id || ':' || item.key, 'eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.member_scores', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value,
                 '$.uploader_revision.candidate_eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.member_scores.evidence', evaluation.id || ':' || item.key, 'eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value, '$.evidence.eligible') IS NOT NULL
UNION ALL
SELECT 'variant_evaluations.member_scores.evidence', evaluation.id || ':' || item.key,
       'uploader_revision.candidate_eligible'
  FROM variant_evaluations AS evaluation
  JOIN json_each(evaluation.member_scores_json) AS item
 WHERE json_type(item.value,
                 '$.evidence.uploader_revision.candidate_eligible') IS NOT NULL;

CREATE TEMP TABLE migration_029_abort_remaining(value INTEGER NOT NULL CHECK(value = 0));
CREATE TEMP TRIGGER migration_029_abort_remaining_legacy
BEFORE INSERT ON migration_029_abort_remaining
WHEN EXISTS (SELECT 1 FROM migration_029_remaining_legacy)
BEGIN
    SELECT RAISE(ABORT, 'migration 029 left legacy evidence names behind');
END;
INSERT INTO migration_029_abort_remaining(value) VALUES (0);

DROP TABLE migration_029_abort_remaining;
DROP TABLE migration_029_remaining_legacy;
DROP TABLE migration_029_abort_conflicts;
DROP TABLE migration_029_evidence_conflicts;
