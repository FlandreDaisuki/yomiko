-- Discovery uses a fixed, code-owned matching identity.  The nullable group
-- value deliberately makes pre-007 completed snapshots immediately stale;
-- migration backfill below gives historical evidence its revision without
-- pretending that those groups have completed a discovery at that revision.
ALTER TABLE variant_groups ADD COLUMN completed_matching_revision INTEGER
    CHECK (completed_matching_revision IS NULL OR completed_matching_revision >= 1);

ALTER TABLE gallery_variants ADD COLUMN matching_revision INTEGER NOT NULL
    DEFAULT 1 CHECK (matching_revision >= 1);

ALTER TABLE variant_reviews ADD COLUMN matching_revision INTEGER
    CHECK (matching_revision IS NULL OR matching_revision >= 1);

CREATE INDEX idx_variant_groups_matching_revision_stale
ON variant_groups(completed_matching_revision, next_discovery_at, id)
WHERE is_active = 1;

-- Candidate-identity reviews have matching evidence; winner reviews remain
-- scoring-policy evidence and intentionally retain NULL here.
CREATE TRIGGER variant_reviews_matching_revision_insert
BEFORE INSERT ON variant_reviews
WHEN (NEW.review_type = 'candidate_identity' AND NEW.matching_revision IS NULL)
  OR (NEW.review_type = 'winner' AND NEW.matching_revision IS NOT NULL)
BEGIN
    SELECT RAISE(ABORT, 'candidate reviews require matching revision; winner reviews do not');
END;

CREATE TRIGGER variant_reviews_matching_revision_update
BEFORE UPDATE OF review_type, matching_revision ON variant_reviews
WHEN (NEW.review_type = 'candidate_identity' AND NEW.matching_revision IS NULL)
  OR (NEW.review_type = 'winner' AND NEW.matching_revision IS NOT NULL)
BEGIN
    SELECT RAISE(ABORT, 'candidate reviews require matching revision; winner reviews do not');
END;

UPDATE variant_reviews
   SET matching_revision = 1
 WHERE review_type = 'candidate_identity' AND matching_revision IS NULL;

CREATE TABLE variant_discovery_runs (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    job_id INTEGER NOT NULL REFERENCES variant_jobs(id),
    matching_revision INTEGER NOT NULL CHECK (matching_revision >= 1),
    phase TEXT NOT NULL CHECK (phase IN (
        'seed_refresh', 'chain_walk', 'search', 'gdata', 'popularity', 'publish'
    )),
    status TEXT NOT NULL DEFAULT 'running' CHECK (status IN (
        'running', 'retryable', 'completed', 'failed', 'cancelled'
    )),
    cursor_json TEXT CHECK (
        cursor_json IS NULL OR
        (json_valid(cursor_json) AND json_type(cursor_json) = 'object')
    ),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    lease_owner TEXT,
    lease_expires_at TEXT,
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN (
        'transient', 'permanent', 'configuration', 'uncertain'
    )),
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT,
    CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL)),
    CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR
        (status <> 'completed' AND completed_at IS NULL)
    )
);

-- A coalesced discover job owns at most one unfinished run.  The second
-- partial index also prevents a stale/duplicate job from running a group
-- concurrently while preserving completed historical runs.
CREATE UNIQUE INDEX idx_variant_discovery_runs_unfinished_job
ON variant_discovery_runs(job_id)
WHERE status IN ('running', 'retryable');
CREATE UNIQUE INDEX idx_variant_discovery_runs_unfinished_group
ON variant_discovery_runs(group_id)
WHERE status IN ('running', 'retryable');
CREATE INDEX idx_variant_discovery_runs_work
ON variant_discovery_runs(status, phase, updated_at, id)
WHERE status IN ('running', 'retryable');
CREATE INDEX idx_variant_discovery_runs_group
ON variant_discovery_runs(group_id, id DESC);

CREATE TABLE variant_discovery_candidates (
    run_id INTEGER NOT NULL REFERENCES variant_discovery_runs(id) ON DELETE CASCADE,
    gid INTEGER NOT NULL CHECK (gid > 0),
    token TEXT NOT NULL CHECK (length(token) > 0),
    matching_revision INTEGER NOT NULL CHECK (matching_revision >= 1),
    expunged INTEGER CHECK (expunged IS NULL OR expunged IN (0, 1)),
    origin_json TEXT NOT NULL DEFAULT '[]'
        CHECK (json_valid(origin_json) AND json_type(origin_json) = 'array'),
    gdata_json TEXT CHECK (gdata_json IS NULL OR json_valid(gdata_json)),
    popularity_json TEXT CHECK (popularity_json IS NULL OR json_valid(popularity_json)),
    evidence_json TEXT CHECK (evidence_json IS NULL OR json_valid(evidence_json)),
    state TEXT NOT NULL DEFAULT 'discovered' CHECK (state IN (
        'discovered', 'gdata_pending', 'gdata_complete', 'popularity_pending',
        'complete', 'error'
    )),
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN (
        'transient', 'permanent', 'configuration', 'uncertain'
    )),
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (run_id, gid, token)
);

CREATE INDEX idx_variant_discovery_candidates_next_work
ON variant_discovery_candidates(run_id, state, gid, token)
WHERE state IN ('discovered', 'gdata_pending', 'gdata_complete', 'popularity_pending');
CREATE INDEX idx_variant_discovery_candidates_gid
ON variant_discovery_candidates(gid, run_id);

CREATE TRIGGER variant_discovery_runs_validate_owner_insert
BEFORE INSERT ON variant_discovery_runs
WHEN NOT EXISTS (
    SELECT 1 FROM variant_jobs
     WHERE id = NEW.job_id AND job_type = 'discover' AND group_id = NEW.group_id
)
BEGIN
    SELECT RAISE(ABORT, 'discovery run must belong to its discover group job');
END;

CREATE TRIGGER variant_discovery_runs_validate_owner_update
BEFORE UPDATE OF group_id, job_id ON variant_discovery_runs
WHEN NOT EXISTS (
    SELECT 1 FROM variant_jobs
     WHERE id = NEW.job_id AND job_type = 'discover' AND group_id = NEW.group_id
)
BEGIN
    SELECT RAISE(ABORT, 'discovery run must belong to its discover group job');
END;

CREATE TRIGGER variant_discovery_candidates_validate_revision_insert
BEFORE INSERT ON variant_discovery_candidates
WHEN NOT EXISTS (
    SELECT 1 FROM variant_discovery_runs
     WHERE id = NEW.run_id AND matching_revision = NEW.matching_revision
)
BEGIN
    SELECT RAISE(ABORT, 'staged candidate revision must match its discovery run');
END;

CREATE TRIGGER variant_discovery_candidates_validate_revision_update
BEFORE UPDATE OF run_id, matching_revision ON variant_discovery_candidates
WHEN NOT EXISTS (
    SELECT 1 FROM variant_discovery_runs
     WHERE id = NEW.run_id AND matching_revision = NEW.matching_revision
)
BEGIN
    SELECT RAISE(ABORT, 'staged candidate revision must match its discovery run');
END;

-- Existing candidate evidence predates durable discovery and uses the initial
-- fixed matching identity.  Winner reviews intentionally remain NULL.
