-- Operational worker state.  The discovery schema remains immutable; this
-- migration only adds the leases, scoring targets, and audit evidence needed
-- by the mutation worker.

ALTER TABLE variant_jobs ADD COLUMN scoring_revision_id INTEGER
    REFERENCES variant_policy_revisions(id)
    CHECK (scoring_revision_id IS NULL OR scoring_revision_id > 0);

UPDATE variant_jobs
   SET scoring_revision_id = (
         SELECT id FROM variant_policy_revisions WHERE is_active = 1
       )
 WHERE job_type IN ('evaluate', 'policy_scoring_sweep')
   AND scoring_revision_id IS NULL;

-- Jobs created by older code are made explicit at insertion time.  Keeping
-- this trigger (rather than a magic DEFAULT) also works when policy revision
-- IDs are not contiguous in an upgraded database.
CREATE TRIGGER variant_jobs_fill_scoring_revision
AFTER INSERT ON variant_jobs
WHEN NEW.job_type IN ('evaluate', 'policy_scoring_sweep')
 AND NEW.scoring_revision_id IS NULL
BEGIN
    UPDATE variant_jobs
       SET scoring_revision_id = (
             SELECT id FROM variant_policy_revisions WHERE is_active = 1
           )
     WHERE id = NEW.id;
END;

CREATE TRIGGER variant_jobs_validate_scoring_revision_insert
BEFORE INSERT ON variant_jobs
WHEN NEW.scoring_revision_id IS NOT NULL
 AND NEW.job_type IN ('evaluate', 'policy_scoring_sweep')
 AND NOT EXISTS (SELECT 1 FROM variant_policy_revisions
                  WHERE id = NEW.scoring_revision_id)
BEGIN
    SELECT RAISE(ABORT, 'job scoring revision does not exist');
END;

CREATE TRIGGER variant_jobs_validate_scoring_revision_update
BEFORE UPDATE OF job_type, scoring_revision_id ON variant_jobs
WHEN NEW.scoring_revision_id IS NOT NULL
 AND NEW.job_type IN ('evaluate', 'policy_scoring_sweep')
 AND NOT EXISTS (SELECT 1 FROM variant_policy_revisions
                  WHERE id = NEW.scoring_revision_id)
BEGIN
    SELECT RAISE(ABORT, 'job scoring revision does not exist');
END;

CREATE TRIGGER variant_jobs_reject_unrelated_scoring_revision_insert
BEFORE INSERT ON variant_jobs
WHEN NEW.job_type NOT IN ('evaluate', 'policy_scoring_sweep')
 AND NEW.scoring_revision_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'only scoring jobs may target a scoring revision');
END;

CREATE TRIGGER variant_jobs_reject_unrelated_scoring_revision_update
BEFORE UPDATE OF job_type, scoring_revision_id ON variant_jobs
WHEN NEW.job_type NOT IN ('evaluate', 'policy_scoring_sweep')
 AND NEW.scoring_revision_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'only scoring jobs may target a scoring revision');
END;

CREATE INDEX idx_variant_jobs_scoring_target
ON variant_jobs(job_type, scoring_revision_id, status, id)
WHERE job_type IN ('evaluate', 'policy_scoring_sweep');

ALTER TABLE variant_actions ADD COLUMN lease_owner TEXT;
ALTER TABLE variant_actions ADD COLUMN lease_expires_at TEXT;
ALTER TABLE variant_actions ADD COLUMN lease_job_id INTEGER
    REFERENCES variant_jobs(id);
ALTER TABLE variant_actions ADD COLUMN last_error_class TEXT
    CHECK (last_error_class IS NULL OR last_error_class IN (
      'transient', 'permanent', 'configuration', 'uncertain'
    ));

-- Rows that were in-flight before leases became durable cannot be proven to
-- have reached the remote endpoint.  Reopen them conservatively as uncertain
-- retries during the migration itself.
UPDATE variant_actions
   SET status = 'retryable_error', lease_owner = NULL,
       lease_expires_at = NULL, lease_job_id = NULL,
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       last_error_class = 'uncertain',
       last_error = COALESCE(last_error,
         'pre-008 in-flight action reopened; remote result is uncertain'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'in_flight';

UPDATE variant_actions
   SET last_error_class = CASE status
         WHEN 'retryable_error' THEN 'uncertain'
         WHEN 'permanent_error' THEN 'permanent'
         WHEN 'configuration_error' THEN 'configuration'
       END
 WHERE status IN ('retryable_error', 'permanent_error', 'configuration_error')
   AND last_error_class IS NULL;

-- A pre-008 crash could leave an action in flight without an action lease.
-- Preserve the attempt and make its uncertain outcome explicitly retryable.
UPDATE variant_actions
   SET status = 'retryable_error',
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       last_error_class = 'uncertain',
       last_error = 'pre-008 in-flight action outcome is uncertain',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'in_flight';

CREATE INDEX idx_variant_actions_expired_lease
ON variant_actions(lease_expires_at, id)
WHERE status = 'in_flight';
CREATE INDEX idx_variant_actions_lease_job
ON variant_actions(lease_job_id, status, id)
WHERE lease_job_id IS NOT NULL;
CREATE INDEX idx_variant_actions_error_class
ON variant_actions(status, last_error_class, available_at, id)
WHERE status IN ('retryable_error', 'configuration_error', 'in_flight');

CREATE TRIGGER variant_actions_validate_lease_insert
BEFORE INSERT ON variant_actions
WHEN (NEW.status = 'in_flight' AND
      (NEW.lease_owner IS NULL OR NEW.lease_expires_at IS NULL OR
       NEW.lease_job_id IS NULL))
  OR (NEW.status <> 'in_flight' AND
      (NEW.lease_owner IS NOT NULL OR NEW.lease_expires_at IS NOT NULL OR
       NEW.lease_job_id IS NOT NULL))
BEGIN
    SELECT RAISE(ABORT, 'in-flight actions require an action lease');
END;

CREATE TRIGGER variant_actions_validate_lease_update
BEFORE UPDATE OF status, lease_owner, lease_expires_at, lease_job_id
ON variant_actions
WHEN (NEW.status = 'in_flight' AND
      (NEW.lease_owner IS NULL OR NEW.lease_expires_at IS NULL OR
       NEW.lease_job_id IS NULL))
  OR (NEW.status <> 'in_flight' AND
      (NEW.lease_owner IS NOT NULL OR NEW.lease_expires_at IS NOT NULL OR
       NEW.lease_job_id IS NOT NULL))
BEGIN
    SELECT RAISE(ABORT, 'in-flight actions require an action lease');
END;

CREATE TRIGGER variant_actions_validate_lease_job_insert
BEFORE INSERT ON variant_actions
WHEN NEW.lease_job_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM variant_jobs
                  WHERE id = NEW.lease_job_id
                    AND job_type = 'reconcile_actions'
                    AND group_id = NEW.group_id)
BEGIN
    SELECT RAISE(ABORT, 'action lease must belong to reconciliation job');
END;

CREATE TRIGGER variant_actions_validate_lease_job_update
BEFORE UPDATE OF group_id, lease_job_id ON variant_actions
WHEN NEW.lease_job_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM variant_jobs
                  WHERE id = NEW.lease_job_id
                    AND job_type = 'reconcile_actions'
                    AND group_id = NEW.group_id)
BEGIN
    SELECT RAISE(ABORT, 'action lease must belong to reconciliation job');
END;

CREATE TRIGGER variant_actions_validate_error_class_insert
BEFORE INSERT ON variant_actions
WHEN (NEW.status = 'retryable_error' AND
      COALESCE(NEW.last_error_class, '') NOT IN ('transient', 'uncertain'))
  OR (NEW.status = 'permanent_error' AND
      COALESCE(NEW.last_error_class, '') <> 'permanent')
  OR (NEW.status = 'configuration_error' AND
      COALESCE(NEW.last_error_class, '') <> 'configuration')
BEGIN
    SELECT RAISE(ABORT, 'action error status requires matching classification');
END;

CREATE TRIGGER variant_actions_validate_error_class_update
BEFORE UPDATE OF status, last_error_class ON variant_actions
WHEN (NEW.status = 'retryable_error' AND
      COALESCE(NEW.last_error_class, '') NOT IN ('transient', 'uncertain'))
  OR (NEW.status = 'permanent_error' AND
      COALESCE(NEW.last_error_class, '') <> 'permanent')
  OR (NEW.status = 'configuration_error' AND
      COALESCE(NEW.last_error_class, '') <> 'configuration')
BEGIN
    SELECT RAISE(ABORT, 'action error status requires matching classification');
END;

ALTER TABLE variant_reviews ADD COLUMN superseded_at TEXT;
CREATE INDEX idx_variant_reviews_pending_current
ON variant_reviews(group_id, evaluation_id, id)
WHERE review_type = 'winner' AND status = 'pending' AND superseded_at IS NULL;

-- A new immutable evaluation supersedes an older pending winner choice.  The
-- row remains audit history and is filtered from current pending views by its
-- timestamp; the existing status/decision CHECKs remain valid.
CREATE TRIGGER variant_reviews_supersede_winner_evaluation
AFTER INSERT ON variant_evaluations
BEGIN
    UPDATE variant_reviews
       SET superseded_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
     WHERE review_type = 'winner' AND status = 'pending'
       AND superseded_at IS NULL AND group_id = NEW.group_id
       AND evaluation_id <> NEW.id;
END;

CREATE TRIGGER variant_reviews_superseded_not_pending
BEFORE UPDATE OF status, superseded_at ON variant_reviews
WHEN NEW.superseded_at IS NOT NULL AND NEW.status = 'pending'
     AND NEW.review_type <> 'winner'
BEGIN
    SELECT RAISE(ABORT, 'only winner reviews may be superseded');
END;
