#!/usr/bin/env bash
set -euo pipefail

# This fixture intentionally exercises the live publication transaction.  It
# creates one disposable database per case so a blocked/faulted run cannot
# hide an accidental mutation made by a previous case.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT
if [[ -n "${YOMIKO_TEST_SCHEMA_SEED:-}" && -f "${YOMIKO_TEST_SCHEMA_SEED}" ]]; then
  SCHEMA_SEED_PATH="${YOMIKO_TEST_SCHEMA_SEED}"
else
  SCHEMA_SEED_PATH="${TEMP_ROOT}/schema-seed.sqlite3"
fi
export HOME="${TEMP_ROOT}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variants.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_unicode.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_policy.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_scoring.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_matching.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_discovery.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_worker.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_retention.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_actions.sh"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant revision publication faults smoke: static contract ok (sqlite3 unavailable)'
  exit 0
fi

export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1
assert_eq() {
  [[ "$1" == "$2" ]] || {
    printf 'expected %s, got %s\n' "$1" "$2" >&2
    return 1
  }
}

prepare_database_seed() {
  local source_db_path="${TEMP_ROOT}/schema-source/db.sqlite3"
  mkdir -p "$(dirname "${source_db_path}")"
  export DB_PATH="${source_db_path}"
  db_init >/dev/null

  # SQLite's backup command includes committed WAL state and closes both
  # connections when it exits. Cases copy this standalone, immutable image.
  sqlite3 "${DB_PATH}" ".backup '${SCHEMA_SEED_PATH}'"
}

new_database() {
  local name="$1"
  export DB_PATH="${TEMP_ROOT}/${name}/db.sqlite3"
  export VARIANTS_WORK_LOCK_PATH="${TEMP_ROOT}/${name}/variant.lock"
  mkdir -p "$(dirname "${DB_PATH}")"
  cp -- "${SCHEMA_SEED_PATH}" "${DB_PATH}"
}

# Keep the live projection deliberately non-empty.  The action and review are
# useful sentinels: a rollback must preserve both their exact status and their
# decision/evidence fields, not merely the galleries table.
seed_live_projection() {
  db_write "
    INSERT INTO galleries(
      gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
      uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (910001,'fault-source-token','Before publication','',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'','fault',910001,
       100,'thumb-source',910001,'fault-source-token',NULL,NULL,NULL,NULL,3,7),
      (910002,'fault-terminal-token','Existing terminal','',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,'','fault',910002,
       110,'thumb-terminal',910001,'fault-source-token',NULL,NULL,
       NULL,NULL,4,8);
    INSERT INTO variant_groups(
      source_gid,desired_rating,is_active,identity_active,review_state)
      VALUES(910001,11,1,1,'candidate_pending');
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,match_score,evidence_json,
      matching_revision)
      SELECT id,910001,'confirmed','manual',88,'{\"seed\":true}',
             ${VARIANTS_MATCHING_REVISION}
        FROM variant_groups WHERE source_gid=910001;
    INSERT INTO variant_reviews(
      review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
      evidence_json,choices_json,status)
      SELECT 'candidate_identity',grouped.id,910002,policy.id,${VARIANTS_MATCHING_REVISION},
             '{\"origin\":\"fault-fixture\"}','[910001,910002]','pending'
        FROM variant_groups AS grouped
        CROSS JOIN variant_policy_revisions AS policy
       WHERE grouped.source_gid=910001 AND policy.is_active=1;
    INSERT INTO variant_actions(
      group_id,gid,action_type,desired_value,policy_revision_id,status)
      SELECT grouped.id,910001,'rating','11',policy.id,'pending'
        FROM variant_groups AS grouped
        CROSS JOIN variant_policy_revisions AS policy
       WHERE grouped.source_gid=910001 AND policy.is_active=1;
  "
}

seed_manual_canonical() {
  local group_id="$1" gid="$2" evaluation_id review_id
  evaluation_id="$(db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :gid ${gid}" \
    "INSERT INTO variant_evaluations(
       group_id,policy_revision_id,state,metadata_snapshot_json,
       member_scores_json,canonical_gid)
     SELECT :group_id,policy.id,'completed','{}','[]',:gid
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")" || return
  db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :gid ${gid}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    "UPDATE variant_groups SET canonical_gid=:gid,active_evaluation_id=:evaluation_id
      WHERE id=:group_id;
     UPDATE gallery_variants SET variant_state='canonical',variant_score=100
      WHERE group_id=:group_id AND gid=:gid;" || return
  review_id="$(db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :gid ${gid}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    "INSERT INTO variant_reviews(
       review_type,group_id,evaluation_id,policy_revision_id,evidence_json,
       choices_json,status,decision,canonical_gid,resolved_at)
     SELECT 'winner',:group_id,:evaluation_id,policy.id,'{}',json_array(:gid),
            'resolved','winner',:gid,strftime('%Y-%m-%dT%H:%M:%SZ','now')
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")" || return
  db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :gid ${gid}" \
    ".parameter set :review_id ${review_id}" \
    "INSERT INTO variant_canonical_decisions(
       group_id,canonical_gid,source_review_id,policy_revision_id,
       member_fingerprint,status)
     SELECT :group_id,:gid,:review_id,policy.id,
            json_array(:gid),'active'
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;" || return
  printf '%s\n' "${evaluation_id}"
}

new_discovery_run() {
  local owner="$1"
  local group_id job_id run_id
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  job_id="$(db_write "
    INSERT INTO variant_jobs(
      job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
    VALUES('discover',${group_id},910001,500,'leased','${owner}',
           strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
    SELECT last_insert_rowid();")"
  run_id="$(db_write "
    INSERT INTO variant_discovery_runs(
      group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
    VALUES(${group_id},${job_id},${VARIANTS_MATCHING_REVISION},'publish','running',
           '${owner}',strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
    SELECT last_insert_rowid();")"
  printf '%s|%s|%s|%s\n' "${group_id}" "${job_id}" "${run_id}" "${owner}"
}

# Insert one complete candidate.  The relation fields are SQL expressions
# (NULL or an integer/string literal) selected only by this fixture's fixed
# case table; no provider input is interpolated here.
stage_candidate() {
  local run_id="$1" gid="$2" token="$3" origin="$4" title="$5"
  local tags="$6" popularity="$7" first_gid="$8" first_token="$9"
  local parent_gid="${10}" parent_token="${11}" current_gid="${12}" current_token="${13}"
  local first_token_sql="${first_token}" parent_token_sql="${parent_token}" current_token_sql="${current_token}"
  [[ "${first_token_sql}" == NULL ]] || first_token_sql="'${first_token_sql}'"
  [[ "${parent_token_sql}" == NULL ]] || parent_token_sql="'${parent_token_sql}'"
  [[ "${current_token_sql}" == NULL ]] || current_token_sql="'${current_token_sql}'"
  db_write \
    ".parameter set :popularity $(db_parameter_text "${popularity}")" \
    "
    INSERT INTO variant_discovery_candidates(
      run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,
      evidence_json,state)
    VALUES(
      ${run_id},${gid},'${token}',${VARIANTS_MATCHING_REVISION},json('${origin}'),
      json_object(
        'gid',${gid},'token','${token}','title','${title}','title_jpn','',
        'filecount',10,'expunged',0,'tags',json('${tags}'),'rating',4.0,
        'uploader','fault','posted',${gid},'filesize',100,'thumb','fault-thumb',
        'first_gid',${first_gid},'first_token',${first_token_sql},
        'parent_gid',${parent_gid},'parent_token',${parent_token_sql},
        'current_gid',${current_gid},'current_token',${current_token_sql}),
      json(:popularity),json_object('in_scope',1,'score',1),'complete');
  "
}

# This excludes disposable staging/evidence and includes every durable live
# projection that publication can touch: metadata, relation/group/member,
# discover run/job, action, and review.
live_snapshot() {
  db_query "
    SELECT
      (SELECT group_concat(gid || ':' || token || ':' || title || ':' ||
                           COALESCE(file_count,'NULL') || ':' ||
                           COALESCE(first_gid,'NULL') || ':' ||
                           COALESCE(first_token,'NULL') || ':' ||
                           COALESCE(parent_gid,'NULL') || ':' ||
                           COALESCE(parent_token,'NULL') || ':' ||
                           COALESCE(current_gid,'NULL') || ':' ||
                           COALESCE(current_token,'NULL') || ':' || tags || ':' ||
                           COALESCE(favorite_count,'NULL') || ':' ||
                           COALESCE(rating_count,'NULL'),'|')
         FROM galleries WHERE gid IN (910001,910002) ORDER BY gid),
      (SELECT group_concat(id || ':' || source_gid || ':' || desired_rating || ':' ||
                           is_active || ':' || identity_active || ':' ||
                           COALESCE(canonical_gid,'NULL') || ':' || review_state,'|')
         FROM variant_groups WHERE source_gid=910001),
      (SELECT group_concat(group_id || ':' || gid || ':' || membership_state || ':' ||
                           decision_source || ':' || match_score || ':' || evidence_json || ':' ||
                           matching_revision,'|')
         FROM gallery_variants
        WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=910001)
        ORDER BY gid),
      (SELECT group_concat(id || ':' || status || ':' || COALESCE(lease_owner,'NULL') ||
                           ':' || COALESCE(continuation_cursor_json,'NULL') || ':' ||
                           COALESCE(last_error,'NULL'),'|')
         FROM variant_jobs WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=910001)
        ORDER BY id),
      (SELECT group_concat(id || ':' || status || ':' || COALESCE(lease_owner,'NULL') ||
                           ':' || COALESCE(cursor_json,'NULL') || ':' ||
                           COALESCE(last_error,'NULL'),'|')
         FROM variant_discovery_runs
        WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=910001)
        ORDER BY id),
      (SELECT group_concat(id || ':' || gid || ':' || action_type || ':' ||
                           desired_value || ':' || status || ':' ||
                           COALESCE(lease_owner,'NULL') || ':' || COALESCE(last_error,'NULL') || ':' ||
                           COALESCE(result_json,'NULL'),'|')
         FROM variant_actions
        WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=910001)
        ORDER BY id),
      (SELECT group_concat(id || ':' || candidate_gid || ':' || status || ':' ||
                           COALESCE(decision,'NULL') || ':' || COALESCE(superseded_at,'NULL') || ':' ||
                           evidence_json || ':' || choices_json || ':' || policy_revision_id, '|')
         FROM variant_reviews
        WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=910001)
        ORDER BY id);
  "
}

assert_fresh_retry_seed() {
  local group_id="$1" job_id="$2" run_id="$3" owner="$4"
  db_write "
    UPDATE variant_jobs SET status='leased', lease_owner='retry-owner',
      lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes')
      WHERE id=${job_id};
    UPDATE variant_discovery_runs SET status='running', phase='seed_refresh',
      lease_owner='retry-owner', lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes')
      WHERE id=${run_id};
  "
  variants_discovery_stage_seeds "${run_id}" "${group_id}" retry-owner >/dev/null
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates
    WHERE run_id=${run_id} AND state='gdata_pending';")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates
    WHERE run_id=${run_id} AND EXISTS (SELECT 1 FROM json_each(origin_json)
      WHERE json_extract(value,'\$.kind')='seed');")"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates
    WHERE run_id=${run_id} AND gid<>910001;")"
  # The owner argument documents which lease was reset; it is intentionally
  # not used after the fresh retry has acquired the new lease.
  : "${owner}"
}

run_blocked_case() {
  local kind="$1"
  local owner='fault-owner'
  local tuple group_id job_id run_id before after reason status
  new_database "blocked-${kind}"
  seed_live_projection
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"

  case "${kind}" in
  reference_incomplete)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Missing reference' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL 910099 missing-token
    ;;
  scope_incomplete)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Missing scope' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL 910002 fault-terminal-token
    stage_candidate "${run_id}" 910002 fault-terminal-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"current"}]' \
      'Missing scope terminal' '["language:chinese"]' \
      '{"favorite_count":4,"rating_count":8}' NULL NULL 910001 fault-source-token NULL NULL
    ;;
  scoring_input_incomplete)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Null score' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":null,"rating_count":7}' NULL NULL NULL NULL NULL NULL
    ;;
  token_mismatch)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Invalid token' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL NULL NULL
    db_write "UPDATE variant_discovery_candidates SET gdata_json=json_set(
      gdata_json,'\$.token','different-token') WHERE run_id=${run_id} AND gid=910001;"
    ;;
  cycle)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Cycle source' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL 910002 fault-terminal-token
    stage_candidate "${run_id}" 910002 fault-terminal-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"current"}]' \
      'Cycle terminal' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":4,"rating_count":8}' NULL NULL NULL NULL 910001 fault-source-token
    ;;
  branch)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Branch source' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL NULL NULL
    stage_candidate "${run_id}" 910002 fault-terminal-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"parent"}]' \
      'Branch child one' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":4,"rating_count":8}' NULL NULL 910001 fault-source-token NULL NULL
    stage_candidate "${run_id}" 910003 fault-child-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"parent"}]' \
      'Branch child two' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":5,"rating_count":9}' NULL NULL 910001 fault-source-token NULL NULL
    ;;
  relation_conflict)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Conflict source' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' 910003 fault-first-token NULL NULL \
      910002 fault-terminal-token
    stage_candidate "${run_id}" 910002 fault-terminal-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"current"}]' \
      'Conflict current' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":4,"rating_count":8}' NULL NULL NULL NULL NULL NULL
    stage_candidate "${run_id}" 910003 fault-first-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"first"}]' \
      'Conflict first' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":5,"rating_count":9}' NULL NULL NULL NULL NULL NULL
    ;;
  multiple_terminals)
    stage_candidate "${run_id}" 910001 fault-source-token \
      '[{"kind":"seed","gid":910001}]' 'Two terminals source' \
      '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":3,"rating_count":7}' NULL NULL NULL NULL 910002 fault-terminal-token
    stage_candidate "${run_id}" 910002 fault-terminal-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"current"}]' \
      'Two terminals current' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":4,"rating_count":8}' NULL NULL NULL NULL NULL NULL
    stage_candidate "${run_id}" 910003 fault-child-token \
      '[{"kind":"uploader_revision","from_gid":910001,"relation":"parent"}]' \
      'Two terminals child' '["language:chinese","other:tankoubon"]' \
      '{"favorite_count":5,"rating_count":9}' NULL NULL 910001 fault-source-token NULL NULL
    ;;
  *)
    printf 'unknown blocked case: %s\n' "${kind}" >&2
    return 2
    ;;
  esac

  before="$(live_snapshot)"
  reason="$(variants_discovery_publish_block_reason "${run_id}")"
  assert_eq "${kind}" "${reason}"
  status=0
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" -eq 0 ]]; then
    printf 'blocked case unexpectedly published: %s\n' "${kind}" >&2
    return 1
  fi
  assert_eq 76 "${status}"
  after="$(live_snapshot)"
  assert_eq "${before}" "${after}"

  variants_discovery_reset_blocked_run "${run_id}" "${job_id}" "${reason}" "${owner}"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates
    WHERE run_id=${run_id};")"
  assert_eq "retryable|seed_refresh|${reason}" "$(db_query "SELECT status || '|' || phase || '|' || last_error
    FROM variant_discovery_runs WHERE id=${run_id};")"
  assert_eq "queued|${reason}" "$(db_query "SELECT status || '|' || last_error
    FROM variant_jobs WHERE id=${job_id};")"
  assert_fresh_retry_seed "${group_id}" "${job_id}" "${run_id}" "${owner}"
  printf 'publication fault blocked case passed: %s\n' "${kind}"
}

run_transaction_fault_case() {
  local owner='transaction-owner'
  local tuple group_id job_id run_id before after status
  new_database transaction-rollback
  seed_live_projection
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"
  stage_candidate "${run_id}" 910001 fault-source-token \
    '[{"kind":"seed","gid":910001}]' 'After publication' \
    '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":13,"rating_count":17}' NULL NULL NULL NULL \
    910002 fault-terminal-token
  assert_eq '' "$(variants_discovery_publish_block_reason "${run_id}")"
  before="$(live_snapshot)"
  db_write "
    CREATE TRIGGER fault_after_publication_upsert
      AFTER UPDATE OF title ON galleries
      WHEN NEW.gid=910001 AND NEW.title='After publication'
    BEGIN
      SELECT RAISE(ABORT,'controlled publication fault');
    END;
  "
  status=0
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" \
    >/dev/null 2>"${TEMP_ROOT}/transaction-fault.log" || status=$?
  assert_eq 76 "${status}"
  after="$(live_snapshot)"
  assert_eq "${before}" "${after}"
  # A DB error must roll back the frozen candidates too; otherwise a retry
  # could publish a half-applied snapshot with no matching run state.
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates
    WHERE run_id=${run_id} AND state='complete';")"
  assert_eq 'running' "$(db_query "SELECT status FROM variant_discovery_runs WHERE id=${run_id};")"
  assert_eq 'leased' "$(db_query "SELECT status FROM variant_jobs WHERE id=${job_id};")"
  db_write 'DROP TRIGGER fault_after_publication_upsert;'

  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" >/dev/null
  assert_eq 'completed' "$(db_query "SELECT status FROM variant_discovery_runs WHERE id=${run_id};")"
  assert_eq 'completed' "$(db_query "SELECT status FROM variant_jobs WHERE id=${job_id};")"
  assert_eq 'After publication' "$(db_query 'SELECT title FROM galleries WHERE gid=910001;')"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates WHERE run_id=${run_id};")"

  # Calling the completed publication again must be fenced before any write;
  # the counts prove no duplicate action/review/job/member was emitted.
  before="$(live_snapshot)"
  status=0
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" \
    >/dev/null 2>/dev/null || status=$?
  [[ "${status}" -ne 0 ]] || {
    printf 'completed publication was not idempotently fenced\n' >&2
    return 1
  }
  after="$(live_snapshot)"
  assert_eq "${before}" "${after}"
  assert_eq 2 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND action_type='rating';")"
  assert_eq $'910001|superseded|11\n910002|pending|11' "$(db_query "SELECT gid || '|' || status || '|' || desired_value
    FROM variant_actions WHERE group_id=${group_id} AND action_type='rating' ORDER BY gid;")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND action_type='rating' AND status='pending';")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_reviews
    WHERE group_id=${group_id} AND candidate_gid=910002;")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_jobs
    WHERE group_id=${group_id} AND job_type='discover';")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM gallery_variants
    WHERE group_id=${group_id} AND gid=910001;")"
  printf 'publication transaction rollback/idempotency case passed\n'
}

run_canonical_projection_invalidation_case() {
  local owner='canonical-projection-owner'
  local tuple group_id job_id run_id evaluation_id
  new_database canonical-projection
  seed_live_projection
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  db_write "DELETE FROM variant_reviews WHERE group_id=${group_id};
    UPDATE variant_groups SET review_state='none' WHERE id=${group_id};"
  evaluation_id="$(db_write ".parameter set :group_id ${group_id}" \
    "INSERT INTO variant_evaluations(
       group_id,policy_revision_id,state,metadata_snapshot_json,
       member_scores_json,canonical_gid)
     SELECT :group_id,policy.id,'completed','{}','[]',910001
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")"
  db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    "UPDATE variant_groups SET canonical_gid=910001,active_evaluation_id=:evaluation_id
      WHERE id=:group_id;
     UPDATE gallery_variants SET variant_state='canonical',variant_score=100
      WHERE group_id=:group_id AND gid=910001;
     INSERT INTO variant_actions(
       group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,status)
     SELECT :group_id,:evaluation_id,910001,'favorite_move','canonical',policy.id,'pending'
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     INSERT INTO variant_actions(
       group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,status)
     SELECT :group_id,:evaluation_id,910001,'hath_request','request',policy.id,'pending'
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;"
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"
  stage_candidate "${run_id}" 910001 fault-source-token \
    '[{"kind":"seed","gid":910001}]' 'Projection invalidation' \
    '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":13,"rating_count":17}' NULL NULL NULL NULL NULL NULL
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" >/dev/null

  assert_eq 'NULL|NULL' "$(db_query "SELECT COALESCE(active_evaluation_id,'NULL') || '|' ||
    COALESCE(canonical_gid,'NULL') FROM variant_groups WHERE id=${group_id};")"
  assert_eq 'undetermined|NULL' "$(db_query "SELECT variant_state || '|' ||
    COALESCE(variant_score,'NULL') FROM gallery_variants
    WHERE group_id=${group_id} AND gid=910001;")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_evaluations
    WHERE id=${evaluation_id} AND state='completed' AND canonical_gid=910001;")"
  assert_eq 2 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND action_type IN ('favorite_move','hath_request')
      AND status='superseded';")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_jobs
    WHERE group_id=${group_id} AND job_type='evaluate' AND status='queued'
      AND expected_evaluation_id IS NULL;")"
  variants_actions_project "${group_id}" >/dev/null
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND action_type IN ('favorite_move','hath_request')
      AND status IN ('pending','retryable_error','configuration_error','in_flight');")"
  printf 'canonical projection invalidation case passed\n'
}

run_canonical_projection_blocked_review_case() {
  local owner='canonical-review-owner'
  local tuple group_id job_id run_id evaluation_id
  new_database canonical-review-blocked
  seed_live_projection
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  evaluation_id="$(db_write ".parameter set :group_id ${group_id}" \
    "INSERT INTO variant_evaluations(
       group_id,policy_revision_id,state,metadata_snapshot_json,
       member_scores_json,canonical_gid)
     SELECT :group_id,policy.id,'completed','{}','[]',910001
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")"
  db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    "UPDATE variant_groups SET canonical_gid=910001,active_evaluation_id=:evaluation_id
      WHERE id=:group_id;
     UPDATE gallery_variants SET variant_state='canonical',variant_score=100
      WHERE group_id=:group_id AND gid=910001;"
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"
  stage_candidate "${run_id}" 910001 fault-source-token \
    '[{"kind":"seed","gid":910001}]' 'Blocked review publication' \
    '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":13,"rating_count":17}' NULL NULL NULL NULL NULL NULL
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" >/dev/null

  assert_eq 'NULL|NULL|candidate_pending' "$(db_query "SELECT
    COALESCE(active_evaluation_id,'NULL') || '|' || COALESCE(canonical_gid,'NULL') || '|' ||
    review_state FROM variant_groups WHERE id=${group_id};")"
  assert_eq 'undetermined|NULL' "$(db_query "SELECT variant_state || '|' ||
    COALESCE(variant_score,'NULL') FROM gallery_variants
    WHERE group_id=${group_id} AND gid=910001;")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_evaluations
    WHERE id=${evaluation_id} AND state='completed' AND canonical_gid=910001;")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_reviews
    WHERE group_id=${group_id} AND status='pending' AND review_type='candidate_identity';")"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_jobs
    WHERE group_id=${group_id} AND job_type='evaluate' AND status IN ('queued','leased');")"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM gallery_variants AS member
    JOIN variant_groups AS grouped ON grouped.id=member.group_id
    WHERE grouped.id=${group_id} AND grouped.identity_active=1
      AND member.membership_state='confirmed'
      AND member.variant_state IS NOT CASE
        WHEN grouped.canonical_gid IS NULL THEN 'undetermined'
        WHEN member.gid=grouped.canonical_gid THEN 'canonical' ELSE 'alternate' END;")"
  variants_actions_project "${group_id}" >/dev/null
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND action_type IN ('favorite_move','hath_request')
      AND status IN ('pending','retryable_error','configuration_error','in_flight');")"
  printf 'canonical projection blocked-review case passed\n'
}

run_canonical_action_stale_lease_case() {
  local group_id evaluation_id job_id action_id action_json output remote_call_file
  new_database canonical-action-stale-lease
  seed_live_projection
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  db_write "DELETE FROM variant_reviews WHERE group_id=${group_id};
    UPDATE variant_groups SET review_state='none' WHERE id=${group_id};"
  evaluation_id="$(db_write ".parameter set :group_id ${group_id}" \
    "INSERT INTO variant_evaluations(
       group_id,policy_revision_id,state,metadata_snapshot_json,
       member_scores_json,canonical_gid)
     SELECT :group_id,policy.id,'completed','{}','[]',910001
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")"
  db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    "UPDATE variant_groups SET canonical_gid=910001,active_evaluation_id=:evaluation_id
      WHERE id=:group_id;
     UPDATE gallery_variants SET variant_state='canonical'
      WHERE group_id=:group_id AND gid=910001;"
  job_id="$(db_write ".parameter set :group_id ${group_id}" \
    "INSERT INTO variant_jobs(job_type,group_id,source_gid,status,lease_owner,lease_expires_at)
     SELECT 'reconcile_actions',:group_id,910001,'leased','canonical-action-worker',
            strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour');
     SELECT last_insert_rowid();")"
  action_id="$(db_write ".parameter set :group_id ${group_id}" \
    ".parameter set :evaluation_id ${evaluation_id}" \
    ".parameter set :job_id ${job_id}" \
    "INSERT INTO variant_actions(
       group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,
       status,lease_owner,lease_expires_at,lease_job_id)
     SELECT :group_id,:evaluation_id,910001,'favorite_move','canonical',policy.id,
            'in_flight','canonical-action-worker',
            strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'),:job_id
       FROM variant_policy_revisions AS policy WHERE policy.is_active=1;
     SELECT last_insert_rowid();")"
  # Simulate discovery invalidating the current projection after the worker
  # claimed an action, while leaving the job lease itself fenced as-is.
  db_write ".parameter set :group_id ${group_id}" \
    "UPDATE variant_groups SET canonical_gid=NULL,active_evaluation_id=NULL
      WHERE id=:group_id;
     UPDATE gallery_variants SET variant_state='undetermined'
      WHERE group_id=:group_id AND gid=910001;"
  remote_call_file="${TEMP_ROOT}/canonical-action-remote-call"
  exh_action_favorite() {
    : >"${remote_call_file}"
    return 1
  }
  action_json="{\"id\":${action_id},\"action_type\":\"favorite_move\",
    \"desired_value\":\"canonical\",\"gid\":910001,
    \"token\":\"fault-source-token\",\"desired_rating\":11}"
  output="$(variants_actions_execute_one "${action_json}" "${job_id}" canonical-action-worker)"
  jq -e '.status=="superseded" and .remote_mutation==false' <<<"${output}" >/dev/null
  assert_eq 'superseded|NULL|NULL|canonical_projection_changed' "$(db_query \
    "SELECT status || '|' || COALESCE(lease_owner,'NULL') || '|' ||
       COALESCE(lease_job_id,'NULL') || '|' || json_extract(result_json,'$.reason')
      FROM variant_actions WHERE id=${action_id};")"
  assert_eq 'leased|canonical-action-worker' "$(db_query \
    "SELECT status || '|' || lease_owner FROM variant_jobs WHERE id=${job_id};")"
  [[ ! -e "${remote_call_file}" ]] || fail 'stale favorite action reached remote adapter'
  printf 'canonical action stale-lease case passed\n'
}

run_manual_decision_revision_membership_case() {
  local owner='manual-revision-owner'
  local tuple group_id losing_group_id job_id run_id evaluation_id

  new_database manual-revision-retarget
  seed_live_projection
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  db_write "DELETE FROM variant_reviews WHERE group_id=${group_id};
    UPDATE variant_groups SET review_state='none' WHERE id=${group_id};"
  evaluation_id="$(seed_manual_canonical "${group_id}" 910001)"
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"
  stage_candidate "${run_id}" 910001 fault-source-token \
    '[{"kind":"seed","gid":910001}]' 'Manual revision source' \
    '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":13,"rating_count":17}' NULL NULL NULL NULL \
    910002 fault-terminal-token
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" >/dev/null
  assert_eq 'active|910002|[910002]' "$(db_query "SELECT status || '|' || canonical_gid || '|' ||
    member_fingerprint FROM variant_canonical_decisions WHERE group_id=${group_id};")"
  assert_eq 'NULL|910002|canonical' "$(db_query "SELECT
    COALESCE(grouped.active_evaluation_id,'NULL') || '|' || grouped.canonical_gid || '|' ||
    member.variant_state FROM variant_groups AS grouped JOIN gallery_variants AS member
      ON member.group_id=grouped.id AND member.gid=grouped.canonical_gid
    WHERE grouped.id=${group_id};")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_evaluations
    WHERE id=${evaluation_id} AND state='completed';")"

  new_database manual-revision-merge
  seed_live_projection
  group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910001;')"
  db_write "DELETE FROM variant_reviews WHERE group_id=${group_id};
    UPDATE variant_groups SET review_state='none' WHERE id=${group_id};
    INSERT INTO galleries(gid,token,title,tags,rating,file_count,first_gid,first_token)
      VALUES(910003,'fault-new-member-token','Incoming identity member',
        '[\"language:chinese\",\"other:tankoubon\"]',4.0,10,NULL,NULL);
    INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
      VALUES(910002,11,1,1,'none');
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,match_score,evidence_json,matching_revision)
      SELECT grouped.id,910002,'confirmed','manual',88,'{\"seed\":true}',
             ${VARIANTS_MATCHING_REVISION}
        FROM variant_groups AS grouped WHERE grouped.source_gid=910002;
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,match_score,evidence_json,matching_revision)
      SELECT grouped.id,910003,'confirmed','manual',87,'{\"seed\":true}',
             ${VARIANTS_MATCHING_REVISION}
        FROM variant_groups AS grouped WHERE grouped.source_gid=910002;"
  losing_group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=910002;')"
  evaluation_id="$(seed_manual_canonical "${group_id}" 910001)"
  tuple="$(new_discovery_run "${owner}")"
  IFS='|' read -r group_id job_id run_id owner <<<"${tuple}"
  stage_candidate "${run_id}" 910001 fault-source-token \
    '[{"kind":"seed","gid":910001}]' 'Manual revision source' \
    '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":13,"rating_count":17}' NULL NULL NULL NULL \
    910002 fault-terminal-token
  stage_candidate "${run_id}" 910002 fault-terminal-token \
    '[{"kind":"uploader_revision","from_gid":910001,"relation":"current"}]' \
    'Manual revision terminal' '["language:chinese","other:tankoubon"]' \
    '{"favorite_count":14,"rating_count":18}' NULL NULL NULL NULL NULL NULL
  variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" >/dev/null
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_canonical_decisions
    WHERE status='superseded' AND supersede_reason='member_set_changed';")"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM variant_canonical_decisions
    WHERE status='active';")"
  assert_eq 'NULL' "$(db_query "SELECT COALESCE(canonical_gid,'NULL')
    FROM variant_groups WHERE id=${group_id};")"
  assert_eq 0 "$(db_query "SELECT COUNT(*) FROM gallery_variants
    WHERE group_id=${group_id} AND membership_state='confirmed' AND variant_state='canonical';")"
  assert_eq 2 "$(db_query "SELECT COUNT(*) FROM gallery_variants
    WHERE group_id=${group_id} AND membership_state='confirmed'
      AND gid IN (910002,910003) AND variant_state='undetermined';")"
  assert_eq '1|0' "$(db_query "SELECT
    (SELECT identity_active FROM variant_groups WHERE id=${group_id}) || '|' ||
    (SELECT identity_active FROM variant_groups WHERE id=${losing_group_id});")"
  assert_eq 'none|0' "$(db_query "SELECT grouped.review_state || '|' ||
    (SELECT COUNT(*) FROM variant_reviews AS review
      WHERE review.group_id=grouped.id AND review.review_type='candidate_identity'
        AND review.status='pending')
    FROM variant_groups AS grouped WHERE grouped.id=${group_id};")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_actions
    WHERE group_id=${group_id} AND gid=910002 AND action_type='rating'
      AND desired_value='11' AND status='pending';")"
  assert_eq 1 "$(db_query "SELECT COUNT(*) FROM variant_evaluations
    WHERE id=${evaluation_id} AND state='completed';")"
  printf 'manual decision revision membership cases passed\n'
}

if [[ ! -f "${SCHEMA_SEED_PATH}" ]]; then
  prepare_database_seed
fi

for blocked_kind in \
  reference_incomplete scope_incomplete scoring_input_incomplete token_mismatch \
  cycle branch relation_conflict multiple_terminals; do
  run_blocked_case "${blocked_kind}"
done
run_transaction_fault_case
run_canonical_projection_invalidation_case
run_canonical_projection_blocked_review_case
run_canonical_action_stale_lease_case
run_manual_decision_revision_membership_case
echo 'variant revision publication faults smoke: passed'
