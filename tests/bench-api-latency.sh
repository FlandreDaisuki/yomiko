#!/usr/bin/env bash
set -euo pipefail
trap 'printf "API latency benchmark failed at line %s (status %s)\n" "$LINENO" "$?" >&2' ERR

# Run as /home/yomiko/bench-api-latency.sh in an isolated playground container.
# Usage: /home/yomiko/bench-api-latency.sh [warm-runs=20] [strict-ceiling-ms=1000]
#        /home/yomiko/bench-api-latency.sh --fixture-check
#
# This covers every active public local HTTP budget in ADR-0009. Provider-wait
# routes and the archive response body keep their documented exemptions.
FIXTURE_CHECK_MODE=0
if [[ "${1:-}" == --fixture-check ]]; then
  [[ "$#" == 1 ]] || { echo 'fixture check accepts no extra arguments' >&2; exit 2; }
  FIXTURE_CHECK_MODE=1
  runs=1
  strict_ceiling_ms=1000
else
  runs="${1:-20}"
  strict_ceiling_ms="${2:-1000}"
fi
[[ "${runs}" =~ ^[1-9][0-9]*$ ]] || { echo 'warm-runs must be a positive integer' >&2; exit 2; }
[[ "${strict_ceiling_ms}" =~ ^[1-9][0-9]*$ ]] || { echo 'strict-ceiling-ms must be a positive integer' >&2; exit 2; }

# Yomiko paths and DB_PATH are container runtime configuration.
# shellcheck disable=SC1091
source /home/yomiko/lib/path.sh
# shellcheck disable=SC1091
source /home/yomiko/lib/db.sh

[[ -n "${YOMIKO_API_TOKEN:-}" ]] || { echo 'YOMIKO_API_TOKEN must be set by the playground' >&2; exit 2; }
[[ -f "${YOMIKO_METRICS_TOKEN_FILE:-}" ]] || { echo 'metrics token file must be set by the playground' >&2; exit 2; }
[[ -f "${DB_PATH:-}" ]] || { echo 'DB_PATH must point to the playground database' >&2; exit 2; }
[[ "${YOMIKO_BENCH_ISOLATED_PLAYGROUND:-}" == 1 ]] || {
  echo 'set YOMIKO_BENCH_ISOLATED_PLAYGROUND=1 only inside an isolated playground' >&2
  exit 2
}
command -v sqlite3 >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null

api_token="${YOMIKO_API_TOKEN}"
IFS= read -r metrics_token <"${YOMIKO_METRICS_TOKEN_FILE}"
api_base="${YOMIKO_BENCH_API_URL:-http://127.0.0.1}"
[[ "${api_base}" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] || {
  echo 'API benchmark URL must use loopback HTTP' >&2
  exit 2
}
[[ "${YOMIKO_REMOTE_WRITES_ENABLED:-false}" == false ]] || {
  echo 'API benchmark requires YOMIKO_REMOTE_WRITES_ENABLED=false' >&2
  exit 2
}
auth_header="Authorization: Bearer ${api_token}"
metrics_auth_header="Authorization: Bearer ${metrics_token}"
# These arrays are selected indirectly by record_request's Bash nameref.
# shellcheck disable=SC2034
declare -a no_headers=() api_headers=("-H" "${auth_header}") metric_headers=("-H" "${metrics_auth_header}")
tmp_dir="$(mktemp -d)"
original_db="${tmp_dir}/original.sqlite3"
baseline_db="${tmp_dir}/baseline.sqlite3"
original_snapshot_ready=0
fixture_seed_failed=0
coverage_failed=0
status_contract_failed=0
fixture_summary=''
FIXTURE_BASE_GID=''
FIXTURE_SOURCE_GID=''
FIXTURE_TARGET_GID_START=''
FIXTURE_UNGROUPED_GID_START=''
FIXTURE_UNGROUPED_GID_END=''
declare -a CANDIDATE_REVIEW_IDS=() WINNER_TARGETS=()
CANDIDATE_VISIBLE_COUNT=0
WINNER_VISIBLE_COUNT=0

run_locked_db_command() {
  local sqlite_command="$1" lock_path lock_fd status
  lock_path="$(db_writer_lock_path)" || return 1
  exec {lock_fd}>>"${lock_path}" || return 1
  if ! flock -n "${lock_fd}"; then
    printf 'database writer gate is busy; refusing benchmark snapshot operation\n' >&2
    eval "exec ${lock_fd}>&-"
    return 1
  fi
  if sqlite3 -bail "${DB_PATH}" <<<"${sqlite_command}"; then
    status=0
  else
    status=$?
  fi
  flock -u "${lock_fd}" 2>/dev/null || true
  eval "exec ${lock_fd}>&-"
  return "${status}"
}

cleanup_benchmark() {
  local exit_status=$? expected_snapshot_counts actual_snapshot_counts
  trap - EXIT
  if ((original_snapshot_ready)); then
    if ! expected_snapshot_counts="$(sqlite3 -noheader "${original_db}" \
      "SELECT (SELECT COUNT(*) FROM galleries)||char(58)||
              (SELECT COUNT(*) FROM variant_reviews)||char(58)||
              (SELECT COUNT(*) FROM variant_reviews WHERE status='pending');")"; then
      printf 'could not read the pre-benchmark database snapshot counts\n' >&2
      exit_status=1
    fi
    if ! run_locked_db_command ".restore '${original_db}'"; then
      printf 'could not restore the pre-benchmark database snapshot\n' >&2
      exit_status=1
    elif [[ -n "${expected_snapshot_counts}" ]]; then
      if ! actual_snapshot_counts="$(sqlite3 -noheader "${DB_PATH}" \
        "SELECT (SELECT COUNT(*) FROM galleries)||char(58)||
                (SELECT COUNT(*) FROM variant_reviews)||char(58)||
                (SELECT COUNT(*) FROM variant_reviews WHERE status='pending');")"; then
        printf 'could not read the restored database counts\n' >&2
        exit_status=1
      elif [[ "${actual_snapshot_counts}" != "${expected_snapshot_counts}" ]]; then
        printf 'database restore mismatch: expected gallery/review/pending counts %s, found %s\n' \
          "${expected_snapshot_counts}" "${actual_snapshot_counts}" >&2
        exit_status=1
      fi
    fi
  fi
  rm -rf -- "${tmp_dir}"
  exit "${exit_status}"
}
trap cleanup_benchmark EXIT

# Add a deterministic identity graph to the isolated database. The synthetic
# source class has 24 confirmed members. Each of its 21 target classes has 12
# confirmed members and one pending class-pair review. Each target also owns a
# pending winner review. This gives the public projections a connected graph
# with realistic class sizes without relying on production review cards or
# galleries. The benchmark restores this fixture snapshot before each mutation
# sample.
seed_review_fixtures() {
  local fixture_count="$((runs + 1))" source_class_size=24 target_class_size=12
  local fixture_base_gid="${FIXTURE_BASE_GID}"
  local target_gid_start="${FIXTURE_TARGET_GID_START}"
  local ungrouped_gid_start="${FIXTURE_UNGROUPED_GID_START}"
  local ungrouped_gid_end="${FIXTURE_UNGROUPED_GID_END}" fixture_sql

  fixture_sql="$(cat <<SQL
.timeout 5000
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE bench_fixture_groups(
  group_index INTEGER PRIMARY KEY,
  source_gid INTEGER NOT NULL UNIQUE,
  class_size INTEGER NOT NULL,
  group_id INTEGER
);
INSERT INTO bench_fixture_groups(group_index,source_gid,class_size)
VALUES (0,${fixture_base_gid},${source_class_size});
WITH RECURSIVE target_group(group_index) AS (
  SELECT 1
  UNION ALL
  SELECT group_index+1 FROM target_group WHERE group_index<${fixture_count}
)
INSERT INTO bench_fixture_groups(group_index,source_gid,class_size)
SELECT group_index,${target_gid_start}+(group_index-1)*${target_class_size},
       ${target_class_size}
  FROM target_group;
CREATE TEMP TABLE bench_fixture_member AS
WITH RECURSIVE class_member(group_index,source_gid,class_size,member_index) AS (
  SELECT group_index,source_gid,class_size,0 FROM bench_fixture_groups
  UNION ALL
  SELECT group_index,source_gid,class_size,member_index+1
    FROM class_member WHERE member_index+1<class_size
)
SELECT group_index,source_gid,class_size,member_index,
       source_gid+member_index AS gid
  FROM class_member;
INSERT INTO galleries(
  gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
  self_rating,uploader,posted,filesize,favorite_count,
  rating_count,thumb)
SELECT member.gid,printf('benchmark-token-%d',member.gid),
       printf('Synthetic Benchmark Work %03d, Edition %02d',
              member.group_index,member.member_index+1),
       printf('合成ベンチマーク作品 %03d',member.group_index),
       120+((member.group_index*7+member.member_index*11)%35),0,
       json_array('language:chinese','other:tankoubon',
         'artist:synthetic-benchmark-creator',
         printf('parody:synthetic-work-%03d',member.group_index),
         printf('female:synthetic-character-%02d',member.member_index+1)),
       4.2,NULL,11,'Synthetic benchmark uploader',
       1700000000-member.gid,64000000+member.member_index*1000,
       400+member.group_index,1200+member.member_index,''
  FROM bench_fixture_member AS member;
WITH RECURSIVE ungrouped(index_value) AS (
  SELECT 0
  UNION ALL
  SELECT index_value+1 FROM ungrouped WHERE index_value+1<${fixture_count}
)
INSERT INTO galleries(
  gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
  self_rating,uploader,posted,filesize,favorite_count,
  rating_count,thumb)
SELECT ${ungrouped_gid_start}+index_value,
       printf('benchmark-token-%d',${ungrouped_gid_start}+index_value),
       printf('Synthetic Feedback Work %03d',index_value+1),
       printf('合成フィードバック作品 %03d',index_value+1),
       88+index_value,0,
       json_array('language:chinese','other:tankoubon',
         'artist:synthetic-benchmark-creator','parody:synthetic-feedback'),
       4.0,NULL,0,'Synthetic benchmark uploader',
       1690000000-index_value,32000000,12,30,''
  FROM ungrouped;
INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
SELECT source_gid,11,1,1 FROM bench_fixture_groups;
UPDATE bench_fixture_groups
   SET group_id=(SELECT grouped.id FROM variant_groups AS grouped
                  WHERE grouped.source_gid=bench_fixture_groups.source_gid
                  ORDER BY grouped.id DESC LIMIT 1);
INSERT INTO gallery_variants(
  group_id,gid,membership_state,decision_source,match_score,evidence_json,
  variant_state,matching_revision)
SELECT fixture.group_id,member.gid,'confirmed','automatic',100,
       json_object('kind','synthetic_benchmark_member'),
       CASE WHEN member.member_index=0 THEN 'canonical' ELSE 'alternate' END,1
  FROM bench_fixture_groups AS fixture
  JOIN bench_fixture_member AS member
    ON member.group_index=fixture.group_index;
UPDATE variant_groups
   SET canonical_gid=source_gid
 WHERE id IN (SELECT group_id FROM bench_fixture_groups);
CREATE TEMP TABLE bench_candidate_fixture AS
SELECT source.group_id AS source_group_id,source.source_gid,
       target.group_id AS target_group_id,target.source_gid AS candidate_gid
  FROM bench_fixture_groups AS source
  JOIN bench_fixture_groups AS target ON target.group_index>0
 WHERE source.group_index=0;
INSERT INTO gallery_variants(
  group_id,gid,membership_state,decision_source,match_score,evidence_json,
  variant_state,matching_revision)
SELECT fixture.source_group_id,fixture.candidate_gid,'candidate','automatic',82,
       json_object('kind','synthetic_independent_metadata'),
       'undetermined',1
  FROM bench_candidate_fixture AS fixture;
INSERT INTO variant_reviews(
  review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
  evidence_json,choices_json)
SELECT 'candidate_identity',fixture.source_group_id,fixture.candidate_gid,
       policy.id,1,
       json_object('kind','independent_metadata',
         'source_snapshot',json_object('gid',fixture.source_gid,
           'title',(SELECT title FROM galleries WHERE gid=fixture.source_gid),
           'tags',json((SELECT tags FROM galleries WHERE gid=fixture.source_gid))),
         'candidate_snapshot',json_object('gid',fixture.candidate_gid,
           'title',(SELECT title FROM galleries WHERE gid=fixture.candidate_gid),
           'tags',json((SELECT tags FROM galleries WHERE gid=fixture.candidate_gid))),
         'components',json_array('shared_synthetic_creator','similar_page_count'),
         'contradictions',json_array()),
       json_array(fixture.source_gid,fixture.candidate_gid)
  FROM bench_candidate_fixture AS fixture
  CROSS JOIN variant_policy_revisions AS policy
 WHERE policy.is_active=1;
CREATE TEMP TABLE bench_winner_fixture AS
SELECT fixture.group_index,fixture.group_id,fixture.source_gid AS canonical_gid,
       policy.id AS policy_revision_id,
       (SELECT json_group_array(ordered.gid) FROM (
          SELECT member.gid FROM bench_fixture_member AS member
           WHERE member.group_index=fixture.group_index
           ORDER BY member.member_index
        ) AS ordered) AS choices_json,
       (SELECT json_group_array(json(item.value)) FROM (
          SELECT json_object('gid',member.gid,'title',gallery.title,
            'title_jpn',gallery.title_jpn,'filecount',gallery.file_count,
            'posted',gallery.posted,'favorite_count',gallery.favorite_count,
            'rating',gallery.rating,'rating_count',gallery.rating_count,
            'expunged',gallery.expunged,'tags',json(gallery.tags)) AS value
            FROM bench_fixture_member AS member
            JOIN galleries AS gallery ON gallery.gid=member.gid
           WHERE member.group_index=fixture.group_index
           ORDER BY member.member_index
        ) AS item) AS metadata_snapshot_json,
       (SELECT json_group_array(json(item.value)) FROM (
          SELECT json_object('gid',member.gid,
            'score',100-member.member_index,
            'components',json_object(
              'exact_tags',json_object('matches',json_array(),'subtotal',0),
              'title_substrings',json_object('matches',json_array(),'subtotal',0),
              'posted_rank',json_object('rank',member.member_index+1,'points',0),
              'page_count',json_object('points',0),
              'favorite_popularity',json_object('points',0),
              'rating_confidence',json_object('points',0),
              'expunged',json_object('points',0))) AS value
            FROM bench_fixture_member AS member
           WHERE member.group_index=fixture.group_index
           ORDER BY member.member_index
        ) AS item) AS member_scores_json
  FROM bench_fixture_groups AS fixture
  CROSS JOIN variant_policy_revisions AS policy
 WHERE fixture.group_index>0 AND policy.is_active=1;
INSERT INTO variant_evaluations(
  group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,
  canonical_gid,tied_gids_json)
SELECT group_id,policy_revision_id,'completed',metadata_snapshot_json,
       member_scores_json,canonical_gid,NULL
  FROM bench_winner_fixture;
UPDATE variant_groups
   SET active_evaluation_id=(SELECT evaluation.id
                               FROM variant_evaluations AS evaluation
                              WHERE evaluation.group_id=variant_groups.id
                              ORDER BY evaluation.id DESC LIMIT 1)
 WHERE id IN (SELECT group_id FROM bench_winner_fixture);
UPDATE gallery_variants
   SET variant_score=(SELECT CAST(json_extract(score.value,'$.score') AS INTEGER)
                        FROM variant_evaluations AS evaluation
                        JOIN json_each(evaluation.member_scores_json) AS score
                       WHERE evaluation.group_id=gallery_variants.group_id
                         AND CAST(json_extract(score.value,'$.gid') AS INTEGER)=gallery_variants.gid
                       ORDER BY evaluation.id DESC LIMIT 1)
 WHERE group_id IN (SELECT group_id FROM bench_winner_fixture)
   AND membership_state='confirmed';
INSERT INTO variant_reviews(
  review_type,group_id,evaluation_id,policy_revision_id,evidence_json,
  choices_json)
SELECT 'winner',fixture.group_id,evaluation.id,fixture.policy_revision_id,
       json_object('reason','synthetic score gap','score_gap',40),
       fixture.choices_json
  FROM bench_winner_fixture AS fixture
  JOIN variant_evaluations AS evaluation
    ON evaluation.group_id=fixture.group_id
   AND evaluation.id=(SELECT MAX(current.id) FROM variant_evaluations AS current
                       WHERE current.group_id=fixture.group_id);
-- Every synthetic class is an endpoint of one of the fresh unknown candidate
-- pairs, so candidate_pending is the projection for all 22 fixture groups.
UPDATE variant_groups
   SET review_state='candidate_pending'
 WHERE id IN (SELECT group_id FROM bench_fixture_groups);
SELECT 'synthetic_galleries='||
       (SELECT COUNT(*) FROM galleries WHERE gid>=${fixture_base_gid} AND gid<${ungrouped_gid_end});
SELECT 'synthetic_gid_start='||${fixture_base_gid};
SELECT 'source_class_members='||COUNT(*) FROM gallery_variants
 WHERE group_id=(SELECT group_id FROM bench_fixture_groups WHERE group_index=0)
   AND membership_state='confirmed';
SELECT 'target_class_members='||MIN(class_size)||'..'||MAX(class_size)
  FROM bench_fixture_groups WHERE group_index>0;
SELECT 'candidate_fixture_rows='||COUNT(*) FROM bench_candidate_fixture;
SELECT 'winner_fixture_rows='||COUNT(*) FROM bench_winner_fixture;
COMMIT;
SQL
)"
  run_locked_db_command "${fixture_sql}"
}

run_locked_db_command ".backup '${original_db}'"
original_snapshot_ready=1

FIXTURE_BASE_GID="$(sqlite3 -noheader "${DB_PATH}" \
  'SELECT COALESCE(MAX(gid),0)+1
     FROM (SELECT gid FROM galleries
           UNION ALL SELECT gid FROM variant_discovery_candidates);')"
[[ "${FIXTURE_BASE_GID}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'coverage unavailable: could not choose a synthetic gallery ID range\n' >&2
  exit 1
}
FIXTURE_SOURCE_GID="${FIXTURE_BASE_GID}"
FIXTURE_TARGET_GID_START="$((FIXTURE_BASE_GID + 24))"
FIXTURE_UNGROUPED_GID_START="$((FIXTURE_TARGET_GID_START + (runs + 1) * 12))"
FIXTURE_UNGROUPED_GID_END="$((FIXTURE_UNGROUPED_GID_START + runs + 1))"
fixture_summary="$(seed_review_fixtures)" || {
  printf 'could not create isolated review fixtures:\n%s\n' "${fixture_summary}" >&2
  fixture_seed_failed=1
}
printf 'Synthetic review fixtures: %s\n' "${fixture_summary:-unavailable}"
if ((fixture_seed_failed)); then
  printf 'coverage unavailable: synthetic gallery and review fixtures were not created\n' >&2
fi

run_locked_db_command ".backup '${baseline_db}'"

restore_baseline() {
  run_locked_db_command ".restore '${baseline_db}'"
}

record_request() {
  local method="$1" url="$2" output_path="$3" headers_name="$4"
  local -n headers="${headers_name}"
  curl -sS --max-time 60 -X "${method}" -D "${output_path}.headers" -o "${output_path}" \
    -w '%{http_code}\t%{time_total}\t%{size_download}\n' \
    "${headers[@]}" "${url}"
}

assert_status() {
  local label="$1" expected="$2" actual="$3"
  [[ "${actual}" == "${expected}" ]] || {
    printf '%s returned HTTP %s; expected %s\n' "${label}" "${actual}" "${expected}" >&2
    return 1
  }
}

assert_success_json() {
  local label="$1" path="$2"
  jq -e '.success == true' "${path}" >/dev/null || {
    printf '%s returned an invalid success payload\n' "${label}" >&2
    return 1
  }
}

p95_seconds() {
  local path="$1" rank
  rank=$(((runs * 95 + 99) / 100))
  sort -n "${path}" | sed -n "${rank}p"
}

report_route() {
  local label="$1" budget_ms="$2" expected="$3" cold_line="$4" warm_times="$5" last_line="$6"
  local p95 p95_ms effective_budget_ms cold_status cold_time cold_bytes last_status last_time last_bytes
  IFS=$'\t' read -r cold_status cold_time cold_bytes <<<"${cold_line}"
  IFS=$'\t' read -r last_status last_time last_bytes <<<"${last_line}"
  p95="$(p95_seconds "${warm_times}")"
  p95_ms="$(awk -v seconds="${p95}" 'BEGIN {printf "%.0f", seconds*1000}')"
  effective_budget_ms="${budget_ms}"
  if ((budget_ms < 10000 && strict_ceiling_ms < effective_budget_ms)); then
    effective_budget_ms="${strict_ceiling_ms}"
  fi
  printf '%-34s first=%s/%ss/%sB last_warm=%s/%ss/%sB warm_p95=%sms n=%s\n' \
    "${label}" "${cold_status}" "${cold_time}" "${cold_bytes}" \
    "${last_status}" "${last_time}" "${last_bytes}" "${p95_ms}" "${runs}"
  if ((p95_ms >= effective_budget_ms)); then
    printf '%s warm p95 %sms exceeded its %sms gate\n' \
      "${label}" "${p95_ms}" "${effective_budget_ms}" >&2
    budget_failed=1
  fi
  [[ "${cold_status}" == "${expected}" ]]
}

run_read_route() {
  local label="$1" budget_ms="$2" expected="$3" json_success="$4"
  local headers_name="$5" method="$6" url="$7"
  local body="${tmp_dir}/${label}.body" cold_line warm_line sample
  local warm_times="${tmp_dir}/${label}.warm"
  : >"${warm_times}"
  cold_line="$(record_request "${method}" "${url}" "${body}" "${headers_name}")"
  assert_status "${label}" "${expected}" "${cold_line%%$'\t'*}"
  [[ "${json_success}" == 0 ]] || assert_success_json "${label}" "${body}"
  for ((sample=0; sample<runs; sample++)); do
    warm_line="$(record_request "${method}" "${url}" "${body}" "${headers_name}")"
    assert_status "${label} sample ${sample}" "${expected}" "${warm_line%%$'\t'*}"
    [[ "${json_success}" == 0 ]] || assert_success_json "${label}" "${body}"
    printf '%s\n' "${warm_line#*$'\t'}" | cut -f1 >>"${warm_times}"
  done
  report_route "${label}" "${budget_ms}" "${expected}" "${cold_line}" "${warm_times}" "${warm_line}"
}

run_archive_metadata_route() {
  local label='archive_metadata' budget_ms=1000
  local body="${tmp_dir}/${label}.body" cold_line warm_line sample cold_status warm_status
  local warm_times="${tmp_dir}/${label}.warm"
  : >"${warm_times}"
  cold_line="$(record_request GET "${api_base}/api/archive_download.sh?gid=${archive_gid}" \
    "${body}" no_headers)"
  cold_status="${cold_line%%$'\t'*}"
  [[ "${cold_status}" == 404 ]] || status_contract_failed=1
  [[ "$(<"${body}")" == 'Archive not found' ]] || status_contract_failed=1
  for ((sample=0; sample<runs; sample++)); do
    warm_line="$(record_request GET "${api_base}/api/archive_download.sh?gid=${archive_gid}" \
      "${body}" no_headers)"
    warm_status="${warm_line%%$'\t'*}"
    [[ "${warm_status}" == 404 ]] || status_contract_failed=1
    [[ "$(<"${body}")" == 'Archive not found' ]] || status_contract_failed=1
    printf '%s\n' "${warm_line#*$'\t'}" | cut -f1 >>"${warm_times}"
  done
  report_route "${label}" "${budget_ms}" 404 "${cold_line}" "${warm_times}" "${warm_line}" || true
  if ((status_contract_failed)); then
    printf 'HTTP status contract failure: archive metadata must return HTTP 404; observed HTTP %s with body %s\n' \
      "${cold_status}" "$(<"${body}")" >&2
  fi
}

run_mutation_route() {
  local label="$1" budget_ms="$2" url_prefix="$3" header_name="$4" verify_review="$5" restore_each_sample="$6"
  shift 6
  local body="${tmp_dir}/${label}.body" cold_line warm_line sample target
  local warm_times="${tmp_dir}/${label}.warm"
  local -a targets=("$@")
  (("${#targets[@]}" == runs + 1)) || {
    printf '%s needs %s fresh fixtures, got %s\n' \
      "${label}" "$((runs+1))" "${#targets[@]}" >&2
    return 1
  }
  : >"${warm_times}"
  target="${targets[0]}"
  if [[ "${restore_each_sample}" == 1 ]]; then restore_baseline; fi
  if [[ "${verify_review}" == 1 ]]; then
    verify_pending_review "${target}"
  fi
  cold_line="$(record_request PUT "${url_prefix}${target}" "${body}" "${header_name}")"
  assert_status "${label}" 200 "${cold_line%%$'\t'*}"
  assert_success_json "${label}" "${body}"
  if [[ "${url_prefix}" == *"/api/feedback.sh"* ]]; then
    jq -e '.variant_queued == true' "${body}" >/dev/null || {
      printf '%s did not queue rated feedback\n' "${label}" >&2
      return 1
    }
  fi
  for ((sample=1; sample<=runs; sample++)); do
    target="${targets[sample]}"
    if [[ "${restore_each_sample}" == 1 ]]; then restore_baseline; fi
    if [[ "${verify_review}" == 1 ]]; then
      verify_pending_review "${target}"
    fi
    warm_line="$(record_request PUT "${url_prefix}${target}" "${body}" "${header_name}")"
    assert_status "${label} sample ${sample}" 200 "${warm_line%%$'\t'*}"
    assert_success_json "${label}" "${body}"
    if [[ "${url_prefix}" == *"/api/feedback.sh"* ]]; then
      jq -e '.variant_queued == true' "${body}" >/dev/null || {
        printf '%s sample %s did not queue rated feedback\n' "${label}" "${sample}" >&2
        return 1
      }
    fi
    printf '%s\n' "${warm_line#*$'\t'}" | cut -f1 >>"${warm_times}"
  done
  report_route "${label}" "${budget_ms}" 200 "${cold_line}" "${warm_times}" "${warm_line}"
}

verify_pending_review() {
  local target="$1" review_id response_path status
  review_id="${target#*review_id=}"
  review_id="${review_id%%&*}"
  [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'invalid review fixture in %s\n' "${target}" >&2
    return 1
  }
  response_path="${tmp_dir}/pending-review-check.json"
  status="$(record_request GET "${api_base}/api/pending_variant_reviews.sh" \
    "${response_path}" api_headers | cut -f1)"
  assert_status 'pending review fixture check' 200 "${status}"
  jq -e --argjson review_id "${review_id}" \
    '[.reviews[] | select(.id == $review_id and .status == "pending")] | length == 1' \
    "${response_path}" >/dev/null || {
      printf 'review %s was not pending in the authenticated GET immediately before PUT\n' \
        "${review_id}" >&2
      return 1
    }
}

review_fixture_visible() {
  local review_type="$1" response_path="$2" review_id="$3" choice_gid="${4:-}"
  if [[ "${review_type}" == winner ]]; then
    jq -e --argjson review_id "${review_id}" --argjson choice_gid "${choice_gid}" \
      '[.reviews[] | select(.id == $review_id and .review_type == "winner" and
        .status == "pending" and (.choices | length) == 12 and
        any(.choices[]?; .gid == $choice_gid))] | length == 1' \
      "${response_path}" >/dev/null
  else
    jq -e --argjson review_id "${review_id}" \
      '[.reviews[] | select(.id == $review_id and .review_type == "candidate_identity" and
        .status == "pending" and .source_class_size == 24 and
        .candidate_class_size == 12)] | length == 1' "${response_path}" >/dev/null
  fi
}

select_review_fixtures() {
  local response_path="$1" fixture_line review_id choice_gid winner_target
  local candidate_visible_count=0 winner_visible_count=0

  fixture_line="$(record_request GET "${api_base}/api/pending_variant_reviews.sh" \
    "${response_path}" api_headers)"
  assert_status 'review fixture listing' 200 "${fixture_line%%$'\t'*}"
  assert_success_json 'review fixture listing' "${response_path}"

  mapfile -t CANDIDATE_REVIEW_IDS < <(sqlite3 -noheader "${DB_PATH}" \
    "SELECT review.id FROM variant_reviews AS review
       JOIN variant_groups AS grouped ON grouped.id=review.group_id
      WHERE review.review_type='candidate_identity' AND review.status='pending'
        AND grouped.source_gid=${FIXTURE_SOURCE_GID}
        AND review.candidate_gid>=${FIXTURE_TARGET_GID_START}
        AND review.candidate_gid<${FIXTURE_UNGROUPED_GID_START}
      ORDER BY review.candidate_gid LIMIT $((runs+1));")
  for review_id in "${CANDIDATE_REVIEW_IDS[@]}"; do
    if review_fixture_visible candidate_identity "${response_path}" "${review_id}"; then
      ((candidate_visible_count+=1))
    fi
  done
  CANDIDATE_VISIBLE_COUNT="${candidate_visible_count}"
  if ((${#CANDIDATE_REVIEW_IDS[@]} != runs + 1 || candidate_visible_count != runs + 1)); then
    printf 'coverage unavailable: need %s synthetic candidate cards visible through the API, found %s IDs and %s visible\n' \
      "$((runs + 1))" "${#CANDIDATE_REVIEW_IDS[@]}" "${candidate_visible_count}" >&2
    coverage_failed=1
  else
    printf 'Candidate resolution fixtures: %s synthetic cards visible; %s unique review rows used\n' \
      "${candidate_visible_count}" "${#CANDIDATE_REVIEW_IDS[@]}"
  fi

  mapfile -t WINNER_TARGETS < <(sqlite3 -separator $'\t' -noheader "${DB_PATH}" \
    "SELECT review.id,json_extract(review.choices_json,'\$[0]')
       FROM variant_reviews AS review
       JOIN variant_groups AS grouped ON grouped.id=review.group_id
       JOIN variant_evaluations AS evaluation
         ON evaluation.id=review.evaluation_id
        AND evaluation.group_id=grouped.id
        AND evaluation.id=grouped.active_evaluation_id
      WHERE review.review_type='winner' AND review.status='pending'
        AND review.superseded_at IS NULL
        AND grouped.source_gid>=${FIXTURE_TARGET_GID_START}
        AND grouped.source_gid<${FIXTURE_UNGROUPED_GID_START}
        AND grouped.identity_active=1 AND grouped.desired_rating=11
        AND json_array_length(review.choices_json)>0
      ORDER BY grouped.source_gid LIMIT $((runs+1));")
  for winner_target in "${WINNER_TARGETS[@]}"; do
    IFS=$'\t' read -r review_id choice_gid <<<"${winner_target}"
    if review_fixture_visible winner "${response_path}" "${review_id}" "${choice_gid}"; then
      ((winner_visible_count+=1))
    fi
  done
  WINNER_VISIBLE_COUNT="${winner_visible_count}"
  if ((${#WINNER_TARGETS[@]} != runs + 1 || winner_visible_count != runs + 1)); then
    printf 'coverage unavailable: need %s synthetic winner cards and choices visible through the API, found %s IDs and %s visible\n' \
      "$((runs + 1))" "${#WINNER_TARGETS[@]}" "${winner_visible_count}" >&2
    coverage_failed=1
  else
    printf 'Winner resolution fixtures: %s synthetic cards visible; %s warm samples requested\n' \
      "${winner_visible_count}" "${runs}"
  fi
}

fixture_list="${tmp_dir}/review-fixtures.json"
if ((FIXTURE_CHECK_MODE)); then
  select_review_fixtures "${fixture_list}"
  exit $((coverage_failed || fixture_seed_failed))
fi

mapfile -t grouped_gids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT source_gid FROM variant_groups
    WHERE source_gid>=${FIXTURE_BASE_GID}
      AND source_gid<${FIXTURE_UNGROUPED_GID_START}
    ORDER BY source_gid LIMIT $((runs+1));")
((${#grouped_gids[@]} == runs + 1)) || {
  printf 'coverage unavailable: need %s synthetic grouped galleries for feedback samples, found %s\n' \
    "$((runs+1))" "${#grouped_gids[@]}" >&2
  coverage_failed=1
}
mapfile -t fresh_ungrouped_gids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gallery.gid FROM galleries AS gallery
    WHERE gallery.gid>=${FIXTURE_UNGROUPED_GID_START}
      AND gallery.gid<${FIXTURE_UNGROUPED_GID_END}
      AND COALESCE(gallery.self_rating,0)=0
      AND gallery.current_gid IS NULL
      AND NOT EXISTS (SELECT 1 FROM gallery_variants AS member
                       WHERE member.gid=gallery.gid)
      AND NOT EXISTS (SELECT 1 FROM variant_groups AS grouped
                       WHERE grouped.source_gid=gallery.gid)
    ORDER BY gallery.gid;")
((${#fresh_ungrouped_gids[@]} == runs + 1)) || {
  printf 'coverage unavailable: need %s synthetic ungrouped galleries for feedback samples, found %s\n' \
    "$((runs+1))" "${#fresh_ungrouped_gids[@]}" >&2
  coverage_failed=1
}
mapfile -t gallery_ids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gid FROM galleries
    WHERE gid>=${FIXTURE_BASE_GID} AND gid<${FIXTURE_UNGROUPED_GID_END}
    ORDER BY gid LIMIT $((runs+1));")
((${#gallery_ids[@]} == runs + 1)) || {
  printf 'coverage unavailable: need %s synthetic galleries for request samples, found %s\n' \
    "$((runs+1))" "${#gallery_ids[@]}" >&2
  coverage_failed=1
}
archive_gid=''
if ((fixture_seed_failed == 0)); then
  archive_candidates_payload="$(/home/yomiko/bin/yomiko internal archive-paths "${FIXTURE_SOURCE_GID}")"
  archive_gid="$(jq -r 'first(.[] | select(.archive_path == null or .archive_path == "") | .gid) // empty' \
    <<<"${archive_candidates_payload}")"
else
  # Keep independent gallery and archive reads available if review seeding
  # fails. This fallback does not select a card for a review mutation.
  fallback_gallery_gid="$(sqlite3 -noheader "${DB_PATH}" \
    'SELECT gid FROM galleries ORDER BY gid LIMIT 1;')"
  if [[ "${fallback_gallery_gid}" =~ ^[1-9][0-9]*$ ]]; then
    gallery_ids=("${fallback_gallery_gid}")
    mapfile -t fallback_archive_gids < <(sqlite3 -noheader "${DB_PATH}" \
      "SELECT gid FROM galleries WHERE COALESCE(file_path,'')='' ORDER BY gid LIMIT 100;")
    if ((${#fallback_archive_gids[@]} > 0)); then
      archive_candidates_payload="$(/home/yomiko/bin/yomiko internal archive-paths \
        "${fallback_archive_gids[@]}")"
      archive_gid="$(jq -r 'first(.[] | select(.archive_path == null or .archive_path == "") | .gid) // empty' \
        <<<"${archive_candidates_payload}")"
    fi
    printf 'using snapshot galleries only for independent read routes after fixture seed failure\n' >&2
  fi
fi
if [[ ! "${archive_gid}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'coverage unavailable: synthetic archive-not-found fixture is unavailable\n' >&2
  coverage_failed=1
fi

printf 'Acceptance gates: local routes <1s; metrics <1s; %s warm samples per route.\n' "${runs}"
budget_failed=0

run_read_route health 1000 200 0 no_headers GET "${api_base}/health"
run_read_route userscript 1000 200 0 no_headers GET "${api_base}/yomiko.user.js"
run_read_route metrics 1000 200 0 metric_headers GET "${api_base}/metrics"
if ((${#gallery_ids[@]} > 0)); then
  run_read_route galleries 1000 200 1 api_headers GET "${api_base}/api/galleries.sh?gids=${gallery_ids[0]}"
fi
run_read_route pending_feedback 1000 200 1 no_headers GET "${api_base}/api/pending_feedback_galleries.sh?max_count=50"
run_read_route pending_variant_reviews 1000 200 1 api_headers GET "${api_base}/api/pending_variant_reviews.sh"

if ((${#grouped_gids[@]} == runs + 1)); then
  for rating in 8 9 10 11; do
    feedback_targets=()
    for gid in "${grouped_gids[@]}"; do feedback_targets+=("?gid=${gid}&rating=${rating}"); done
    restore_baseline
    run_mutation_route "feedback_rating_${rating}" 1000 "${api_base}/api/feedback.sh" api_headers 0 0 "${feedback_targets[@]}"
  done
  feedback_targets=()
  for gid in "${grouped_gids[@]}"; do feedback_targets+=("?gid=${gid}&rating=3"); done
  restore_baseline
  run_mutation_route feedback_grouped_rating_3 1000 "${api_base}/api/feedback.sh" api_headers 0 0 "${feedback_targets[@]}"
else
  coverage_failed=1
fi
if ((${#fresh_ungrouped_gids[@]} == runs + 1)); then
  feedback_targets=()
  for gid in "${fresh_ungrouped_gids[@]}"; do feedback_targets+=("?gid=${gid}&rating=3"); done
  restore_baseline
  run_mutation_route feedback_fresh_ungrouped_rating_3 1000 "${api_base}/api/feedback.sh" api_headers 0 1 "${feedback_targets[@]}"
else
  coverage_failed=1
fi

# Select generated IDs from their GID range, then require each card to remain
# visible through the authenticated public route before measuring its PUT.
select_review_fixtures "${fixture_list}"
if ((${#CANDIDATE_REVIEW_IDS[@]} == runs + 1 && CANDIDATE_VISIBLE_COUNT == runs + 1)); then
  different_targets=()
  same_targets=()
  for ((INDEX=0; INDEX<=runs; INDEX++)); do
    TARGET_INDEX="${INDEX}"
    different_targets+=("?review_id=${CANDIDATE_REVIEW_IDS[TARGET_INDEX]}&decision=different-book")
    same_targets+=("?review_id=${CANDIDATE_REVIEW_IDS[TARGET_INDEX]}&decision=same-book")
  done
  restore_baseline
  run_mutation_route review_different_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${different_targets[@]}"
  restore_baseline
  run_mutation_route review_same_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${same_targets[@]}"
fi

# Candidate same-book samples merge one target into the source class. Restore
# the synthetic snapshot before testing the independent winner fixtures.
restore_baseline
fixture_line="$(record_request GET "${api_base}/api/pending_variant_reviews.sh" "${fixture_list}" api_headers)"
assert_status 'winner fixture listing' 200 "${fixture_line%%$'\t'*}"
assert_success_json 'winner fixture listing' "${fixture_list}"
if ((${#WINNER_TARGETS[@]} == runs + 1 && WINNER_VISIBLE_COUNT == runs + 1)); then
  winner_decisions=()
  for ((INDEX=0; INDEX<=runs; INDEX++)); do
    TARGET_INDEX="${INDEX}"
    IFS=$'\t' read -r REVIEW_ID WINNER_GID <<<"${WINNER_TARGETS[TARGET_INDEX]}"
    winner_decisions+=("?review_id=${REVIEW_ID}&decision=winner&gid=${WINNER_GID}")
  done
  restore_baseline
  run_mutation_route review_winner 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${winner_decisions[@]}"
fi

# The archive body is exempt. Use a no-archive GID so this request measures its
# bounded metadata lookup and stable not-found response without a transfer.
if [[ "${archive_gid}" =~ ^[1-9][0-9]*$ ]]; then
  restore_baseline
  run_archive_metadata_route
fi
exit $((budget_failed || coverage_failed || fixture_seed_failed || status_contract_failed))
