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

run_locked_db_command() {
  local sqlite_command="$1" lock_path lock_fd status
  lock_path="$(db_writer_lock_path)" || return 1
  exec {lock_fd}>>"${lock_path}" || return 1
  if ! flock -n "${lock_fd}"; then
    printf 'database writer gate is busy; refusing benchmark snapshot operation\n' >&2
    eval "exec ${lock_fd}>&-"
    return 1
  fi
  if sqlite3 "${DB_PATH}" "${sqlite_command}"; then
    status=0
  else
    status=$?
  fi
  flock -u "${lock_fd}" 2>/dev/null || true
  eval "exec ${lock_fd}>&-"
  return "${status}"
}

run_locked_db_command ".backup '${baseline_db}'"

restore_baseline() {
  run_locked_db_command ".restore '${baseline_db}'"
}

record_request() {
  local method="$1" url="$2" output_path="$3" headers_name="$4"
  local -n headers="${headers_name}"
  curl -sS --max-time 60 -X "${method}" -o "${output_path}" \
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
  for ((sample=1; sample<=runs; sample++)); do
    target="${targets[sample]}"
    if [[ "${restore_each_sample}" == 1 ]]; then restore_baseline; fi
    if [[ "${verify_review}" == 1 ]]; then
      verify_pending_review "${target}"
    fi
    warm_line="$(record_request PUT "${url_prefix}${target}" "${body}" "${header_name}")"
    assert_status "${label} sample ${sample}" 200 "${warm_line%%$'\t'*}"
    assert_success_json "${label}" "${body}"
    printf '%s\n' "${warm_line#*$'\t'}" | cut -f1 >>"${warm_times}"
  done
  report_route "${label}" "${budget_ms}" 200 "${cold_line}" "${warm_times}" "${warm_line}"
}

run_fixture_limited_winner_route() {
  local label="$1" budget_ms="$2" url_prefix="$3" header_name="$4" target="$5"
  local body="${tmp_dir}/${label}.body" line status seconds bytes elapsed_ms
  verify_pending_review "${target}"
  line="$(record_request PUT "${url_prefix}${target}" "${body}" "${header_name}")"
  IFS=$'\t' read -r status seconds bytes <<<"${line}"
  assert_status "${label}" 200 "${status}"
  assert_success_json "${label}" "${body}"
  elapsed_ms="$(awk -v value="${seconds}" 'BEGIN {printf "%.0f", value*1000}')"
  printf '%-34s sample=%s/%ss/%sB fixtures=1\n' "${label}" "${status}" "${seconds}" "${bytes}"
  if ((elapsed_ms >= budget_ms)); then
    printf '%s took %sms; expected below %sms\n' "${label}" "${elapsed_ms}" "${budget_ms}" >&2
    budget_failed=1
  fi
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
mapfile -t gallery_ids < <(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gid FROM galleries ORDER BY gid LIMIT $((runs+1));")
(("${#gallery_ids[@]}" == runs + 1)) || { echo 'not enough galleries for request samples' >&2; exit 2; }
archive_gid="$(sqlite3 -noheader "${DB_PATH}" \
  "SELECT gid FROM galleries WHERE COALESCE(file_path,'')='' ORDER BY gid LIMIT 1;")"
[[ "${archive_gid}" =~ ^[1-9][0-9]*$ ]] || { echo 'no gallery without an archive path for metadata lookup' >&2; exit 2; }

printf 'Acceptance gates: local routes <1s; metrics <10s; %s warm samples per route.\n' "${runs}"
budget_failed=0

# These arrays are selected indirectly by record_request's Bash nameref.
# shellcheck disable=SC2034
declare -a no_headers=() api_headers=("-H" "${auth_header}") metric_headers=("-H" "${metrics_auth_header}")
run_read_route health 1000 200 0 no_headers GET "${api_base}/health"
run_read_route userscript 1000 200 0 no_headers GET "${api_base}/yomiko.user.js"
run_read_route metrics 10000 200 0 metric_headers GET "${api_base}/metrics"
run_read_route galleries 1000 200 1 api_headers GET "${api_base}/api/galleries.sh?gids=${gallery_ids[0]}"
run_read_route pending_feedback 1000 200 1 no_headers GET "${api_base}/api/pending_feedback_galleries.sh?max_count=50"
run_read_route pending_variant_reviews 1000 200 1 api_headers GET "${api_base}/api/pending_variant_reviews.sh"

# Select only fixtures already visible through the authenticated public route.
fixture_list="${tmp_dir}/review-fixtures.json"
fixture_line="$(record_request GET "${api_base}/api/pending_variant_reviews.sh" "${fixture_list}" api_headers)"
assert_status 'review fixture listing' 200 "${fixture_line%%$'\t'*}"
assert_success_json 'review fixture listing' "${fixture_list}"
mapfile -t candidate_review_ids < <(jq -r '.reviews[] | select(.review_type == "candidate_identity") | .id' "${fixture_list}" | head -n "$((runs+1))")
((${#candidate_review_ids[@]} == runs + 1)) || { echo 'not enough authenticated pending candidate reviews for decision samples' >&2; exit 2; }
mapfile -t winner_targets < <(jq -r '.reviews[] | select(.review_type == "winner" and (.choices | length) > 0) | [.id, .choices[0].gid] | @tsv' "${fixture_list}" | head -n 1)
((${#winner_targets[@]} > 0)) || { echo 'no pending winner review is available for the fixture-limited check' >&2; exit 2; }

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

different_targets=()
same_targets=()
for ((index=0; index<=runs; index++)); do
  different_targets+=("?review_id=${candidate_review_ids[index]}&decision=different-book")
  same_targets+=("?review_id=${candidate_review_ids[index]}&decision=same-book")
done
restore_baseline
run_mutation_route review_different_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${different_targets[@]}"
restore_baseline
run_mutation_route review_same_book 1000 "${api_base}/api/review_resolve.sh" api_headers 1 1 "${same_targets[@]}"
winner_decisions=()
for target in "${winner_targets[@]}"; do
  IFS=$'\t' read -r review_id winner_gid <<<"${target}"
  winner_decisions+=("?review_id=${review_id}&decision=winner&gid=${winner_gid}")
done
restore_baseline
run_fixture_limited_winner_route review_winner 1000 "${api_base}/api/review_resolve.sh" api_headers "${winner_decisions[0]}"

# The archive body is exempt. Use a no-archive GID so this request measures its
# bounded metadata lookup and stable not-found response without a transfer.
run_read_route archive_metadata 1000 404 0 no_headers GET "${api_base}/api/archive_download.sh?gid=${archive_gid}"
exit "${budget_failed}"
