-- Durable lifecycle events for variant jobs.  This table starts at zero on
-- deployment; existing job rows are state/history and cannot reconstruct the
-- retries and continuations that happened before this migration.
CREATE TABLE variant_job_outcome_counters (
    job_type TEXT NOT NULL CHECK (job_type IN (
        'discover', 'evaluate', 'reconcile_actions', 'reconcile_retention',
        'policy_scoring_sweep'
    )),
    outcome TEXT NOT NULL CHECK (outcome IN (
        'completed', 'continued', 'retryable_error', 'permanent_error',
        'configuration_error', 'cancelled'
    )),
    value INTEGER NOT NULL DEFAULT 0 CHECK (value >= 0),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (job_type, outcome)
);

INSERT INTO variant_job_outcome_counters(job_type, outcome)
VALUES
    ('discover', 'completed'),
    ('discover', 'continued'),
    ('discover', 'retryable_error'),
    ('discover', 'permanent_error'),
    ('discover', 'configuration_error'),
    ('discover', 'cancelled'),
    ('evaluate', 'completed'),
    ('evaluate', 'continued'),
    ('evaluate', 'retryable_error'),
    ('evaluate', 'permanent_error'),
    ('evaluate', 'configuration_error'),
    ('evaluate', 'cancelled'),
    ('reconcile_actions', 'completed'),
    ('reconcile_actions', 'continued'),
    ('reconcile_actions', 'retryable_error'),
    ('reconcile_actions', 'permanent_error'),
    ('reconcile_actions', 'configuration_error'),
    ('reconcile_actions', 'cancelled'),
    ('reconcile_retention', 'completed'),
    ('reconcile_retention', 'continued'),
    ('reconcile_retention', 'retryable_error'),
    ('reconcile_retention', 'permanent_error'),
    ('reconcile_retention', 'configuration_error'),
    ('reconcile_retention', 'cancelled'),
    ('policy_scoring_sweep', 'completed'),
    ('policy_scoring_sweep', 'continued'),
    ('policy_scoring_sweep', 'retryable_error'),
    ('policy_scoring_sweep', 'permanent_error'),
    ('policy_scoring_sweep', 'configuration_error'),
    ('policy_scoring_sweep', 'cancelled');

CREATE TRIGGER variant_jobs_count_lifecycle_outcome
AFTER UPDATE OF status, last_error_class ON variant_jobs
WHEN
    (OLD.status = 'leased' AND NEW.status = 'completed')
 OR (OLD.status = 'leased' AND NEW.status = 'queued'
     AND NEW.last_error_class IS NULL)
 OR (OLD.status = 'leased' AND NEW.status = 'queued'
     AND NEW.last_error_class IN ('transient', 'uncertain'))
 OR (OLD.status = 'leased' AND NEW.status = 'failed'
     AND NEW.last_error_class IN ('permanent', 'configuration'))
 OR (OLD.status IN ('queued', 'leased') AND NEW.status = 'cancelled')
BEGIN
    UPDATE variant_job_outcome_counters
       SET value = value + 1,
           updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
     WHERE job_type = NEW.job_type
       AND outcome = CASE
         WHEN OLD.status = 'leased' AND NEW.status = 'completed'
           THEN 'completed'
         WHEN OLD.status = 'leased' AND NEW.status = 'queued'
              AND NEW.last_error_class IS NULL
           THEN 'continued'
         WHEN OLD.status = 'leased' AND NEW.status = 'queued'
              AND NEW.last_error_class IN ('transient', 'uncertain')
           THEN 'retryable_error'
         WHEN OLD.status = 'leased' AND NEW.status = 'failed'
              AND NEW.last_error_class = 'permanent'
           THEN 'permanent_error'
         WHEN OLD.status = 'leased' AND NEW.status = 'failed'
              AND NEW.last_error_class = 'configuration'
           THEN 'configuration_error'
         WHEN OLD.status IN ('queued', 'leased') AND NEW.status = 'cancelled'
           THEN 'cancelled'
       END;

    SELECT CASE WHEN changes() = 1 THEN 1
                ELSE RAISE(ABORT, 'variant job outcome counter row missing') END;
END;
