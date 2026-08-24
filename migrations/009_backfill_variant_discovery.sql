-- Historical ratings from before the variant workflow already express user
-- intent. Materialize the eligible set before writing any variant rows so
-- existing confirmed membership and discovery history remain untouched.
--
-- Priority 250 places this one-time backlog above annual rediscovery (100),
-- below policy work (500), and below fresh explicit feedback (1000).
CREATE TEMP TABLE migration_009_clock (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    migration_at TEXT NOT NULL
);

INSERT INTO migration_009_clock(singleton, migration_at)
VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

CREATE TEMP TABLE migration_009_candidates (
    group_id INTEGER PRIMARY KEY,
    gid INTEGER NOT NULL UNIQUE,
    desired_rating INTEGER NOT NULL,
    intent_at TEXT NOT NULL
);

INSERT INTO migration_009_candidates(
    group_id, gid, desired_rating, intent_at
)
SELECT
    (SELECT COALESCE(MAX(id), 0) FROM variant_groups)
      + row_number() OVER (ORDER BY gallery.gid),
    gallery.gid,
    gallery.self_rating,
    COALESCE(
      gallery.feedbacked_at,
      gallery.updated_at,
      (SELECT migration_at FROM migration_009_clock WHERE singleton = 1)
    )
  FROM galleries AS gallery
 WHERE gallery.self_rating BETWEEN 1 AND 11
   AND NOT EXISTS (
     SELECT 1
       FROM gallery_variants AS member
      WHERE member.gid = gallery.gid
        AND member.membership_state = 'confirmed'
   )
 ORDER BY gallery.gid;

INSERT INTO variant_groups(
    id, source_gid, desired_rating, is_active, latest_feedback_at,
    created_at, updated_at
)
SELECT candidate.group_id, candidate.gid, candidate.desired_rating, 1,
       candidate.intent_at, clock.migration_at, clock.migration_at
  FROM migration_009_candidates AS candidate
 CROSS JOIN migration_009_clock AS clock
 ORDER BY candidate.gid;

INSERT INTO gallery_variants(
    group_id, gid, membership_state, decision_source, match_score,
    evidence_json, metadata_snapshot_json, decided_at, created_at, updated_at
)
SELECT candidate.group_id, gallery.gid, 'confirmed', 'automatic', 0,
       json_object(
         'kind', 'historical_rating_backfill',
         'migration', 9
       ),
       json_object(
         'gid', gallery.gid, 'token', gallery.token,
         'title', gallery.title, 'title_jpn', gallery.title_jpn,
         'category', gallery.category, 'uploader', gallery.uploader,
         'posted', gallery.posted, 'filecount', gallery.file_count,
         'filesize', gallery.filesize, 'expunged', gallery.expunged,
         'rating', gallery.rating,
         'favorite_count', gallery.favorite_count,
         'rating_count', gallery.rating_count,
         'popularity_fetched_at', gallery.popularity_fetched_at,
         'tags', CASE
           WHEN json_valid(gallery.tags) THEN json(gallery.tags)
           ELSE json('[]')
         END,
         'thumb', gallery.thumb, 'first_gid', gallery.first_gid,
         'first_key', gallery.first_key, 'parent_gid', gallery.parent_gid,
         'parent_key', gallery.parent_key, 'current_gid', gallery.current_gid,
         'current_key', gallery.current_key
       ),
       clock.migration_at, clock.migration_at, clock.migration_at
  FROM migration_009_candidates AS candidate
  JOIN galleries AS gallery ON gallery.gid = candidate.gid
 CROSS JOIN migration_009_clock AS clock
 ORDER BY candidate.gid;

INSERT INTO variant_jobs(
    job_type, group_id, source_gid, priority, status,
    available_at, created_at, updated_at
)
SELECT 'discover', candidate.group_id, candidate.gid, 250, 'queued',
       clock.migration_at, clock.migration_at, clock.migration_at
  FROM migration_009_candidates AS candidate
 CROSS JOIN migration_009_clock AS clock
 ORDER BY candidate.gid;

DROP TABLE migration_009_candidates;
DROP TABLE migration_009_clock;
