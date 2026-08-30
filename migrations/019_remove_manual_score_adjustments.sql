-- Keep automatic scores independent from manual identity and canonical
-- decisions. Existing immutable evaluations remain untouched; this migration
-- normalizes only the mutable identity projection and queues local refreshes
-- for legacy manual-canonical projections.
ALTER TABLE variant_evaluations ADD COLUMN canonical_decision_id INTEGER
    REFERENCES variant_canonical_decisions(id);

CREATE INDEX idx_variant_evaluations_canonical_decision
ON variant_evaluations(canonical_decision_id);

CREATE TRIGGER variant_evaluations_validate_canonical_decision_insert
BEFORE INSERT ON variant_evaluations
WHEN NEW.canonical_decision_id IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM variant_canonical_decisions AS decision
      WHERE decision.id = NEW.canonical_decision_id
        AND decision.group_id = NEW.group_id
        AND decision.selected_gid = NEW.selected_canonical_gid
        AND decision.status = 'active'
 )
BEGIN
    SELECT RAISE(ABORT, 'evaluation canonical decision does not match active selection');
END;

-- The historical writer only emitted integer +/-9999 adjustments. Abort on
-- anything else so an unexpected payload is inspected rather than silently
-- changing a current score.
CREATE TEMP TABLE migration_019_adjustment_guard(
    valid INTEGER NOT NULL CHECK (valid = 0)
);
INSERT INTO migration_019_adjustment_guard(valid)
SELECT count(*)
  FROM gallery_variants
 WHERE json_type(evidence_json, '$.manual_adjustment') IS NOT NULL
   AND (json_type(evidence_json, '$.manual_adjustment') <> 'integer'
        OR json_extract(evidence_json, '$.manual_adjustment') NOT IN (-9999, 9999));

UPDATE gallery_variants
   SET match_score = match_score - json_extract(evidence_json, '$.manual_adjustment'),
       evidence_json = json_remove(evidence_json, '$.manual_adjustment'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE json_type(evidence_json, '$.manual_adjustment') = 'integer'
   AND json_extract(evidence_json, '$.manual_adjustment') IN (-9999, 9999);

CREATE TEMP TABLE migration_019_refresh_groups(
    group_id INTEGER PRIMARY KEY,
    source_gid INTEGER NOT NULL,
    evaluation_id INTEGER NOT NULL
);
INSERT INTO migration_019_refresh_groups(group_id, source_gid, evaluation_id)
SELECT grouped.id, grouped.source_gid, grouped.active_evaluation_id
  FROM variant_groups AS grouped
  JOIN variant_evaluations AS evaluation
    ON evaluation.id = grouped.active_evaluation_id
  JOIN variant_canonical_decisions AS decision
    ON decision.group_id = grouped.id AND decision.status = 'active'
 WHERE grouped.is_active = 1
   AND EXISTS (
       SELECT 1
         FROM json_each(evaluation.member_scores_json) AS member_score
        WHERE json_type(member_score.value, '$.components.manual_winner_override') IS NOT NULL
   );

UPDATE variant_jobs AS job
   SET expected_evaluation_id = (
         SELECT refresh.evaluation_id
           FROM migration_019_refresh_groups AS refresh
          WHERE refresh.group_id = job.group_id
       ),
       priority = MAX(priority, 1000),
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job.job_type = 'evaluate'
   AND job.status = 'queued'
   AND EXISTS (
       SELECT 1 FROM migration_019_refresh_groups AS refresh
        WHERE refresh.group_id = job.group_id
   );

INSERT OR IGNORE INTO variant_jobs(
    job_type, group_id, source_gid, priority, status, expected_evaluation_id
)
SELECT 'evaluate', group_id, source_gid, 1000, 'queued', evaluation_id
  FROM migration_019_refresh_groups;
