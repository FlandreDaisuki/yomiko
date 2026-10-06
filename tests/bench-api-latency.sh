#!/usr/bin/env bash
set -euo pipefail
trap 'printf "API latency benchmark failed at line %s (status %s)\n" "$LINENO" "$?" >&2' ERR

# Run as /home/yomiko/bench-api-latency.sh in an isolated playground container.
# Usage: /home/yomiko/bench-api-latency.sh [warm-runs=20] [strict-ceiling-ms=1000]
#
# This covers every active public local HTTP budget in ADR-0009. Provider-wait
# routes and the archive response body keep their documented exemptions.
runs="${1:-20}"
strict_ceiling_ms="${2:-1000}"
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
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
baseline_db="${tmp_dir}/baseline.sqlite3"
fixture_seed_failed=0
coverage_failed=0
status_contract_failed=0
fixture_summary=''

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

# Add representative pending reviews to the isolated database. Use current
# confirmed members so every fixture has a scoreable source and candidate.
# The benchmark restores this fixture snapshot before each mutation sample.
seed_review_fixtures() {
  local fixture_count="$((runs + 1))" fixture_sql
  fixture_sql="$(cat <<SQL
.timeout 5000
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE bench_active_member AS
SELECT member.group_id,member.gid
  FROM gallery_variants AS member
  JOIN variant_groups AS grouped ON grouped.id=member.group_id
 WHERE member.membership_state='confirmed'
   AND grouped.identity_active=1;
CREATE INDEX bench_active_member_by_gid ON bench_active_member(gid);
CREATE INDEX bench_active_member_by_group ON bench_active_member(group_id,gid);
CREATE TEMP TABLE bench_known_class_pair AS
SELECT DISTINCT MIN(low_member.group_id,high_member.group_id) AS low_group_id,
       MAX(low_member.group_id,high_member.group_id) AS high_group_id
  FROM gallery_identity_pairs AS pair
  JOIN bench_active_member AS low_member ON low_member.gid=pair.low_gid
  JOIN bench_active_member AS high_member ON high_member.gid=pair.high_gid
 WHERE low_member.group_id<>high_member.group_id;
CREATE TEMP TABLE bench_pending_class_pair AS
SELECT DISTINCT MIN(source_member.group_id,candidate_member.group_id) AS low_group_id,
       MAX(source_member.group_id,candidate_member.group_id) AS high_group_id
  FROM variant_reviews AS review
  JOIN variant_groups AS owner ON owner.id=review.group_id
  JOIN gallery_variants AS owner_member
    ON owner_member.group_id=owner.id
   AND owner_member.membership_state='confirmed'
  JOIN bench_active_member AS source_member ON source_member.gid=owner_member.gid
  JOIN bench_active_member AS candidate_member ON candidate_member.gid=review.candidate_gid
 WHERE review.review_type='candidate_identity'
   AND review.status='pending';
CREATE TEMP TABLE bench_candidate_eligible AS
SELECT source_member.group_id AS source_group_id,
       source.source_gid,
       target_member.group_id AS target_group_id,
       MIN(target_member.gid) AS candidate_gid,
       COUNT(*) AS target_class_size
  FROM bench_active_member AS source_member
  JOIN variant_groups AS source
    ON source.id=source_member.group_id
   AND source.source_gid=source_member.gid
  JOIN bench_active_member AS target_member
    ON target_member.group_id<>source_member.group_id
  LEFT JOIN bench_known_class_pair AS known
    ON known.low_group_id=MIN(source_member.group_id,target_member.group_id)
   AND known.high_group_id=MAX(source_member.group_id,target_member.group_id)
  LEFT JOIN bench_pending_class_pair AS pending
    ON pending.low_group_id=MIN(source_member.group_id,target_member.group_id)
   AND pending.high_group_id=MAX(source_member.group_id,target_member.group_id)
 WHERE known.low_group_id IS NULL
   AND pending.low_group_id IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM gallery_variants AS existing
      WHERE existing.group_id=source_member.group_id
        AND existing.gid=target_member.gid)
 GROUP BY source_member.group_id,source.source_gid,target_member.group_id;
CREATE TEMP TABLE bench_candidate_source AS
SELECT source_group_id
  FROM bench_candidate_eligible
 GROUP BY source_group_id
 ORDER BY COUNT(*) DESC,source_group_id
 LIMIT 1;
CREATE TEMP TABLE bench_candidate_fixture AS
SELECT eligible.source_group_id,eligible.source_gid,
       eligible.target_group_id,eligible.candidate_gid
  FROM bench_candidate_eligible AS eligible
  JOIN bench_candidate_source AS source
    ON source.source_group_id=eligible.source_group_id
 ORDER BY eligible.target_class_size,eligible.candidate_gid
 LIMIT ${fixture_count};
INSERT INTO gallery_variants(
  group_id,gid,membership_state,decision_source,match_score,evidence_json,
  variant_state,matching_revision)
SELECT source_group_id,candidate_gid,'candidate','automatic',0,'{}',
       'undetermined',1
  FROM bench_candidate_fixture;
INSERT INTO variant_reviews(
  review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
  evidence_json,choices_json)
SELECT 'candidate_identity',fixture.source_group_id,fixture.candidate_gid,
       policy.id,1,'{}',json_array(fixture.source_gid,fixture.candidate_gid)
  FROM bench_candidate_fixture AS fixture
  CROSS JOIN variant_policy_revisions AS policy
 WHERE policy.is_active=1;

CREATE TEMP TABLE bench_winner_fixture AS
SELECT grouped.id AS group_id,evaluation.id AS evaluation_id,
       evaluation.policy_revision_id,
       COALESCE(grouped.canonical_gid,
         (SELECT MIN(member.gid) FROM gallery_variants AS member
           WHERE member.group_id=grouped.id
             AND member.membership_state='confirmed')) AS selected_gid,
       (SELECT json_group_array(choice.gid) FROM (
          SELECT member.gid FROM gallery_variants AS member
           WHERE member.group_id=grouped.id
             AND member.membership_state='confirmed'
           ORDER BY CASE WHEN member.gid=COALESCE(grouped.canonical_gid,
             (SELECT MIN(selected.gid) FROM gallery_variants AS selected
               WHERE selected.group_id=grouped.id
                 AND selected.membership_state='confirmed')) THEN 0 ELSE 1 END,
             member.gid
        ) AS choice) AS choices_json
  FROM variant_groups AS grouped
  JOIN variant_evaluations AS evaluation
    ON evaluation.id=grouped.active_evaluation_id
   AND evaluation.state='completed'
 WHERE grouped.identity_active=1
   AND grouped.desired_rating=11
   AND grouped.review_state='none'
   AND grouped.id NOT IN (SELECT source_group_id FROM bench_candidate_source)
   AND NOT EXISTS (
     SELECT 1 FROM variant_reviews AS existing
      WHERE existing.review_type='winner'
        AND existing.evaluation_id=evaluation.id
        AND existing.status='pending')
   AND EXISTS (
     SELECT 1 FROM gallery_variants AS member
      WHERE member.group_id=grouped.id
        AND member.membership_state='confirmed')
 ORDER BY grouped.id
 LIMIT ${fixture_count};
INSERT INTO variant_reviews(
  review_type,group_id,evaluation_id,policy_revision_id,evidence_json,
  choices_json)
SELECT 'winner',group_id,evaluation_id,policy_revision_id,'{}',choices_json
  FROM bench_winner_fixture;
SELECT 'candidate_fixture_rows='||COUNT(*) FROM bench_candidate_fixture;
SELECT 'winner_fixture_rows='||COUNT(*) FROM bench_winner_fixture;
COMMIT;
SQL
)"
  run_locked_db_command "${fixture_sql}"
}

fixture_summary="$(seed_review_fixtures)" || {
  printf 'could not create isolated review fixtures:\n%s\n' "${fixture_summary}" >&2
  fixture_seed_failed=1
}
printf 'Synthetic review fixtures: %s\n' "${fixture_summary:-unavailable}"

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

mapfile -t grouped_gids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT MIN(member.gid) FROM gallery_variants AS member
     JOIN variant_groups AS grouped ON grouped.id=member.group_id
    WHERE member.membership_state='confirmed' AND grouped.identity_active=1
    GROUP BY grouped.id ORDER BY MIN(member.gid) LIMIT $((runs+1));")
(("${#grouped_gids[@]}" == runs + 1)) || { echo 'not enough confirmed grouped galleries for feedback budget samples' >&2; exit 2; }
mapfile -t fresh_ungrouped_gids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gallery.gid FROM galleries AS gallery
    WHERE COALESCE(gallery.self_rating,0)=0
      AND gallery.current_gid IS NULL
      AND NOT EXISTS (SELECT 1 FROM gallery_variants AS member
                       WHERE member.gid=gallery.gid)
      AND NOT EXISTS (SELECT 1 FROM variant_groups AS grouped
                       WHERE grouped.source_gid=gallery.gid)
    ORDER BY gallery.gid LIMIT $((runs+1));")
((${#fresh_ungrouped_gids[@]} == runs + 1)) || { echo 'not enough fresh ungrouped galleries for low-feedback budget samples' >&2; exit 2; }
mapfile -t gallery_ids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gid FROM galleries ORDER BY gid LIMIT $((runs+1));")
(("${#gallery_ids[@]}" == runs + 1)) || { echo 'not enough galleries for request samples' >&2; exit 2; }
mapfile -t archive_candidate_gids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gid FROM galleries WHERE COALESCE(file_path,'')='' ORDER BY gid LIMIT 100;")
archive_candidates_payload="$(/home/yomiko/bin/yomiko internal archive-paths "${archive_candidate_gids[@]}")"
archive_gid="$(jq -r 'first(.[] | select(.archive_path == null or .archive_path == "") | .gid) // empty' \
  <<<"${archive_candidates_payload}")"
if [[ ! "${archive_gid}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'coverage unavailable: no gallery has a null archive source for metadata lookup\n' >&2
  coverage_failed=1
fi

printf 'Acceptance gates: local routes <1s; metrics <1s; %s warm samples per route.\n' "${runs}"
budget_failed=0

# These arrays are selected indirectly by record_request's Bash nameref.
# shellcheck disable=SC2034
declare -a no_headers=() api_headers=("-H" "${auth_header}") metric_headers=("-H" "${metrics_auth_header}")
run_read_route health 1000 200 0 no_headers GET "${api_base}/health"
run_read_route userscript 1000 200 0 no_headers GET "${api_base}/yomiko.user.js"
run_read_route metrics 1000 200 0 metric_headers GET "${api_base}/metrics"
run_read_route galleries 1000 200 1 api_headers GET "${api_base}/api/galleries.sh?gids=${gallery_ids[0]}"
run_read_route pending_feedback 1000 200 1 no_headers GET "${api_base}/api/pending_feedback_galleries.sh?max_count=50"
run_read_route pending_variant_reviews 1000 200 1 api_headers GET "${api_base}/api/pending_variant_reviews.sh"

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
feedback_targets=()
for gid in "${fresh_ungrouped_gids[@]}"; do feedback_targets+=("?gid=${gid}&rating=3"); done
restore_baseline
run_mutation_route feedback_fresh_ungrouped_rating_3 1000 "${api_base}/api/feedback.sh" api_headers 0 1 "${feedback_targets[@]}"

# Select only fixtures already visible through the authenticated public route.
fixture_list="${tmp_dir}/review-fixtures.json"
fixture_line="$(record_request GET "${api_base}/api/pending_variant_reviews.sh" "${fixture_list}" api_headers)"
assert_status 'review fixture listing' 200 "${fixture_line%%$'\t'*}"
assert_success_json 'review fixture listing' "${fixture_list}"
mapfile -t candidate_review_ids < <(jq -r --argjson limit "$((runs+1))" \
  '[.reviews[] | select(.review_type == "candidate_identity")] | .[:$limit][] | .id' \
  "${fixture_list}")
if ((${#candidate_review_ids[@]} < runs + 1)); then
  printf 'coverage unavailable: need %s distinct candidate identity cards, found %s\n' \
    "$((runs + 1))" "${#candidate_review_ids[@]}" >&2
  coverage_failed=1
else
  printf 'Candidate resolution fixtures: %s visible cards; %s unique review rows used\n' \
    "$(jq '[.reviews[] | select(.review_type == "candidate_identity")] | length' "${fixture_list}")" \
    "${#candidate_review_ids[@]}"
  different_targets=()
  same_targets=()
  for ((INDEX=0; INDEX<=runs; INDEX++)); do
    TARGET_INDEX="${INDEX}"
    different_targets+=("?review_id=${candidate_review_ids[TARGET_INDEX]}&decision=different-book")
    same_targets+=("?review_id=${candidate_review_ids[TARGET_INDEX]}&decision=same-book")
  done
  restore_baseline
  run_mutation_route review_different_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${different_targets[@]}"
  restore_baseline
  run_mutation_route review_same_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${same_targets[@]}"
fi

mapfile -t winner_targets < <(jq -r --argjson limit "$((runs+1))" \
  '[.reviews[] | select(.review_type == "winner" and (.choices | length) > 0)] | .[:$limit][] | [.id, .choices[0].gid] | @tsv' \
  "${fixture_list}")
if ((${#winner_targets[@]} < runs + 1)); then
  printf 'coverage unavailable: need %s distinct winner cards, found %s\n' \
    "$((runs + 1))" "${#winner_targets[@]}" >&2
  coverage_failed=1
else
  printf 'Winner resolution fixtures: %s visible cards; %s warm samples requested\n' \
    "$(jq '[.reviews[] | select(.review_type == "winner")] | length' "${fixture_list}")" "${runs}"
  winner_decisions=()
  for ((INDEX=0; INDEX<=runs; INDEX++)); do
    TARGET_INDEX="${INDEX}"
    IFS=$'\t' read -r REVIEW_ID WINNER_GID <<<"${winner_targets[TARGET_INDEX]}"
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
