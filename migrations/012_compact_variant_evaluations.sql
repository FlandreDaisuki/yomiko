-- Compact historical evaluation payloads before dropping the mutable member
-- breakdown copy. Evaluation IDs, policy revisions, winners, ties, and review
-- relationships are intentionally preserved.

DROP TRIGGER variant_evaluations_no_update;
DROP TRIGGER variant_evaluations_no_delete;

CREATE TEMP TABLE migration_012_compact_evaluations(
    evaluation_id INTEGER PRIMARY KEY,
    scoring_snapshot_json TEXT NOT NULL CHECK (json_valid(scoring_snapshot_json)),
    member_scores_json TEXT NOT NULL CHECK (json_valid(member_scores_json))
);

INSERT INTO migration_012_compact_evaluations(
    evaluation_id, scoring_snapshot_json, member_scores_json
)
SELECT evaluation.id,
       COALESCE((
         SELECT json_group_array(json_object(
           'gid', json_extract(snapshot.value, '$.gid'),
           'title', json_extract(snapshot.value, '$.metadata.title'),
           'title_jpn', json_extract(snapshot.value, '$.metadata.title_jpn'),
           'tags', json_extract(snapshot.value, '$.metadata.tags'),
           'filecount', json_extract(snapshot.value, '$.metadata.filecount'),
           'posted', json_extract(snapshot.value, '$.metadata.posted'),
           'favorite_count', json_extract(snapshot.value, '$.metadata.favorite_count'),
           'rating', json_extract(snapshot.value, '$.metadata.rating'),
           'rating_count', json_extract(snapshot.value, '$.metadata.rating_count'),
           'expunged', json_extract(snapshot.value, '$.metadata.expunged')
         ))
           FROM json_each(evaluation.metadata_snapshot_json) AS snapshot
       ), '[]'),
       COALESCE((
         SELECT json_group_array(json(
           json_patch(
             json_object(
               'gid', json_extract(score.value, '$.gid'),
               'components', json_patch(
                 json_object(
                   'exact_tags', json_object(
                     'matches', COALESCE((
                       SELECT json_group_array(json_object(
                         'tag', json_extract(tag.value, '$.tag'),
                         'points', json_extract(tag.value, '$.points')
                       )) FROM json_each(score.value, '$.components.exact_tags.matches') AS tag
                     ), '[]'),
                     'subtotal', json_extract(score.value, '$.components.exact_tags.subtotal')
                   ),
                   'title_substrings', json_object(
                     'matches', COALESCE((
                       SELECT json_group_array(json_object(
                         'substring', json_extract(title.value, '$.substring'),
                         'matched_fields', json(json_extract(title.value, '$.matched_fields')),
                         'points', json_extract(title.value, '$.points')
                       )) FROM json_each(score.value, '$.components.title_substrings.matches') AS title
                     ), '[]'),
                     'subtotal', json_extract(score.value, '$.components.title_substrings.subtotal')
                   ),
                   'posted_rank', json_object(
                     'rank', json_extract(score.value, '$.components.posted_rank.rank'),
                     'points', json_extract(score.value, '$.components.posted_rank.points')
                   ),
                   'page_count', json_object(
                     'points', json_extract(score.value, '$.components.page_count.points')
                   ),
                   'favorite_popularity', json_object(
                     'points', json_extract(score.value, '$.components.favorite_popularity.points')
                   ),
                   'rating_confidence', json_object(
                     'points', json_extract(score.value, '$.components.rating_confidence.points')
                   ),
                   'expunged', json_object(
                     'points', json_extract(score.value, '$.components.expunged.points')
                   )
                 ),
                 CASE WHEN json_type(score.value, '$.components.manual_winner_override') IS NULL
                      THEN json('{}')
                      ELSE json_object('manual_winner_override',
                                       json_extract(score.value, '$.components.manual_winner_override'))
                 END
               ),
               'score', json_extract(score.value, '$.score')
             ),
             json('{}')
           )
         )) FROM json_each(evaluation.member_scores_json) AS score
       ), '[]')
  FROM variant_evaluations AS evaluation;

UPDATE variant_evaluations
   SET metadata_snapshot_json = (
         SELECT scoring_snapshot_json
           FROM migration_012_compact_evaluations AS compact
          WHERE compact.evaluation_id = variant_evaluations.id
       ),
       member_scores_json = (
         SELECT member_scores_json
           FROM migration_012_compact_evaluations AS compact
          WHERE compact.evaluation_id = variant_evaluations.id
       );

UPDATE variant_reviews
   SET evidence_json = json_remove(evidence_json, '$.member_scores')
 WHERE review_type = 'winner'
   AND json_type(evidence_json, '$.member_scores') IS NOT NULL;

ALTER TABLE gallery_variants DROP COLUMN variant_score_json;

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

CREATE TABLE IF NOT EXISTS schema_maintenance(
    name TEXT PRIMARY KEY,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')),
    queued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT
);

INSERT INTO schema_maintenance(name, status)
VALUES ('vacuum_after_012', 'pending')
ON CONFLICT(name) DO UPDATE SET
    status = 'pending', completed_at = NULL, queued_at = excluded.queued_at;

DROP TABLE migration_012_compact_evaluations;
