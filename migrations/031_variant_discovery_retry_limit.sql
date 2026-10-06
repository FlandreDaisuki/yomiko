-- Discovery run claim counts include successful phase continuations. Keep a
-- separate bounded counter for transient failures so stalled work cannot
-- monopolize the scheduler indefinitely.
ALTER TABLE variant_discovery_runs
    ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0
        CHECK (retry_count >= 0);
