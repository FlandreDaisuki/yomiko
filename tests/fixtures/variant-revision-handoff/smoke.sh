#!/usr/bin/env bash
set -euo pipefail

# Chain-specific handoff/restart smoke.  This fixture is intentionally
# standalone: the main test runner may invoke it later, but it must also be
# useful when run directly against a disposable SQLite database.

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
source "${ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
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

# Keep this fixture runnable in the shell-only image used by static checks.
rg -n 'variants_retention_commit_archive|variants_worker_handle_reconcile_retention|variants_actions_project' \
  "${ROOT}/lib/variant_retention.sh" "${ROOT}/lib/variant_actions.sh" >/dev/null
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant revision handoff smoke: static contract ok (sqlite3 unavailable)'
  exit 0
fi

export DB_PATH="${HOME}/data/db.sqlite3"
export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1
db_init >/dev/null

assert_eq() {
  [[ "$1" == "$2" ]] || {
    printf 'expected %s, got %s\n' "$1" "$2" >&2
    return 1
  }
}

assert_file() {
  [[ -f "$1" && ! -L "$1" ]] || {
    printf 'expected regular file %s\n' "$1" >&2
    return 1
  }
}

old_archive='handoff-old-102.7z'
new_archive='handoff-new-103.7z'
printf 'old archive\n' >"${ARCHIVED_DIR}/${old_archive}"

# 102 is the exact-GID historical representative.  103 is a ready terminal
# with no inherited local acquisition state.  The old H@H action/timestamps
# are deliberately seeded before publication so every restart assertion can
# prove that they remain attached to 102.
db_write "
  INSERT INTO galleries(
    gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
    uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
    current_gid,current_token,self_rating,feedbacked_at,hath_requested_at,
    hath_last_attempted_at,favorite_count,rating_count)
  VALUES
    (102,'handoff-token-102','Handoff predecessor','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'${old_archive}',
     'handoff',102,100,'thumb-102',102,'handoff-token-102',NULL,NULL,
     103,'handoff-token-103',11,'2026-09-18T00:00:00Z',
     '2026-09-18T01:00:00Z','2026-09-18T02:00:00Z',10,20),
    (103,'handoff-token-103','Handoff terminal','',11,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.2,NULL,
     'handoff',103,110,'thumb-103',102,'handoff-token-102',
     102,'handoff-token-102',NULL,NULL,0,NULL,NULL,NULL,12,22);
  UPDATE galleries
     SET rated_then_deleted_at='2026-09-18T04:00:00Z'
   WHERE gid=102;
  INSERT INTO variant_groups(
    source_gid,desired_rating,is_active,identity_active,review_state,
    latest_feedback_at)
  VALUES(102,11,1,1,'none','2026-09-18T00:00:00Z');
  INSERT INTO gallery_variants(
    group_id,gid,membership_state,decision_source,evidence_json,
    variant_state,matching_revision)
  VALUES(last_insert_rowid(),102,'confirmed','automatic','{}','canonical',${VARIANTS_MATCHING_REVISION});
  INSERT INTO variant_evaluations(
    group_id,policy_revision_id,state,metadata_snapshot_json,
    member_scores_json,canonical_gid)
  SELECT 1,id,'completed',json_array(json_object('gid',102,'title','Handoff predecessor')),
         json_array(json_object('gid',102,'score',50)),102
    FROM variant_policy_revisions WHERE is_active=1;
  UPDATE variant_groups SET canonical_gid=102,active_evaluation_id=last_insert_rowid()
    WHERE id=1;
  INSERT INTO variant_actions(
    group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,
    status,result_json,completed_at,last_attempt_at)
  SELECT 1,active_evaluation_id,102,'hath_request','request',policy_revision_id,
         'succeeded',json_object('gid',102,'mutation_sent',json('true'),
                                 'historical','exact-102'),
         '2026-09-18T03:00:00Z','2026-09-18T02:00:00Z'
    FROM variant_groups
    JOIN variant_evaluations ON variant_evaluations.id=variant_groups.active_evaluation_id;
"

group_id=1
old_hath_before="$(db_query "SELECT hath_requested_at || '|' || hath_last_attempted_at
  FROM galleries WHERE gid=102;")"
old_cleanup_before="$(db_query "SELECT rated_then_deleted_at FROM galleries WHERE gid=102;")"
old_action_before="$(db_query "SELECT status || '|' || completed_at || '|' || last_attempt_at
  FROM variant_actions WHERE gid=102 AND action_type='hath_request';")"

stage_publish() {
  local owner="$1" job_id run_id
  local source_meta terminal_meta popularity source_origin terminal_origin source_evidence terminal_evidence
  source_meta='{"gid":102,"token":"handoff-token-102","title":"Handoff predecessor","title_jpn":"","filecount":10,"expunged":false,"tags":["language:chinese","other:tankoubon"],"rating":4.0,"uploader":"handoff","posted":102,"filesize":100,"thumb":"thumb-102","first_gid":102,"first_token":"handoff-token-102","parent_gid":null,"parent_token":null,"current_gid":103,"current_token":"handoff-token-103"}'
  terminal_meta='{"gid":103,"token":"handoff-token-103","title":"Handoff terminal","title_jpn":"","filecount":11,"expunged":false,"tags":["language:chinese","other:tankoubon"],"rating":4.2,"uploader":"handoff","posted":103,"filesize":110,"thumb":"thumb-103","first_gid":102,"first_token":"handoff-token-102","parent_gid":102,"parent_token":"handoff-token-102","current_gid":null,"current_token":null}'
  popularity='{"favorite_count":12,"rating_count":22,"popularity_fetched_at":"2026-09-20T00:00:00Z","error":null}'
  source_origin='[{"kind":"seed","gid":102}]'
  terminal_origin='[{"kind":"uploader_revision","from_gid":102,"relation":"current"}]'
  source_evidence='{"in_scope":1,"score":50}'
  terminal_evidence='{"in_scope":1,"score":60}'

  job_id="$(db_write \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "INSERT INTO variant_jobs(
       job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
     VALUES('discover',${group_id},102,500,'leased',:owner,
            strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
     SELECT last_insert_rowid();")"
  run_id="$(db_write \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "INSERT INTO variant_discovery_runs(
       group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
     VALUES(${group_id},${job_id},${VARIANTS_MATCHING_REVISION},'publish','running',
            :owner,strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
     SELECT last_insert_rowid();")"
  db_write \
    ".parameter set :source $(db_parameter_text "${source_meta}")" \
    ".parameter set :terminal $(db_parameter_text "${terminal_meta}")" \
    ".parameter set :popularity $(db_parameter_text "${popularity}")" \
    ".parameter set :source_origin $(db_parameter_text "${source_origin}")" \
    ".parameter set :terminal_origin $(db_parameter_text "${terminal_origin}")" \
    ".parameter set :source_evidence $(db_parameter_text "${source_evidence}")" \
    ".parameter set :terminal_evidence $(db_parameter_text "${terminal_evidence}")" \
    "INSERT INTO variant_discovery_candidates(
       run_id,gid,token,matching_revision,origin_json,gdata_json,
       popularity_json,evidence_json,state)
     VALUES
       (${run_id},102,'handoff-token-102',${VARIANTS_MATCHING_REVISION},
        json(:source_origin),json(:source),json(:popularity),
        json(:source_evidence),'complete'),
       (${run_id},103,'handoff-token-103',${VARIANTS_MATCHING_REVISION},
        json(:terminal_origin),json(:terminal),json(:popularity),
        json(:terminal_evidence),'complete');"
  printf '%s|%s|%s\n' "${job_id}" "${run_id}" "${owner}"
}

IFS='|' read -r publish_job publish_run publish_owner < <(stage_publish promotion-crash-owner)

# Boundary 1: a crash immediately after terminal membership promotion must
# roll back the complete publication.  A rerun after restart must promote only
# 103, retain the old exact archive, and queue one evaluation.
db_write "CREATE TRIGGER handoff_crash_after_promotion
  AFTER INSERT ON gallery_variants
  WHEN NEW.gid=103 AND NEW.membership_state='confirmed'
  BEGIN SELECT RAISE(ABORT,'handoff crash after eligible promotion'); END;"
if variants_discovery_publish "${publish_run}" "${publish_job}" "${group_id}" "${publish_owner}" >/dev/null 2>&1; then
  printf 'promotion crash trigger did not abort publication\n' >&2
  exit 1
fi
assert_eq '102' "$(db_query 'SELECT source_gid FROM variant_groups WHERE id=1;')"
assert_eq '102' "$(db_query "SELECT group_concat(gid,'') FROM gallery_variants
  WHERE group_id=1 AND membership_state='confirmed';")"
assert_eq '103|103|102|102|handoff-old-102.7z|0|1' "$(db_query "SELECT gid || '|' || terminal_gid || '|' ||
  component_gid || '|' || archive_gid || '|' || file_path || '|' || is_effective || '|' || archive_rank
  FROM available_galleries WHERE gid=103;")"
fallback_provenance="$(db_query "SELECT edge_provenance
  FROM uploader_revision_representatives WHERE revision_gid=103;")"
jq -e 'length == 2
  and all(.[]; .from_gid == 102 and .to_gid == 103)
  and ([.[].relation] | sort == ["current", "parent"])' <<<"${fallback_provenance}" >/dev/null
assert_eq "${old_hath_before}" "$(db_query "SELECT hath_requested_at || '|' || hath_last_attempted_at
  FROM galleries WHERE gid=102;")"
assert_eq "${old_cleanup_before}" "$(db_query "SELECT rated_then_deleted_at FROM galleries WHERE gid=102;")"
assert_eq "${old_action_before}" "$(db_query "SELECT status || '|' || completed_at || '|' || last_attempt_at
  FROM variant_actions WHERE gid=102 AND action_type='hath_request';")"
db_write 'DROP TRIGGER handoff_crash_after_promotion;'
publish_json="$(variants_discovery_publish "${publish_run}" "${publish_job}" "${group_id}" "${publish_owner}")"
jq -e '.status == "completed" and .source_gid == 103 and .evaluation_queued == true' <<<"${publish_json}" >/dev/null
assert_eq '103' "$(db_query 'SELECT source_gid FROM variant_groups WHERE id=1;')"
assert_eq '103' "$(db_query "SELECT group_concat(gid,'') FROM gallery_variants
  WHERE group_id=1 AND membership_state='confirmed';")"
assert_eq '102' "$(db_query "SELECT archive_gid FROM available_galleries WHERE gid=103;")"
assert_eq "${old_hath_before}" "$(db_query "SELECT hath_requested_at || '|' || hath_last_attempted_at
  FROM galleries WHERE gid=102;")"
assert_eq "${old_cleanup_before}" "$(db_query "SELECT rated_then_deleted_at FROM galleries WHERE gid=102;")"
assert_eq '|||' "$(db_query "SELECT COALESCE(hath_requested_at,'') || '|' ||
  COALESCE(hath_last_attempted_at,'') || '|' || COALESCE(file_path,'') || '|' ||
  COALESCE(rated_then_deleted_at,'')
  FROM galleries WHERE gid=103;")"

# Install a completed terminal evaluation.  The first projection attempt is
# aborted at H@H action acceptance; retrying the projection must create one
# terminal action only and must never copy/retarget the old exact-GID action.
evaluation_id="$(db_write "INSERT INTO variant_evaluations(
    group_id,policy_revision_id,state,metadata_snapshot_json,
    member_scores_json,canonical_gid)
  SELECT 1,id,'completed',json_array(json_object('gid',103,'title','Handoff terminal')),
         json_array(json_object('gid',103,'score',60)),103
    FROM variant_policy_revisions WHERE is_active=1;
  SELECT last_insert_rowid();")"
db_write "UPDATE variant_groups SET canonical_gid=103,active_evaluation_id=${evaluation_id}
  WHERE id=1;"
db_write "CREATE TRIGGER handoff_crash_after_hath_acceptance
  AFTER INSERT ON variant_actions
  WHEN NEW.gid=103 AND NEW.action_type='hath_request'
  BEGIN SELECT RAISE(ABORT,'handoff crash after H@H acceptance'); END;"
if variants_actions_project "${group_id}" >/dev/null 2>&1; then
  printf 'H@H acceptance crash trigger did not abort projection\n' >&2
  exit 1
fi
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';")"
assert_eq "${old_action_before}" "$(db_query "SELECT status || '|' || completed_at || '|' || last_attempt_at
  FROM variant_actions WHERE gid=102 AND action_type='hath_request';")"
db_write 'DROP TRIGGER handoff_crash_after_hath_acceptance;'
variants_actions_project "${group_id}" >/dev/null
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='hath_request'
    AND status IN ('pending','in_flight');")"
assert_eq '102' "$(db_query "SELECT archive_gid FROM available_galleries WHERE gid=103;")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup'
    AND status IN ('pending','in_flight');")"

# Boundary 2: accept the terminal H@H remotely, then crash while persisting
# the action result.  The lease recovery path must preserve one exact terminal
# action, retain the old timestamp, and avoid a second remote call on cooldown.
hath_calls_file="${TEMP_ROOT}/hath.calls"
: >"${hath_calls_file}"
exh_action_hath() {
  printf '%s\n' "$1" >>"${hath_calls_file}"
  jq -nc --argjson gid "$1" \
    '{operation:"hath_request",gid:$gid,outcome:"succeeded",mutation_sent:true}'
}
# The crash fixture is about the H@H transaction boundary.  Mark the other
# already-projected remote work as completed so the action worker cannot make
# an unrelated network call before reaching the terminal H@H action.  The
# production projector is still exercised above and remains authoritative.
db_write "UPDATE variant_actions
     SET status='succeeded', completed_at='2026-09-20T00:00:00Z'
   WHERE group_id=1 AND gid=103 AND action_type<>'hath_request'
     AND status IN ('pending','retryable_error','configuration_error');"
db_write "INSERT OR IGNORE INTO variant_jobs(
    job_type,group_id,source_gid,priority,status)
  VALUES('reconcile_actions',1,103,500,'queued');"
hath_job_json="$(variants_worker_claim_job handoff-hath-owner)"
db_write "CREATE TRIGGER handoff_crash_after_hath_result
  BEFORE UPDATE OF status ON variant_actions
  WHEN NEW.gid=103 AND NEW.action_type='hath_request' AND NEW.status='succeeded'
  BEGIN SELECT RAISE(ABORT,'handoff crash after H@H result'); END;"
if variants_worker_handle_reconcile_actions "${hath_job_json}" handoff-hath-owner 25 >/dev/null 2>&1; then
  printf 'H@H result crash trigger did not abort action finish\n' >&2
  exit 1
fi
assert_eq '1' "$(wc -l <"${hath_calls_file}" | tr -d '[:space:]')"
assert_eq 'in_flight' "$(db_query "SELECT status FROM variant_actions
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';")"
new_hath_attempt="$(db_query "SELECT COALESCE(hath_last_attempted_at,'')
  FROM galleries WHERE gid=103;")"
[[ -n "${new_hath_attempt}" && "${new_hath_attempt}" != "2026-09-18T02:00:00Z" ]] || {
  printf 'terminal H@H attempt did not remain exact-GID and distinct from predecessor\n' >&2
  exit 1
}
assert_eq '' "$(db_query "SELECT COALESCE(hath_requested_at,'')
  FROM galleries WHERE gid=103;")"
assert_eq "${old_hath_before}" "$(db_query "SELECT hath_requested_at || '|' || hath_last_attempted_at
  FROM galleries WHERE gid=102;")"
assert_eq "${old_action_before}" "$(db_query "SELECT status || '|' || completed_at || '|' || last_attempt_at
  FROM variant_actions WHERE gid=102 AND action_type='hath_request';")"
db_write 'DROP TRIGGER handoff_crash_after_hath_result;'
db_write "UPDATE variant_jobs SET lease_expires_at='2000-01-01T00:00:00Z'
  WHERE id=$(jq -r '.id' <<<"${hath_job_json}");
  UPDATE variant_actions SET lease_expires_at='2000-01-01T00:00:00Z'
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';"
variants_worker_requeue_expired_leases >/dev/null
variants_actions_requeue_expired >/dev/null
assert_eq 'retryable_error' "$(db_query "SELECT status FROM variant_actions
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';")"
assert_eq '1' "$(wc -l <"${hath_calls_file}" | tr -d '[:space:]')"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=103 AND action_type='hath_request';")"

# Boundary 3: archive commit fails before the SQLite path update.  The final
# archive file may already exist, but the old path/projection/jobs must remain
# authoritative until the transaction is retried successfully.
printf 'new archive\n' >"${ARCHIVED_DIR}/${new_archive}"
db_write "CREATE TRIGGER handoff_crash_before_archive_commit
  BEFORE UPDATE OF file_path ON galleries
  WHEN NEW.gid=103 AND NEW.file_path='${new_archive}'
  BEGIN SELECT RAISE(ABORT,'handoff crash before archive commit'); END;"
if variants_retention_commit_archive 103 "${new_archive}" >/dev/null 2>&1; then
  printf 'archive commit crash trigger did not abort commit\n' >&2
  exit 1
fi
assert_eq '' "$(db_query "SELECT COALESCE(file_path,'') FROM galleries WHERE gid=103;")"
assert_eq '102' "$(db_query "SELECT archive_gid FROM available_galleries WHERE gid=103;")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_retention' AND status='queued';")"
assert_file "${ARCHIVED_DIR}/${new_archive}"
db_write 'DROP TRIGGER handoff_crash_before_archive_commit;'
variants_retention_commit_archive 103 "${new_archive}" >/dev/null
assert_eq "${new_archive}" "$(db_query "SELECT file_path FROM galleries WHERE gid=103;")"
assert_eq '103' "$(db_query "SELECT archive_gid FROM available_galleries WHERE gid=103;")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_retention' AND status='queued';")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_actions' AND status IN ('queued','leased');")"
assert_file "${ARCHIVED_DIR}/${old_archive}"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_actions' AND status IN ('queued','leased');")"
# The previous action job is deliberately asleep until the H@H cooldown.  The
# retention job must be the next restart-owned job, not a duplicate action
# reconciliation; retention completion wakes the same coalesced action job.
db_write "UPDATE variant_jobs
     SET available_at='2099-01-01T00:00:00Z'
   WHERE group_id=1 AND job_type='reconcile_actions' AND status='queued';"

# Boundary 4: restart after the replacement archive commit but before cleanup.
# Retention completion only queues/reuses action reconciliation; it does not
# delete the old archive itself.
retention_job_json="$(variants_worker_claim_job handoff-retention-owner)"
 jq -e '.job_type == "reconcile_retention"' <<<"${retention_job_json}" >/dev/null
retention_output="$(variants_worker_handle_reconcile_retention "${retention_job_json}" handoff-retention-owner)"
jq -e '.status == "completed" and .canonical_archive == true' <<<"${retention_output}" >/dev/null
assert_file "${ARCHIVED_DIR}/${old_archive}"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_actions' AND status='queued';")"

# Boundary 5: cleanup performs the filesystem delete, then crashes before the
# action row can be marked succeeded.  Restart must reconcile the missing file
# idempotently and keep exactly one cleanup action row.
db_write "CREATE TRIGGER handoff_crash_after_cleanup
  BEFORE UPDATE OF status ON variant_actions
  WHEN NEW.gid=102 AND NEW.action_type='archive_cleanup' AND NEW.status='succeeded'
  BEGIN SELECT RAISE(ABORT,'handoff crash after cleanup'); END;"
cleanup_job_json="$(variants_worker_claim_job handoff-cleanup-owner)"
jq -e '.job_type == "reconcile_actions"' <<<"${cleanup_job_json}" >/dev/null
if variants_worker_handle_reconcile_actions "${cleanup_job_json}" handoff-cleanup-owner 0 >/dev/null 2>&1; then
  printf 'cleanup crash trigger did not abort action finish\n' >&2
  exit 1
fi
[[ ! -e "${ARCHIVED_DIR}/${old_archive}" ]] || {
  printf 'cleanup crash did not remove old archive\n' >&2
  exit 1
}
assert_eq 'in_flight' "$(db_query "SELECT status FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup';")"
db_write 'DROP TRIGGER handoff_crash_after_cleanup;'
db_write "UPDATE variant_jobs SET lease_expires_at='2000-01-01T00:00:00Z'
  WHERE id=$(jq -r '.id' <<<"${cleanup_job_json}");
  UPDATE variant_actions SET lease_expires_at='2000-01-01T00:00:00Z'
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup';"
variants_worker_requeue_expired_leases >/dev/null
variants_actions_requeue_expired >/dev/null
# H@H uncertainty keeps the shared action job asleep until its cooldown.  A
# local cleanup is independently safe to retry after the delete-side crash,
# so wake this same coalesced job before claiming the local work.
cleanup_job_id="$(jq -r '.id' <<<"${cleanup_job_json}")"
db_write "UPDATE variant_jobs
     SET available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
   WHERE id=${cleanup_job_id}
     AND status='queued';"
cleanup_job_json="$(variants_worker_claim_job handoff-cleanup-retry-owner)"
jq -e '.job_type == "reconcile_actions"' <<<"${cleanup_job_json}" >/dev/null
cleanup_output="$(variants_worker_handle_reconcile_actions "${cleanup_job_json}" handoff-cleanup-retry-owner 0)"
jq -e '.status == "continued" and .local_cleanups == 1' <<<"${cleanup_output}" >/dev/null
assert_eq 'succeeded' "$(db_query "SELECT status FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup';")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup';")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=1 AND job_type='reconcile_actions' AND status IN ('queued','leased','completed');")"
variants_actions_project "${group_id}" >/dev/null
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=1 AND gid=102 AND action_type='archive_cleanup';")"

# Rating 1-10 replacement path: a terminal without an archive still receives
# the ordinary rating work, but it does not wait for archive handoff and never
# creates winner/H@H replacement work.
printf 'low-rating old archive\n' >"${ARCHIVED_DIR}/handoff-low-202.7z"
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,file_path,uploader,posted,
    filesize,thumb,first_gid,first_token,parent_gid,parent_token,
    current_gid,current_token,self_rating,favorite_count,rating_count)
  VALUES
    (202,'handoff-token-202','Low predecessor',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'handoff-low-202.7z',
     'handoff-low',202,100,'thumb-202',202,'handoff-token-202',NULL,NULL,
     203,'handoff-token-203',8,1,1),
    (203,'handoff-token-203','Low terminal',11,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.2,NULL,
     'handoff-low',203,110,'thumb-203',202,'handoff-token-202',
     202,'handoff-token-202',NULL,NULL,0,2,2);
  INSERT INTO variant_groups(
    source_gid,desired_rating,is_active,identity_active,review_state)
  VALUES(203,8,1,1,'none');
  INSERT INTO gallery_variants(
    group_id,gid,membership_state,decision_source,evidence_json,
    variant_state,matching_revision)
  VALUES(last_insert_rowid(),203,'confirmed','automatic','{}','canonical',${VARIANTS_MATCHING_REVISION});
  INSERT INTO variant_evaluations(
    group_id,policy_revision_id,state,metadata_snapshot_json,
    member_scores_json,canonical_gid)
  SELECT 2,id,'completed',json_array(json_object('gid',203,'title','Low terminal')),
         json_array(json_object('gid',203,'score',20)),203
    FROM variant_policy_revisions WHERE is_active=1;
  UPDATE variant_groups SET canonical_gid=203,active_evaluation_id=last_insert_rowid()
    WHERE id=2;"
variants_actions_project 2 >/dev/null
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=2 AND action_type='hath_request';")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=2 AND job_type IN ('evaluate','discover');")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=2 AND gid=203 AND action_type='rating' AND desired_value='8';")"

echo 'variant revision handoff smoke: ok'
