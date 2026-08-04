-- Metadata used by variant matching and scoring. Chain "key" values are
-- gallery tokens returned by gdata and are intentionally stored as text.
ALTER TABLE galleries ADD COLUMN category TEXT;
ALTER TABLE galleries ADD COLUMN uploader TEXT;
ALTER TABLE galleries ADD COLUMN posted INTEGER CHECK (posted IS NULL OR posted >= 0);
ALTER TABLE galleries ADD COLUMN filesize INTEGER CHECK (filesize IS NULL OR filesize >= 0);
ALTER TABLE galleries ADD COLUMN thumb TEXT;
ALTER TABLE galleries ADD COLUMN first_gid INTEGER CHECK (first_gid IS NULL OR first_gid > 0);
ALTER TABLE galleries ADD COLUMN first_key TEXT;
ALTER TABLE galleries ADD COLUMN parent_gid INTEGER CHECK (parent_gid IS NULL OR parent_gid > 0);
ALTER TABLE galleries ADD COLUMN parent_key TEXT;
ALTER TABLE galleries ADD COLUMN current_gid INTEGER CHECK (current_gid IS NULL OR current_gid > 0);
ALTER TABLE galleries ADD COLUMN current_key TEXT;

CREATE TABLE variant_policy_revisions (
    id INTEGER PRIMARY KEY,
    policy_json TEXT NOT NULL CHECK (json_valid(policy_json)),
    content_hash TEXT NOT NULL UNIQUE CHECK (length(content_hash) = 64),
    matching_hash TEXT NOT NULL CHECK (length(matching_hash) = 64),
    scoring_hash TEXT NOT NULL CHECK (length(scoring_hash) = 64),
    operations_hash TEXT NOT NULL CHECK (length(operations_hash) = 64),
    is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    activated_at TEXT
);

CREATE UNIQUE INDEX idx_variant_policy_one_active
ON variant_policy_revisions(is_active) WHERE is_active = 1;

-- Policy contents and hashes are immutable. Activation is lifecycle state and
-- is the only part of a revision that may change.
CREATE TRIGGER variant_policy_revisions_immutable_content
BEFORE UPDATE OF policy_json, content_hash, matching_hash, scoring_hash,
                 operations_hash, created_at ON variant_policy_revisions
BEGIN
    SELECT RAISE(ABORT, 'variant policy revision content is immutable');
END;

CREATE TRIGGER variant_policy_revisions_no_delete
BEFORE DELETE ON variant_policy_revisions
BEGIN
    SELECT RAISE(ABORT, 'variant policy revisions cannot be deleted');
END;

CREATE TABLE variant_groups (
    id INTEGER PRIMARY KEY,
    source_gid INTEGER NOT NULL REFERENCES galleries(gid),
    desired_rating INTEGER NOT NULL CHECK (desired_rating BETWEEN 1 AND 11),
    is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    canonical_gid INTEGER REFERENCES galleries(gid),
    last_discovered_at TEXT,
    last_evaluated_at TEXT,
    next_discovery_at TEXT,
    active_evaluation_id INTEGER REFERENCES variant_evaluations(id),
    review_state TEXT NOT NULL DEFAULT 'none'
        CHECK (review_state IN ('none', 'candidate_pending', 'winner_pending')),
    latest_feedback_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX idx_variant_groups_source ON variant_groups(source_gid);
CREATE INDEX idx_variant_groups_stale
ON variant_groups(next_discovery_at, id) WHERE is_active = 1;
CREATE INDEX idx_variant_groups_active_evaluation
ON variant_groups(active_evaluation_id) WHERE active_evaluation_id IS NOT NULL;

CREATE TABLE gallery_variants (
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    gid INTEGER NOT NULL REFERENCES galleries(gid),
    membership_state TEXT NOT NULL
        CHECK (membership_state IN ('candidate', 'confirmed', 'rejected')),
    decision_source TEXT NOT NULL
        CHECK (decision_source IN ('automatic', 'manual')),
    match_score INTEGER NOT NULL DEFAULT 0,
    evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
    metadata_snapshot_json TEXT NOT NULL CHECK (json_valid(metadata_snapshot_json)),
    variant_score INTEGER,
    variant_score_json TEXT
        CHECK (variant_score_json IS NULL OR json_valid(variant_score_json)),
    variant_state TEXT NOT NULL DEFAULT 'undetermined'
        CHECK (variant_state IN ('undetermined', 'canonical', 'alternate')),
    decided_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (group_id, gid)
);

CREATE INDEX idx_gallery_variants_gid_state
ON gallery_variants(gid, membership_state, group_id);
CREATE INDEX idx_gallery_variants_group_state
ON gallery_variants(group_id, membership_state, variant_state, gid);

-- A candidate may occur in multiple unresolved groups. A confirmed member may
-- occur in historical inactive groups, but never in two active groups.
CREATE TRIGGER gallery_variants_one_active_group_insert
BEFORE INSERT ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups WHERE id = NEW.group_id AND is_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.is_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another active variant group');
END;

CREATE TRIGGER gallery_variants_one_active_group_update
BEFORE UPDATE OF group_id, gid, membership_state ON gallery_variants
WHEN NEW.membership_state = 'confirmed'
 AND EXISTS (SELECT 1 FROM variant_groups WHERE id = NEW.group_id AND is_active = 1)
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id = member.group_id
      WHERE member.gid = NEW.gid
        AND member.membership_state = 'confirmed'
        AND grouped.is_active = 1
        AND member.group_id <> NEW.group_id
 )
BEGIN
    SELECT RAISE(ABORT, 'gallery is already confirmed in another active variant group');
END;

CREATE TRIGGER variant_groups_no_conflict_on_activation
BEFORE UPDATE OF is_active ON variant_groups
WHEN OLD.is_active = 0 AND NEW.is_active = 1
 AND EXISTS (
     SELECT 1
       FROM gallery_variants AS member
       JOIN gallery_variants AS other ON other.gid = member.gid
       JOIN variant_groups AS other_group ON other_group.id = other.group_id
      WHERE member.group_id = NEW.id
        AND member.membership_state = 'confirmed'
        AND other.membership_state = 'confirmed'
        AND other.group_id <> NEW.id
        AND other_group.is_active = 1
 )
BEGIN
    SELECT RAISE(ABORT, 'variant group has a member confirmed in another active group');
END;

-- A group canonical cannot be silently orphaned by mutating the membership
-- row that makes the pointer valid. Change/clear the group pointer first.
CREATE TRIGGER gallery_variants_preserve_canonical_update
BEFORE UPDATE OF group_id, gid, membership_state ON gallery_variants
WHEN EXISTS (
    SELECT 1 FROM variant_groups
     WHERE id = OLD.group_id AND canonical_gid = OLD.gid
)
 AND (
     NEW.group_id <> OLD.group_id
     OR NEW.gid <> OLD.gid
     OR NEW.membership_state <> 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must remain a confirmed group member');
END;

CREATE TRIGGER gallery_variants_preserve_canonical_delete
BEFORE DELETE ON gallery_variants
WHEN EXISTS (
    SELECT 1 FROM variant_groups
     WHERE id = OLD.group_id AND canonical_gid = OLD.gid
)
BEGIN
    SELECT RAISE(ABORT, 'canonical gallery must remain a confirmed group member');
END;

CREATE TABLE variant_evaluations (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    policy_revision_id INTEGER NOT NULL REFERENCES variant_policy_revisions(id),
    supersedes_evaluation_id INTEGER REFERENCES variant_evaluations(id),
    state TEXT NOT NULL CHECK (state IN ('completed', 'review_blocked')),
    metadata_snapshot_json TEXT NOT NULL CHECK (json_valid(metadata_snapshot_json)),
    member_scores_json TEXT NOT NULL CHECK (json_valid(member_scores_json)),
    selected_canonical_gid INTEGER REFERENCES galleries(gid),
    tied_gids_json TEXT CHECK (tied_gids_json IS NULL OR json_valid(tied_gids_json)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    CHECK (
        (state = 'completed' AND selected_canonical_gid IS NOT NULL AND tied_gids_json IS NULL)
        OR
        (state = 'review_blocked' AND selected_canonical_gid IS NULL AND tied_gids_json IS NOT NULL)
    )
);

CREATE INDEX idx_variant_evaluations_group
ON variant_evaluations(group_id, id DESC);
CREATE INDEX idx_variant_evaluations_policy
ON variant_evaluations(policy_revision_id, group_id);

CREATE TRIGGER variant_evaluations_no_update
BEFORE UPDATE ON variant_evaluations
BEGIN
    SELECT RAISE(ABORT, 'variant evaluations are immutable');
END;

CREATE TRIGGER variant_evaluations_no_delete
BEFORE DELETE ON variant_evaluations
BEGIN
    SELECT RAISE(ABORT, 'variant evaluations cannot be deleted');
END;

CREATE TRIGGER variant_evaluations_validate_canonical_insert
BEFORE INSERT ON variant_evaluations
WHEN NEW.selected_canonical_gid IS NOT NULL
 AND NOT EXISTS (
     SELECT 1 FROM gallery_variants
      WHERE group_id = NEW.group_id
        AND gid = NEW.selected_canonical_gid
        AND membership_state = 'confirmed'
 )
BEGIN
    SELECT RAISE(ABORT, 'evaluation canonical must be a confirmed group member');
END;

CREATE TABLE variant_jobs (
    id INTEGER PRIMARY KEY,
    job_type TEXT NOT NULL CHECK (job_type IN (
        'discover', 'evaluate', 'reconcile_actions', 'reconcile_retention',
        'policy_scoring_sweep'
    )),
    group_id INTEGER REFERENCES variant_groups(id),
    source_gid INTEGER REFERENCES galleries(gid),
    priority INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN (
        'queued', 'leased', 'completed', 'failed', 'cancelled'
    )),
    continuation_cursor_json TEXT
        CHECK (continuation_cursor_json IS NULL OR json_valid(continuation_cursor_json)),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    available_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    lease_owner TEXT,
    lease_expires_at TEXT,
    last_error_class TEXT CHECK (last_error_class IS NULL OR last_error_class IN (
        'transient', 'permanent', 'configuration', 'uncertain'
    )),
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT,
    CHECK (
        (job_type = 'policy_scoring_sweep' AND group_id IS NULL)
        OR
        (job_type <> 'policy_scoring_sweep' AND group_id IS NOT NULL)
    ),
    CHECK (status = 'leased' OR (lease_owner IS NULL AND lease_expires_at IS NULL))
);

CREATE UNIQUE INDEX idx_variant_jobs_coalesced_group
ON variant_jobs(group_id, job_type)
WHERE group_id IS NOT NULL AND status IN ('queued', 'leased');
CREATE UNIQUE INDEX idx_variant_jobs_coalesced_policy_sweep
ON variant_jobs(job_type)
WHERE group_id IS NULL AND status IN ('queued', 'leased');
CREATE INDEX idx_variant_jobs_runnable
ON variant_jobs(status, available_at, priority DESC, id)
WHERE status = 'queued';
CREATE INDEX idx_variant_jobs_expired_lease
ON variant_jobs(lease_expires_at, priority DESC, id)
WHERE status = 'leased';
CREATE INDEX idx_variant_jobs_policy_cursor
ON variant_jobs(job_type, status, id)
WHERE job_type = 'policy_scoring_sweep';

CREATE TABLE variant_actions (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    evaluation_id INTEGER REFERENCES variant_evaluations(id),
    gid INTEGER NOT NULL REFERENCES galleries(gid),
    action_type TEXT NOT NULL CHECK (action_type IN (
        'rating', 'favorite_move', 'favorite_remove', 'hath_request',
        'archive_cleanup'
    )),
    desired_value TEXT NOT NULL,
    decision_revision_id INTEGER NOT NULL REFERENCES variant_policy_revisions(id),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
        'pending', 'in_flight', 'succeeded', 'retryable_error',
        'permanent_error', 'configuration_error', 'superseded'
    )),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    available_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_attempt_at TEXT,
    result_json TEXT CHECK (result_json IS NULL OR json_valid(result_json)),
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT,
    UNIQUE (action_type, gid, desired_value, decision_revision_id)
);

CREATE INDEX idx_variant_actions_reconcile
ON variant_actions(status, available_at, group_id, id)
WHERE status IN ('pending', 'retryable_error', 'configuration_error', 'in_flight');
CREATE INDEX idx_variant_actions_group
ON variant_actions(group_id, action_type, gid, id);

CREATE TABLE variant_reviews (
    id INTEGER PRIMARY KEY,
    review_type TEXT NOT NULL CHECK (review_type IN ('candidate_identity', 'winner')),
    group_id INTEGER NOT NULL REFERENCES variant_groups(id),
    candidate_gid INTEGER REFERENCES galleries(gid),
    evaluation_id INTEGER REFERENCES variant_evaluations(id),
    policy_revision_id INTEGER NOT NULL REFERENCES variant_policy_revisions(id),
    evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
    choices_json TEXT NOT NULL CHECK (json_valid(choices_json)),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolved')),
    decision TEXT CHECK (decision IS NULL OR decision IN ('same_book', 'different_book', 'winner')),
    selected_gid INTEGER REFERENCES galleries(gid),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    resolved_at TEXT,
    CHECK (
        (
            review_type = 'candidate_identity'
            AND candidate_gid IS NOT NULL
            AND evaluation_id IS NULL
            AND selected_gid IS NULL
            AND (decision IS NULL OR decision IN ('same_book', 'different_book'))
        )
        OR
        (
            review_type = 'winner'
            AND candidate_gid IS NULL
            AND evaluation_id IS NOT NULL
            AND (decision IS NULL OR (decision = 'winner' AND selected_gid IS NOT NULL))
        )
    ),
    CHECK (
        (status = 'pending' AND decision IS NULL AND selected_gid IS NULL AND resolved_at IS NULL)
        OR
        (status = 'resolved' AND decision IS NOT NULL AND resolved_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_variant_reviews_pending_candidate
ON variant_reviews(group_id, candidate_gid)
WHERE review_type = 'candidate_identity' AND status = 'pending';
CREATE UNIQUE INDEX idx_variant_reviews_pending_winner
ON variant_reviews(evaluation_id)
WHERE review_type = 'winner' AND status = 'pending';
CREATE INDEX idx_variant_reviews_unresolved
ON variant_reviews(status, review_type, group_id, id)
WHERE status = 'pending';

-- Canonical and active-evaluation pointers must refer to the same group.
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

-- Canonical state is unique within the current mutable membership projection.
CREATE UNIQUE INDEX idx_gallery_variants_one_canonical
ON gallery_variants(group_id)
WHERE membership_state = 'confirmed' AND variant_state = 'canonical';

-- Initial policy, canonicalized before hashing. Its three sections are hashed
-- independently so activation can schedule only the required work.
INSERT INTO variant_policy_revisions (
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash,
    is_active, activated_at
) VALUES (
    '{"matching":{"automatic_evidence_kinds":["exact_file","official_chain"],"independent_metadata_requires_review":true,"manual_decision_adjustments":{"different_book":-9999,"same_book":9999},"metadata_score":{"content_tags":{"max_points":20,"namespaces":["parody","character","male","female","mixed"],"similarity":"jaccard"},"creator_overlap":{"disjoint_nonempty_is_contradiction":true,"match":"exact_artist_or_group","max_points":30},"page_count":{"formula":"round(10*min(filecount)/max(filecount))","max_points":10},"title":{"english_romaji_similarity":"token","japanese_similarity":"character_bigram","max_points":40,"selection":"maximum"},"total_max":100},"required_scope_tags":["language:chinese","other:tankoubon"],"search":{"disable_filters":["user_language","uploader","tags"],"expunged_separate":true},"title_normalization":{"preserve":["volume","part"],"remove":["creator","language","translator","digital","edition","punctuation"]},"visible_contradictions":["category_mismatch","title_volume_part_conflict","disjoint_creator_sets","missing_evidence"]},"operations":{"annual_rediscovery_days":365,"discovery_groups_per_run":1,"gdata_batch_size":25,"gdata_batches_per_continuation":4,"job_priority":["explicit_feedback","policy_work","annual_stale_discovery"],"lease_minutes":15,"policy_sweep_batch_size":100,"retry_delays_seconds":[300,900,3600,21600,86400],"search_requests_per_continuation":8,"search_throttle_seconds":3},"scoring":{"expunged_adjustment":0,"manual_winner_override":9999,"posted_bonus":{"direction":"newest_to_oldest","equal_timestamps_share_rank":true,"oldest_bonus":1,"ranking":"distinct_posted"},"tag_weights":{"other:full color":100,"other:uncensored":100}}}',
    '95cfec1154b96ff2dbd8ac5569e7e841e78645d71470b763d2cf4735c23f1e3b',
    'a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e',
    '70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69',
    '7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d',
    1,
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
);
