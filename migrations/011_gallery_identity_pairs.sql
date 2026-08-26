-- Manual identity decisions describe unordered gallery pairs, while
-- gallery_variants rows are scoped to one mutable group.  Materialize the
-- current pair decision as a pointer to its resolved review so discovery sees
-- the same answer in both source/candidate directions without duplicating the
-- review decision or evidence.
CREATE TEMP TABLE migration_011_resolved_pairs AS
SELECT
    MIN(grouped.source_gid, review.candidate_gid) AS low_gid,
    MAX(grouped.source_gid, review.candidate_gid) AS high_gid,
    review.id AS review_id,
    review.decision,
    review.resolved_at
  FROM variant_reviews AS review
  JOIN variant_groups AS grouped ON grouped.id = review.group_id
 WHERE review.review_type = 'candidate_identity'
   AND review.status = 'resolved'
   AND review.decision IN ('same_book', 'different_book');

CREATE TEMP TABLE migration_011_conflicts (
    low_gid INTEGER NOT NULL,
    high_gid INTEGER NOT NULL,
    reason TEXT NOT NULL,
    PRIMARY KEY (low_gid, high_gid, reason)
);

-- A pair cannot refer to itself, and historical disagreement must be repaired
-- explicitly instead of silently inventing migration precedence.
INSERT OR IGNORE INTO migration_011_conflicts(low_gid, high_gid, reason)
SELECT low_gid, high_gid, 'same GID appears on both sides'
  FROM migration_011_resolved_pairs
 WHERE low_gid = high_gid;

INSERT OR IGNORE INTO migration_011_conflicts(low_gid, high_gid, reason)
SELECT low_gid, high_gid, 'resolved reviews disagree'
  FROM migration_011_resolved_pairs
 GROUP BY low_gid, high_gid
HAVING COUNT(DISTINCT decision) > 1;

-- Existing active membership is the effective equivalence-class projection.
-- Refuse both a negative edge within one class and a positive edge spanning
-- two classes; either case needs operator inspection before migration.
INSERT OR IGNORE INTO migration_011_conflicts(low_gid, high_gid, reason)
SELECT low_gid, high_gid, 'different-book decision is inside one active class'
  FROM (
    SELECT pair.*,
           COALESCE((
             SELECT MIN(class_member.gid)
               FROM gallery_variants AS endpoint
               JOIN variant_groups AS grouped
                 ON grouped.id=endpoint.group_id AND grouped.is_active=1
               JOIN gallery_variants AS class_member
                 ON class_member.group_id=endpoint.group_id
                AND class_member.membership_state='confirmed'
              WHERE endpoint.gid=pair.low_gid
                AND endpoint.membership_state='confirmed'
           ),pair.low_gid) AS low_class_gid,
           COALESCE((
             SELECT MIN(class_member.gid)
               FROM gallery_variants AS endpoint
               JOIN variant_groups AS grouped
                 ON grouped.id=endpoint.group_id AND grouped.is_active=1
               JOIN gallery_variants AS class_member
                 ON class_member.group_id=endpoint.group_id
                AND class_member.membership_state='confirmed'
              WHERE endpoint.gid=pair.high_gid
                AND endpoint.membership_state='confirmed'
           ),pair.high_gid) AS high_class_gid
      FROM migration_011_resolved_pairs AS pair
  )
 WHERE decision='different_book' AND low_class_gid=high_class_gid;

INSERT OR IGNORE INTO migration_011_conflicts(low_gid, high_gid, reason)
SELECT low_gid, high_gid, 'same-book decision spans current classes'
  FROM (
    SELECT pair.*,
           COALESCE((
             SELECT MIN(class_member.gid)
               FROM gallery_variants AS endpoint
               JOIN variant_groups AS grouped
                 ON grouped.id=endpoint.group_id AND grouped.is_active=1
               JOIN gallery_variants AS class_member
                 ON class_member.group_id=endpoint.group_id
                AND class_member.membership_state='confirmed'
              WHERE endpoint.gid=pair.low_gid
                AND endpoint.membership_state='confirmed'
           ),pair.low_gid) AS low_class_gid,
           COALESCE((
             SELECT MIN(class_member.gid)
               FROM gallery_variants AS endpoint
               JOIN variant_groups AS grouped
                 ON grouped.id=endpoint.group_id AND grouped.is_active=1
               JOIN gallery_variants AS class_member
                 ON class_member.group_id=endpoint.group_id
                AND class_member.membership_state='confirmed'
              WHERE endpoint.gid=pair.high_gid
                AND endpoint.membership_state='confirmed'
           ),pair.high_gid) AS high_class_gid
      FROM migration_011_resolved_pairs AS pair
  )
 WHERE decision='same_book' AND low_class_gid<>high_class_gid;

-- sqlite3 prints these rows before the guard aborts, giving the operator exact
-- repair targets while the outer migration transaction rolls back everything.
SELECT printf(
         'gallery identity migration conflict: (%d, %d): %s',
         low_gid, high_gid, reason
       )
  FROM migration_011_conflicts
 ORDER BY low_gid, high_gid, reason;

CREATE TEMP TABLE migration_011_guard(singleton INTEGER PRIMARY KEY);
CREATE TEMP TRIGGER migration_011_abort_conflicts
BEFORE INSERT ON migration_011_guard
WHEN EXISTS (SELECT 1 FROM migration_011_conflicts)
BEGIN
    SELECT RAISE(ABORT, 'gallery identity migration conflicts require repair');
END;
INSERT INTO migration_011_guard(singleton) VALUES (1);

CREATE TABLE gallery_identity_pairs (
    low_gid INTEGER NOT NULL REFERENCES galleries(gid),
    high_gid INTEGER NOT NULL REFERENCES galleries(gid),
    current_review_id INTEGER NOT NULL UNIQUE REFERENCES variant_reviews(id),
    PRIMARY KEY (low_gid, high_gid),
    CHECK (low_gid < high_gid)
);

CREATE INDEX idx_gallery_identity_pairs_high_gid
ON gallery_identity_pairs(high_gid, low_gid);

INSERT INTO gallery_identity_pairs(low_gid, high_gid, current_review_id)
SELECT low_gid, high_gid, review_id
  FROM (
    SELECT pair.*,
           row_number() OVER (
             PARTITION BY low_gid, high_gid
             ORDER BY resolved_at DESC, review_id DESC
           ) AS precedence
      FROM migration_011_resolved_pairs AS pair
  )
 WHERE precedence = 1
 ORDER BY low_gid, high_gid;

-- Candidate supersession is now a reversible identity projection. Winner
-- supersession remains evaluation-driven and immutable; both kinds of rows
-- stay raw pending reviews until a person resolves the actionable row.
DROP TRIGGER variant_reviews_superseded_not_pending;
CREATE TRIGGER variant_reviews_superseded_pending_only
BEFORE UPDATE OF status, superseded_at ON variant_reviews
WHEN NEW.review_type = 'candidate_identity'
 AND NEW.superseded_at IS NOT NULL AND NEW.status <> 'pending'
BEGIN
    SELECT RAISE(ABORT, 'only pending reviews may be superseded');
END;

CREATE INDEX idx_variant_reviews_pending_actionable_candidate
ON variant_reviews(group_id, candidate_gid, id)
WHERE review_type = 'candidate_identity'
  AND status = 'pending' AND superseded_at IS NULL;

-- Build the initial class-lifted review projection for schema-010 databases.
-- Runtime uses the equivalent reusable block in lib/variants.sh after every
-- identity change.
CREATE TEMP TABLE migration_011_active_membership AS
SELECT member.gid, member.group_id AS active_group_id,
       MIN(member.gid) OVER (PARTITION BY member.group_id) AS class_gid,
       COUNT(*) OVER (PARTITION BY member.group_id) AS class_size
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped
    ON grouped.id=member.group_id AND grouped.is_active=1
 WHERE member.membership_state='confirmed';

CREATE TEMP TABLE migration_011_gid_class AS
WITH relevant(gid) AS (
  SELECT gid FROM migration_011_active_membership
  UNION SELECT grouped.source_gid
    FROM variant_reviews AS review
    JOIN variant_groups AS grouped ON grouped.id=review.group_id
   WHERE review.review_type='candidate_identity'
  UNION SELECT candidate_gid FROM variant_reviews
   WHERE review_type='candidate_identity'
  UNION SELECT low_gid FROM gallery_identity_pairs
  UNION SELECT high_gid FROM gallery_identity_pairs
)
SELECT relevant.gid,
       COALESCE(active.class_gid,relevant.gid) AS class_gid,
       active.active_group_id,
       COALESCE(active.class_size,1) AS class_size
  FROM relevant
  LEFT JOIN migration_011_active_membership AS active ON active.gid=relevant.gid;

CREATE TEMP TABLE migration_011_class_pair AS
SELECT MIN(low_class.class_gid,high_class.class_gid) AS low_class_gid,
       MAX(low_class.class_gid,high_class.class_gid) AS high_class_gid,
       'different_book' AS decision,
       MIN(pair.current_review_id) AS supporting_review_id
  FROM gallery_identity_pairs AS pair
  JOIN variant_reviews AS review ON review.id=pair.current_review_id
  JOIN migration_011_gid_class AS low_class ON low_class.gid=pair.low_gid
  JOIN migration_011_gid_class AS high_class ON high_class.gid=pair.high_gid
 WHERE review.status='resolved' AND review.decision='different_book'
   AND low_class.class_gid<>high_class.class_gid
 GROUP BY 1,2;

CREATE TEMP TABLE migration_011_pending AS
SELECT classified.*,
       CASE WHEN classified.implied_decision IS NULL THEN
         ROW_NUMBER() OVER (
           PARTITION BY classified.low_class_gid,classified.high_class_gid
           ORDER BY classified.owner_is_active DESC,classified.review_id
         ) END AS rank
  FROM (
    SELECT review.id AS review_id,
           MIN(source_class.class_gid,candidate_class.class_gid) AS low_class_gid,
           MAX(source_class.class_gid,candidate_class.class_gid) AS high_class_gid,
           CASE WHEN owner.is_active=1 THEN 1 ELSE 0 END AS owner_is_active,
           CASE
             WHEN source_class.class_gid=candidate_class.class_gid
               THEN 'same_book'
             WHEN class_pair.decision='different_book'
               THEN 'different_book'
             ELSE NULL
           END AS implied_decision,
           class_pair.supporting_review_id
      FROM variant_reviews AS review
      JOIN variant_groups AS grouped ON grouped.id=review.group_id
      JOIN variant_groups AS owner ON owner.id=review.group_id
      JOIN migration_011_gid_class AS source_class
        ON source_class.gid=grouped.source_gid
      JOIN migration_011_gid_class AS candidate_class
        ON candidate_class.gid=review.candidate_gid
      LEFT JOIN migration_011_class_pair AS class_pair
        ON class_pair.low_class_gid=MIN(source_class.class_gid,candidate_class.class_gid)
       AND class_pair.high_class_gid=MAX(source_class.class_gid,candidate_class.class_gid)
     WHERE review.review_type='candidate_identity' AND review.status='pending'
  ) AS classified;

CREATE TEMP TABLE migration_011_actionable AS
SELECT review_id,low_class_gid,high_class_gid
  FROM migration_011_pending
 WHERE implied_decision IS NULL AND rank=1;

UPDATE variant_reviews AS review
   SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       evidence_json=json_set(review.evidence_json,'$.identity_projection',json(
         (SELECT json_object(
           'reason',CASE WHEN pending.implied_decision='same_book'
                         THEN 'same_class'
                         WHEN pending.implied_decision='different_book'
                         THEN 'known_different_book'
                         ELSE 'duplicate_class_pair' END,
           'implied_decision',pending.implied_decision,
           'supporting_review_id',pending.supporting_review_id,
           'representative_review_id',CASE
             WHEN pending.implied_decision IS NULL THEN (
               SELECT actionable.review_id FROM migration_011_actionable AS actionable
                WHERE actionable.low_class_gid=pending.low_class_gid
                  AND actionable.high_class_gid=pending.high_class_gid
             ) ELSE NULL END
         ) FROM migration_011_pending AS pending
            WHERE pending.review_id=review.id)))
 WHERE review.id IN (
   SELECT review_id FROM migration_011_pending
    WHERE implied_decision IS NOT NULL OR rank>1
 );

UPDATE variant_groups AS grouped
   SET review_state=CASE
     WHEN EXISTS (
       SELECT 1
         FROM migration_011_actionable AS actionable
         JOIN migration_011_gid_class AS member_class
           ON member_class.class_gid IN (
                actionable.low_class_gid,actionable.high_class_gid)
        WHERE member_class.active_group_id=grouped.id
     ) THEN 'candidate_pending'
     WHEN EXISTS (
       SELECT 1 FROM variant_reviews AS winner
        WHERE winner.group_id=grouped.id AND winner.review_type='winner'
          AND winner.status='pending' AND winner.superseded_at IS NULL
     ) THEN 'winner_pending'
     ELSE 'none' END
 WHERE grouped.is_active=1;

INSERT OR IGNORE INTO variant_jobs(job_type,group_id,source_gid,priority,status)
SELECT 'evaluate',grouped.id,grouped.source_gid,1000,'queued'
  FROM variant_groups AS grouped
 WHERE grouped.is_active=1
   AND grouped.review_state<>'candidate_pending'
   AND EXISTS (
     SELECT 1 FROM migration_011_pending AS pending
     JOIN migration_011_gid_class AS member_class
       ON member_class.class_gid IN (
            pending.low_class_gid,pending.high_class_gid)
    WHERE member_class.active_group_id=grouped.id
   );

CREATE TEMP TABLE migration_011_validation_guard(
    valid INTEGER NOT NULL CHECK(valid=1)
);
INSERT INTO migration_011_validation_guard(valid)
SELECT CASE WHEN
  NOT EXISTS (
    SELECT low_class_gid,high_class_gid
      FROM migration_011_actionable
     GROUP BY low_class_gid,high_class_gid HAVING COUNT(*)>1
  )
  AND NOT EXISTS (SELECT 1 FROM pragma_foreign_key_check)
  AND (SELECT integrity_check FROM pragma_integrity_check)='ok'
  THEN 1 ELSE 0 END;

DROP TABLE migration_011_validation_guard;
DROP TABLE migration_011_actionable;
DROP TABLE migration_011_pending;
DROP TABLE migration_011_class_pair;
DROP TABLE migration_011_gid_class;
DROP TABLE migration_011_active_membership;

DROP TRIGGER migration_011_abort_conflicts;
DROP TABLE migration_011_guard;
DROP TABLE migration_011_conflicts;
DROP TABLE migration_011_resolved_pairs;
