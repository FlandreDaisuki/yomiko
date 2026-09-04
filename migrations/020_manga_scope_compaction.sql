-- Restrict the stored EXH corpus to validated Manga galleries, then remove
-- category from the durable schema and compact historical variant evidence.

CREATE TEMP TABLE migration_020_purge(
    gid INTEGER PRIMARY KEY
);

INSERT INTO migration_020_purge(gid)
SELECT gid FROM galleries
 WHERE category IS NOT NULL AND category <> 'Manga';

CREATE TEMP TABLE migration_020_blockers(
    gid INTEGER NOT NULL,
    reason TEXT NOT NULL,
    PRIMARY KEY (gid, reason)
);

INSERT INTO migration_020_blockers(gid, reason)
SELECT purge.gid, 'local archive path'
  FROM migration_020_purge AS purge
  JOIN galleries AS gallery ON gallery.gid = purge.gid
 WHERE gallery.file_path IS NOT NULL AND length(gallery.file_path) > 0;

INSERT INTO migration_020_blockers(gid, reason)
SELECT purge.gid, 'variant-group source or canonical'
  FROM migration_020_purge AS purge
 WHERE EXISTS (SELECT 1 FROM variant_groups AS grouped
                WHERE grouped.source_gid = purge.gid
                   OR grouped.canonical_gid = purge.gid);

INSERT INTO migration_020_blockers(gid, reason)
SELECT purge.gid, 'evaluation selected canonical'
  FROM migration_020_purge AS purge
 WHERE EXISTS (SELECT 1 FROM variant_evaluations AS evaluation
                WHERE evaluation.selected_canonical_gid = purge.gid);

INSERT INTO migration_020_blockers(gid, reason)
SELECT purge.gid, 'winner-review choice'
  FROM migration_020_purge AS purge
 WHERE EXISTS (
   SELECT 1 FROM variant_reviews AS review
    JOIN json_each(review.choices_json) AS choice
   WHERE review.review_type = 'winner'
     AND CAST(choice.value AS INTEGER) = purge.gid
 );

INSERT INTO migration_020_blockers(gid, reason)
SELECT purge.gid, 'winner-review selection'
  FROM migration_020_purge AS purge
 WHERE EXISTS (
   SELECT 1 FROM variant_reviews AS review
    WHERE review.review_type = 'winner'
      AND review.selected_gid = purge.gid
 );

-- Print exact repair targets before aborting. The guard makes this migration
-- atomic, so the diagnostic never accompanies a partially applied purge.
SELECT printf('migration 020 purge blocked: GID %d: %s', gid, reason)
  FROM migration_020_blockers
 ORDER BY gid, reason;

CREATE TEMP TABLE migration_020_guard(value INTEGER NOT NULL CHECK (value = 0));
CREATE TEMP TRIGGER migration_020_abort_blocked_purge
BEFORE INSERT ON migration_020_guard
WHEN EXISTS (SELECT 1 FROM migration_020_blockers)
BEGIN
    SELECT RAISE(ABORT, 'migration 020 purge targets have blockers');
END;
INSERT INTO migration_020_guard(value) VALUES (0);

CREATE TEMP TABLE migration_020_affected_groups(
    group_id INTEGER PRIMARY KEY
);
INSERT OR IGNORE INTO migration_020_affected_groups(group_id)
SELECT member.group_id
  FROM gallery_variants AS member
  JOIN migration_020_purge AS purge ON purge.gid = member.gid
  JOIN variant_groups AS grouped ON grouped.id = member.group_id
 WHERE grouped.is_active = 1;
INSERT OR IGNORE INTO migration_020_affected_groups(group_id)
SELECT review.group_id
  FROM variant_reviews AS review
  JOIN migration_020_purge AS purge ON purge.gid = review.candidate_gid
  JOIN variant_groups AS grouped ON grouped.id = review.group_id
 WHERE grouped.is_active = 1;
INSERT OR IGNORE INTO migration_020_affected_groups(group_id)
SELECT action.group_id
  FROM variant_actions AS action
  JOIN migration_020_purge AS purge ON purge.gid = action.gid
  JOIN variant_groups AS grouped ON grouped.id = action.group_id
 WHERE grouped.is_active = 1;

-- Evaluation rows are immutable audit records, but their member arrays and
-- canonical-decision fingerprints are mutable projections of the membership
-- set. Temporarily suspend only the evaluation update trigger while removing
-- purged members from those arrays.
DROP TRIGGER variant_evaluations_no_update;

UPDATE variant_evaluations AS evaluation
   SET metadata_snapshot_json = (
         SELECT COALESCE(json_group_array(json(item.value)), json('[]'))
           FROM (
             SELECT json_remove(value, '$.category') AS value
               FROM json_each(evaluation.metadata_snapshot_json)
              WHERE NOT EXISTS (
                SELECT 1 FROM migration_020_purge AS purge
                 WHERE CAST(json_extract(value, '$.gid') AS INTEGER) = purge.gid
              )
              ORDER BY CAST(key AS INTEGER)
           ) AS item
       ),
       member_scores_json = (
         SELECT COALESCE(json_group_array(json(item.value)), json('[]'))
           FROM (
             SELECT json_remove(value, '$.category') AS value
               FROM json_each(evaluation.member_scores_json)
              WHERE NOT EXISTS (
                SELECT 1 FROM migration_020_purge AS purge
                 WHERE CAST(json_extract(value, '$.gid') AS INTEGER) = purge.gid
              )
              ORDER BY CAST(key AS INTEGER)
           ) AS item
       )
 WHERE EXISTS (
         SELECT 1 FROM json_each(evaluation.metadata_snapshot_json) AS item
          WHERE CAST(json_extract(item.value, '$.gid') AS INTEGER)
                IN (SELECT gid FROM migration_020_purge)
       )
    OR EXISTS (
         SELECT 1 FROM json_each(evaluation.member_scores_json) AS item
          WHERE CAST(json_extract(item.value, '$.gid') AS INTEGER)
                IN (SELECT gid FROM migration_020_purge)
       )
    OR EXISTS (
         SELECT 1 FROM json_each(evaluation.metadata_snapshot_json) AS item
          WHERE json_type(item.value, '$.category') IS NOT NULL
       )
    OR EXISTS (
         SELECT 1 FROM json_each(evaluation.member_scores_json) AS item
          WHERE json_type(item.value, '$.category') IS NOT NULL
       );

UPDATE variant_canonical_decisions AS decision
   SET member_fingerprint = (
         SELECT COALESCE(json_group_array(CAST(item.value AS INTEGER)), json('[]'))
           FROM (
             SELECT value FROM json_each(decision.member_fingerprint)
              WHERE NOT EXISTS (
                SELECT 1 FROM migration_020_purge AS purge
                 WHERE CAST(value AS INTEGER) = purge.gid
              )
              ORDER BY CAST(key AS INTEGER)
           ) AS item
       )
 WHERE EXISTS (
         SELECT 1 FROM json_each(decision.member_fingerprint) AS item
          WHERE CAST(item.value AS INTEGER) IN (SELECT gid FROM migration_020_purge)
       );

CREATE TRIGGER variant_evaluations_no_update
BEFORE UPDATE ON variant_evaluations
BEGIN
    SELECT RAISE(ABORT, 'variant evaluations are immutable');
END;

-- Remove category from every surviving frozen metadata object. Evaluation
-- scoring snapshots already omit this EXH field and are intentionally left
-- unchanged apart from purge-member removal above.
UPDATE gallery_variants
   SET metadata_snapshot_json = json_remove(metadata_snapshot_json, '$.category');
UPDATE variant_discovery_candidates
   SET gdata_json = json_remove(gdata_json, '$.category')
 WHERE gdata_json IS NOT NULL;
UPDATE variant_reviews
   SET evidence_json = json_remove(
         evidence_json,
         '$.source_snapshot.category', '$.candidate_snapshot.category');

-- Resolved candidate reviews retain their provenance and endpoint GIDs but no
-- longer retain full frozen snapshots. Pending reviews, including reversible
-- superseded pending rows, remain complete.
UPDATE variant_reviews
   SET evidence_json = json_set(
         evidence_json,
         '$.source_snapshot', json_object(
           'gid', json_extract(evidence_json, '$.source_snapshot.gid')),
         '$.candidate_snapshot', json_object(
           'gid', json_extract(evidence_json, '$.candidate_snapshot.gid')))
 WHERE review_type = 'candidate_identity'
   AND status = 'resolved'
   AND json_type(evidence_json, '$.source_snapshot') = 'object'
   AND json_type(evidence_json, '$.candidate_snapshot') = 'object';

-- Remove direct relational history for safe purge targets. Legacy NULL-category
-- rows are deliberately absent from migration_020_purge and remain intact.
DELETE FROM gallery_identity_pairs
 WHERE low_gid IN (SELECT gid FROM migration_020_purge)
    OR high_gid IN (SELECT gid FROM migration_020_purge);
DELETE FROM variant_reviews
 WHERE review_type = 'candidate_identity'
   AND (candidate_gid IN (SELECT gid FROM migration_020_purge)
        OR group_id IN (
          SELECT grouped.id FROM variant_groups AS grouped
           WHERE grouped.source_gid IN (SELECT gid FROM migration_020_purge)
        ));

CREATE TEMP TABLE migration_020_direct_jobs(
    job_id INTEGER PRIMARY KEY
);
INSERT INTO migration_020_direct_jobs(job_id)
SELECT id FROM variant_jobs
 WHERE source_gid IN (SELECT gid FROM migration_020_purge);

DELETE FROM variant_actions
 WHERE gid IN (SELECT gid FROM migration_020_purge);

-- A reconciliation job can lease another member's action. Reopen such an
-- action as uncertain before deleting the job so the lease foreign key and
-- lease invariants remain valid while preserving the retryable history.
UPDATE variant_actions
   SET status = 'retryable_error', lease_owner = NULL,
       lease_expires_at = NULL, lease_job_id = NULL,
       last_error_class = 'uncertain',
       last_error = 'migration 020 removed the reconciliation job',
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE lease_job_id IN (SELECT job_id FROM migration_020_direct_jobs);

-- Discovery runs own candidate staging and reference their jobs, so remove
-- those runs before removing a direct job reference.
DELETE FROM variant_discovery_runs
 WHERE job_id IN (SELECT job_id FROM migration_020_direct_jobs);
DELETE FROM variant_jobs
 WHERE id IN (SELECT job_id FROM migration_020_direct_jobs);
DELETE FROM gallery_variants
 WHERE gid IN (SELECT gid FROM migration_020_purge);
DELETE FROM galleries
 WHERE gid IN (SELECT gid FROM migration_020_purge);

-- Coalesce one local reevaluation for every affected active group after the
-- membership and direct-history deletes have completed.
UPDATE variant_jobs
   SET priority = MAX(priority, 1000),
       source_gid = (SELECT source_gid FROM variant_groups
                      WHERE id = variant_jobs.group_id),
       expected_evaluation_id = (SELECT active_evaluation_id FROM variant_groups
                                  WHERE id = variant_jobs.group_id),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'evaluate' AND status = 'queued'
   AND group_id IN (SELECT group_id FROM migration_020_affected_groups);
INSERT OR IGNORE INTO variant_jobs(
    job_type, group_id, source_gid, priority, status, expected_evaluation_id)
SELECT 'evaluate', grouped.id, grouped.source_gid, 1000, 'queued',
       grouped.active_evaluation_id
  FROM variant_groups AS grouped
 WHERE grouped.is_active = 1
   AND grouped.id IN (SELECT group_id FROM migration_020_affected_groups);

-- Completed discovery is historical publication metadata only. Failed and
-- retryable runs retain their candidates and cursor for diagnosis/resumption.
DELETE FROM variant_discovery_candidates
 WHERE run_id IN (SELECT id FROM variant_discovery_runs WHERE status = 'completed');
UPDATE variant_discovery_runs
   SET cursor_json = NULL
 WHERE status = 'completed';

ALTER TABLE galleries DROP COLUMN category;

INSERT INTO schema_maintenance(name, status)
VALUES ('vacuum_after_020', 'pending')
ON CONFLICT(name) DO UPDATE SET
    status = 'pending', completed_at = NULL,
    queued_at = excluded.queued_at;
