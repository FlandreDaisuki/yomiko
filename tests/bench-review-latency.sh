#!/usr/bin/env bash
set -euo pipefail
trap 'printf "benchmark failed at line %s (status %s)\n" "$LINENO" "$?" >&2' ERR

# Run inside the isolated playground web container. Usage:
#   tests/bench-review-latency.sh [warm-runs=20] [regression-ceiling-ms=1000]

runs="${1:-20}"
regression_ceiling_ms="${2:-1000}"
[[ "${runs}" =~ ^[1-9][0-9]*$ ]] || { echo 'warm-runs must be a positive integer' >&2; exit 2; }
[[ "${regression_ceiling_ms}" =~ ^[1-9][0-9]*$ ]] || { echo 'regression-ceiling-ms must be a positive integer' >&2; exit 2; }

ROOT="${YOMIKO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -n "${YOMIKO_API_TOKEN:-}" ]] || { echo 'YOMIKO_API_TOKEN must be set by the playground' >&2; exit 2; }
api_token="${YOMIKO_API_TOKEN}"

# The same pending-only library projection used by the CLI. query_only
# preserves the review GET boundary.
# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variants.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_retention.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT
TIMEFORMAT='%3R %3U %3S'
REVISION_SQL="$(variants_revision_projection_sql review)"
cat >"${TMP_DIR}/mock-yomiko" <<'MOCK'
#!/usr/bin/env bash
cat -- "${YOMIKO_BENCH_CLI_FILE}"
MOCK
chmod +x "${TMP_DIR}/mock-yomiko"

run_cli() {
  "${ROOT}/bin/yomiko" variants pending-reviews
}

run_cgi() {
  HOME="${HOME}" YOMIKO_BIN="${ROOT}/bin/yomiko" YOMIKO_API_TOKEN="${api_token}" \
    HTTP_AUTHORIZATION="Bearer ${api_token}" REQUEST_METHOD=GET \
    QUERY_STRING='' HTTP_ORIGIN='' bash "${ROOT}/web/api/pending_variant_reviews.sh"
}

run_cached_validator() {
  local cli_file="$1"
  HOME="${HOME}" YOMIKO_BIN="${TMP_DIR}/mock-yomiko" \
    YOMIKO_BENCH_CLI_FILE="${cli_file}" YOMIKO_API_TOKEN="${api_token}" \
    HTTP_AUTHORIZATION="Bearer ${api_token}" REQUEST_METHOD=GET \
    QUERY_STRING='' HTTP_ORIGIN='' bash "${ROOT}/web/api/pending_variant_reviews.sh"
}

run_http() {
  local body_path="$1"
  curl -sS -o "${body_path}" -w '%{http_code}' \
    -H "Authorization: Bearer ${api_token}" \
    http://127.0.0.1/api/pending_variant_reviews.sh
}

time_to_file() {
  local metrics_path="$1" output_path="$2"
  shift 2
  local time_path="${TMP_DIR}/time" error_path="${TMP_DIR}/command-error"
  if { time "$@" >"${output_path}" 2>"${error_path}"; } 2>"${time_path}"; then
    cat "${time_path}" >>"${metrics_path}"
  else
    cat "${error_path}" >&2
    return 1
  fi
}

run_revision_stage() {
  sqlite3 -bail "${DB_PATH}" <<SQL >/dev/null
.timeout 5000
PRAGMA foreign_keys=ON;
PRAGMA query_only=ON;
${REVISION_SQL}
SELECT COUNT(*) FROM revision_projection;
SQL
}

extract_cgi_body() {
  awk 'body { print; next } /^$/ { body=1 }' "$1" >"$2"
}

assert_same_reviews() {
  local cli_path="$1" api_path="$2"
  jq -e '.actionable_count == (.reviews | length) and
    all(.reviews[]; .status == "pending")' "${cli_path}" >/dev/null || {
    echo 'CLI review response violates the pending queue contract' >&2
    return 1
  }
  jq -Sc '{success:true,actionable_count,reviews}' "${cli_path}" >"${TMP_DIR}/expected.json"
  jq -e 'type == "object" and keys == ["actionable_count", "reviews", "success"] and
    .success == true and .actionable_count == (.reviews | length) and
    all(.reviews[]; .status == "pending")' "${api_path}" >/dev/null || {
    echo 'API review response violates the pending queue contract' >&2
    return 1
  }
  jq -Sc '.' "${api_path}" >"${TMP_DIR}/actual.json"
  cmp -s "${TMP_DIR}/expected.json" "${TMP_DIR}/actual.json" || {
    echo 'CLI and API review payloads differ' >&2
    return 1
  }
}

p95_seconds() {
  local path="$1" count rank
  local -a sorted
  mapfile -t sorted < <(sort -n "${path}")
  count="${#sorted[@]}"
  rank=$(((count * 95 + 99) / 100))
  printf '%s\n' "${sorted[rank - 1]}"
}

summarize() {
  local label="$1" metrics_path="$2" bytes="$3" count p95 cpu
  count="$(wc -l <"${metrics_path}")"
  p95="$(p95_seconds "${metrics_path}")"
  cpu="$(awk '{u += $2; s += $3} END {if (NR) printf "%.3f", (u+s)/NR}' "${metrics_path}")"
  printf '%-7s n=%s p95=%ss avg_cpu=%ss bytes=%s\n' \
    "${label}" "${count}" "${p95}" "${cpu}" "${bytes}"
}

budget_failed=0
label=pending
cli_path="${TMP_DIR}/${label}.cli.json"
cgi_path="${TMP_DIR}/${label}.cgi.txt"
cgi_body="${TMP_DIR}/${label}.cgi.json"
http_path="${TMP_DIR}/${label}.http.json"
http_status_path="${TMP_DIR}/${label}.http-status"
stage_metrics="${TMP_DIR}/${label}.stage.metrics"
cli_metrics="${TMP_DIR}/${label}.cli.metrics"
validator_metrics="${TMP_DIR}/${label}.validator.metrics"
cgi_metrics="${TMP_DIR}/${label}.cgi.metrics"
http_metrics="${TMP_DIR}/${label}.http.metrics"
: >"${stage_metrics}"
: >"${cli_metrics}"
: >"${validator_metrics}"
: >"${cgi_metrics}"
: >"${http_metrics}"
cold_stage="${TMP_DIR}/${label}.cold-stage.metrics"
cold_cli="${TMP_DIR}/${label}.cold-cli.metrics"
cold_validator="${TMP_DIR}/${label}.cold-validator.metrics"
cold_cgi="${TMP_DIR}/${label}.cold-cgi.metrics"
cold_http="${TMP_DIR}/${label}.cold-http.metrics"

printf 'Acceptance gates: pending CLI and HTTP p95 <1000ms (regression ceiling %sms).\n' "${regression_ceiling_ms}"
time_to_file "${cold_stage}" "${TMP_DIR}/stage.count" run_revision_stage
time_to_file "${cold_cli}" "${cli_path}" run_cli
time_to_file "${cold_validator}" "${cgi_path}" run_cached_validator "${cli_path}"
extract_cgi_body "${cgi_path}" "${cgi_body}"
assert_same_reviews "${cli_path}" "${cgi_body}"
time_to_file "${cold_cgi}" "${cgi_path}" run_cgi
extract_cgi_body "${cgi_path}" "${cgi_body}"
time_to_file "${cold_http}" "${http_status_path}" run_http "${http_path}"
[[ "$(<"${http_status_path}")" == 200 ]] || {
  echo 'HTTP endpoint did not return 200' >&2
  exit 1
}
assert_same_reviews "${cli_path}" "${cgi_body}"
assert_same_reviews "${cli_path}" "${http_path}"
cli_bytes="$(wc -c <"${cli_path}")"
api_bytes="$(wc -c <"${http_path}")"
printf '%-7s first-run stage=%s cli=%s validator=%s cgi=%s http=%s cli_bytes=%s http_bytes=%s\n' \
  "${label}" "$(awk '{printf "%s/%s/%s",$1,$2,$3}' "${cold_stage}")" \
  "$(awk '{printf "%s/%s/%s",$1,$2,$3}' "${cold_cli}")" \
  "$(awk '{printf "%s/%s/%s",$1,$2,$3}' "${cold_validator}")" \
  "$(awk '{printf "%s/%s/%s",$1,$2,$3}' "${cold_cgi}")" \
  "$(awk '{printf "%s/%s/%s",$1,$2,$3}' "${cold_http}")" "${cli_bytes}" "${api_bytes}"

# Warm each entry point once, then collect the requested number of samples.
run_revision_stage >/dev/null
run_cli >"${cli_path}"
run_cached_validator "${cli_path}" >/dev/null
run_cgi >/dev/null
run_http "${TMP_DIR}/warm-http.json" >/dev/null

for ((sample = 0; sample < runs; sample++)); do
  time_to_file "${stage_metrics}" "${TMP_DIR}/stage.count" run_revision_stage
  time_to_file "${cli_metrics}" "${cli_path}" run_cli
  time_to_file "${validator_metrics}" "${cgi_path}" run_cached_validator "${cli_path}"
  extract_cgi_body "${cgi_path}" "${cgi_body}"
  assert_same_reviews "${cli_path}" "${cgi_body}"
  time_to_file "${cgi_metrics}" "${cgi_path}" run_cgi
  extract_cgi_body "${cgi_path}" "${cgi_body}"
  time_to_file "${http_metrics}" "${http_status_path}" run_http "${http_path}"
  [[ "$(<"${http_status_path}")" == 200 ]] || {
    echo "HTTP endpoint did not return 200 on sample ${sample}" >&2
    exit 1
  }
  assert_same_reviews "${cli_path}" "${cgi_body}"
  assert_same_reviews "${cli_path}" "${http_path}"
done

printf '%-7s ' "${label}"
summarize stage "${stage_metrics}" "n/a"
printf '%-7s ' ""
summarize cli "${cli_metrics}" "$(wc -c <"${cli_path}")"
printf '%-7s ' ""
summarize validator "${validator_metrics}" "$(wc -c <"${cgi_body}")"
printf '%-7s ' ""
summarize cgi "${cgi_metrics}" "$(wc -c <"${cgi_body}")"
printf '%-7s ' ""
summarize http "${http_metrics}" "$(wc -c <"${http_path}")"
for metric in cli http; do
  metric_path="${TMP_DIR}/${label}.${metric}.metrics"
  metric_p95="$(p95_seconds "${metric_path}")"
  metric_p95_ms="$(awk -v seconds="${metric_p95}" 'BEGIN { printf "%.0f", seconds*1000 }')"
  if ((metric_p95_ms >= 1000)); then
    echo "${label}: ${metric} p95 ${metric_p95_ms}ms exceeded the 1000ms acceptance target" >&2
    budget_failed=1
  fi
  if ((metric_p95_ms >= regression_ceiling_ms)); then
    echo "${label}: ${metric} p95 ${metric_p95_ms}ms exceeded ${regression_ceiling_ms}ms regression ceiling" >&2
    budget_failed=1
  fi
done

exit "${budget_failed}"
