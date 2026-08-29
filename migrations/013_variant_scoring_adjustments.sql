-- Update the built-in scoring policy without rewriting an operator's custom
-- policy. The active policy at this point is the migration-010 default.
CREATE TEMP TABLE migration_013_policy (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    old_revision_id INTEGER NOT NULL,
    new_revision_id INTEGER
);

INSERT INTO migration_013_policy(singleton, old_revision_id)
SELECT 1, id
  FROM variant_policy_revisions
 WHERE is_active = 1
   AND content_hash = 'e5be1191ab859a44e2823ce35c125ebf93459585be6feb1705d43f4fb3365e2f';

INSERT OR IGNORE INTO variant_policy_revisions(
    policy_json, content_hash, matching_hash, scoring_hash, operations_hash
)
SELECT '{"format_version":1,"matching":{"automatic_evidence_kinds":["exact_file","official_chain"],"independent_metadata_requires_review":true,"manual_decision_adjustments":{"different_book":-9999,"same_book":9999},"metadata_score":{"content_tags":{"max_points":20,"namespaces":["parody","character","male","female","mixed"],"similarity":"jaccard"},"creator_overlap":{"disjoint_nonempty_is_contradiction":true,"match":"exact_artist_or_group","max_points":30},"page_count":{"formula":"round(10*min(filecount)/max(filecount))","max_points":10},"title":{"english_romaji_similarity":"token","japanese_similarity":"character_bigram","max_points":40,"selection":"maximum"},"total_max":100},"required_scope_tags":["language:chinese","other:tankoubon"],"search":{"disable_filters":["user_language","uploader","tags"],"expunged_separate":true},"title_normalization":{"preserve":["volume","part"],"remove":["creator","language","translator","digital","edition","punctuation"]},"visible_contradictions":["category_mismatch","title_volume_part_conflict","disjoint_creator_sets","missing_evidence"]},"operations":{"annual_rediscovery_days":365,"discovery_groups_per_run":1,"gdata_batch_size":25,"gdata_batches_per_continuation":4,"job_priority":["explicit_feedback","policy_work","annual_stale_discovery"],"lease_minutes":15,"policy_sweep_batch_size":100,"retry_delays_seconds":[300,900,3600,21600,86400],"search_requests_per_continuation":8,"search_throttle_seconds":3},"scoring":{"expunged_adjustment":-1000,"favorite_popularity":{"cap":500,"divisor":10,"missing_count_points":0,"rounding":"floor"},"manual_winner_override":9999,"page_count":{"cap":100,"formula":"min(cap,filecount-offset)","missing_count_points":0,"offset":70},"posted_rank":{"equal_timestamps_share_rank":true,"oldest_rank":1,"step":1},"rating_confidence":{"cap":500,"count_divisor":2,"minimum":0,"missing_count_points":0,"rating_baseline":3,"rounding":"floor"},"tag_scores":{"other:full color":100,"other:incomplete":-500,"other:uncensored":100},"title_normalization":"NFKC_Casefold","title_substring_scores":{},"winner_review_score_gap_exclusive":30}}',
       '4a1d55ea1d8e88ff790cee1737fa57cdc43fdee61ec4eca12baebc58405e4862',
       'a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e',
       'dccb517215741b5417a883d28446c22e6f48b18f20c14f8cf69446d7dd278720',
       '7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d'
 WHERE EXISTS (SELECT 1 FROM migration_013_policy);

UPDATE migration_013_policy
   SET new_revision_id = (
         SELECT id FROM variant_policy_revisions
          WHERE content_hash = '4a1d55ea1d8e88ff790cee1737fa57cdc43fdee61ec4eca12baebc58405e4862'
       );

UPDATE variant_policy_revisions
   SET is_active = 0
 WHERE id = (SELECT old_revision_id FROM migration_013_policy);

UPDATE variant_policy_revisions
   SET is_active = 1,
       activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = (SELECT new_revision_id FROM migration_013_policy);

INSERT OR IGNORE INTO variant_jobs(job_type, priority, status, scoring_revision_id)
SELECT 'policy_scoring_sweep', 500, 'queued', new_revision_id
  FROM migration_013_policy
 WHERE EXISTS (SELECT 1 FROM variant_groups);

UPDATE variant_jobs
   SET priority = MAX(priority, 500),
       scoring_revision_id = (SELECT new_revision_id FROM migration_013_policy),
       continuation_cursor_json = NULL,
       available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE job_type = 'policy_scoring_sweep'
   AND status IN ('queued', 'leased')
   AND EXISTS (SELECT 1 FROM migration_013_policy);

DROP TABLE migration_013_policy;
