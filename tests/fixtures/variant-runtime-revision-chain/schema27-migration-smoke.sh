#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT
export HOME="${TEMP_ROOT}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
# The migration fixtures use the runtime's matching revision in staged rows.
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_worker.sh"

export DB_PATH="${HOME}/data/db.sqlite3"
export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant schema-27/28 migration smoke: skipped (sqlite3 unavailable)'
  exit 0
fi

assert_eq() { [[ "$1" == "$2" ]] || { printf 'expected %s, got %s\n' "$1" "$2" >&2; return 1; }; }

# Schema-26 -> schema-27 -> schema-28 migration is valid for a complete chain
# and aborts atomically for an invalid graph. Both checks use disposable databases so
# this fixture never touches the playground snapshot.
run_schema27_migration_checks() {
  local saved_db_path="${DB_PATH}" saved_migrations_dir="${MIGRATIONS_DIR}"
  local valid_root="${TEMP_ROOT}/schema27-valid" invalid_root="${TEMP_ROOT}/schema27-invalid"
  local relation_root="${TEMP_ROOT}/schema27-invalid-relation"
  local incomplete_root="${TEMP_ROOT}/schema27-incomplete"
  local valid_db="${valid_root}/data.sqlite3" invalid_db="${invalid_root}/data.sqlite3"
  local relation_db="${relation_root}/data.sqlite3" incomplete_db="${incomplete_root}/data.sqlite3"
  local schema_26_seed="${TEMP_ROOT}/schema-26-seed.sqlite3"
  mkdir -p "${valid_root}/migrations" "${invalid_root}/migrations" \
    "${relation_root}/migrations" "${incomplete_root}/migrations"
  cp "${ROOT}"/migrations/*.sql "${valid_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${invalid_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${relation_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${incomplete_root}/migrations/"
  # Hold every post-26 migration back so each disposable database can advance
  # deliberately through schema 27 and then schema 28.
  rm -f "${valid_root}/migrations/027_"*.sql \
    "${valid_root}/migrations/028_"*.sql \
    "${valid_root}/migrations/029_"*.sql \
    "${invalid_root}/migrations/027_"*.sql \
    "${invalid_root}/migrations/028_"*.sql \
    "${invalid_root}/migrations/029_"*.sql \
    "${relation_root}/migrations/027_"*.sql \
    "${relation_root}/migrations/028_"*.sql \
    "${relation_root}/migrations/029_"*.sql \
    "${incomplete_root}/migrations/027_"*.sql \
    "${incomplete_root}/migrations/028_"*.sql \
    "${incomplete_root}/migrations/029_"*.sql

  DB_PATH="${valid_db}"
  MIGRATIONS_DIR="${valid_root}/migrations"
  db_init >/dev/null
  sqlite3 "${DB_PATH}" ".backup '${schema_26_seed}'"
  db_write "
    INSERT INTO galleries(
      gid,token,title,title_jpn,file_count,expunged,tags,rating,uploader,posted,
      filesize,thumb,first_gid,first_token,parent_gid,parent_token,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (910001,'migration-token-1','Migration parent','',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'migration',910001,100,
       'thumb-m1',910001,'migration-token-1',NULL,NULL,
       910002,'migration-token-2',1,1),
      (910002,'migration-token-2','Migration terminal','',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,'migration',910002,110,
       'thumb-m2',910001,'migration-token-1',910001,'migration-token-1',
       NULL,NULL,2,2);
    INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
      VALUES(910001,11,1,1);
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
      VALUES(last_insert_rowid(),910001,'confirmed','automatic','{}',
             json_object('title','Migration parent','filecount',10,
                         'tags',json('[\"language:chinese\",\"other:tankoubon\"]')));
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${valid_root}/migrations/"
  db_init >/dev/null
  assert_eq '27' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  # Historical pre-028 assertion: migration 027 owns the legacy view name.
  assert_eq '910002' "$(db_query \
    'SELECT gid FROM eligible_galleries WHERE component_gid=910001;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  cp "${ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" \
    "${valid_root}/migrations/"
  db_init >/dev/null
  assert_eq '28' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '910002' "$(db_query \
    'SELECT gid FROM scoreable_revision_terminals WHERE component_gid=910001;')"
  assert_eq '910002' "$(db_query \
    "SELECT gid FROM gallery_variants WHERE membership_state='confirmed';")"
  assert_eq '0' "$(db_query \
    "SELECT COUNT(*) FROM pragma_table_info('gallery_variants')
      WHERE name='metadata_snapshot_json';")"

  DB_PATH="${invalid_db}"
  MIGRATIONS_DIR="${invalid_root}/migrations"
  sqlite3 "${schema_26_seed}" ".backup '${DB_PATH}'"
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (920001,'cycle-token-1','Invalid cycle A',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',1,10,'thumb',
       920002,'cycle-token-2',1,1),
      (920002,'cycle-token-2','Invalid cycle B',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',2,10,'thumb',
       920001,'cycle-token-1',1,1);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${invalid_root}/migrations/"
  if db_init >/dev/null 2>&1; then
    printf 'schema-27 migration accepted an invalid cycle\n' >&2
    DB_PATH="${saved_db_path}"
    MIGRATIONS_DIR="${saved_migrations_dir}"
    return 1
  fi
  assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '920002' "$(db_query \
    'SELECT current_gid FROM galleries WHERE gid=920001;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"

  DB_PATH="${relation_db}"
  MIGRATIONS_DIR="${relation_root}/migrations"
  sqlite3 "${schema_26_seed}" ".backup '${DB_PATH}'"
  # Schema 26 has no pair guard; migration 27 must diagnose and roll back a
  # fetched half-null relation before creating any replacement views.
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (930001,'relation-token-1','Invalid relation',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',1,10,'thumb',
       930002,NULL,1,1);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${relation_root}/migrations/"
  if db_init >/dev/null 2>&1; then
    printf 'schema-27 migration accepted a half-null relation\n' >&2
    DB_PATH="${saved_db_path}"
    MIGRATIONS_DIR="${saved_migrations_dir}"
    return 1
  fi
  assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  assert_eq '930002|' "$(db_query \
    "SELECT current_gid || '|' || COALESCE(current_token,'')
       FROM galleries WHERE gid=930001;")"

  # Every malformed fetched component must abort the migration before the
  # replacement views are committed. These cases exercise graph diagnostics
  # independently of the half-null/token-pair guard above.
  reject_graph_case() {
    local case_name="$1" case_kind="$2"
    local case_root="${TEMP_ROOT}/schema27-${case_name}"
    local case_db="${case_root}/data.sqlite3"
    mkdir -p "${case_root}/migrations"
    cp "${ROOT}"/migrations/*.sql "${case_root}/migrations/"
    # Keep the disposable database at schema 26 until migration 027 is copied.
    rm -f "${case_root}/migrations/027_"*.sql \
      "${case_root}/migrations/028_"*.sql \
      "${case_root}/migrations/029_"*.sql
    DB_PATH="${case_db}"
    MIGRATIONS_DIR="${case_root}/migrations"
    sqlite3 "${schema_26_seed}" ".backup '${DB_PATH}'"
    case "${case_kind}" in
      branch)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,parent_gid,parent_token,favorite_count,rating_count)
          VALUES
            (950001,'branch-token-1','Branch root',10,0,'[]',4.0,'invalid',
             1,10,'thumb',NULL,NULL,1,1),
            (950002,'branch-token-2','Branch child A',10,0,'[]',4.0,'invalid',
             2,10,'thumb',950001,'branch-token-1',1,1),
            (950003,'branch-token-3','Branch child B',10,0,'[]',4.0,'invalid',
             3,10,'thumb',950001,'branch-token-1',1,1);"
        ;;
      relation-conflict)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,first_gid,first_token,current_gid,current_token,
            favorite_count,rating_count)
          VALUES
            (951001,'conflict-token-1','Conflict source',10,0,'[]',4.0,'invalid',
             1,10,'thumb',951003,'conflict-token-3',951002,'conflict-token-2',1,1),
            (951002,'conflict-token-2','Conflict terminal',10,0,'[]',4.0,'invalid',
             2,10,'thumb',NULL,NULL,NULL,NULL,1,1),
            (951003,'conflict-token-3','Unrelated first',10,0,'[]',4.0,'invalid',
             3,10,'thumb',NULL,NULL,NULL,NULL,1,1);"
        ;;
      multiple-terminals)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,parent_gid,parent_token,current_gid,current_token,
            favorite_count,rating_count)
          VALUES
            (952001,'multi-token-1','Multiple root',10,0,'[]',4.0,'invalid',
             1,10,'thumb',NULL,NULL,952003,'multi-token-3',1,1),
            (952002,'multi-token-2','Multiple parent terminal',10,0,'[]',4.0,'invalid',
             2,10,'thumb',952001,'multi-token-1',NULL,NULL,1,1),
            (952003,'multi-token-3','Multiple current terminal',10,0,'[]',4.0,'invalid',
             3,10,'thumb',NULL,NULL,NULL,NULL,1,1);"
        ;;
      token-mismatch)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,current_gid,current_token,favorite_count,rating_count)
          VALUES
            (953001,'mismatch-token-1','Mismatch source',10,0,'[]',4.0,'invalid',
             1,10,'thumb',953002,'wrong-token',1,1),
            (953002,'mismatch-token-2','Mismatch target',10,0,'[]',4.0,'invalid',
             2,10,'thumb',NULL,NULL,1,1);"
        ;;
      *) return 1 ;;
    esac
    cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" "${case_root}/migrations/"
    if db_init >/dev/null 2>&1; then
      printf 'schema-27 migration accepted invalid %s component\n' "${case_kind}" >&2
      return 1
    fi
    assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
    assert_eq '' "$(db_query "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  }
  reject_graph_case branch branch
  reject_graph_case relation-conflict relation-conflict
  reject_graph_case multiple-terminals multiple-terminals
  reject_graph_case token-mismatch token-mismatch

  # A blocked replacement is retryable input, not permission to erase the
  # previously effective revision.  Exercise all three incomplete classes in
  # one schema-26 database and keep the old member, canonical/evaluation
  # pointer, pending current action, and exact archive visible after 027.
  DB_PATH="${incomplete_db}"
  MIGRATIONS_DIR="${incomplete_root}/migrations"
  sqlite3 "${schema_26_seed}" ".backup '${DB_PATH}'"
  printf 'reference predecessor' >"${ARCHIVED_DIR}/incomplete-reference.7z"
  printf 'scope predecessor' >"${ARCHIVED_DIR}/incomplete-scope.7z"
  printf 'scoring predecessor' >"${ARCHIVED_DIR}/incomplete-scoring.7z"
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,file_path,uploader,posted,
      filesize,thumb,current_gid,current_token,favorite_count,rating_count)
    VALUES
      (940001,'incomplete-reference-1','Reference predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-reference.7z','retry',940001,100,'thumb-940001',940002,
       'incomplete-reference-2',1,1),
      (941001,'incomplete-scope-1','Scope predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-scope.7z','retry',941001,100,'thumb-941001',941002,
       'incomplete-scope-2',1,1),
      (941002,'incomplete-scope-2','Scope replacement',11,0,'[]',4.2,NULL,
       'retry',941002,110,'thumb-941002',NULL,NULL,2,2),
      (942001,'incomplete-scoring-1','Scoring predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-scoring.7z','retry',942001,100,'thumb-942001',942002,
       'incomplete-scoring-2',1,1),
      (942002,'incomplete-scoring-2','Scoring replacement',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,NULL,
       'retry',942002,110,'thumb-942002',NULL,NULL,NULL,NULL);
    INSERT INTO variant_groups(
      id,source_gid,desired_rating,is_active,identity_active)
    VALUES
      (9401,940001,11,1,1),
      (9411,941001,11,1,1),
      (9421,942001,11,1,1);
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json,
      variant_state)
    VALUES
      (9401,940001,'confirmed','manual','{\"history\":\"reference\"}','{}','canonical'),
      (9411,941001,'confirmed','manual','{\"history\":\"scope\"}','{}','canonical'),
      (9421,942001,'confirmed','manual','{\"history\":\"scoring\"}','{}','canonical');
    UPDATE variant_groups SET canonical_gid=CASE id
      WHEN 9401 THEN 940001 WHEN 9411 THEN 941001 WHEN 9421 THEN 942001 END
      WHERE id IN (9401,9411,9421);
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94001,9401,id,'completed','[]','[]',940001
      FROM variant_policy_revisions WHERE is_active=1;
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94101,9411,id,'completed','[]','[]',941001
      FROM variant_policy_revisions WHERE is_active=1;
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94201,9421,id,'completed','[]','[]',942001
      FROM variant_policy_revisions WHERE is_active=1;
    UPDATE variant_groups SET active_evaluation_id=CASE id
      WHEN 9401 THEN 94001 WHEN 9411 THEN 94101 WHEN 9421 THEN 94201 END
      WHERE id IN (9401,9411,9421);
    INSERT INTO variant_actions(
      group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,status)
    SELECT grouped.id,grouped.active_evaluation_id,grouped.source_gid,
           'rating','10',policy.id,'pending'
      FROM variant_groups AS grouped
      CROSS JOIN variant_policy_revisions AS policy
     WHERE policy.is_active=1 AND grouped.id IN (9401,9411,9421);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${incomplete_root}/migrations/"
  db_init >/dev/null
  cp "${ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" \
    "${incomplete_root}/migrations/"
  db_init >/dev/null
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(canonical_gid, '|')
    FROM (SELECT canonical_gid FROM variant_groups
           WHERE id IN (9401,9411,9421) ORDER BY id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(gid, '|')
    FROM (SELECT gid FROM gallery_variants
           WHERE group_id IN (9401,9411,9421)
             AND membership_state='confirmed' ORDER BY group_id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(gid, '|')
    FROM (SELECT gid FROM variant_actions
           WHERE group_id IN (9401,9411,9421) ORDER BY group_id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(archive_gid, '|')
    FROM (SELECT archive_gid FROM archive_source_galleries
           WHERE gid IN (940001,941001,942001) ORDER BY gid);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(source_gid, '|')
    FROM (SELECT source_gid FROM variant_jobs
           WHERE group_id IN (9401,9411,9421)
             AND job_type='discover' AND status='queued' ORDER BY group_id);")"
  assert_eq 'reference_incomplete|scope_incomplete|scoring_input_incomplete' \
    "$(db_query "SELECT group_concat(blocked_reason, '|')
      FROM current_revision_projection
      WHERE revision_gid IN (940001,941001,942001) ORDER BY revision_gid;")"
  DB_PATH="${saved_db_path}"
  MIGRATIONS_DIR="${saved_migrations_dir}"
}
run_schema27_migration_checks

echo 'variant schema-27/28 migration smoke: ok'
