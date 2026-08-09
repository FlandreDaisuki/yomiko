-- Popularity inputs are parsed from authenticated gallery-detail pages rather
-- than gdata. NULL means that no usable count was available; scoring treats a
-- missing count as zero while retaining that distinction in its breakdown.
ALTER TABLE galleries ADD COLUMN favorite_count INTEGER
    CHECK (favorite_count IS NULL OR favorite_count >= 0);
ALTER TABLE galleries ADD COLUMN rating_count INTEGER
    CHECK (rating_count IS NULL OR rating_count >= 0);
ALTER TABLE galleries ADD COLUMN popularity_fetched_at TEXT;

-- Migration 005 remains immutable audit history. Replace only its active-state
-- projection with the initial compact scoring policy expanded together with
-- the unchanged fixed matching and operational behavior. The JSON and section
-- values below are recursively key-sorted canonical bytes; their SHA-256
-- hashes must stay aligned with the runtime policy expander.
UPDATE variant_policy_revisions
   SET is_active = 0
 WHERE is_active = 1;

INSERT INTO variant_policy_revisions (
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash,
    is_active, activated_at
) VALUES (
    '{"format_version":1,"matching":{"automatic_evidence_kinds":["exact_file","official_chain"],"independent_metadata_requires_review":true,"manual_decision_adjustments":{"different_book":-9999,"same_book":9999},"metadata_score":{"content_tags":{"max_points":20,"namespaces":["parody","character","male","female","mixed"],"similarity":"jaccard"},"creator_overlap":{"disjoint_nonempty_is_contradiction":true,"match":"exact_artist_or_group","max_points":30},"page_count":{"formula":"round(10*min(filecount)/max(filecount))","max_points":10},"title":{"english_romaji_similarity":"token","japanese_similarity":"character_bigram","max_points":40,"selection":"maximum"},"total_max":100},"required_scope_tags":["language:chinese","other:tankoubon"],"search":{"disable_filters":["user_language","uploader","tags"],"expunged_separate":true},"title_normalization":{"preserve":["volume","part"],"remove":["creator","language","translator","digital","edition","punctuation"]},"visible_contradictions":["category_mismatch","title_volume_part_conflict","disjoint_creator_sets","missing_evidence"]},"operations":{"annual_rediscovery_days":365,"discovery_groups_per_run":1,"gdata_batch_size":25,"gdata_batches_per_continuation":4,"job_priority":["explicit_feedback","policy_work","annual_stale_discovery"],"lease_minutes":15,"policy_sweep_batch_size":100,"retry_delays_seconds":[300,900,3600,21600,86400],"search_requests_per_continuation":8,"search_throttle_seconds":3},"scoring":{"expunged_adjustment":0,"favorite_popularity":{"cap":500,"divisor":10,"missing_count_points":0,"rounding":"floor"},"manual_winner_override":9999,"posted_rank":{"equal_timestamps_share_rank":true,"oldest_rank":1,"step":1},"rating_confidence":{"cap":500,"count_divisor":2,"minimum":0,"missing_count_points":0,"rating_baseline":3,"rounding":"floor"},"tag_scores":{"other:full color":100,"other:uncensored":100},"title_normalization":"NFKC_Casefold","title_substring_scores":{},"winner_review_score_gap_exclusive":5}}',
    'da687dc4a0474cec0e02f2005144864e8e655533bfba6b525209e92f2d4e560f',
    'a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e',
    '6a6e344ae547ba271252717a3e983b04e0e7e1b6df38f4e4664ff828bb6af2e0',
    '7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d',
    1,
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
);
