#!/usr/bin/env bash
set -uo pipefail

TEST_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

passed=0
failed=0

fail() {
	printf '    %s\n' "$1" >&2
	return 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"

	[[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

assert_contains() {
	local haystack="$1"
	local needle="$2"

	[[ "${haystack}" == *"${needle}"* ]] || fail "expected output to contain '${needle}'"
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"

	[[ "${haystack}" != *"${needle}"* ]] || fail "expected output not to contain '${needle}'"
}

assert_not_exists() {
	local path="$1"

	[[ ! -e "${path}" ]] || fail "expected path not to exist: ${path}"
}

metrics_review_outcome_value() {
	local output="$1" review_type="$2" resolution="$3" line
	line="$(grep "^yomiko_variant_review_outcome_audit_records{review_type=\"${review_type}\",resolution=\"${resolution}\"} " <<<"${output}")" || return 1
	[[ "$(grep -c "^yomiko_variant_review_outcome_audit_records{review_type=\"${review_type}\",resolution=\"${resolution}\"} " <<<"${output}")" -eq 1 ]] || return 1
	printf '%s\n' "${line##* }"
}

assert_metrics_review_outcomes_match_lifecycle() {
	local output="$1" review_type resolution expected actual
	while IFS='|' read -r review_type resolution; do
		[[ -n "${review_type}" ]] || continue
		expected="$(db_query "SELECT COUNT(*)
			FROM variant_reviews AS review
			JOIN variant_review_product_lifecycle AS lifecycle
			  ON lifecycle.review_id=review.id
			WHERE review.review_type='${review_type}'
			  AND lifecycle.resolution='${resolution}'
			  AND lifecycle.projected_status='resolved';")" || return 1
		actual="$(metrics_review_outcome_value "${output}" "${review_type}" "${resolution}")" || return 1
		assert_eq "${expected}" "${actual}" || return 1
	done <<'EOF'
candidate_identity|same_book
candidate_identity|different_book
candidate_identity|superseded
winner|winner
winner|superseded
EOF
}

assert_success() {
	"$@" || fail "expected command to succeed: $*"
}

assert_failure() {
	if "$@"; then
		fail "expected command to fail: $*"
	fi
}

run_test() {
	local name="$1"
	shift
	if [[ -n "${YOMIKO_TEST_FILTER:-}" && "${name}" != *"${YOMIKO_TEST_FILTER}"* ]]; then
		return
	fi

	if ("$@"); then
		printf 'ok - %s\n' "${name}"
		passed=$((passed + 1))
	else
		printf 'not ok - %s\n' "${name}" >&2
		failed=$((failed + 1))
	fi
}

# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/db.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/metrics.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variants.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_unicode.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_policy.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_scoring.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_matching.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_discovery.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_worker.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_retention.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variant_actions.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/web/api/_middleware.sh"

# Keep the per-database writer gates inside the test sandbox. Production uses
# /tmp; this override prevents the suite from leaving test lock inodes behind.
DB_WRITER_LOCK_DIR="${TEST_TMPDIR}/writer-locks"

test_logging_without_api_mode() {
	unset YOMIKO_CLI_IN_API_MODE

	assert_eq 'hello' "$(log 'hello')" || return 1
	assert_eq 'ERROR: problem' "$(log_err 'problem' 2>&1)" || return 1
}

test_logging_in_api_mode() {
	export YOMIKO_CLI_IN_API_MODE=1

	assert_eq '' "$(log 'hello')" || return 1
	assert_eq '' "$(log_err 'problem' 2>&1)" || return 1
}

test_memory_limit_to_kb() {
	assert_eq '' "$(memory_limit_to_kb '')" || return 1
	assert_eq '1' "$(memory_limit_to_kb 1KiB)" || return 1
	assert_eq '1024' "$(memory_limit_to_kb 1MiB)" || return 1
	assert_eq '1048576' "$(memory_limit_to_kb 1GiB)" || return 1
	assert_failure memory_limit_to_kb 0MiB || return 1
	assert_failure memory_limit_to_kb unlimited || return 1
	assert_failure memory_limit_to_kb 1MB
}

test_db_parameter_text_encoding() {
	assert_eq '"CAST(X'\''4f275265696c6c79'\'' AS TEXT)"' "$(db_parameter_text "O'Reilly")" || return 1
	assert_eq '"CAST(X'\''5b226172746973743a74657374225d'\'' AS TEXT)"' \
		"$(db_parameter_text '["artist:test"]')" || return 1
	assert_eq '"CAST(X'\''615c6e62'\'' AS TEXT)"' "$(db_parameter_text 'a\nb')" || return 1
	assert_eq '"CAST(X'\'''\'' AS TEXT)"' "$(db_parameter_text '')"
}

test_db_parameter_text_round_trips_through_sqlite() {
	command -v sqlite3 >/dev/null || return 0

	local input=$'["artist:test","name:O'\''Reilly","path:a\\nb","文字"]\nsecond line'
	local expected_hex actual
	expected_hex="$(printf '%s' "${input}" | od -An -v -tx1 | tr -d '[:space:]')"
	DB_PATH="${TEST_TMPDIR}/parameter-round-trip.sqlite3"

	actual="$(db_query \
		".parameter set :value $(db_parameter_text "${input}")" \
		"SELECT lower(hex(:value)) || '|' || typeof(:value);")" || return 1

	assert_eq "${expected_hex}|text" "${actual}"
}

test_db_query_streams_large_payload_through_stdin() {
	local home_dir="${TEST_TMPDIR}/streaming-query-home"
	local sqlite3_args="${TEST_TMPDIR}/streaming-query-input"
	local payload query input

	mkdir -p "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/capture-sqlite3.sh" "${home_dir}/bin/sqlite3"
	local PATH="${home_dir}/bin:${PATH}"
	local DB_PATH="${TEST_TMPDIR}/streaming-query.sqlite3"
	payload=""
	printf -v payload '%*s' 263000 ''
	payload="${payload// /x}"
	query="SELECT length('${payload}');"

	SQLITE3_ARGS_PATH="${sqlite3_args}" \
		db_query "${query}" >/dev/null || return 1

	input="$(<"${sqlite3_args}")"
	assert_contains "${input}" '.timeout 5000' || return 1
	assert_contains "${input}" 'PRAGMA foreign_keys=ON;' || return 1
	assert_contains "${input}" 'PRAGMA query_only=ON;' || return 1
	assert_contains "${input}" "${query}" || return 1
	if [[ "$(sed -n '1p' "${sqlite3_args}")" == *"${query}"* ]]; then
		fail 'large db_query payload was passed as an sqlite3 argument'
		return 1
	fi

	SQLITE3_ARGS_PATH="${sqlite3_args}" \
		db_query_json "${query}" >/dev/null || return 1
	input="$(<"${sqlite3_args}")"
	assert_contains "${input}" '.timeout 5000' || return 1
	assert_contains "${input}" 'PRAGMA query_only=ON;' || return 1
	assert_contains "${input}" "${query}" || return 1

	SQLITE3_ARGS_PATH="${sqlite3_args}" \
		db_write "${query}" >/dev/null || return 1
	input="$(<"${sqlite3_args}")"
	assert_contains "${input}" '.timeout 5000' || return 1
	assert_contains "${input}" 'PRAGMA foreign_keys=ON;' || return 1
	assert_contains "${input}" "${query}"
}

test_db_writer_gate_lives_in_container_tmp() {
	command -v sqlite3 >/dev/null || return 0

	local db="${TEST_TMPDIR}/tmp-writer.sqlite3" lock_path
	(
		DB_WRITER_LOCK_DIR='/tmp'
		DB_PATH="${db}"
		db_write 'CREATE TABLE marker (value INTEGER);' >/dev/null || exit 1
		lock_path="$(db_writer_lock_path)" || exit 1
		[[ "${lock_path}" == /tmp/yomiko-sqlite-writer-*.writer.lock ]] || exit 1
		[[ "${lock_path}" != "${db}.writer.lock" ]] || exit 1
		[[ -e "${lock_path}" && ! -e "${db}.writer.lock" ]] || exit 1
		rm -f -- "${lock_path}"
	)
}

test_db_query_connections_enable_foreign_keys() {
	command -v sqlite3 >/dev/null || return 0

	local json
	DB_PATH="${TEST_TMPDIR}/foreign-keys.sqlite3"
	export DB_PATH

	db_write '
		CREATE TABLE parents (id INTEGER PRIMARY KEY);
		CREATE TABLE children (
			id INTEGER PRIMARY KEY,
			parent_id INTEGER NOT NULL REFERENCES parents(id)
		);
	' || return 1

	assert_eq '1' "$(db_query 'PRAGMA foreign_keys;')" || return 1
	json="$(db_query_json 'PRAGMA foreign_keys;')" || return 1
	if ! jq -e 'length == 1 and .[0].foreign_keys == 1' <<<"${json}" >/dev/null; then
		fail 'db_query_json did not enable foreign keys'
		return 1
	fi
	assert_failure db_query 'INSERT INTO children (id, parent_id) VALUES (1, 999);' \
		>/dev/null 2>&1 || return 1
	assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM children;')"
}

prepare_migration_test() {
	local name="$1"

	MIGRATION_TEST_ROOT="${TEST_TMPDIR}/migration-${name}"
	DB_PATH="${MIGRATION_TEST_ROOT}/data/db.sqlite3"
	MIGRATIONS_DIR="${MIGRATION_TEST_ROOT}/migrations"
	MOCK_SQLITE_STATE_DIR="${MIGRATION_TEST_ROOT}/state"
	MOCK_SQLITE_TRACE="${MIGRATION_TEST_ROOT}/sqlite.trace"
	PATH="${MIGRATION_TEST_ROOT}/bin:${PATH}"
	export DB_PATH MIGRATIONS_DIR MOCK_SQLITE_STATE_DIR MOCK_SQLITE_TRACE PATH
	mkdir -p "${MIGRATION_TEST_ROOT}/bin" "${MIGRATIONS_DIR}" "${MOCK_SQLITE_STATE_DIR}"
	ln -s "${TEST_ROOT}/tests/fixtures/migration-sqlite3.sh" "${MIGRATION_TEST_ROOT}/bin/sqlite3"
}

test_db_queries_preserve_sqlite_failures() {
	local status=0
	prepare_migration_test query-failure

	db_query 'MOCK_QUERY_FAILURE' >/dev/null 2>&1 || status=$?
	assert_eq '23' "${status}" || return 1

	status=0
	db_query_json 'MOCK_QUERY_FAILURE' >/dev/null 2>&1 || status=$?
	assert_eq '23' "${status}" || return 1

	status=0
	db_write 'MOCK_QUERY_FAILURE' >/dev/null 2>&1 || status=$?
	assert_eq '23' "${status}" || return 1
}

test_db_write_waits_for_direct_writer_and_readers_skip_gate() {
	command -v sqlite3 >/dev/null || return 0

	unset YOMIKO_CLI_IN_API_MODE
	local db="${TEST_TMPDIR}/direct-writer.sqlite3"
	local fifo="${db}.fifo" ready_path="${db}.ready"
	local holder_pid contender_pid holder_fd ready=0 status=0 reader
	DB_PATH="${db}"
	db_write 'PRAGMA journal_mode=WAL; CREATE TABLE counters (value INTEGER NOT NULL); INSERT INTO counters VALUES (0);' >/dev/null || return 1
	mkfifo "${fifo}"
	sqlite3 "${DB_PATH}" <"${fifo}" >/dev/null 2>&1 &
	holder_pid=$!
	exec {holder_fd}>"${fifo}"
	printf 'BEGIN IMMEDIATE; UPDATE counters SET value=value+10;\n.shell touch %s\n' "${ready_path}" >&"${holder_fd}"
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		if [[ -e "${ready_path}" ]]; then
			ready=1
			break
		fi
		sleep 0.01
	done
	if ((ready == 0)); then
		printf 'ROLLBACK;\n' >&"${holder_fd}" || true
		exec {holder_fd}>&-
		wait "${holder_pid}" || true
		fail 'direct SQLite writer did not acquire its transaction'
		return 1
	fi

	reader="$(db_query 'SELECT value FROM counters;')" || status=$?
	if [[ "${status}" -ne 0 || "${reader}" != 0 ]]; then
		printf 'ROLLBACK;\n' >&"${holder_fd}" || true
		exec {holder_fd}>&-
		wait "${holder_pid}" || true
		fail "WAL reader failed while the direct writer was active: ${reader}"
		return 1
	fi

	(
		YOMIKO_SQLITE_BUSY_TIMEOUT_MS=2000 db_write 'UPDATE counters SET value=value+1;'
	) >"${db}.contender-output" 2>"${db}.contender-error" &
	contender_pid=$!
	sleep 0.2
	printf 'COMMIT;\n' >&"${holder_fd}"
	exec {holder_fd}>&-
	status=0
	wait "${holder_pid}" || status=$?
	assert_eq '0' "${status}" || return 1
	status=0
	wait "${contender_pid}" || status=$?
	assert_eq '0' "${status}" || return 1
	assert_eq '11' "$(db_query 'SELECT value FROM counters;')" || return 1
	assert_not_contains "$(<"${db}.contender-error")" 'database is locked'
}

test_db_write_timeout_preserves_atomicity_and_reports_component() {
	command -v sqlite3 >/dev/null || return 0

	unset YOMIKO_CLI_IN_API_MODE
	local db="${TEST_TMPDIR}/direct-writer-timeout.sqlite3"
	local fifo="${db}.fifo" ready_path="${db}.ready"
	local holder_pid holder_fd ready=0 status=0 output
	DB_PATH="${db}"
	db_write 'PRAGMA journal_mode=WAL; CREATE TABLE counters (value INTEGER NOT NULL); INSERT INTO counters VALUES (0);' >/dev/null || return 1
	mkfifo "${fifo}"
	sqlite3 "${DB_PATH}" <"${fifo}" >/dev/null 2>&1 &
	holder_pid=$!
	exec {holder_fd}>"${fifo}"
	printf 'BEGIN IMMEDIATE; UPDATE counters SET value=value+100;\n.shell touch %s\n' "${ready_path}" >&"${holder_fd}"
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		if [[ -e "${ready_path}" ]]; then
			ready=1
			break
		fi
		sleep 0.01
	done
	if ((ready == 0)); then
		printf 'ROLLBACK;\n' >&"${holder_fd}" || true
		exec {holder_fd}>&-
		wait "${holder_pid}" || true
		fail 'direct SQLite writer did not acquire its transaction'
		return 1
	fi

	output="$(YOMIKO_SQLITE_BUSY_TIMEOUT_MS=100 YOMIKO_DB_COMPONENT=test \
		db_write 'UPDATE counters SET value=value+1;' 2>&1)" || status=$?
	printf 'COMMIT;\n' >&"${holder_fd}"
	exec {holder_fd}>&-
	local holder_status=0
	wait "${holder_pid}" || holder_status=$?
	assert_eq '0' "${holder_status}" || return 1
	assert_eq '1' "${status}" || return 1
	assert_contains "${output}" 'SQLite write failed for component test' || return 1
	assert_not_contains "${output}" 'UPDATE counters' || return 1
	assert_eq '100' "$(db_query 'SELECT value FROM counters;')"
}

test_db_writer_gate_serializes_writers_and_times_out_with_owner() {
	command -v sqlite3 >/dev/null || return 0

	unset YOMIKO_CLI_IN_API_MODE
	local db="${TEST_TMPDIR}/cooperating-writers.sqlite3"
	local lock_path owner_path
	local pids=() errors status=0
	DB_PATH="${db}"
	db_write 'CREATE TABLE counters (value INTEGER NOT NULL); INSERT INTO counters VALUES (0);' || return 1
	lock_path="$(db_writer_lock_path)" || return 1
	owner_path="${lock_path}.owner"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		(
			export YOMIKO_DB_COMPONENT=test
			db_write 'BEGIN IMMEDIATE; UPDATE counters SET value=value+1; COMMIT;'
		) >>"${db}.writer-output" 2>>"${db}.writer-error" &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		status=0
		wait "${pid}" || status=$?
		assert_eq '0' "${status}" || return 1
	done
	assert_eq '10' "$(db_query 'SELECT value FROM counters;')" || return 1
	errors="$(<"${db}.writer-error")"
	assert_not_contains "${errors}" 'database is locked' || return 1

	local lock_fd output
	exec {lock_fd}>>"${lock_path}"
	flock -n "${lock_fd}" || return 1
	printf 'component=variant_worker pid=999 started=2026-09-15T00:00:00Z\n' >"${owner_path}"
	status=0
	output="$(YOMIKO_DB_COMPONENT=test YOMIKO_DB_WRITER_GATE_TIMEOUT_MS=100 \
		db_write 'UPDATE counters SET value=value+1;' 2>&1)" || status=$?
	assert_eq '75' "${status}" || return 1
	assert_contains "${output}" 'component test' || return 1
	assert_contains "${output}" 'component=variant_worker pid=999' || return 1
	assert_not_contains "${output}" 'UPDATE counters' || return 1
	[[ -e "${lock_path}" && -e "${owner_path}" ]] || return 1
	exec {lock_fd}>&-
	rm -f -- "${owner_path}"
}

test_db_init_applies_atomic_migrations() {
	local output effects trace
	prepare_migration_test success
	printf '%s\n' \
		'-- MOCK_EFFECT: initial-schema' \
		'CREATE TABLE galleries (gid INTEGER PRIMARY KEY);' \
		>"${MIGRATIONS_DIR}/001_initial.sql"
	printf '%s\n' \
		'-- MOCK_EFFECT: add-feedback' \
		'ALTER TABLE galleries ADD COLUMN feedbacked_at TEXT;' \
		>"${MIGRATIONS_DIR}/002_feedback.sql"

	output="$(db_init)" || return 1
	effects="$(<"${MOCK_SQLITE_STATE_DIR}/effects")"
	trace="$(<"${MOCK_SQLITE_TRACE}")"

	assert_contains "${output}" 'Applying migration version 1: 001_initial.sql...' || return 1
	assert_contains "${output}" 'Applying migration version 2: 002_feedback.sql...' || return 1
	assert_eq '2' "$(<"${MOCK_SQLITE_STATE_DIR}/version")" || return 1
	assert_eq $'initial-schema\nadd-feedback' "${effects}" || return 1
	assert_contains "${trace}" 'BEGIN IMMEDIATE;' || return 1
	assert_contains "${trace}" 'PRAGMA foreign_keys=ON;' || return 1
	assert_contains "${trace}" 'INSERT OR IGNORE INTO _schema_version (version) VALUES (2);' || return 1
	assert_contains "${trace}" 'COMMIT;'
}

test_db_init_backs_up_before_each_pending_migration() {
	local backup_path output
	prepare_migration_test backup-success
	mkdir -p "$(dirname "${DB_PATH}")"
	: >"${DB_PATH}"
	printf '10\n' >"${MOCK_SQLITE_STATE_DIR}/version"
	printf '%s\n' \
		'-- MOCK_EFFECT: add-identity-pairs' \
		'CREATE TABLE gallery_identity_pairs (low_gid INTEGER, high_gid INTEGER);' \
		>"${MIGRATIONS_DIR}/011_gallery_identity_pairs.sql"
	backup_path="$(dirname "${DB_PATH}")/before-11.sqlite3"

	output="$(db_init)" || return 1

	assert_contains "${output}" "Backing up database before migration 11: ${backup_path}" || return 1
	assert_eq '10' "$(<"${backup_path}")" || return 1
	assert_eq '11' "$(<"${MOCK_SQLITE_STATE_DIR}/version")" || return 1
	assert_not_exists "${backup_path}.tmp.$$"
}

test_db_init_stops_when_migration_backup_fails() {
	local output status=0
	prepare_migration_test backup-failure
	mkdir -p "$(dirname "${DB_PATH}")"
	: >"${DB_PATH}"
	printf '10\n' >"${MOCK_SQLITE_STATE_DIR}/version"
	printf '%s\n' \
		'-- MOCK_EFFECT: must-not-commit' \
		'CREATE TABLE galleries (gid INTEGER PRIMARY KEY);' \
		>"${MIGRATIONS_DIR}/011_gallery_identity_pairs.sql"
	export MOCK_SQLITE_BACKUP_FAILURE=1

	output="$(db_init 2>&1)" || status=$?
	unset MOCK_SQLITE_BACKUP_FAILURE

	assert_eq '24' "${status}" || return 1
	assert_contains "${output}" 'Failed to back up database before migration 11.' || return 1
	assert_not_exists "$(dirname "${DB_PATH}")/before-11.sqlite3" || return 1
	assert_not_exists "$(dirname "${DB_PATH}")/before-11.sqlite3.tmp.$$" || return 1
	assert_eq '10' "$(<"${MOCK_SQLITE_STATE_DIR}/version")" || return 1
	assert_not_exists "${MOCK_SQLITE_STATE_DIR}/effects"
}

test_db_init_skips_migration_backups_for_new_database() {
	prepare_migration_test new-database
	printf '%s\n' \
		'-- MOCK_EFFECT: initial-schema' \
		'CREATE TABLE galleries (gid INTEGER PRIMARY KEY);' \
		>"${MIGRATIONS_DIR}/001_initial.sql"

	db_init >/dev/null || return 1

	assert_not_exists "$(dirname "${DB_PATH}")/before-1.sqlite3"
}

test_db_init_rolls_back_failed_migration() {
	local output status=0
	prepare_migration_test rollback
	printf '%s\n' \
		'-- MOCK_EFFECT: initial-schema' \
		'CREATE TABLE galleries (gid INTEGER PRIMARY KEY);' \
		>"${MIGRATIONS_DIR}/001_initial.sql"
	printf '%s\n' \
		'-- MOCK_EFFECT: must-not-commit' \
		'ALTER TABLE galleries ADD COLUMN feedbacked_at TEXT;' \
		'-- MOCK_MIGRATION_FAILURE' \
		>"${MIGRATIONS_DIR}/002_feedback.sql"

	output="$(db_init 2>&1)" || status=$?

	assert_eq '19' "${status}" || return 1
	assert_contains "${output}" 'Migration 002_feedback.sql failed; changes were rolled back.' || return 1
	assert_eq '1' "$(<"${MOCK_SQLITE_STATE_DIR}/version")" || return 1
	assert_eq 'initial-schema' "$(<"${MOCK_SQLITE_STATE_DIR}/effects")" || return 1

	printf '%s\n' \
		'-- MOCK_EFFECT: add-feedback' \
		'ALTER TABLE galleries ADD COLUMN feedbacked_at TEXT;' \
		>"${MIGRATIONS_DIR}/002_feedback.sql"
	db_init >/dev/null || return 1

	assert_eq '2' "$(<"${MOCK_SQLITE_STATE_DIR}/version")" || return 1
	assert_eq $'initial-schema\nadd-feedback' "$(<"${MOCK_SQLITE_STATE_DIR}/effects")"
}

test_db_init_suppresses_migration_logs_in_api_mode() {
	local output
	prepare_migration_test api-mode
	printf '%s\n' \
		'-- MOCK_EFFECT: initial-schema' \
		'CREATE TABLE galleries (gid INTEGER PRIMARY KEY);' \
		>"${MIGRATIONS_DIR}/001_initial.sql"
	export YOMIKO_CLI_IN_API_MODE=1

	output="$(db_init)" || return 1

	assert_eq '' "${output}" || return 1
	assert_eq '1' "$(<"${MOCK_SQLITE_STATE_DIR}/version")"
}

test_gallery_tag_validation_migration_allows_repair_only_to_valid_arrays() {
	command -v sqlite3 >/dev/null || return 0

	local migration_dir="${TEST_TMPDIR}/tag-validation-migrations"
	local output
	mkdir -p "${migration_dir}"
	cp "${TEST_ROOT}"/migrations/00[1-3]_*.sql "${migration_dir}/"
	DB_PATH="${TEST_TMPDIR}/tag-validation.sqlite3"
	MIGRATIONS_DIR="${migration_dir}"
	export DB_PATH MIGRATIONS_DIR

	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags) VALUES (1, 'token', 'title', NULL);" || return 1

	cp "${TEST_ROOT}/migrations/004_validate_gallery_tags.sql" "${migration_dir}/"
	output="$(db_init)" || return 1
	assert_contains "${output}" 'Applying migration version 4: 004_validate_gallery_tags.sql...' || return 1
	assert_eq '1' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE tags IS NULL;')" || return 1

	assert_failure db_write "UPDATE galleries SET tags = NULL WHERE gid = 1;" >/dev/null 2>&1 || return 1
	assert_failure db_write \
		".parameter set :tags $(db_parameter_text '{"artist":"test"}')" \
		"UPDATE galleries SET tags = :tags WHERE gid = 1;" >/dev/null 2>&1 || return 1

	db_write \
		".parameter set :tags $(db_parameter_text '["artist:test"]')" \
		"UPDATE galleries SET tags = :tags WHERE gid = 1;" || return 1
	assert_eq '["artist:test"]' "$(db_query 'SELECT tags FROM galleries WHERE gid = 1;')"
}

prepare_gallery_variant_migration_test() {
	local name="$1"

	VARIANT_MIGRATION_DIR="${TEST_TMPDIR}/variant-migrations-${name}"
	DB_PATH="${TEST_TMPDIR}/variant-migrations-${name}.sqlite3"
	MIGRATIONS_DIR="${VARIANT_MIGRATION_DIR}"
	export DB_PATH MIGRATIONS_DIR
	mkdir -p "${MIGRATIONS_DIR}"
}

assert_gallery_variant_schema() {
	local expected_discovery_tables="${1:-1}" expected_canonical_decisions="${2:-1}" expected_category="${3:-1}" metadata_columns variant_tables
	metadata_columns="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('category', 'uploader', 'posted', 'filesize', 'thumb', 'first_gid', 'first_key', 'parent_gid', 'parent_key', 'current_gid', 'current_key') ORDER BY cid);")" || return 1
variant_tables="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'table' AND name IN ('gallery_identity_pairs', 'variant_policy_revisions', 'variant_groups', 'gallery_variants', 'variant_evaluations', 'variant_jobs', 'variant_actions', 'variant_reviews', 'variant_canonical_decisions', 'variant_discovery_runs', 'variant_discovery_candidates') ORDER BY name);")" || return 1

	if [[ "${expected_category}" -eq 1 ]]; then
		assert_eq 'category,uploader,posted,filesize,thumb,first_gid,first_key,parent_gid,parent_key,current_gid,current_key' "${metadata_columns}" || return 1
	else
		assert_eq 'uploader,posted,filesize,thumb,first_gid,first_key,parent_gid,parent_key,current_gid,current_key' "${metadata_columns}" || return 1
	fi
	if [[ "${expected_discovery_tables}" -eq 1 ]]; then
		if [[ "${expected_canonical_decisions}" -eq 1 ]]; then
			assert_eq 'gallery_identity_pairs,gallery_variants,variant_actions,variant_canonical_decisions,variant_discovery_candidates,variant_discovery_runs,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
		else
			assert_eq 'gallery_identity_pairs,gallery_variants,variant_actions,variant_discovery_candidates,variant_discovery_runs,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
		fi
	else
		if [[ "${expected_canonical_decisions}" -eq 1 ]]; then
			assert_eq 'gallery_variants,variant_actions,variant_canonical_decisions,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
		else
			assert_eq 'gallery_variants,variant_actions,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
		fi
	fi
}

assert_gallery_revision_traversal_indexes() {
	assert_eq '1' "$(db_query "SELECT partial FROM pragma_index_list('galleries') WHERE name='idx_galleries_parent_gid';")" || return 1
	assert_eq '1' "$(db_query "SELECT partial FROM pragma_index_list('galleries') WHERE name='idx_galleries_current_gid';")" || return 1
	assert_eq '0|parent_gid|1' "$(db_query "SELECT seqno || '|' || name || '|' || key FROM pragma_index_xinfo('idx_galleries_parent_gid') WHERE key=1;")" || return 1
	assert_eq '0|current_gid|1' "$(db_query "SELECT seqno || '|' || name || '|' || key FROM pragma_index_xinfo('idx_galleries_current_gid') WHERE key=1;")" || return 1
}

test_gallery_variant_migration_upgrades_schema_004() {
	command -v sqlite3 >/dev/null || return 0

	local output
	prepare_gallery_variant_migration_test upgrade
	cp "${TEST_ROOT}"/migrations/00[1-4]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, self_rating) VALUES (123, 'token', 'title', '[]', 8);" || return 1

	cp "${TEST_ROOT}/migrations/005_gallery_variants.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init)" || return 1

	assert_contains "${output}" 'Applying migration version 5: 005_gallery_variants.sql...' || return 1
	assert_eq '5' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '123|token|title|8' "$(db_query 'SELECT gid, token, title, self_rating FROM galleries WHERE gid = 123;')" || return 1
	assert_gallery_variant_schema 0 0
}

test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants() {
	command -v sqlite3 >/dev/null || return 0

	local policy_json expected_content_hash expected_matching_hash expected_scoring_hash expected_operations_hash
	prepare_gallery_variant_migration_test fresh
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1

	assert_eq '30' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_revision_traversal_indexes || return 1
	assert_eq '3' "$(db_query 'SELECT COUNT(*) FROM runtime_component_state;')" || return 1
	assert_eq '30' "$(db_query 'SELECT COUNT(*) FROM variant_job_outcome_counters;')" || return 1
	assert_eq '0' "$(db_query 'SELECT COALESCE(SUM(value),0) FROM variant_job_outcome_counters;')" || return 1
	assert_eq 'uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,current_gid,current_token' "$(db_query "SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('uploader', 'posted', 'filesize', 'thumb', 'first_gid', 'first_token', 'parent_gid', 'parent_token', 'current_gid', 'current_token') ORDER BY cid);")" || return 1
	assert_eq 'variant_job_diagnostics' "$(db_query "SELECT name FROM sqlite_schema WHERE type='view' AND name='variant_job_diagnostics';")" || return 1
	assert_eq '7' "$(db_query "SELECT COUNT(*) FROM sqlite_schema WHERE type='view' AND name LIKE 'variant_identity_%';")" || return 1
	assert_eq 'review_id|projected_status|resolution' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM pragma_table_info('variant_review_product_lifecycle') ORDER BY cid);")" || return 1
	policy_json="$(db_query 'SELECT policy_json FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	expected_content_hash="$(variants_policy_sha256 "${policy_json}")" || return 1
	expected_matching_hash="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${policy_json}")")" || return 1
	expected_scoring_hash="$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"${policy_json}")")" || return 1
	expected_operations_hash="$(variants_policy_sha256 "$(jq -cS '.operations' <<<"${policy_json}")")" || return 1
	assert_eq "8|1|64|64|64|64" "$(db_query 'SELECT (SELECT COUNT(*) FROM variant_policy_revisions), SUM(is_active), length(content_hash), length(matching_hash), length(scoring_hash), length(operations_hash) FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	assert_eq "${expected_content_hash}|${expected_matching_hash}|${expected_scoring_hash}|${expected_operations_hash}" \
		"$(db_query 'SELECT content_hash, matching_hash, scoring_hash, operations_hash FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	assert_eq 'Manga|1019|language:chinese|other:tankoubon|500|-500|500|400|400|-2000|100|70|365|25' "$(jq -r '[.matching.required_category, .matching.search.category_exclusion_mask, .matching.required_scope_tags[0], .matching.required_scope_tags[1], .scoring.tag_scores["other:full color"], .scoring.tag_scores["other:incomplete"], .scoring.tag_scores["other:uncensored"], .scoring.favorite_popularity.cap, .scoring.rating_confidence.cap, .scoring.expunged_adjustment, .scoring.page_count.cap, .scoring.page_count.offset, .operations.annual_rediscovery_days, .operations.gdata_batch_size] | join("|")' <<<"${policy_json}")" || return 1
	assert_eq '1' "$(jq -r '.format_version' <<<"${policy_json}")" || return 1
	assert_eq '0' "$(db_query "SELECT is_active FROM variant_policy_revisions WHERE id = (SELECT MIN(id) FROM variant_policy_revisions WHERE is_active = 0);")" || return 1
	assert_eq 'true' "$(jq -r '(.matching | (has("official_chain_visibility") | not) and (.visible_contradictions | length >= 8))' <<<"${policy_json}")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM pragma_table_info('gallery_variants') WHERE name='metadata_snapshot_json';")" || return 1
	assert_eq 'archive_source_galleries|current_revision_projection|scoreable_revision_terminals' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM sqlite_schema WHERE type='view' AND name IN ('archive_source_galleries','scoreable_revision_terminals','current_revision_projection') ORDER BY name);")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM sqlite_schema WHERE type='view' AND name IN ('available_galleries','eligible_galleries','uploader_revision_representatives','uploader_revision_members');")" || return 1
	assert_eq '7' "$(db_query "SELECT COUNT(*) FROM sqlite_schema WHERE type='view' AND name LIKE 'variant_identity_%';")" || return 1
	assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM revision_members;')" || return 1
	assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM scoreable_revision_terminals;')" || return 1
	assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM archive_source_galleries;')" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep';")" || return 1
	assert_eq 'favorite_count|rating_count|popularity_fetched_at' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('favorite_count','rating_count','popularity_fetched_at') ORDER BY cid);")" || return 1
	assert_eq 'target_policy_revision_id' "$(db_query "SELECT name FROM pragma_table_info('variant_jobs') WHERE name='target_policy_revision_id';")" || return 1
	assert_eq 'expected_evaluation_id' "$(db_query "SELECT name FROM pragma_table_info('variant_jobs') WHERE name='expected_evaluation_id';")" || return 1
	assert_eq 'lease_owner|lease_expires_at|lease_job_id|last_error_class' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM pragma_table_info('variant_actions') WHERE name IN ('lease_owner','lease_expires_at','lease_job_id','last_error_class') ORDER BY cid);")" || return 1
	assert_eq 'superseded_at' "$(db_query "SELECT name FROM pragma_table_info('variant_reviews') WHERE name='superseded_at';")" || return 1
	assert_eq 'hath_last_attempted_at' "$(db_query "SELECT name FROM pragma_table_info('galleries') WHERE name='hath_last_attempted_at';")" || return 1
	assert_failure db_write 'UPDATE variant_policy_revisions SET scoring_hash = lower(hex(randomblob(32))) WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	assert_failure db_write 'DELETE FROM variant_policy_revisions WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	db_write "INSERT INTO variant_policy_revisions (policy_json, content_hash, matching_hash, scoring_hash, operations_hash) SELECT policy_json, printf('%064d', 2), printf('%064d', 3), printf('%064d', 4), printf('%064d', 5) FROM variant_policy_revisions WHERE is_active = 1;" || return 1
	assert_failure db_write "UPDATE variant_policy_revisions SET is_active = 1, activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE content_hash = printf('%064d', 2);" >/dev/null 2>&1 || return 1

	db_write "INSERT INTO galleries (gid, token, title, tags) VALUES (1, 'one', 'one', '[]'), (2, 'two', 'two', '[]');" || return 1
	assert_failure db_write 'UPDATE galleries SET favorite_count = -1 WHERE gid = 1;' >/dev/null 2>&1 || return 1
	assert_failure db_write 'UPDATE galleries SET rating_count = -1 WHERE gid = 1;' >/dev/null 2>&1 || return 1
	db_write 'INSERT INTO variant_groups (id, source_gid, desired_rating) VALUES (1, 1, 8), (2, 2, 8);' || return 1
	assert_eq '1' "$(db_query 'PRAGMA foreign_keys;')" || return 1
	assert_failure db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES (1, 999, 'confirmed', 'automatic', '{}');" >/dev/null 2>&1 || return 1
	db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES (1, 1, 'confirmed', 'automatic', '{}');" || return 1
	assert_failure db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES (2, 1, 'confirmed', 'automatic', '{}');" >/dev/null 2>&1 || return 1

	db_write "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" || return 1
	assert_failure db_write "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" >/dev/null 2>&1 || return 1
	db_write "UPDATE variant_jobs SET status = 'completed', completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE group_id = 1 AND job_type = 'discover';" || return 1
	db_write "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" || return 1
	assert_eq '2' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE group_id = 1 AND job_type = 'discover';")" || return 1
	db_write "INSERT INTO variant_jobs (job_type) VALUES ('policy_scoring_sweep');" || return 1
	assert_failure db_write "INSERT INTO variant_jobs (job_type) VALUES ('policy_scoring_sweep');" >/dev/null 2>&1 || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')"
}

test_revision_traversal_indexes_migrate_from_schema_029() {
	command -v sqlite3 >/dev/null || return 0

	local migration output
	prepare_gallery_variant_migration_test revision-traversal-indexes
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	assert_eq '29' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1

	cp "${TEST_ROOT}/migrations/030_revision_traversal_indexes.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init)" || return 1
	assert_contains "${output}" 'Applying migration version 30: 030_revision_traversal_indexes.sql...' || return 1
	assert_eq '30' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_revision_traversal_indexes || return 1

	db_init >/dev/null || return 1
	assert_eq '30' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_revision_traversal_indexes
}

test_discovery_revision_archive_vocabulary_migration_replaces_schema_27_views() {
	command -v sqlite3 >/dev/null || return 0

	local migration output
	prepare_gallery_variant_migration_test discovery-revision-archive-vocabulary
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	assert_eq '27' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq 'available_galleries|eligible_galleries|uploader_revision_members|uploader_revision_representatives' \
		"$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM sqlite_schema WHERE type='view' AND name IN ('available_galleries','eligible_galleries','uploader_revision_members','uploader_revision_representatives') ORDER BY name);")" || return 1

	db_write "INSERT INTO galleries(
		gid,token,title,file_count,tags,rating,favorite_count,rating_count,file_path,
		current_gid,current_token)
	VALUES
		(101,'token-101','Singleton',12,'[\"language:chinese\",\"other:tankoubon\"]',4.0,3,4,NULL,NULL,NULL),
		(102,'token-102','Predecessor',12,'[\"language:chinese\",\"other:tankoubon\"]',4.0,3,4,'/archives/102.7z',103,'token-103');
	INSERT INTO galleries(
		gid,token,title,file_count,tags,rating,favorite_count,rating_count,parent_gid,parent_token)
	VALUES (103,'token-103','Replacement',13,'[\"language:chinese\",\"other:tankoubon\"]',4.5,5,6,102,'token-102');" || return 1

	cp "${TEST_ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || return 1
	assert_contains "${output}" 'Applying migration version 28: 028_discovery_revision_archive_vocabulary.sql...' || return 1
	assert_eq '28' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq 'archive_source_galleries|current_revision_projection|revision_members|scoreable_revision_terminals' \
		"$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM sqlite_schema WHERE type='view' AND name IN ('archive_source_galleries','current_revision_projection','revision_members','scoreable_revision_terminals') ORDER BY name);")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM sqlite_schema WHERE type='view' AND name IN ('available_galleries','eligible_galleries','uploader_revision_members','uploader_revision_representatives');")" || return 1
	assert_eq '7' "$(db_query "SELECT COUNT(*) FROM sqlite_schema WHERE type='view' AND name LIKE 'variant_identity_%';")" || return 1
	assert_eq '101|101|1|1
102|103|1|0
103|103|1|1' "$(db_query "SELECT revision_gid||'|'||gid||'|'||ready||'|'||is_terminal FROM current_revision_projection ORDER BY revision_gid;")" || return 1
	assert_eq '101|NULL|0|0
103|102|0|1' "$(db_query "SELECT gid||'|'||COALESCE(archive_gid,'NULL')||'|'||is_effective||'|'||archive_rank FROM archive_source_galleries ORDER BY gid;")" || return 1

	# Committing the target archive switches the source mapping atomically from
	# the replaced fallback GID to the scoreable terminal GID.
	db_write "UPDATE galleries SET file_path='/archives/103.7z' WHERE gid=103;" || return 1
	assert_eq '103|103|1|1' "$(db_query "SELECT gid||'|'||archive_gid||'|'||is_effective||'|'||archive_rank FROM archive_source_galleries WHERE gid=103;")" || return 1
}

test_discovery_revision_archive_policy_migration_retargets_and_recovers_hashes() {
	command -v sqlite3 >/dev/null || return 0

	local migration old_id inactive_id new_id old_policy old_hashes output before_hashes
	prepare_gallery_variant_migration_test policy-028-queued
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	old_id="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	inactive_id="$(db_query "SELECT id FROM variant_policy_revisions WHERE is_active=0 AND id<>${old_id} ORDER BY id LIMIT 1;")" || return 1
	old_policy="$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${old_id};")" || return 1
	old_hashes="$(db_query "SELECT content_hash||'|'||matching_hash||'|'||scoring_hash||'|'||operations_hash FROM variant_policy_revisions WHERE id=${old_id};")" || return 1
	db_write "
		INSERT INTO galleries(gid,token,title,tags) VALUES(1,'token-1','Source','[]');
		INSERT INTO variant_groups(id,source_gid,desired_rating) VALUES(1,1,8);
		INSERT INTO variant_actions(
			id,group_id,gid,action_type,desired_value,policy_revision_id,status)
		VALUES(1,1,1,'rating','8',${old_id},'pending');
		INSERT INTO variant_jobs(
			id,job_type,target_policy_revision_id,status,continuation_cursor_json)
		VALUES(100,'policy_scoring_sweep',${old_id},'queued','{\"offset\":4}');
		INSERT INTO variant_jobs(
			id,job_type,target_policy_revision_id,status,completed_at)
		VALUES(101,'policy_scoring_sweep',${inactive_id},'completed','2026-09-20T00:00:00Z');
		INSERT INTO variant_jobs(
			id,job_type,group_id,source_gid,status,lease_owner,lease_expires_at)
		VALUES(102,'discover',1,1,'leased','discovery-worker','2099-01-01T00:00:00Z');
		INSERT INTO variant_discovery_runs(
			id,group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
		VALUES(1,1,102,1,'publish','running','discovery-worker','2099-01-01T00:00:00Z');" || return 1

	cp "${TEST_ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || return 1
	assert_contains "${output}" 'Applying migration version 28: 028_discovery_revision_archive_vocabulary.sql...' || return 1
	assert_eq '1' "$(db_query 'SELECT SUM(is_active) FROM variant_policy_revisions;')" || return 1
	new_id="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	[[ "${new_id}" != "${old_id}" ]] || return 1
	assert_eq "${old_policy}|${old_hashes}" "$(db_query "SELECT policy_json,content_hash||'|'||matching_hash||'|'||scoring_hash||'|'||operations_hash FROM variant_policy_revisions WHERE id=${old_id};")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_policy_revisions WHERE id=${old_id} AND is_active=1;")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_policy_revisions WHERE is_active=1 AND (json_type(policy_json,'$.matching.official_chain_visibility') IS NOT NULL OR json_extract(policy_json,'$.matching.automatic_evidence_kinds') LIKE '%official_chain%');")" || return 1
	assert_eq "${new_id}|queued||||" "$(db_query "SELECT target_policy_revision_id,status,COALESCE(lease_owner,''),COALESCE(lease_expires_at,''),COALESCE(continuation_cursor_json,''),COALESCE(last_error_class,'') FROM variant_jobs WHERE id=100;")" || return 1
	assert_eq "${inactive_id}|completed|2026-09-20T00:00:00Z" "$(db_query "SELECT target_policy_revision_id,status,completed_at FROM variant_jobs WHERE id=101;")" || return 1
	assert_eq 'running|discovery-worker' "$(db_query "SELECT status,lease_owner FROM variant_discovery_runs WHERE id=1;")" || return 1
	assert_eq "${old_id}" "$(db_query 'SELECT policy_revision_id FROM variant_actions WHERE id=1;')" || return 1

	assert_eq "$(variants_policy_sha256 "$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")|$(variants_policy_sha256 "$(jq -cS '.matching' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")|$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")|$(variants_policy_sha256 "$(jq -cS '.operations' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")" "$(db_query "SELECT content_hash||'|'||matching_hash||'|'||scoring_hash||'|'||operations_hash FROM variant_policy_revisions WHERE id=${new_id};")" || return 1

	# Simulate a schema-28 startup whose active hashes were left as placeholders.
	db_write "DROP TRIGGER variant_policy_revisions_immutable_content;
		UPDATE variant_policy_revisions
		   SET content_hash=printf('%064d',id), matching_hash=printf('%064d',id),
		       scoring_hash=printf('%064d',id), operations_hash=printf('%064d',id)
		 WHERE is_active=1;
		CREATE TRIGGER variant_policy_revisions_immutable_content
		BEFORE UPDATE OF policy_json,content_hash,matching_hash,scoring_hash,operations_hash,created_at ON variant_policy_revisions
		BEGIN SELECT RAISE(ABORT,'variant policy revision content is immutable'); END;" || return 1
	db_init >/dev/null || return 1
	before_hashes="$(db_query "SELECT content_hash||'|'||matching_hash||'|'||scoring_hash||'|'||operations_hash FROM variant_policy_revisions WHERE id=${new_id};")" || return 1
	assert_eq "$(variants_policy_sha256 "$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")|$(variants_policy_sha256 "$(jq -cS '.matching' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")|$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")|$(variants_policy_sha256 "$(jq -cS '.operations' <<<"$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${new_id};")")")" "${before_hashes}" || return 1
	db_init >/dev/null || return 1
	assert_eq "${before_hashes}" "$(db_query "SELECT content_hash||'|'||matching_hash||'|'||scoring_hash||'|'||operations_hash FROM variant_policy_revisions WHERE id=${new_id};")" || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1

	prepare_gallery_variant_migration_test policy-028-leased
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	old_id="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	db_write "INSERT INTO variant_jobs(
		id,job_type,target_policy_revision_id,status,continuation_cursor_json,
		lease_owner,lease_expires_at)
		VALUES(100,'policy_scoring_sweep',${old_id},'leased','{\"offset\":4}',
			'policy-worker','2099-01-01T00:00:00Z');" || return 1
	cp "${TEST_ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	new_id="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	assert_eq "${new_id}|queued|||uncertain|policy revision changed" "$(db_query "SELECT target_policy_revision_id,status,COALESCE(lease_owner,''),COALESCE(continuation_cursor_json,''),COALESCE(last_error_class,''),COALESCE(last_error,'') FROM variant_jobs WHERE id=100;")" || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1
}

test_revision_evidence_vocabulary_migration_rewrites_persisted_json() {
	command -v sqlite3 >/dev/null || return 0

	local migration output status=0 old_count
	prepare_gallery_variant_migration_test revision-evidence-vocabulary
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	cp "${TEST_ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "
		INSERT INTO galleries(gid,token,title,tags)
		VALUES(1,'token-1','Source','[]'),(2,'token-2','Candidate','[]');
		INSERT INTO variant_groups(id,source_gid,desired_rating)
		VALUES(1,1,8);
		INSERT INTO gallery_variants(
			group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(1,1,'confirmed','automatic',
			'{\"eligible\":true,\"uploader_revision\":{\"candidate_eligible\":false},\"keep\":{\"value\":7,\"eligible\":\"business\"},\"latest_discovery\":{\"eligible\":false,\"uploader_revision\":{\"candidate_eligible\":true}}}');
		INSERT INTO variant_jobs(id,job_type,group_id,source_gid,status,completed_at)
		VALUES(1,'discover',1,1,'completed','2026-09-21T00:00:00Z');
		INSERT INTO variant_discovery_runs(
			id,group_id,job_id,matching_revision,phase,status,completed_at)
		VALUES(1,1,1,1,'publish','completed','2026-09-21T00:00:00Z');
		INSERT INTO variant_discovery_candidates(
			run_id,gid,token,matching_revision,evidence_json,state)
		VALUES(1,2,'token-2',1,
			'{\"eligible\":false,\"uploader_revision\":{\"candidate_eligible\":true}}',
			'complete');
		INSERT INTO variant_evaluations(
			id,group_id,policy_revision_id,state,metadata_snapshot_json,
			member_scores_json,canonical_gid)
		VALUES(1,1,(SELECT id FROM variant_policy_revisions WHERE is_active=1),
			'completed',
			'[{\"gid\":1,\"evidence\":{\"eligible\":true,\"uploader_revision\":{\"candidate_eligible\":false}},\"keep\":\"metadata\"}]',
			'[{\"gid\":1,\"score\":4,\"evidence\":{\"eligible\":false,\"uploader_revision\":{\"candidate_eligible\":true}}}]',1);
		INSERT INTO variant_reviews(
			review_type,group_id,evaluation_id,policy_revision_id,evidence_json,
			choices_json,status)
		VALUES('winner',1,1,
			(SELECT id FROM variant_policy_revisions WHERE is_active=1),
			'{\"eligible\":true,\"uploader_revision\":{\"candidate_eligible\":false}}',
			'[1]','pending');" || return 1

	cp "${TEST_ROOT}/migrations/029_revision_evidence_vocabulary.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || return 1
	assert_contains "${output}" 'Applying migration version 29: 029_revision_evidence_vocabulary.sql...' || return 1
	assert_eq '29' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '1|0|0|1|7|business' "$(db_query "SELECT
		json_extract(evidence_json,'$.is_revision_terminal'),
		json_extract(evidence_json,'$.uploader_revision.candidate_is_revision_terminal'),
		json_extract(evidence_json,'$.latest_discovery.is_revision_terminal'),
		json_extract(evidence_json,'$.latest_discovery.uploader_revision.candidate_is_revision_terminal'),
		json_extract(evidence_json,'$.keep.value'),
		json_extract(evidence_json,'$.keep.eligible')
		FROM gallery_variants WHERE group_id=1 AND gid=1;")" || return 1
	assert_eq '0|1' "$(db_query "SELECT
		json_extract(evidence_json,'$.is_revision_terminal'),
		json_extract(evidence_json,'$.uploader_revision.candidate_is_revision_terminal')
		FROM variant_discovery_candidates WHERE run_id=1 AND gid=2;")" || return 1
	assert_eq '1|0' "$(db_query "SELECT
		json_extract(evidence_json,'$.is_revision_terminal'),
		json_extract(evidence_json,'$.uploader_revision.candidate_is_revision_terminal')
		FROM variant_reviews WHERE id=1;")" || return 1
	assert_eq '1|0|metadata|0|1|4' "$(db_query "SELECT
		json_extract(metadata_snapshot_json,'\$[0].evidence.is_revision_terminal'),
		json_extract(metadata_snapshot_json,'\$[0].evidence.uploader_revision.candidate_is_revision_terminal'),
		json_extract(metadata_snapshot_json,'\$[0].keep'),
		json_extract(member_scores_json,'\$[0].evidence.is_revision_terminal'),
		json_extract(member_scores_json,'\$[0].evidence.uploader_revision.candidate_is_revision_terminal'),
		json_extract(member_scores_json,'\$[0].score')
		FROM variant_evaluations WHERE id=1;")" || return 1
	old_count="$(db_query "SELECT
		(SELECT COUNT(*) FROM gallery_variants WHERE json_type(evidence_json,'$.eligible') IS NOT NULL OR json_type(evidence_json,'$.uploader_revision.candidate_eligible') IS NOT NULL OR json_type(evidence_json,'$.latest_discovery.eligible') IS NOT NULL OR json_type(evidence_json,'$.latest_discovery.uploader_revision.candidate_eligible') IS NOT NULL)+
		(SELECT COUNT(*) FROM variant_discovery_candidates WHERE json_type(evidence_json,'$.eligible') IS NOT NULL OR json_type(evidence_json,'$.uploader_revision.candidate_eligible') IS NOT NULL)+
		(SELECT COUNT(*) FROM variant_reviews WHERE json_type(evidence_json,'$.eligible') IS NOT NULL OR json_type(evidence_json,'$.uploader_revision.candidate_eligible') IS NOT NULL)+
		(SELECT COUNT(*) FROM variant_evaluations AS evaluation JOIN json_each(evaluation.metadata_snapshot_json) AS item ON 1=1 WHERE json_type(item.value,'$.eligible') IS NOT NULL OR json_type(item.value,'$.uploader_revision.candidate_eligible') IS NOT NULL OR json_type(item.value,'$.evidence.eligible') IS NOT NULL OR json_type(item.value,'$.evidence.uploader_revision.candidate_eligible') IS NOT NULL)+
		(SELECT COUNT(*) FROM variant_evaluations AS evaluation JOIN json_each(evaluation.member_scores_json) AS item ON 1=1 WHERE json_type(item.value,'$.eligible') IS NOT NULL OR json_type(item.value,'$.uploader_revision.candidate_eligible') IS NOT NULL OR json_type(item.value,'$.evidence.eligible') IS NOT NULL OR json_type(item.value,'$.evidence.uploader_revision.candidate_eligible') IS NOT NULL);")" || return 1
	assert_eq '0' "${old_count}" || return 1
	assert_failure db_write "UPDATE variant_evaluations SET member_scores_json='[]' WHERE id=1;" >/dev/null 2>&1 || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1

	prepare_gallery_variant_migration_test revision-evidence-conflict
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	cp "${TEST_ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "
		INSERT INTO galleries(gid,token,title,tags) VALUES(1,'token-1','Source','[]');
		INSERT INTO variant_groups(id,source_gid,desired_rating) VALUES(1,1,8);
		INSERT INTO gallery_variants(
			group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(1,1,'confirmed','automatic',
			'{\"eligible\":true,\"is_revision_terminal\":false}');" || return 1
	cp "${TEST_ROOT}/migrations/029_revision_evidence_vocabulary.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || status=$?
	((status != 0)) || return 1
	assert_contains "${output}" 'migration 029 found conflicting legacy and canonical evidence names' || return 1
	assert_eq '28' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '1|0' "$(db_query "SELECT json_extract(evidence_json,'$.eligible'),json_extract(evidence_json,'$.is_revision_terminal') FROM gallery_variants;")" || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1
}

test_variant_review_product_lifecycle_projects_terminal_outcomes() {
	command -v sqlite3 >/dev/null || return 0

	local output list_output reviews_output before after
	prepare_variant_runtime_test review-product-lifecycle || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,file_count,favorite_count,rating_count) VALUES
		(2,'token-2','Candidate 2','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(3,'token-3','Candidate 3','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(4,'token-4','Candidate 4','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(5,'token-5','Candidate 5','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(106,'token-106','Winner 106','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(107,'token-107','Winner 107','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(108,'token-108','Winner 108','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(109,'token-109','Winner 109','[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
	UPDATE galleries SET tags='[\"language:chinese\",\"other:tankoubon\"]',
		file_count=10,favorite_count=1,rating_count=1 WHERE gid=101;
	INSERT INTO variant_groups(id,source_gid,desired_rating,is_active,review_state)
		VALUES(1,101,11,1,'none'),(2,106,11,1,'none'),(3,107,11,1,'none'),
		      (4,108,11,1,'none'),(5,109,11,1,'none');
	INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(2,106,'confirmed','automatic','{}'),
		      (3,107,'confirmed','automatic','{}'),
		      (4,108,'confirmed','automatic','{}'),
		      (5,109,'confirmed','automatic','{}');
	INSERT INTO variant_evaluations(id,group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,canonical_gid)
		VALUES(2,2,1,'completed','[]','[]',106),
		      (3,3,1,'completed','[]','[]',107),
		      (4,4,1,'completed','[]','[]',108),
		      (5,5,1,'completed','[]','[]',109);
	INSERT INTO variant_reviews(
		id,review_type,group_id,candidate_gid,evaluation_id,policy_revision_id,
		matching_revision,evidence_json,choices_json,status,decision,canonical_gid,
		resolved_at,superseded_at)
		VALUES
			(101,'candidate_identity',1,2,NULL,1,${VARIANTS_MATCHING_REVISION},'{}','[101,2]','pending',NULL,NULL,NULL,NULL),
			(102,'candidate_identity',1,3,NULL,1,${VARIANTS_MATCHING_REVISION},'{}','[101,3]','pending',NULL,NULL,NULL,'2026-09-17T00:00:00Z'),
			(103,'candidate_identity',1,4,NULL,1,${VARIANTS_MATCHING_REVISION},'{}','[101,4]','resolved','same_book',NULL,'2026-09-17T00:00:00Z',NULL),
			(104,'candidate_identity',1,5,NULL,1,${VARIANTS_MATCHING_REVISION},'{}','[101,5]','resolved','different_book',NULL,'2026-09-17T00:00:00Z',NULL),
			(201,'winner',2,NULL,2,1,NULL,'{}','[106]','pending',NULL,NULL,NULL,NULL),
			(202,'winner',3,NULL,3,1,NULL,'{}','[107]','pending',NULL,NULL,NULL,'2026-09-17T00:00:00Z'),
			(203,'winner',4,NULL,4,1,NULL,'{}','[108]','resolved','winner',108,'2026-09-17T00:00:00Z',NULL),
			(204,'winner',5,NULL,5,1,NULL,'{}','[109]','resolved','winner',109,'2026-09-17T00:00:00Z','2026-09-17T00:00:01Z');" || return 1

	assert_eq '8' "$(db_query 'SELECT COUNT(*) FROM variant_review_product_lifecycle;')" || return 1
	assert_eq 'resolved|superseded|resolved|superseded' "$(db_query "SELECT
		(SELECT projected_status FROM variant_review_product_lifecycle WHERE review_id=102),
		(SELECT resolution FROM variant_review_product_lifecycle WHERE review_id=102),
		(SELECT projected_status FROM variant_review_product_lifecycle WHERE review_id=204),
		(SELECT resolution FROM variant_review_product_lifecycle WHERE review_id=204);")" || return 1

	before="$(db_query "SELECT id,review_type,status,COALESCE(decision,''),COALESCE(superseded_at,''),COALESCE(resolved_at,'') FROM variant_reviews ORDER BY id;")" || return 1
	output="$(metrics_emit_payload)" || return 1
	after="$(db_query "SELECT id,review_type,status,COALESCE(decision,''),COALESCE(superseded_at,''),COALESCE(resolved_at,'') FROM variant_reviews ORDER BY id;")" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_metrics_review_outcomes_match_lifecycle "${output}" || return 1
	assert_eq '1' "$(metrics_review_outcome_value "${output}" candidate_identity same_book)" || return 1
	assert_eq '1' "$(metrics_review_outcome_value "${output}" candidate_identity different_book)" || return 1
	assert_eq '1' "$(metrics_review_outcome_value "${output}" candidate_identity superseded)" || return 1
	assert_eq '1' "$(metrics_review_outcome_value "${output}" winner winner)" || return 1
	assert_eq '2' "$(metrics_review_outcome_value "${output}" winner superseded)" || return 1
	assert_eq '6' "$(db_query "SELECT COUNT(*) FROM variant_review_product_lifecycle WHERE projected_status='resolved' AND resolution IS NOT NULL;")" || return 1

	list_output="$(variants_list_json)" || return 1
	jq -e '
		([.groups[].reviews[] | select(.id == 102)] | length == 1)
		and ([.groups[].reviews[] | select(.id == 102) | .status] | .[0] == "resolved")
		and ([.groups[].reviews[] | select(.id == 102) | .resolution] | .[0] == "superseded")
		and ([.groups[].reviews[] | select(.id == 204)] | length == 1)
		and ([.groups[].reviews[] | select(.id == 204) | .status] | .[0] == "resolved")
		and ([.groups[].reviews[] | select(.id == 204) | .resolution] | .[0] == "superseded")
	' <<<"${list_output}" >/dev/null || return 1
	reviews_output="$(variants_reviews_json resolved)" || return 1
	jq -e '
		([.reviews[] | select(.id == 103) | .status == "resolved" and .resolution == "same_book"] | any)
		and ([.reviews[] | select(.id == 104) | .status == "resolved" and .resolution == "different_book"] | any)
		and ([.reviews[] | select(.id == 203) | .status == "resolved" and .resolution == "winner"] | any)
		and ([.reviews[] | select(.id == 204) | .status == "resolved" and .resolution == "superseded"] | any)
	' <<<"${reviews_output}" >/dev/null || return 1
}

test_variant_job_outcome_counters_are_transactional_and_non_backfilled() {
	command -v sqlite3 >/dev/null || return 0

	local migration output group_id before
	prepare_gallery_variant_migration_test job-outcome-counters
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 024_* || "${migration##*/}" == 025_* || "${migration##*/}" == 026_* || "${migration##*/}" == 027_* || "${migration##*/}" == 028_* || "${migration##*/}" == 029_* || "${migration##*/}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES(1,'token-1','One','[]'),(2,'token-2','Two','[]');
		INSERT INTO variant_groups(id,source_gid,desired_rating) VALUES(1,1,8),(2,2,8);
		INSERT INTO variant_jobs(id,job_type,group_id,source_gid,status)
		VALUES(1,'discover',1,1,'completed'),(2,'evaluate',1,1,'failed');" || return 1
	cp "${TEST_ROOT}/migrations/024_variant_job_outcome_counters.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '30|0' "$(db_query 'SELECT COUNT(*),COALESCE(SUM(value),0) FROM variant_job_outcome_counters;')" || return 1

	db_write "INSERT INTO variant_jobs(id,job_type,group_id,source_gid,status,lease_owner,lease_expires_at)
		VALUES
			(3,'discover',1,1,'leased','worker-complete','2099-01-01T00:00:00Z'),
			(4,'evaluate',1,1,'leased','worker-continue','2099-01-01T00:00:00Z'),
			(5,'reconcile_actions',1,1,'leased','worker-retry','2099-01-01T00:00:00Z'),
			(6,'reconcile_retention',1,1,'leased','worker-permanent','2099-01-01T00:00:00Z'),
			(7,'policy_scoring_sweep',NULL,NULL,'leased','worker-config','2099-01-01T00:00:00Z'),
			(8,'discover',2,2,'queued',NULL,NULL);
		UPDATE variant_jobs SET status='completed',lease_owner=NULL,lease_expires_at=NULL WHERE id=3;
		UPDATE variant_jobs SET status='queued',lease_owner=NULL,lease_expires_at=NULL WHERE id=4;
		UPDATE variant_jobs SET status='queued',lease_owner=NULL,lease_expires_at=NULL,last_error_class='transient' WHERE id=5;
		UPDATE variant_jobs SET status='failed',lease_owner=NULL,lease_expires_at=NULL,last_error_class='permanent' WHERE id=6;
		UPDATE variant_jobs SET status='failed',lease_owner=NULL,lease_expires_at=NULL,last_error_class='configuration' WHERE id=7;
		UPDATE variant_jobs SET status='queued',lease_owner=NULL,lease_expires_at=NULL WHERE id=3;
		UPDATE variant_jobs SET status='cancelled',completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=3;
		UPDATE variant_jobs SET status='cancelled',completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=8;" || return 1
	assert_eq '1|1|1|1|1|2' "$(db_query "SELECT
		(SELECT value FROM variant_job_outcome_counters WHERE job_type='discover' AND outcome='completed'),
		(SELECT value FROM variant_job_outcome_counters WHERE job_type='evaluate' AND outcome='continued'),
		(SELECT value FROM variant_job_outcome_counters WHERE job_type='reconcile_actions' AND outcome='retryable_error'),
		(SELECT value FROM variant_job_outcome_counters WHERE job_type='reconcile_retention' AND outcome='permanent_error'),
		(SELECT value FROM variant_job_outcome_counters WHERE job_type='policy_scoring_sweep' AND outcome='configuration_error'),
		(SELECT COALESCE(SUM(value),0) FROM variant_job_outcome_counters WHERE outcome='cancelled');")" || return 1

	db_write "UPDATE variant_jobs SET status='leased',lease_owner='worker-same',lease_expires_at='2099-01-01T00:00:00Z' WHERE id=3;
		UPDATE variant_jobs SET status='leased',lease_owner='worker-rollback',lease_expires_at='2099-01-01T00:00:00Z' WHERE id=4;" || return 1
	before="$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='discover' AND outcome='completed';")" || return 1
	db_write "BEGIN;
		UPDATE variant_jobs SET status='leased',lease_owner='worker-same' WHERE id=3;
		UPDATE variant_jobs SET status='completed',lease_owner=NULL,lease_expires_at=NULL WHERE id=4;
		ROLLBACK;" || return 1
	assert_eq "${before}" "$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='discover' AND outcome='completed';")" || return 1
	assert_eq 'leased|worker-rollback' "$(db_query "SELECT status,lease_owner FROM variant_jobs WHERE id=4;")" || return 1

	db_init >/dev/null || return 1
	assert_eq '1' "$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='discover' AND outcome='completed';")" || return 1
}

test_metrics_identity_repair_migration_backfills_terminals_and_group_projection() {
	command -v sqlite3 >/dev/null || return 0

	local output
	prepare_gallery_variant_migration_test metrics-identity-repair
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(901,'token-901','Active source','[]'),
		(902,'token-902','Historical source','[]');
	INSERT INTO variant_groups(id,source_gid,desired_rating,is_active,review_state)
		VALUES(1,901,11,1,'none'),(2,902,11,0,'candidate_pending');
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES(1,901,'confirmed','automatic','{}','{}'),
		      (1,902,'confirmed','automatic','{}','{}');
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status)
	SELECT 'candidate_identity',2,901,id,${VARIANTS_MATCHING_REVISION},'{}','[902,901]','pending'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_jobs(
		job_type,group_id,source_gid,status,updated_at,completed_at)
	VALUES('discover',1,901,'failed','2026-09-01T00:00:00Z',NULL);
	INSERT INTO variant_actions(
		group_id,gid,action_type,desired_value,policy_revision_id,status,
		updated_at,completed_at)
	VALUES(1,901,'rating','10',
		(SELECT id FROM variant_policy_revisions WHERE is_active=1),
		'superseded','2026-09-02T00:00:00Z',NULL);" || return 1

	cp "${TEST_ROOT}/migrations/023_metrics_identity_projection.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || return 1
	assert_contains "${output}" 'Applying migration version 23: 023_metrics_identity_projection.sql...' || return 1
	assert_eq '23|2026-09-01T00:00:00Z|2026-09-02T00:00:00Z|none|none|0' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT completed_at FROM variant_jobs WHERE id=1),
		(SELECT completed_at FROM variant_actions WHERE id=1),
		(SELECT review_state FROM variant_groups WHERE id=1),
		(SELECT review_state FROM variant_groups WHERE id=2),
		(SELECT COUNT(*) FROM variant_identity_actionable_review);")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_identity_group_review_state AS projected JOIN variant_groups AS grouped ON grouped.id=projected.group_id WHERE grouped.review_state<>projected.review_state;")" || return 1
}

test_priority_1_domain_naming_migration_preserves_rating_and_rewrites_snapshots() {
	command -v sqlite3 >/dev/null || return 0

	local migration migration_name output status=0
	prepare_gallery_variant_migration_test priority-1-domain-naming
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		migration_name="${migration##*/}"
		[[ "${migration_name}" == 021_* || "${migration_name}" == 022_* || "${migration_name}" == 023_* || "${migration_name}" == 024_* || "${migration_name}" == 025_* || "${migration_name}" == 026_* || "${migration_name}" == 027_* || "${migration_name}" == 028_* || "${migration_name}" == 029_* || "${migration_name}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(
		gid, token, title, tags, rating, self_rating,
		first_gid, first_key, parent_gid, parent_key, current_gid, current_key
	) VALUES
		(1, 'source-token', 'Source', '[]', 4.25, 9, 1, 'source-token', NULL, NULL, NULL, NULL),
		(2, 'candidate-token', 'Candidate', '[]', 3.5, 7, 1, 'source-token', NULL, NULL, NULL, NULL);
	INSERT INTO variant_groups(id, source_gid, desired_rating, is_active)
		VALUES(1, 1, 9, 1);
	INSERT INTO gallery_variants(
		group_id, gid, membership_state, decision_source, evidence_json,
		metadata_snapshot_json, variant_state
	) VALUES
		(1, 1, 'confirmed', 'automatic',
		 '{\"kind\":\"chain_key_mismatch\"}',
		 '{\"gid\":1,\"rating\":4.25,\"first_gid\":1,\"first_key\":\"source-token\",\"parent_gid\":null,\"parent_key\":null,\"current_gid\":null,\"current_key\":null}',
		 'canonical'),
		(1, 2, 'candidate', 'automatic', '{}',
		 '{\"gid\":2,\"rating\":3.5,\"first_gid\":1,\"first_key\":\"source-token\",\"parent_gid\":null,\"parent_key\":null,\"current_gid\":null,\"current_key\":null}',
		 'undetermined');
	UPDATE variant_groups SET canonical_gid=1 WHERE id=1;
	INSERT INTO variant_evaluations(
		id, group_id, policy_revision_id, state, metadata_snapshot_json,
		member_scores_json, selected_canonical_gid
	) VALUES(1, 1, (SELECT id FROM variant_policy_revisions WHERE is_active=1),
		'completed',
		'[{\"gid\":1,\"rating\":4.25,\"first_key\":\"source-token\",\"parent_key\":null,\"current_key\":null}]',
		'[]', 1);
	UPDATE variant_groups SET active_evaluation_id=1 WHERE id=1;
	INSERT INTO variant_reviews(
		review_type, group_id, candidate_gid, policy_revision_id,
		matching_revision, evidence_json, choices_json
	) VALUES(
		'candidate_identity', 1, 2,
		(SELECT id FROM variant_policy_revisions WHERE is_active=1), 4,
		'{\"source_snapshot\":{\"gid\":1,\"rating\":4.25,\"first_key\":\"source-token\",\"parent_key\":null,\"current_key\":null},\"candidate_snapshot\":{\"gid\":2,\"rating\":3.5,\"first_key\":\"source-token\",\"parent_key\":null,\"current_key\":null}}',
		'[1,2]');
	INSERT INTO variant_jobs(job_type, group_id, source_gid, status)
		VALUES('discover', 1, 1, 'queued');
	INSERT INTO variant_discovery_runs(
		id, group_id, job_id, matching_revision, phase, status,
		lease_owner, lease_expires_at
	) VALUES(1, 1,
		(SELECT id FROM variant_jobs WHERE job_type='discover' AND group_id=1),
		4, 'search', 'running', 'migration-test', '2099-01-01T00:00:00Z');
	UPDATE variant_jobs
		SET status='leased', lease_owner='migration-test',
		lease_expires_at='2099-01-01T00:00:00Z'
		WHERE job_type='discover' AND group_id=1;
	INSERT INTO variant_jobs(job_type, continuation_cursor_json)
		VALUES('policy_scoring_sweep', '{\"target_revision_id\":7}');" || return 1

	cp "${TEST_ROOT}/migrations/021_priority_1_domain_naming.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '21' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '4.25|9|source-token|' "$(db_query 'SELECT rating, self_rating, first_token, current_token FROM galleries WHERE gid=1;')" || return 1
	assert_eq '4.25|source-token||' "$(db_query "SELECT json_extract(metadata_snapshot_json,'$.rating'), json_extract(metadata_snapshot_json,'$.first_token'), json_extract(metadata_snapshot_json,'$.first_key'), json_extract(metadata_snapshot_json,'$.community_rating') FROM gallery_variants WHERE gid=1;")" || return 1
	assert_eq '4.25|source-token||' "$(db_query "SELECT json_extract(metadata_snapshot_json,'\$[0].rating'), json_extract(metadata_snapshot_json,'\$[0].first_token'), json_extract(metadata_snapshot_json,'\$[0].first_key'), json_extract(metadata_snapshot_json,'\$[0].community_rating') FROM variant_evaluations WHERE id=1;")" || return 1
	assert_eq 'source-token||source-token||4.25' "$(db_query "SELECT json_extract(evidence_json,'$.source_snapshot.first_token'), json_extract(evidence_json,'$.source_snapshot.first_key'), json_extract(evidence_json,'$.candidate_snapshot.first_token'), json_extract(evidence_json,'$.candidate_snapshot.first_key'), json_extract(evidence_json,'$.source_snapshot.rating') FROM variant_reviews WHERE id=1;")" || return 1
	assert_eq '{"target_policy_revision_id":7}' "$(db_query "SELECT continuation_cursor_json FROM variant_jobs WHERE job_type='policy_scoring_sweep';")" || return 1
	assert_eq 'cancelled|queued|cancelled' "$(db_query "SELECT (SELECT status FROM variant_jobs WHERE job_type='discover' AND status='cancelled'), (SELECT status FROM variant_jobs WHERE job_type='discover' AND status='queued'), (SELECT status FROM variant_discovery_runs WHERE id=1);")" || return 1
	assert_eq '8|1|1' "$(db_query "SELECT (SELECT COUNT(*) FROM variant_policy_revisions), (SELECT COUNT(*) FROM variant_policy_revisions WHERE is_active=1), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep');")" || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1

	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -eq 0 ]] || fail "priority-1 migration was not idempotent: ${output}" || return 1
}

test_priority_1_domain_naming_migration_rejects_conflicting_json_atomically() {
	command -v sqlite3 >/dev/null || return 0

	local migration migration_name output status=0
	prepare_gallery_variant_migration_test priority-1-domain-naming-conflict
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		migration_name="${migration##*/}"
		[[ "${migration_name}" == 021_* || "${migration_name}" == 022_* || "${migration_name}" == 023_* || "${migration_name}" == 024_* || "${migration_name}" == 025_* || "${migration_name}" == 026_* || "${migration_name}" == 027_* || "${migration_name}" == 028_* || "${migration_name}" == 029_* || "${migration_name}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid, token, title, tags) VALUES(1, 'token-1', 'Conflict', '[]');
		INSERT INTO variant_groups(id, source_gid, desired_rating) VALUES(1, 1, 8);
		INSERT INTO gallery_variants(
			group_id, gid, membership_state, decision_source, evidence_json,
			metadata_snapshot_json
		) VALUES(1, 1, 'confirmed', 'automatic', '{}',
			'{\"rating\":4.5,\"first_key\":\"legacy-token\",\"first_token\":\"canonical-token\"}');" || return 1
	cp "${TEST_ROOT}/migrations/021_priority_1_domain_naming.sql" "${MIGRATIONS_DIR}/"

	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'conflicting priority-1 JSON unexpectedly migrated' || return 1
	assert_contains "${output}" 'migration 021 found conflicting legacy and canonical JSON names' || return 1
	assert_eq '20|first_key|4.5|legacy-token|canonical-token' "$(db_query "SELECT (SELECT MAX(version) FROM _schema_version), (SELECT name FROM pragma_table_info('galleries') WHERE name='first_key'), json_extract(metadata_snapshot_json,'$.rating'), json_extract(metadata_snapshot_json,'$.first_key'), json_extract(metadata_snapshot_json,'$.first_token') FROM gallery_variants;")" || return 1
}

test_priority_1_startup_discovery_coalescing_is_idempotent() {
	command -v sqlite3 >/dev/null || return 0

	local migration migration_name before after count_before count_after
	prepare_gallery_variant_migration_test priority-1-startup-idempotence
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		migration_name="${migration##*/}"
		[[ "${migration_name}" == 021_* || "${migration_name}" == 022_* || "${migration_name}" == 023_* || "${migration_name}" == 024_* || "${migration_name}" == 025_* || "${migration_name}" == 026_* || "${migration_name}" == 027_* || "${migration_name}" == 028_* || "${migration_name}" == 029_* || "${migration_name}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(1,'token-1','Group one','[]'),
		(2,'token-2','Group two','[]'),
		(3,'token-3','Group three','[]'),
		(4,'token-4','Inactive group','[]'),
		(5,'token-5','Completed group','[]');
	INSERT INTO variant_groups(
		id,source_gid,desired_rating,is_active,completed_matching_revision,
		next_discovery_at)
	VALUES
		(1,1,8,1,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
		(2,2,8,1,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
		(3,3,8,1,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
		(4,4,8,0,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
		(5,5,8,1,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z');
	INSERT INTO variant_jobs(
		id,job_type,group_id,source_gid,priority,status,available_at,
		lease_owner,lease_expires_at,updated_at)
	VALUES
		(1,'discover',2,2,10,'queued','2099-01-02T00:00:00Z',NULL,NULL,'2026-09-01T00:00:00Z'),
		(2,'discover',3,3,20,'leased','2099-01-03T00:00:00Z',
		 'startup-worker','2099-01-04T00:00:00Z','2026-09-02T00:00:00Z');" || return 1

	cp "${TEST_ROOT}/migrations/021_priority_1_domain_naming.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	# Make one of the one-time jobs historical before the restart. The old
	# finalizer would insert a fresh queued row for this non-due group.
	db_write "UPDATE variant_jobs
		SET status='completed', completed_at='2026-09-03T00:00:00Z',
			updated_at='2026-09-03T00:00:00Z'
		WHERE group_id=5 AND job_type='discover';" || return 1

	before="$(db_query "SELECT id,group_id,status,priority,available_at,
		COALESCE(lease_owner,''),COALESCE(lease_expires_at,''),updated_at
		FROM variant_jobs WHERE job_type='discover' ORDER BY id;")" || return 1
	count_before="$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover';")" || return 1
	db_init >/dev/null || return 1
	after="$(db_query "SELECT id,group_id,status,priority,available_at,
		COALESCE(lease_owner,''),COALESCE(lease_expires_at,''),updated_at
		FROM variant_jobs WHERE job_type='discover' ORDER BY id;")" || return 1
	count_after="$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover';")" || return 1

	assert_eq "${before}" "${after}" || return 1
	assert_eq "${count_before}" "${count_after}" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs
		WHERE job_type='discover' AND group_id=4;")" || return 1
	assert_eq '2|1' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='queued'),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='leased');")"
}

test_priority_1_startup_does_not_schedule_already_finalized_non_due_groups() {
	assert_contains "$(<"${TEST_ROOT}/lib/metrics.sh")" 'completed_matching_revision,0) <> 6' || return 1
	assert_contains "$(<"${TEST_ROOT}/lib/db.sh")" 'run.matching_revision <> 6' || return 1
	command -v sqlite3 >/dev/null || return 0

	local before after schedule_json
	prepare_gallery_variant_migration_test priority-1-finalized
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,self_rating,feedbacked_at) VALUES
		(501,'token-501','Non-due','[]',8,'2026-01-01T00:00:00Z'),
		(502,'token-502','Annual due','[]',8,'2026-01-01T00:00:00Z'),
		(503,'token-503','Revision stale','[]',8,'2026-01-01T00:00:00Z'),
		(504,'token-504','Inactive due','[]',8,'2026-01-01T00:00:00Z');
	INSERT INTO variant_groups(
		id,source_gid,desired_rating,is_active,identity_active,completed_matching_revision,
		next_discovery_at)
	VALUES
		(1,501,8,1,1,${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
		(2,502,8,1,1,${VARIANTS_MATCHING_REVISION},'2000-01-01T00:00:00Z'),
		(3,503,8,1,1,${VARIANTS_MATCHING_REVISION}-1,'2099-01-01T00:00:00Z'),
		(4,504,8,0,0,${VARIANTS_MATCHING_REVISION},'2000-01-01T00:00:00Z');" || return 1

	before="$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover';")" || return 1
	db_init >/dev/null || return 1
	after="$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover';")" || return 1
	assert_eq '0' "${before}" || return 1
	assert_eq '0' "${after}" || return 1

	schedule_json="$(variants_worker_schedule_discovery)" || return 1
	jq -e '.due_groups == 2 and .runnable_jobs == 2' <<<"${schedule_json}" >/dev/null || return 1
	assert_eq $'502|100\n503|500' "$(db_query "SELECT grouped.source_gid || '|' || job.priority
		FROM variant_jobs AS job
		JOIN variant_groups AS grouped ON grouped.id=job.group_id
		WHERE job.job_type='discover' AND job.status='queued'
		ORDER BY grouped.source_gid;")" || return 1
	assert_eq '0|0' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_jobs AS job WHERE job.group_id=1),
		(SELECT COUNT(*) FROM variant_jobs AS job WHERE job.group_id=4);")"
}

test_priority_1_policy_finalization_rolls_back_and_retries() {
	command -v sqlite3 >/dev/null || return 0

	local migration migration_name output status=0 policy_before policy_after
	prepare_gallery_variant_migration_test priority-1-finalization-rollback
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		migration_name="${migration##*/}"
		[[ "${migration_name}" == 021_* || "${migration_name}" == 022_* || "${migration_name}" == 023_* || "${migration_name}" == 024_* || "${migration_name}" == 025_* || "${migration_name}" == 026_* || "${migration_name}" == 027_* || "${migration_name}" == 028_* || "${migration_name}" == 029_* || "${migration_name}" == 030_* ]] || cp "${migration}" "${MIGRATIONS_DIR}/"
	done
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES(601,'token-601','Retry','[]');
		INSERT INTO variant_groups(
			id,source_gid,desired_rating,is_active,completed_matching_revision)
		VALUES(1,601,8,1,${VARIANTS_MATCHING_REVISION}-1);
		INSERT INTO variant_jobs(
			id,job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
		VALUES(1,'discover',1,601,40,'leased','old-worker','2099-01-01T00:00:00Z');
		INSERT INTO variant_discovery_runs(
			id,group_id,job_id,matching_revision,phase,status,
			lease_owner,lease_expires_at)
		VALUES(1,1,1,${VARIANTS_MATCHING_REVISION}-1,'search','running',
			'old-worker','2099-01-01T00:00:00Z');
		CREATE TRIGGER test_priority_1_abort_discovery
		BEFORE INSERT ON variant_jobs
		WHEN NEW.job_type='discover'
		BEGIN
			SELECT RAISE(ABORT,'test priority-1 queue failure');
		END;" || return 1
	policy_before="$(db_query "SELECT COUNT(*),SUM(is_active) FROM variant_policy_revisions;")" || return 1

	cp "${TEST_ROOT}/migrations/021_priority_1_domain_naming.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'priority-1 finalization unexpectedly succeeded' || return 1
	assert_eq '21' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	policy_after="$(db_query "SELECT COUNT(*),SUM(is_active) FROM variant_policy_revisions;")" || return 1
	assert_eq "${policy_before}" "${policy_after}" || return 1
	assert_eq 'leased|old-worker|2099-01-01T00:00:00Z|running|old-worker|2099-01-01T00:00:00Z' \
		"$(db_query "SELECT job.status,job.lease_owner,job.lease_expires_at,
			run.status,run.lease_owner,run.lease_expires_at
			FROM variant_jobs AS job JOIN variant_discovery_runs AS run
				ON run.job_id=job.id WHERE job.id=1;")" || return 1

	db_write 'DROP TRIGGER test_priority_1_abort_discovery;' || return 1
	db_init >/dev/null || return 1
	assert_eq "$(( ${policy_before%%|*} + 1 ))" \
		"$(db_query "SELECT COUNT(*) FROM variant_policy_revisions;")" || return 1
	assert_eq 'cancelled|||cancelled||' "$(db_query "SELECT
		job.status,COALESCE(job.lease_owner,''),COALESCE(job.lease_expires_at,''),
		run.status,COALESCE(run.lease_owner,''),COALESCE(run.lease_expires_at,'')
		FROM variant_jobs AS job JOIN variant_discovery_runs AS run
			ON run.job_id=job.id WHERE job.id=1;")" || return 1
	assert_eq '1|500' "$(db_query "SELECT COUNT(*),MAX(priority) FROM variant_jobs
		WHERE group_id=1 AND job_type='discover' AND status='queued';")"
}

test_manga_scope_compaction_purges_safe_targets_and_retains_required_history() {
	command -v sqlite3 >/dev/null || return 0

	local group_id evaluation_id winner_review_id
	prepare_gallery_variant_migration_test manga-compaction || return 1
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,category) VALUES
		(301,'token-301','Manga source','[]','Manga'),
		(302,'token-302','Purged category','[]','Doujinshi'),
		(303,'token-303','Legacy category','[]',NULL),
		(304,'token-304','Retained Manga','[]','Manga');
	INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(301,11,1);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=301;')" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,metadata_snapshot_json,
		evidence_json)
		VALUES
		(${group_id},301,'confirmed','automatic','{\"gid\":301,\"category\":\"Manga\"}','{}'),
		(${group_id},302,'candidate','automatic','{\"gid\":302,\"category\":\"Doujinshi\"}','{}');
		INSERT INTO variant_evaluations(
			group_id,policy_revision_id,state,metadata_snapshot_json,
			member_scores_json,selected_canonical_gid)
		SELECT ${group_id},id,'completed',
			'[{\"gid\":301,\"category\":\"Manga\"},{\"gid\":302,\"category\":\"Doujinshi\"}]',
			'[{\"gid\":301,\"score\":10},{\"gid\":302,\"score\":9}]',301
		  FROM variant_policy_revisions WHERE is_active=1;
		SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups SET canonical_gid=301,active_evaluation_id=${evaluation_id};
		INSERT INTO variant_reviews(
			review_type,group_id,evaluation_id,policy_revision_id,matching_revision,
			evidence_json,choices_json,status,decision,selected_gid,resolved_at)
		SELECT 'winner',${group_id},${evaluation_id},id,NULL,'{}','[301]',
			'resolved','winner',301,'2026-08-30T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		SELECT last_insert_rowid();" >/dev/null || return 1
	winner_review_id="$(db_query "SELECT MAX(id) FROM variant_reviews WHERE review_type='winner';")" || return 1
	db_write "INSERT INTO variant_canonical_decisions(
		group_id,selected_gid,source_review_id,policy_revision_id,
		member_fingerprint,status)
		SELECT ${group_id},301,${winner_review_id},id,'[301,302]','active'
		  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
	SELECT 'candidate_identity',${group_id},303,id,3,
		'{\"source_snapshot\":{\"gid\":301,\"category\":\"Manga\",\"title\":\"Source\"},\"candidate_snapshot\":{\"gid\":303,\"category\":\"Manga\",\"title\":\"Legacy\"}}',
		'[301,303]','pending',NULL,NULL
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
	SELECT 'candidate_identity',${group_id},303,id,3,
		'{\"source_snapshot\":{\"gid\":301,\"category\":\"Manga\",\"title\":\"Source\"},\"candidate_snapshot\":{\"gid\":303,\"category\":\"Manga\",\"title\":\"Legacy\"}}',
		'[301,303]','resolved','same_book','2026-08-31T00:00:00Z'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_actions(group_id,gid,action_type,desired_value,decision_revision_id)
		SELECT ${group_id},302,'archive_cleanup','delete',id
		  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_jobs(job_type,group_id,source_gid,status,completed_at)
		VALUES('discover',${group_id},302,'completed','2026-08-31T00:00:00Z');
	INSERT INTO variant_discovery_runs(group_id,job_id,matching_revision,phase,status,completed_at)
		VALUES(${group_id},last_insert_rowid(),3,'publish','completed','2026-08-31T00:00:00Z');
	INSERT INTO variant_discovery_candidates(
		run_id,gid,token,matching_revision,origin_json,gdata_json,state)
		VALUES(last_insert_rowid(),302,'token-302',3,'[]',
		'{\"gid\":302,\"category\":\"Doujinshi\"}','complete');
	INSERT INTO variant_jobs(job_type,group_id,source_gid,status)
		VALUES('discover',${group_id},301,'failed');
	INSERT INTO variant_discovery_runs(group_id,job_id,matching_revision,phase,status,cursor_json)
		VALUES(${group_id},last_insert_rowid(),3,'search','failed','{\"page\":2}');
	INSERT INTO variant_discovery_candidates(
		run_id,gid,token,matching_revision,origin_json,gdata_json,state)
		VALUES(last_insert_rowid(),304,'token-304',3,'[]',
		'{\"gid\":304,\"category\":\"Manga\"}','complete');" || return 1
	cp "${TEST_ROOT}/migrations/020_manga_scope_compaction.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1

	assert_eq '20' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '301|303|304' "$(db_query "SELECT group_concat(gid, '|') FROM galleries ORDER BY gid;")" || return 1
	assert_eq '0|1|1' "$(db_query "SELECT
		(SELECT COUNT(*) FROM galleries WHERE gid=302),
		(SELECT COUNT(*) FROM galleries WHERE gid=303),
		(SELECT COUNT(*) FROM galleries WHERE gid=304);")" || return 1
	assert_eq '[301]' "$(db_query "SELECT member_fingerprint FROM variant_canonical_decisions WHERE group_id=${group_id};")" || return 1
	assert_eq '301|10' "$(db_query "SELECT json_extract(value,'$.gid') || '|' || json_extract(value,'$.score') FROM variant_evaluations,json_each(member_scores_json) WHERE group_id=${group_id} ORDER BY json_extract(value,'$.gid');")" || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_evaluations,json_each(metadata_snapshot_json) WHERE group_id=${group_id} AND json_type(value,'$.category') IS NOT NULL;")" || return 1
	assert_eq '0|0|0' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_actions WHERE gid=302),
		(SELECT COUNT(*) FROM variant_discovery_candidates WHERE gid=302),
		(SELECT COUNT(*) FROM variant_discovery_runs AS run JOIN variant_jobs AS job ON job.id=run.job_id WHERE job.source_gid=302);")" || return 1
	assert_eq '1|{"gid":301}|{"gid":303}' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_reviews WHERE review_type='candidate_identity' AND status='pending'),
		(SELECT json_extract(evidence_json,'$.source_snapshot') FROM variant_reviews WHERE review_type='candidate_identity' AND status='resolved'),
		(SELECT json_extract(evidence_json,'$.candidate_snapshot') FROM variant_reviews WHERE review_type='candidate_identity' AND status='resolved');")" || return 1
	assert_eq '1|{"page":2}|0' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_discovery_candidates WHERE gid=304),
		(SELECT cursor_json FROM variant_discovery_runs WHERE status='failed'),
		(SELECT COUNT(*) FROM variant_discovery_candidates WHERE run_id IN (SELECT id FROM variant_discovery_runs WHERE status='completed'));" )" || return 1
	assert_eq '1|1000|301' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate' AND group_id=${group_id} AND status='queued'),
		(SELECT priority FROM variant_jobs WHERE job_type='evaluate' AND group_id=${group_id} AND status='queued'),
		(SELECT source_gid FROM variant_jobs WHERE job_type='evaluate' AND group_id=${group_id} AND status='queued');")" || return 1
	assert_eq '0|ok' "$(db_query "SELECT (SELECT COUNT(*) FROM pragma_table_info('galleries') WHERE name='category'), (SELECT integrity_check FROM pragma_integrity_check);")"
}

test_manga_scope_compaction_blocks_local_archive_purge_and_rolls_back() {
	command -v sqlite3 >/dev/null || return 0

	local output status=0
	prepare_gallery_variant_migration_test manga-compaction-blocked || return 1
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,category,file_path)
		VALUES(401,'token-401','Archived other','[]','Doujinshi','already.7z');" || return 1
	cp "${TEST_ROOT}/migrations/020_manga_scope_compaction.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'blocked Manga-scope purge unexpectedly succeeded' || return 1
	assert_contains "${output}" 'migration 020 purge blocked: GID 401: local archive path' || return 1
	assert_eq '19|1|Doujinshi|already.7z' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM galleries WHERE gid=401),category,file_path
		FROM galleries WHERE gid=401;")" || return 1
}

test_manual_score_adjustment_migration_normalizes_and_queues_refresh() {
	command -v sqlite3 >/dev/null || return 0

	local group_id evaluation_id
	prepare_gallery_variant_migration_test remove-manual-adjustments || return 1
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/019_remove_manual_score_adjustments.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(201,'token-201','Automatic one','[]'),(202,'token-202','Automatic two','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(201,11,1);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=201;')" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json)
		VALUES
		(${group_id},201,'confirmed','automatic',55,'{}','{}'),
		(${group_id},202,'confirmed','manual',-9979,
		 '{\"score\":20,\"manual_decision\":\"different_book\",\"manual_adjustment\":-9999,\"manual_review_id\":7,\"manual_decided_at\":\"2026-08-30T00:00:00Z\"}','{}');
		INSERT INTO variant_evaluations(
			group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,selected_canonical_gid)
		SELECT ${group_id},id,'completed','[]',
			'[{\"gid\":201,\"score\":20},{\"gid\":202,\"score\":10054,\"components\":{\"manual_winner_override\":{\"points\":9999}}}]',202
		  FROM variant_policy_revisions WHERE is_active=1;
		SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups SET canonical_gid=202,active_evaluation_id=${evaluation_id};
		INSERT INTO variant_reviews(review_type,group_id,evaluation_id,policy_revision_id,
			evidence_json,choices_json,status,decision,selected_gid,resolved_at)
		SELECT 'winner',${group_id},${evaluation_id},id,'{}','[201,202]',
			'resolved','winner',202,'2026-08-30T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_canonical_decisions(
			group_id,selected_gid,source_review_id,policy_revision_id,member_fingerprint,status)
		SELECT ${group_id},202,last_insert_rowid(),id,'[201,202]','active'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	cp "${TEST_ROOT}/migrations/019_remove_manual_score_adjustments.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '19' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '20|different_book|7|2026-08-30T00:00:00Z|1' "$(db_query "SELECT match_score,json_extract(evidence_json,'$.manual_decision'),json_extract(evidence_json,'$.manual_review_id'),json_extract(evidence_json,'$.manual_decided_at'),json_type(evidence_json,'$.manual_adjustment') IS NULL FROM gallery_variants WHERE group_id=${group_id} AND gid=202;")" || return 1
	assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE group_id=${group_id} AND job_type='evaluate' AND status='queued';")" || return 1
	assert_eq "${evaluation_id}" "$(db_query "SELECT expected_evaluation_id FROM variant_jobs WHERE group_id=${group_id} AND job_type='evaluate' AND status='queued';")" || return 1
	assert_eq '' "$(db_query "SELECT COALESCE(canonical_decision_id,'') FROM variant_evaluations WHERE id=${evaluation_id};")" || return 1
	assert_eq '[{"gid":201,"score":20},{"gid":202,"score":10054,"components":{"manual_winner_override":{"points":9999}}}]' "$(db_query "SELECT member_scores_json FROM variant_evaluations WHERE id=${evaluation_id};")" || return 1
	assert_failure db_write "INSERT INTO variant_evaluations(
		group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,
		selected_canonical_gid,canonical_decision_id)
	SELECT ${group_id},id,'completed','[]','[]',201,
		(SELECT id FROM variant_canonical_decisions WHERE group_id=${group_id} AND status='active')
	  FROM variant_policy_revisions WHERE is_active=1;" >/dev/null 2>&1 || return 1
}

test_variant_job_diagnostics_migration_and_view() {
	command -v sqlite3 >/dev/null || return 0

	local before after active_actions action_errors job_snapshot
	prepare_gallery_variant_migration_test job-diagnostics
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/017_variant_job_diagnostics.sql"
	rm -f "${MIGRATIONS_DIR}/018_canonical_winner_decisions.sql"
	rm -f "${MIGRATIONS_DIR}/019_remove_manual_score_adjustments.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(1,'token-1','One','[]'),(2,'token-2','Two','[]'),
		(3,'token-3','Three','[]'),(4,'token-4','Four','[]'),
		(5,'token-5','Five','[]'),(6,'token-6','Six','[]'),
		(7,'token-7','Seven','[]'),(8,'token-8','Eight','[]');
	INSERT INTO variant_groups(id,source_gid,desired_rating)
		VALUES(1,1,8),(2,2,8),(3,3,8),(4,4,8),(5,5,8),(6,6,8),(7,7,8),(8,8,8);
	INSERT INTO variant_jobs(id,job_type,group_id,source_gid,status,available_at,completed_at)
		VALUES(1,'reconcile_actions',1,1,'completed',strftime('%Y-%m-%dT%H:%M:%SZ','now','-2 hours'),strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')),
		       (2,'reconcile_actions',1,1,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (3,'discover',2,2,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (4,'reconcile_actions',3,3,'leased',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (5,'reconcile_actions',4,4,'leased',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (6,'discover',5,5,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now','+2 hours'),NULL),
		       (7,'discover',6,6,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (8,'policy_scoring_sweep',NULL,NULL,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (9,'discover',7,7,'failed',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (10,'reconcile_actions',8,8,'leased',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL),
		       (11,'discover',7,7,'queued',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL);
	UPDATE variant_jobs SET lease_owner='worker-3', lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour') WHERE id=4;
	UPDATE variant_jobs SET lease_owner='worker-5', lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour') WHERE id=5;
	UPDATE variant_jobs SET lease_owner='worker-10', lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour') WHERE id=10;
	UPDATE variant_jobs SET last_error_class='transient', last_error='job' || char(10) || 'error' WHERE id=11;
	INSERT INTO variant_actions(id,group_id,gid,action_type,desired_value,decision_revision_id,status,attempt_count,available_at,last_error)
		VALUES(1,1,1,'rating','8',1,'pending',2,strftime('%Y-%m-%dT%H:%M:%SZ','now','+2 hours'),'historical' || char(10) || 'error');
	INSERT INTO variant_actions(id,group_id,gid,action_type,desired_value,decision_revision_id,status,attempt_count,available_at,last_error_class,last_error)
		VALUES(2,1,2,'favorite_move','favorites',1,'retryable_error',3,strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'),'transient','retry' || char(13) || 'error' || char(10) || char(9) || 'line'),
		       (3,1,1,'favorite_remove','0',1,'configuration_error',4,strftime('%Y-%m-%dT%H:%M:%SZ','now','+3 hours'),'configuration','configuration error');
	INSERT INTO variant_actions(id,group_id,gid,action_type,desired_value,decision_revision_id,status,attempt_count,available_at,lease_owner,lease_expires_at,lease_job_id)
		VALUES(4,1,2,'hath_request','request',1,'in_flight',5,strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour'),'worker-2',strftime('%Y-%m-%dT%H:%M:%SZ','now','+4 hours'),2);
	INSERT INTO variant_actions(id,group_id,gid,action_type,desired_value,decision_revision_id,status,available_at,last_error_class,last_error)
		VALUES(5,1,1,'archive_cleanup','delete',1,'succeeded',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL,NULL),
		       (6,1,2,'rating','9',1,'permanent_error',strftime('%Y-%m-%dT%H:%M:%SZ','now'),'permanent','permanent error'),
		       (7,1,2,'favorite_move','gallery',1,'superseded',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL,NULL),
		       (8,2,2,'rating','8',1,'pending',strftime('%Y-%m-%dT%H:%M:%SZ','now'),NULL,NULL);
	INSERT INTO variant_actions(id,group_id,gid,action_type,desired_value,decision_revision_id,status,available_at,lease_owner,lease_expires_at,lease_job_id)
		VALUES(9,8,8,'hath_request','request',1,'in_flight',strftime('%Y-%m-%dT%H:%M:%SZ','now'),'worker-10',strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour'),10);" || return 1

	cp "${TEST_ROOT}/migrations/017_variant_job_diagnostics.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '17' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '11' "$(db_query 'SELECT COUNT(*) FROM variant_job_diagnostics;')" || return 1
	assert_eq '0|0|0|0||' "$(db_query "SELECT active_action_count,action_error_count,in_flight_action_count,expired_action_lease_count,COALESCE(active_actions,''),COALESCE(action_errors,'') FROM variant_job_diagnostics WHERE job_id=1;")" || return 1
	assert_eq '4|2|1|0' "$(db_query "SELECT active_action_count,action_error_count,in_flight_action_count,expired_action_lease_count FROM variant_job_diagnostics WHERE job_id=2;")" || return 1
	assert_eq "action_error|$(db_query "SELECT available_at FROM variant_actions WHERE id=2;")" "$(db_query "SELECT diagnostic_state || '|' || next_action_available_at FROM variant_job_diagnostics WHERE job_id=2;")" || return 1
	active_actions="$(db_query "SELECT active_actions FROM variant_job_diagnostics WHERE job_id=2;")" || return 1
	assert_eq $'id=4 gid=2 type=hath_request desired=request status=in_flight attempts=5 available_at='"$(db_query "SELECT available_at FROM variant_actions WHERE id=4;")"$'\nid=2 gid=2 type=favorite_move desired=favorites status=retryable_error attempts=3 available_at='"$(db_query "SELECT available_at FROM variant_actions WHERE id=2;")"$'\nid=1 gid=1 type=rating desired=8 status=pending attempts=2 available_at='"$(db_query "SELECT available_at FROM variant_actions WHERE id=1;")"$'\nid=3 gid=1 type=favorite_remove desired=0 status=configuration_error attempts=4 available_at='"$(db_query "SELECT available_at FROM variant_actions WHERE id=3;")" "${active_actions}" || return 1
	action_errors="$(db_query "SELECT action_errors FROM variant_job_diagnostics WHERE job_id=2;")" || return 1
	assert_contains "${action_errors}" 'id=2 gid=2 type=favorite_move status=retryable_error class=transient error=retry error  line' || return 1
	assert_contains "${action_errors}" 'id=3 gid=1 type=favorite_remove status=configuration_error class=configuration error=configuration error' || return 1
	assert_not_contains "${action_errors}" 'historical' || return 1
	assert_eq '0|0|0' "$(db_query "SELECT active_action_count,action_error_count,in_flight_action_count FROM variant_job_diagnostics WHERE job_id=3;")" || return 1
	assert_eq '0|0|0' "$(db_query "SELECT active_action_count,action_error_count,in_flight_action_count FROM variant_job_diagnostics WHERE job_id=8;")" || return 1
	assert_eq 'scheduled|0' "$(db_query "SELECT diagnostic_state,schedule_due FROM variant_job_diagnostics WHERE job_id=6;")" || return 1
	assert_eq 'ready|1' "$(db_query "SELECT diagnostic_state,schedule_due FROM variant_job_diagnostics WHERE job_id=7;")" || return 1
	assert_eq 'leased|0' "$(db_query "SELECT diagnostic_state,job_lease_expired FROM variant_job_diagnostics WHERE job_id=4;")" || return 1
	assert_eq 'expired_job_lease|1' "$(db_query "SELECT diagnostic_state,job_lease_expired FROM variant_job_diagnostics WHERE job_id=5;")" || return 1
	assert_eq 'expired_action_lease|1' "$(db_query "SELECT diagnostic_state,expired_action_lease_count FROM variant_job_diagnostics WHERE job_id=10;")" || return 1
	assert_eq 'failed' "$(db_query "SELECT diagnostic_state FROM variant_job_diagnostics WHERE job_id=9;")" || return 1
	assert_eq 'job_error' "$(db_query "SELECT diagnostic_state FROM variant_job_diagnostics WHERE job_id=11;")" || return 1
	assert_eq 'completed' "$(db_query "SELECT diagnostic_state FROM variant_job_diagnostics WHERE job_id=1;")" || return 1
	job_snapshot="$(db_query 'SELECT id,status,attempt_count,last_error FROM variant_jobs ORDER BY id;')" || return 1
	before="$(db_query 'SELECT COUNT(*) FROM variant_job_diagnostics;')" || return 1
	db_query 'SELECT * FROM variant_job_diagnostics ORDER BY job_id;' >/dev/null || return 1
	after="$(db_query 'SELECT COUNT(*) FROM variant_job_diagnostics;')" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq "${job_snapshot}" "$(db_query 'SELECT id,status,attempt_count,last_error FROM variant_jobs ORDER BY id;')"
}

test_variant_hath_retry_migration_backfills_watermarks_and_unblocks_cleanup() {
	command -v sqlite3 >/dev/null || return 0

	local watermark_before watermark_after
	prepare_gallery_variant_migration_test hath-retry
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/017_variant_job_diagnostics.sql"
	rm -f "${MIGRATIONS_DIR}/016_variant_hath_retry_recovery.sql"
	rm -f "${MIGRATIONS_DIR}/018_canonical_winner_decisions.sql"
	rm -f "${MIGRATIONS_DIR}/019_remove_manual_score_adjustments.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,file_path,hath_requested_at) VALUES
		(101,'t101','Canonical','[]','missing.7z','2026-08-20T00:00:00Z'),
		(102,'t102','Alternate','[]','alternate.7z',NULL),
		(103,'t103','In flight','[]',NULL,'2026-08-01T00:00:00Z');
	INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(101,11,1);
	INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES(1,101,'confirmed','automatic','{}','{}'),
		      (1,102,'confirmed','automatic','{}','{}');
	INSERT INTO variant_evaluations(group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,selected_canonical_gid)
		VALUES(1,1,'completed','{}','[]',101);
	UPDATE variant_groups SET canonical_gid=101 WHERE id=1;
	UPDATE variant_groups SET active_evaluation_id=last_insert_rowid() WHERE id=1;
	INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status,attempt_count,available_at)
		VALUES('reconcile_actions',1,101,10,'queued',4,'2099-01-01T00:00:00Z');
	INSERT INTO variant_actions(group_id,gid,action_type,desired_value,decision_revision_id,status,attempt_count,available_at,last_attempt_at,result_json,last_error_class,last_error)
		VALUES(1,102,'archive_cleanup','delete',1,'retryable_error',7,'2099-01-01T00:00:00Z',
		       '2026-08-20T00:00:00Z','{\"old\":\"evidence\"}','transient','canonical archive is not available');
	INSERT INTO variant_actions(group_id,gid,action_type,desired_value,decision_revision_id,status,last_attempt_at,result_json)
		VALUES(1,101,'hath_request','request',1,'succeeded','2026-08-29T00:00:00Z',
		       '{\"mutation_sent\":true}');
	INSERT INTO variant_actions(group_id,gid,action_type,desired_value,decision_revision_id,status,last_attempt_at,result_json)
		VALUES(1,103,'hath_request','request',1,'succeeded','2026-08-30T00:00:00Z',
		       '{\"mutation_sent\":true}');" || return 1

	cp "${TEST_ROOT}/migrations/016_variant_hath_retry_recovery.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '16' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '2026-08-29T00:00:00Z' "$(db_query 'SELECT hath_last_attempted_at FROM galleries WHERE gid=101;')" || return 1
	assert_eq '2026-08-30T00:00:00Z' "$(db_query 'SELECT hath_last_attempted_at FROM galleries WHERE gid=103;')" || return 1
	assert_eq '' "$(db_query "SELECT COALESCE(hath_last_attempted_at,'') FROM galleries WHERE gid=102;")" || return 1
	assert_eq 'superseded|7|2026-08-20T00:00:00Z|{"old":"evidence"}|transient|canonical archive is not available' "$(db_query "SELECT status,attempt_count,last_attempt_at,result_json,last_error_class,last_error FROM variant_actions WHERE gid=102;")" || return 1
	assert_eq 'queued|4|500' "$(db_query "SELECT status,attempt_count,priority FROM variant_jobs WHERE group_id=1 AND job_type='reconcile_actions';")" || return 1
	watermark_before="$(db_query 'SELECT gid,hath_last_attempted_at FROM galleries ORDER BY gid;')" || return 1
	db_init >/dev/null || return 1
	watermark_after="$(db_query 'SELECT gid,hath_last_attempted_at FROM galleries ORDER BY gid;')" || return 1
	assert_eq "${watermark_before}" "${watermark_after}"
}

test_gallery_chain_visibility_migration_preserves_custom_scoring_and_queues_rediscovery() {
	command -v sqlite3 >/dev/null || return 0

	local custom_policy custom_content custom_matching custom_scoring custom_operations active_before active_after active_policy_after expected_content expected_matching
	prepare_gallery_variant_migration_test chain-visibility-custom
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/014_gallery_chain_visibility.sql"
	rm -f "${MIGRATIONS_DIR}/015_scoring_policy_weights.sql"
	rm -f "${MIGRATIONS_DIR}/016_variant_hath_retry_recovery.sql"
	rm -f "${MIGRATIONS_DIR}/017_variant_job_diagnostics.sql"
	rm -f "${MIGRATIONS_DIR}/018_canonical_winner_decisions.sql"
	rm -f "${MIGRATIONS_DIR}/019_remove_manual_score_adjustments.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES(700,'token-700','Custom source','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(700,11,1);
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('discover',last_insert_rowid(),700,10,'queued');" || return 1
	active_before="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	custom_policy="$(db_query "SELECT json_set(policy_json,'$.scoring.tag_scores.\"other:full color\"',777) FROM variant_policy_revisions WHERE id=${active_before};")" || return 1
	custom_content="$(variants_policy_sha256 "${custom_policy}")" || return 1
	custom_matching="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${custom_policy}")")" || return 1
	custom_scoring="$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"${custom_policy}")")" || return 1
	custom_operations="$(variants_policy_sha256 "$(jq -cS '.operations' <<<"${custom_policy}")")" || return 1
	db_write \
		".parameter set :custom_policy $(db_parameter_text "${custom_policy}")" \
		"INSERT INTO variant_policy_revisions(
			policy_json,content_hash,matching_hash,scoring_hash,operations_hash
		) SELECT :custom_policy,'${custom_content}','${custom_matching}','${custom_scoring}','${custom_operations}';
		UPDATE variant_policy_revisions SET is_active=0 WHERE id=${active_before};
		UPDATE variant_policy_revisions SET is_active=1
		WHERE content_hash='${custom_content}';" || return 1

	cp "${TEST_ROOT}/migrations/014_gallery_chain_visibility.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	active_after="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	active_policy_after="$(db_query "SELECT policy_json FROM variant_policy_revisions WHERE id=${active_after};")" || return 1
	expected_content="$(variants_policy_sha256 "${active_policy_after}")" || return 1
	expected_matching="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${active_policy_after}")")" || return 1
	[[ "${active_after}" != "${active_before}" ]] || fail 'migration did not create a new active policy revision' || return 1
	assert_eq '14|6|1|777|0|1' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_policy_revisions),
		(SELECT is_active FROM variant_policy_revisions WHERE id=${active_after}),
		json_extract(policy_json,'$.scoring.tag_scores.\"other:full color\"'),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep'),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='queued' AND priority=500)
		FROM variant_policy_revisions WHERE id=${active_after};")" || return 1
	assert_eq "${expected_content}|${expected_matching}|${custom_scoring}|${custom_operations}" \
		"$(db_query "SELECT content_hash,matching_hash,scoring_hash,operations_hash FROM variant_policy_revisions WHERE id=${active_after};")" || return 1
}

test_gallery_chain_visibility_migration_rolls_back_and_retries() {
	command -v sqlite3 >/dev/null || return 0

	local output status=0
	prepare_gallery_variant_migration_test chain-visibility-rollback
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	rm -f "${MIGRATIONS_DIR}/027_uploader_revision_chain_projection.sql"
	rm -f "${MIGRATIONS_DIR}/028_discovery_revision_archive_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/029_revision_evidence_vocabulary.sql"
	rm -f "${MIGRATIONS_DIR}/014_gallery_chain_visibility.sql"
	rm -f "${MIGRATIONS_DIR}/015_scoring_policy_weights.sql"
	rm -f "${MIGRATIONS_DIR}/016_variant_hath_retry_recovery.sql"
	rm -f "${MIGRATIONS_DIR}/017_variant_job_diagnostics.sql"
	rm -f "${MIGRATIONS_DIR}/018_canonical_winner_decisions.sql"
	rm -f "${MIGRATIONS_DIR}/019_remove_manual_score_adjustments.sql"
	rm -f "${MIGRATIONS_DIR}/020_manga_scope_compaction.sql"
	rm -f "${MIGRATIONS_DIR}/021_priority_1_domain_naming.sql"
	rm -f "${MIGRATIONS_DIR}/022_runtime_component_state.sql"
	rm -f "${MIGRATIONS_DIR}/023_metrics_identity_projection.sql"
	rm -f "${MIGRATIONS_DIR}/024_variant_job_outcome_counters.sql"
	rm -f "${MIGRATIONS_DIR}/025_variant_review_product_lifecycle.sql"
	rm -f "${MIGRATIONS_DIR}/026_identity_authority.sql"
	rm -f "${MIGRATIONS_DIR}/030_revision_traversal_indexes.sql"
	db_init >/dev/null || return 1
	cp "${TEST_ROOT}/migrations/014_gallery_chain_visibility.sql" "${MIGRATIONS_DIR}/"
	printf '%s\n' 'SELECT no_such_function();' >>"${MIGRATIONS_DIR}/014_gallery_chain_visibility.sql"
	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'broken migration 014 unexpectedly succeeded' || return 1
	assert_contains "${output}" 'Migration 014_gallery_chain_visibility.sql failed; changes were rolled back.' || return 1
	assert_eq '13|4|1' "$(db_query "SELECT (SELECT MAX(version) FROM _schema_version), (SELECT COUNT(*) FROM variant_policy_revisions), (SELECT SUM(is_active) FROM variant_policy_revisions);")" || return 1

	cp "${TEST_ROOT}/migrations/014_gallery_chain_visibility.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '14|5|1' "$(db_query "SELECT (SELECT MAX(version) FROM _schema_version), (SELECT COUNT(*) FROM variant_policy_revisions), (SELECT SUM(is_active) FROM variant_policy_revisions);")"
}

test_gallery_variant_migration_rolls_back_and_retries() {
	command -v sqlite3 >/dev/null || return 0

	local output status=0
	prepare_gallery_variant_migration_test rollback
	cp "${TEST_ROOT}"/migrations/00[1-4]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	cp "${TEST_ROOT}/migrations/005_gallery_variants.sql" "${MIGRATIONS_DIR}/"
	printf '%s\n' 'SELECT no_such_function();' >>"${MIGRATIONS_DIR}/005_gallery_variants.sql"

	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'broken migration 005 unexpectedly succeeded' || return 1
	assert_contains "${output}" 'Migration 005_gallery_variants.sql failed; changes were rolled back.' || return 1
	assert_eq '4' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq $'0\n0' "$(db_query "SELECT COUNT(*) FROM pragma_table_info('galleries') WHERE name = 'category'; SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'variant_groups';")" || return 1

	cp "${TEST_ROOT}/migrations/005_gallery_variants.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '5' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_variant_schema 0 0
}

test_page_count_scoring_migration_upgrades_only_the_default_policy() {
	command -v sqlite3 >/dev/null || return 0

	local active_revision custom_revision custom_policy custom_content custom_matching
	local custom_scoring custom_operations active_after
	prepare_gallery_variant_migration_test page-count-default
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	active_revision="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES(77,'token-77','Page score','[]');
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES(77,11);
		INSERT INTO variant_jobs(job_type,priority,scoring_revision_id)
		VALUES('policy_scoring_sweep',100,${active_revision});" || return 1
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '10|3|e5be1191ab859a44e2823ce35c125ebf93459585be6feb1705d43f4fb3365e2f|30|70|500|1' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_policy_revisions),
		active.content_hash,
		json_extract(active.policy_json,'$.scoring.page_count.cap'),
		json_extract(active.policy_json,'$.scoring.page_count.offset'),
		job.priority,
		job.scoring_revision_id=active.id
		FROM variant_policy_revisions AS active
		JOIN variant_jobs AS job ON job.job_type='policy_scoring_sweep'
		WHERE active.is_active=1;")" || return 1
	prepare_gallery_variant_migration_test page-count-custom
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	active_revision="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	custom_policy="$(db_query "SELECT json_set(policy_json,'$.scoring.tag_scores.\"other:full color\"',777) FROM variant_policy_revisions WHERE id=${active_revision};")" || return 1
	custom_policy="$(jq -cS '.' <<<"${custom_policy}")" || return 1
	custom_content="$(variants_policy_sha256 "${custom_policy}")" || return 1
	custom_matching="$(variants_policy_sha256 "$(jq -cS '.matching' <<<"${custom_policy}")")" || return 1
	custom_scoring="$(variants_policy_sha256 "$(jq -cS '.scoring' <<<"${custom_policy}")")" || return 1
	custom_operations="$(variants_policy_sha256 "$(jq -cS '.operations' <<<"${custom_policy}")")" || return 1
	db_write \
		".parameter set :custom_policy $(db_parameter_text "${custom_policy}")" \
		"INSERT INTO variant_policy_revisions(
		policy_json,content_hash,matching_hash,scoring_hash,operations_hash
	) SELECT json(:custom_policy),'${custom_content}','${custom_matching}',
		'${custom_scoring}','${custom_operations}';
	UPDATE variant_policy_revisions SET is_active=0 WHERE is_active=1;
	UPDATE variant_policy_revisions SET is_active=1 WHERE content_hash='${custom_content}';" || return 1
	custom_revision="$(db_query "SELECT id FROM variant_policy_revisions WHERE content_hash='${custom_content}';")" || return 1
	db_write "INSERT INTO variant_jobs(job_type,priority,scoring_revision_id)
		VALUES('policy_scoring_sweep',100,${custom_revision});" || return 1
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	active_after="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	assert_eq '10|3|1|777|0' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_policy_revisions),
		is_active,
		json_extract(policy_json,'$.scoring.tag_scores.\"other:full color\"'),
		json_type(policy_json,'$.scoring.page_count') IS NOT NULL
		FROM variant_policy_revisions WHERE is_active=1;")" || return 1
	assert_eq "${custom_revision}" "${active_after}" || return 1
	assert_eq "${active_revision}|0" "$(db_query "SELECT id||'|'||is_active FROM variant_policy_revisions WHERE id=${active_revision};")" || return 1
	assert_eq "${custom_revision}|100|queued" "$(db_query "SELECT scoring_revision_id||'|'||priority||'|'||status FROM variant_jobs WHERE job_type='policy_scoring_sweep';")" || return 1
	assert_eq "${custom_content}|${custom_matching}|${custom_scoring}|${custom_operations}" \
		"$(db_query "SELECT content_hash,matching_hash,scoring_hash,operations_hash FROM variant_policy_revisions WHERE id=${active_after};")" || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')" || return 1
}

test_gallery_identity_pair_migration_backfills_and_rejects_conflicts() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group output status=0
	prepare_gallery_variant_migration_test identity-pairs
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(1,'one','One','[]'),(2,'two','Two','[]'),
		(3,'three','Three','[]'),(4,'four','Four','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(1,8,0);" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=1;')" || return 1
	db_write "INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(2,8,0);" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=2;')" || return 1
	db_write "INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${first_group},2,id,1,'{}','[1,2]',
		       'resolved','different_book','2026-01-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${second_group},1,id,1,'{}','[2,1]',
		       'resolved','different_book','2026-02-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
		VALUES(3,8,0,'candidate_pending'),(4,8,0,'candidate_pending');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
		SELECT 'candidate_identity',3,4,id,1,'{}','[3,4]'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
		SELECT 'candidate_identity',4,3,id,1,'{}','[4,3]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	cp "${TEST_ROOT}/migrations/011_gallery_identity_pairs.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '11|1|2|2' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),low_gid,high_gid,current_review_id
		FROM gallery_identity_pairs;")" || return 1
	assert_failure db_write "INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id) VALUES(2,1,1);" >/dev/null 2>&1 || return 1
	assert_eq '1|1|duplicate_class_pair' "$(db_query "SELECT
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NULL),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NOT NULL),
		(SELECT json_extract(evidence_json,'$.identity_projection.reason')
		   FROM variant_reviews WHERE superseded_at IS NOT NULL);")" || return 1
	assert_eq 'idx_variant_reviews_pending_actionable_candidate' "$(db_query "SELECT name FROM sqlite_schema WHERE type='index' AND name='idx_variant_reviews_pending_actionable_candidate';")" || return 1
	assert_eq 'ok|0' "$(db_query "SELECT (SELECT integrity_check FROM pragma_integrity_check),(SELECT count(*) FROM pragma_foreign_key_check);")" || return 1

	prepare_gallery_variant_migration_test identity-pair-conflict
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags) VALUES
		(1,'one','One','[]'),(2,'two','Two','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(1,8,0),(2,8,0);
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',1,2,id,1,'{}','[1,2]',
		       'resolved','same_book','2026-01-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',2,1,id,1,'{}','[2,1]',
		       'resolved','different_book','2026-02-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	cp "${TEST_ROOT}/migrations/011_gallery_identity_pairs.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'conflicting identity migration unexpectedly succeeded' || return 1
	assert_contains "${output}" 'gallery identity migration conflict: (1, 2): resolved reviews disagree' || return 1
	assert_eq '10|0' "$(db_query "SELECT (SELECT MAX(version) FROM _schema_version),
		(SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='gallery_identity_pairs');")"
}

test_historical_variant_backfill_upgrades_schema_008() {
	command -v sqlite3 >/dev/null || return 0

	local before after snapshot counts
	prepare_gallery_variant_migration_test historical-backfill
	cp "${TEST_ROOT}"/migrations/00[1-8]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(
		gid, token, title, title_jpn, file_count, expunged, tags, rating,
		file_path, self_rating, created_at, updated_at, feedbacked_at,
		category, uploader, posted, filesize, thumb, first_gid, first_key,
		parent_gid, parent_key, current_gid, current_key, favorite_count,
		rating_count, popularity_fetched_at
	) VALUES
		(1,'token-1','Null rating',NULL,1,0,'[]',1.0,'one.7z',NULL,'2025-01-01T00:00:00Z','2025-01-02T00:00:00Z',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(2,'token-2','Zero rating',NULL,2,0,'[]',2.0,'two.7z',0,'2025-02-01T00:00:00Z','2025-02-02T00:00:00Z',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(3,'token-3','Rating seven',NULL,3,0,'[]',3.0,'three.7z',7,'2025-03-01T00:00:00Z','2025-03-02T00:00:00Z',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(4,'token-4','Rating eight','Eight JP',40,0,'[\"language:chinese\",\"artist:eight\"]',4.1,'four.7z',8,'2025-04-01T00:00:00Z','2025-04-02T00:00:00Z','2025-04-03T00:00:00Z','Manga','uploader-4',1710000004,4004,'thumb-4',104,'first-4',204,'parent-4',304,'current-4',14,24,'2025-04-04T00:00:00Z'),
		(5,'token-5','Rating nine',NULL,50,1,'[\"language:chinese\"]',4.2,'five.7z',9,'2025-05-01T00:00:00Z','2025-05-02T00:00:00Z',NULL,'Manga','uploader-5',1710000005,5005,'thumb-5',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(6,'token-6','Rating ten',NULL,60,0,'[]',4.3,'six.7z',10,'2025-06-01T00:00:00Z',NULL,NULL,'Manga',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(7,'token-7','Rating eleven',NULL,70,0,'[]',4.4,'seven.7z',11,'2025-07-01T00:00:00Z','2025-07-02T00:00:00Z','2025-07-03T00:00:00Z','Manga',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(8,'token-8','Above threshold',NULL,80,0,'[]',4.5,'eight.7z',12,'2025-08-01T00:00:00Z','2025-08-02T00:00:00Z',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(9,'token-9','Already confirmed',NULL,90,0,'[]',4.6,'nine.7z',8,'2025-09-01T00:00:00Z','2025-09-02T00:00:00Z','2025-09-03T00:00:00Z','Manga',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
		(10,'token-10','Candidate elsewhere',NULL,100,0,'[]',4.7,'ten.7z',9,'2025-10-01T00:00:00Z','2025-10-02T00:00:00Z','2025-10-03T00:00:00Z','Manga',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
	INSERT INTO galleries(gid, token, title, tags, self_rating, updated_at) VALUES
		(11,'token-11','Rating one','[]',1,'2025-11-01T00:00:00Z'),
		(12,'token-12','Rating two','[]',2,'2025-12-01T00:00:00Z'),
		(13,'token-13','Rating three','[]',3,'2026-01-01T00:00:00Z'),
		(14,'token-14','Rating four','[]',4,'2026-02-01T00:00:00Z'),
		(15,'token-15','Rating five','[]',5,'2026-03-01T00:00:00Z'),
		(16,'token-16','Rating six','[]',6,'2026-04-01T00:00:00Z');
	INSERT INTO variant_groups(source_gid, desired_rating, is_active, latest_feedback_at)
	VALUES(9, 8, 1, '2025-09-03T00:00:00Z');
	INSERT INTO gallery_variants(
		group_id, gid, membership_state, decision_source,
		evidence_json, metadata_snapshot_json, decided_at
	) SELECT id, 9, 'confirmed', 'automatic', '{\"kind\":\"feedback_source\"}',
		'{}', '2025-09-03T00:00:00Z' FROM variant_groups WHERE source_gid=9;
	INSERT INTO gallery_variants(
		group_id, gid, membership_state, decision_source,
		evidence_json, metadata_snapshot_json
	) SELECT id, 10, 'candidate', 'automatic', '{\"kind\":\"independent\"}',
		'{}' FROM variant_groups WHERE source_gid=9;
	INSERT INTO variant_jobs(
		job_type, group_id, source_gid, priority, status, completed_at
	) SELECT 'discover', id, 9, 1000, 'completed', '2025-09-04T00:00:00Z'
		FROM variant_groups WHERE source_gid=9;" || return 1

	before="$(db_query "SELECT gid, self_rating, COALESCE(feedbacked_at,''), COALESCE(updated_at,''), tags, COALESCE(file_path,'') FROM galleries ORDER BY gid;")" || return 1
	cp "${TEST_ROOT}/migrations/009_backfill_variant_discovery.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	after="$(db_query "SELECT gid, self_rating, COALESCE(feedbacked_at,''), COALESCE(updated_at,''), tags, COALESCE(file_path,'') FROM galleries ORDER BY gid;")" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq '9' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1

	assert_eq '3,4,5,6,7,10,11,12,13,14,15,16' "$(db_query "SELECT group_concat(source_gid, ',') FROM (SELECT source_gid FROM variant_groups WHERE source_gid <> 9 ORDER BY id);")" || return 1
	assert_eq '1,2,3,4,5,6,7,8,9,9,10,11' "$(db_query "SELECT group_concat(desired_rating, ',') FROM (SELECT desired_rating FROM variant_groups WHERE source_gid <> 9 ORDER BY desired_rating, source_gid);")" || return 1
	assert_eq '12|12|12' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_groups WHERE source_gid <> 9 AND is_active=1),
		(SELECT COUNT(*) FROM gallery_variants AS member JOIN variant_groups AS grouped ON grouped.id=member.group_id WHERE grouped.source_gid <> 9 AND member.gid=grouped.source_gid AND member.membership_state='confirmed'),
		(SELECT COUNT(*) FROM variant_jobs AS job JOIN variant_groups AS grouped ON grouped.id=job.group_id WHERE grouped.source_gid <> 9 AND job.job_type='discover' AND job.status='queued');")" || return 1
	assert_eq '1|1|0' "$(db_query "SELECT
		(SELECT COUNT(*) FROM gallery_variants WHERE gid=9 AND membership_state='confirmed'),
		(SELECT COUNT(*) FROM variant_jobs WHERE source_gid=9 AND job_type='discover' AND status='completed'),
		(SELECT COUNT(*) FROM variant_jobs WHERE source_gid=9 AND job_type='discover' AND status='queued');")" || return 1
	assert_eq 'candidate|confirmed' "$(db_query "SELECT
		(SELECT membership_state FROM gallery_variants AS member JOIN variant_groups AS grouped ON grouped.id=member.group_id WHERE grouped.source_gid=9 AND member.gid=10),
		(SELECT membership_state FROM gallery_variants AS member JOIN variant_groups AS grouped ON grouped.id=member.group_id WHERE grouped.source_gid=10 AND member.gid=10);")" || return 1

	assert_eq '2025-04-03T00:00:00Z|2025-05-02T00:00:00Z|1' "$(db_query "SELECT
		(SELECT latest_feedback_at FROM variant_groups WHERE source_gid=4),
		(SELECT latest_feedback_at FROM variant_groups WHERE source_gid=5),
		(SELECT latest_feedback_at <> '' FROM variant_groups WHERE source_gid=6);")" || return 1
	assert_eq '250|1' "$(db_query "SELECT MIN(priority), MAX(priority) < ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY} FROM variant_jobs WHERE status='queued';")" || return 1

	snapshot="$(db_query "SELECT metadata_snapshot_json FROM gallery_variants AS member JOIN variant_groups AS grouped ON grouped.id=member.group_id WHERE grouped.source_gid=4 AND member.gid=4;")" || return 1
	jq -e '.gid == 4 and .token == "token-4" and .title == "Rating eight" and
		.title_jpn == "Eight JP" and .category == "Manga" and
		.uploader == "uploader-4" and .posted == 1710000004 and
		.filecount == 40 and .filesize == 4004 and .expunged == 0 and
		.rating == 4.1 and .favorite_count == 14 and .rating_count == 24 and
		.popularity_fetched_at == "2025-04-04T00:00:00Z" and
		.tags == ["language:chinese","artist:eight"] and .thumb == "thumb-4" and
		.first_gid == 104 and .first_key == "first-4" and
		.parent_gid == 204 and .parent_key == "parent-4" and
		.current_gid == 304 and .current_key == "current-4"' <<<"${snapshot}" >/dev/null || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM gallery_variants AS member JOIN variant_groups AS grouped ON grouped.id=member.group_id WHERE grouped.source_gid <> 9 AND (json_valid(member.evidence_json)=0 OR json_extract(member.evidence_json,'$.kind') <> 'historical_rating_backfill' OR json_extract(member.evidence_json,'$.migration') <> 9 OR json_valid(member.metadata_snapshot_json)=0 OR member.matching_revision <> 1);")" || return 1
	assert_eq '0|0|13|12' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_actions),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type <> 'discover'),
		(SELECT COUNT(*) FROM variant_groups),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='queued');")" || return 1
	assert_eq 'ok' "$(db_query "PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check)='ok' THEN 'ok' ELSE 'failed' END;")" || return 1

	counts="$(db_query 'SELECT (SELECT COUNT(*) FROM variant_groups), (SELECT COUNT(*) FROM gallery_variants), (SELECT COUNT(*) FROM variant_jobs);')" || return 1
	db_init >/dev/null || return 1
	assert_eq "${counts}" "$(db_query 'SELECT (SELECT COUNT(*) FROM variant_groups), (SELECT COUNT(*) FROM gallery_variants), (SELECT COUNT(*) FROM variant_jobs);')"
}

test_historical_variant_backfill_rolls_back_and_retries() {
	command -v sqlite3 >/dev/null || return 0

	local output status=0
	prepare_gallery_variant_migration_test historical-backfill-rollback
	cp "${TEST_ROOT}"/migrations/00[1-8]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid, token, title, tags, self_rating)
		VALUES(88, 'token-88', 'Backfill rollback', '[]', 11);" || return 1
	cp "${TEST_ROOT}/migrations/009_backfill_variant_discovery.sql" "${MIGRATIONS_DIR}/"
	printf '%s\n' 'SELECT no_such_function();' >>"${MIGRATIONS_DIR}/009_backfill_variant_discovery.sql"

	output="$(db_init 2>&1)" || status=$?
	[[ "${status}" -ne 0 ]] || fail 'broken migration 009 unexpectedly succeeded' || return 1
	assert_contains "${output}" 'Migration 009_backfill_variant_discovery.sql failed; changes were rolled back.' || return 1
	assert_eq '8|0|0|0' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_groups),
		(SELECT COUNT(*) FROM gallery_variants),
		(SELECT COUNT(*) FROM variant_jobs);")" || return 1

	cp "${TEST_ROOT}/migrations/009_backfill_variant_discovery.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '9|1|1|1' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_groups),
		(SELECT COUNT(*) FROM gallery_variants),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='queued');")"
}

test_active_historical_low_rating_projects_actions_after_evaluation() {
	command -v sqlite3 >/dev/null || return 0

	local group_id evaluation_id
	prepare_variant_runtime_test historical-low-actions || return 1
	group_id="$(db_write "INSERT INTO variant_groups(
		source_gid, desired_rating, is_active, review_state
	) VALUES(101, 4, 1, 'none');
	SELECT last_insert_rowid();")" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id, gid, membership_state, decision_source,
		evidence_json, variant_state
	) VALUES
		(${group_id},101,'confirmed','automatic','{}','canonical'),
		(${group_id},102,'confirmed','manual','{}','alternate');" || return 1
	evaluation_id="$(db_write "INSERT INTO variant_evaluations(
		group_id, policy_revision_id, state, metadata_snapshot_json,
		member_scores_json, canonical_gid
	) SELECT ${group_id}, id, 'completed', '[]', '[]', 101
		FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups
		SET canonical_gid=101, active_evaluation_id=${evaluation_id}
		WHERE id=${group_id};" || return 1
	assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM variant_actions;')" || return 1

	variants_actions_project "${group_id}" >/dev/null || return 1
	assert_eq $'101|archive_cleanup|delete\n101|favorite_remove|favdel\n101|rating|4\n102|archive_cleanup|delete\n102|favorite_remove|favdel\n102|rating|4' \
		"$(db_query "SELECT gid, action_type, desired_value FROM variant_actions ORDER BY gid, action_type;")"
}

test_variant_policy_validation_is_strict_canonical_and_unicode_safe() {
	local ordered reordered first second invalid
	ordered='{"format_version":1,"tag_scores":{"other:full color":100,"other:uncensored":100},"title_substring_scores":{"ＳＴＲＡＳＳＥ":7},"page_count":{"cap":30,"offset":70},"posted_rank_step":2}'
	reordered=' { "posted_rank_step" : 2, "page_count" : { "offset" : 70, "cap" : 30 }, "title_substring_scores" : { "ＳＴＲＡＳＳＥ" : 7 }, "tag_scores" : { "other:uncensored" : 100, "other:full color" : 100 }, "format_version" : 1 } '

	first="$(printf '%s' "${ordered}" | variants_policy_prepare -)" || return 1
	second="$(printf '%s' "${reordered}" | variants_policy_prepare -)" || return 1
	assert_eq "$(jq -r '.compact_hash' <<<"${first}")" "$(jq -r '.compact_hash' <<<"${second}")" || return 1
	assert_eq "$(jq -r '.content_hash' <<<"${first}")" "$(jq -r '.content_hash' <<<"${second}")" || return 1
	assert_eq 'ＳＴＲＡＳＳＥ' "$(jq -r '.compact_policy.title_substring_scores | keys[0]' <<<"${first}")" || return 1
	assert_eq '22ec640858bb6f3df2446869df29c5fc9634e1d3a7da84c72f5761b97dcaf0c3' \
		"$(printf '%s' '{"format_version":1,"tag_scores":{"other:full color":100,"other:uncensored":100},"title_substring_scores":{},"posted_rank_step":1}  ' | variants_policy_prepare - | jq -r '.compact_hash')" || return 1

	for invalid in \
		'{"format_version":1,"tag_scores":{},"title_substring_scores":{},"posted_rank_step":1,"unknown":true}' \
		'{"format_version":1,"tag_scores":{},"title_substring_scores":{},"page_count":{"cap":30,"offset":-1},"posted_rank_step":1}' \
		'{"format_version":1,"tag_scores":{},"title_substring_scores":{},"page_count":{"cap":30,"offset":70,"unknown":1},"posted_rank_step":1}' \
		'{"format_version":1,"tag_scores":{"other:full color":100.5},"title_substring_scores":{},"posted_rank_step":1}' \
		'{"format_version":1,"tag_scores":{"malformed":1},"title_substring_scores":{},"posted_rank_step":1}' \
		'{"format_version":1,"tag_scores":{},"title_substring_scores":{"":1},"posted_rank_step":1}' \
		'{"format_version":1,"tag_scores":{},"title_substring_scores":{"Straße":1,"ＳＴＲＡＳＳＥ":2},"posted_rank_step":1}'; do
		assert_failure variants_policy_validate_compact "${invalid}" >/dev/null 2>&1 || return 1
	done
}

test_variant_unicode_normalizer_matches_reference_fixtures() {
	local input expected output normalizer
	input='["ＳＴＲＡＳＳＥ","Straße","ǰ","ΐ","ẖ","ΰ","ﬃ","İ","­","①"]'
	expected='["strasse","strasse","ǰ","ΐ","ẖ","ΰ","ffi","i̇","­","1"]'
	output="$(printf '%s' "${input}" | variants_unicode_nfkc_casefold_array)" || return 1
	assert_eq "$(jq -cS '.' <<<"${expected}")" "$(jq -cS '.' <<<"${output}")" || return 1
	assert_eq '[]' "$(printf '[]' | variants_unicode_nfkc_casefold_array)" || return 1

	normalizer="$(variants_unicode_normalizer)" || return 1
	if printf '\xff' | "${normalizer}" >/dev/null 2>&1; then
		fail 'native Unicode normalizer accepted invalid UTF-8'
	fi
}

test_variant_policy_check_does_not_mutate_and_activation_reuses_and_coalesces() {
	command -v sqlite3 >/dev/null || return 0
	local initial changed again before after output first_revision
	prepare_variant_runtime_test policy || return 1
	initial='{"format_version":1,"tag_scores":{"other:full color":100,"other:uncensored":100},"title_substring_scores":{},"page_count":{"cap":30,"offset":70},"posted_rank_step":1}'
	changed='{"format_version":1,"tag_scores":{"other:full color":101,"other:uncensored":100},"title_substring_scores":{},"page_count":{"cap":30,"offset":70},"posted_rank_step":1}'
	again='{"format_version":1,"tag_scores":{"other:full color":102,"other:uncensored":100},"title_substring_scores":{},"page_count":{"cap":30,"offset":70},"posted_rank_step":1}'

	before="$(db_query 'SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs) FROM variant_policy_revisions;')" || return 1
	output="$(printf '%s' "${changed}" | variants_policy_check -)" || return 1
	jq -e '.valid == true and .changed == true and .scoring_changed == true and .scoring_sweep_would_queue == true' <<<"${output}" >/dev/null || return 1
	after="$(db_query 'SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs) FROM variant_policy_revisions;')" || return 1
	assert_eq "${before}" "${after}" || return 1

	output="$(printf '%s' "${changed}" | variants_policy_activate -)" || return 1
	jq -e '.changed == true and .scoring_changed == true and .scoring_sweep_queued == true and .scoring_sweep_coalesced == false' <<<"${output}" >/dev/null || return 1
	first_revision="$(jq -r '.revision_id' <<<"${output}")"
	assert_eq '9|1|1' "$(db_query "SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${changed}" | variants_policy_activate -)" || return 1
	jq -e --argjson revision "${first_revision}" '.revision_id == $revision and .changed == false and .scoring_sweep_queued == false' <<<"${output}" >/dev/null || return 1
	assert_eq '9|1' "$(db_query "SELECT COUNT(*), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${again}" | variants_policy_activate -)" || return 1
	jq -e '.changed == true and .scoring_sweep_queued == false and .scoring_sweep_coalesced == true' <<<"${output}" >/dev/null || return 1
	assert_eq '10|1' "$(db_query "SELECT COUNT(*), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${initial}" | variants_policy_activate -)" || return 1
	jq -e '.revision_id == 11 and .changed == true and .scoring_sweep_coalesced == true' <<<"${output}" >/dev/null || return 1
	assert_eq '11|1|1' "$(db_query "SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")"
}

test_variant_scoring_components_are_deterministic() {
	local compact policy input output
	compact="$(variants_policy_validate_compact '{"format_version":1,"tag_scores":{"other:full color":100,"other:incomplete":-500},"title_substring_scores":{"ＳＴＲＡＳＳＥ":7},"page_count":{"cap":100,"offset":70},"posted_rank_step":2}')" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"Straße Straße",title_jpn:"ＳＴＲＡＳＳＥ",tags:["other:full color","other:full colorful"],filecount:180,posted:100,favorite_count:19,rating:4.9,rating_count:3,expunged:true}},
		{gid:2,metadata:{title:"plain",title_jpn:null,tags:["other:incomplete"],filecount:50,posted:200,favorite_count:99999,rating:5,rating_count:1000,expunged:false}},
		{gid:3,metadata:{title:"plain",title_jpn:null,tags:null,filecount:null,posted:200,favorite_count:null,rating:null,rating_count:null,expunged:true}}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1

	jq -e '
		.canonical_gid == 2 and .tied_gids == [2] and
		(.member_scores[0].score == -788) and
		(.member_scores[0].components.exact_tags.matches | length == 1) and
		(.member_scores[0].components.title_substrings.matches | length == 1) and
		(.member_scores[0].components.title_substrings.matches[0].matched_fields == ["title","title_jpn"]) and
		(.member_scores[0].components.posted_rank | .rank == 1 and .points == 2) and
		(.member_scores[0].components.page_count.points == 100) and
		(.member_scores[0].components.favorite_popularity.points == 1) and
		(.member_scores[0].components.rating_confidence.points == 2) and
		(.member_scores[0].components.expunged.points == -1000) and
		(.member_scores[1].score == 484) and
		(.member_scores[1].components.exact_tags.matches[0].points == -500) and
		(.member_scores[1].components.page_count.points == -20) and
		(.member_scores[1].components.favorite_popularity.points == 500) and
		(.member_scores[1].components.rating_confidence.points == 500) and
		(.member_scores[1].components.posted_rank.rank == 2) and
		(.member_scores[2].score == -996) and
		(.member_scores[2].components.page_count.points == 0) and
		(.member_scores[2].components.favorite_popularity.points == 0) and
		(.member_scores[2].components.rating_confidence.points == 0) and
		(.member_scores[0] | has("raw") | not) and
		(.member_scores[0] | has("normalization") | not) and
		(.scoring_snapshot[0] | has("title") and has("tags") and has("filecount") and has("expunged")) and
		(.member_scores[2].components.posted_rank.rank == 2) and
		(.member_scores[2].components.expunged.points == -1000)
	' <<<"${output}" >/dev/null
}

test_variant_scoring_uses_exact_decimal_flooring() {
	local compact policy input output
	compact="$(variants_policy_validate_compact '{"format_version":1,"tag_scores":{},"title_substring_scores":{},"posted_rank_step":0}')" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"decimal boundary",title_jpn:null,tags:[],posted:null,
		 favorite_count:null,rating:4.1,rating_count:20,popularity_fetched_at:null,
		 expunged:false},metadata_raw:"one"}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '.top_score == 11 and
		.member_scores[0].components.rating_confidence.points == 11' \
		<<<"${output}" >/dev/null
}

test_variant_scoring_honors_updated_policy_weights() {
	local compact policy input output
	compact='{"format_version":1,"expunged_adjustment":-2000,"favorite_popularity_cap":400,"tag_scores":{"other:full color":500,"other:uncensored":500},"title_substring_scores":{},"posted_rank_step":5,"rating_confidence_cap":400}'
	compact="$(variants_policy_validate_compact "${compact}")" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"updated weights",title_jpn:null,tags:["other:full color"],filecount:null,posted:100,favorite_count:99999,rating:5,rating_count:1000,expunged:true}},
		{gid:2,metadata:{title:"updated weights",title_jpn:null,tags:["other:uncensored"],filecount:null,posted:200,favorite_count:0,rating:3,rating_count:0,expunged:false}}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '
		.member_scores[0].components.exact_tags.subtotal == 500 and
		.member_scores[0].components.favorite_popularity.points == 400 and
		.member_scores[0].components.rating_confidence.points == 400 and
		.member_scores[0].components.expunged.points == -2000 and
		.member_scores[0].components.posted_rank.points == 5 and
		.member_scores[1].components.exact_tags.subtotal == 500 and
		.member_scores[1].components.posted_rank.points == 10
	' <<<"${output}" >/dev/null
}

test_variant_near_tie_review_uses_exclusive_thirty_point_gap() {
	local compact policy input output
	compact="$(variants_policy_validate_compact '{"format_version":1,"tag_scores":{},"title_substring_scores":{},"posted_rank_step":0}')" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"top",tags:[],posted:null,favorite_count:300,rating:null,rating_count:null,expunged:false},metadata_raw:"one"},
		{gid:2,metadata:{title:"twenty-nine behind",tags:[],posted:null,favorite_count:10,rating:null,rating_count:null,expunged:false},metadata_raw:"two"},
		{gid:3,metadata:{title:"thirty behind",tags:[],posted:null,favorite_count:0,rating:null,rating_count:null,expunged:false},metadata_raw:"three"}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1

	jq -e '
		.canonical_gid == null and .tied_gids == [1,2] and
		(.winner_review | .reason == "near_tie" and .score_gap == 29 and
		 (.score_gap_exclusive | not) and .choices == [1,2])
	' <<<"${output}" >/dev/null || return 1

	input="$(jq -c '.members[1].metadata.favorite_count = 0' <<<"${input}")" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '
		.canonical_gid == 1 and .tied_gids == [1] and
		(.winner_review | .reason == null and .score_gap == 30 and .choices == [1])
	' <<<"${output}" >/dev/null
}

test_variant_evaluation_persists_unique_winner_and_routes_tie_review() {
	command -v sqlite3 >/dev/null || return 0
	local result group_id tie_group near_group
	prepare_variant_runtime_test evaluate || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags) VALUES
		(201, 'token-201', 'Winner', '[]'), (202, 'token-202', 'Alternate', '[]'),
		(203, 'token-203', 'Tie one', '[]'), (204, 'token-204', 'Tie two', '[]');
	UPDATE galleries SET file_count=70,posted=100,favorite_count=0,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\",\"other:full color\"]' WHERE gid=201;
	UPDATE galleries SET file_count=70,posted=100,favorite_count=0,rating=3,
		rating_count=0,expunged=1,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid=202;
	UPDATE galleries SET file_count=70,posted=NULL,favorite_count=0,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid IN (203,204);
	INSERT INTO variant_groups (source_gid, desired_rating) VALUES (201, 11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=201;')" || return 1
	db_write "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json) VALUES
		(${group_id},201,'confirmed','automatic','{}'),
		(${group_id},202,'confirmed','automatic','{}');" || return 1
	result="$(variants_evaluate_gid 202)" || return 1
	jq -e '.state == "completed" and .canonical_gid == 201 and .top_score == 505 and (has("group_id") | not)' <<<"${result}" >/dev/null || return 1
	assert_eq '201|none|completed|201|canonical|505|202|alternate|2' "$(db_query "SELECT g.canonical_gid,g.review_state,e.state,e.canonical_gid,(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=201),(SELECT variant_score FROM gallery_variants WHERE group_id=${group_id} AND gid=201),(SELECT gid FROM gallery_variants WHERE group_id=${group_id} AND gid=202),(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=202),json_array_length(e.metadata_snapshot_json) FROM variant_groups g JOIN variant_evaluations e ON e.id=g.active_evaluation_id WHERE g.id=${group_id};")" || return 1
	assert_failure db_write "UPDATE variant_evaluations SET state='review_blocked' WHERE group_id=${group_id};" >/dev/null 2>&1 || return 1

	db_write "INSERT INTO variant_groups (source_gid, desired_rating) VALUES (203, 11);" || return 1
	tie_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=203;')" || return 1
	db_write "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json) VALUES
		(${tie_group},203,'confirmed','automatic','{}'),
		(${tie_group},204,'confirmed','automatic','{}');" || return 1
	result="$(variants_evaluate_group "${tie_group}")" || return 1
	jq -e '.state == "review_blocked" and .canonical_gid == null and .tied_gids == [203,204] and .top_score == 0' <<<"${result}" >/dev/null || return 1
	assert_eq 'winner_pending||review_blocked|203,204|winner|pending|203,204|undetermined,undetermined' "$(db_query "SELECT g.review_state,COALESCE(g.canonical_gid,''),e.state,(SELECT group_concat(value,',') FROM json_each(e.tied_gids_json)),r.review_type,r.status,(SELECT group_concat(value,',') FROM json_each(r.choices_json)),(SELECT group_concat(variant_state,',') FROM (SELECT variant_state FROM gallery_variants WHERE group_id=${tie_group} ORDER BY gid)) FROM variant_groups g JOIN variant_evaluations e ON e.id=g.active_evaluation_id JOIN variant_reviews r ON r.evaluation_id=e.id WHERE g.id=${tie_group};")"

	db_write "INSERT INTO galleries (gid, token, title, tags) VALUES
		(205, 'token-205', 'Near top', '[]'), (206, 'token-206', 'Near runner-up', '[]');
	UPDATE galleries SET file_count=70,posted=NULL,favorite_count=100,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid=205;
	UPDATE galleries SET file_count=70,posted=NULL,favorite_count=60,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid=206;
	INSERT INTO variant_groups (source_gid, desired_rating) VALUES (205, 11);" || return 1
	near_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=205;')" || return 1
	db_write "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json) VALUES
		(${near_group},205,'confirmed','automatic','{}'),
		(${near_group},206,'confirmed','automatic','{}');" || return 1
	result="$(variants_evaluate_group "${near_group}")" || return 1
	jq -e '.state == "review_blocked" and .canonical_gid == null and .tied_gids == [205,206] and (.winner_review | .reason == "near_tie" and .score_gap == 4 and (.score_gap_exclusive | not))' <<<"${result}" >/dev/null || return 1
	assert_eq 'near_tie|4|205,206' "$(db_query "SELECT json_extract(evidence_json,'$.reason'),json_extract(evidence_json,'$.score_gap'),(SELECT group_concat(value,',') FROM json_each(choices_json)) FROM variant_reviews WHERE group_id=${near_group};")"
}

test_variant_evaluate_gid_prefers_direct_group_lookup() {
	command -v sqlite3 >/dev/null || return 0
	local group_id historical_group trace_path
	prepare_variant_runtime_test evaluate-gid-lookup || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count,
		current_gid,current_token)
		VALUES
			(301,'token-301','Historical','[]',10,1,1,302,'token-302'),
			(302,'token-302','Published','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL);
		INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
			VALUES(101,11,1,1,'none'),(302,11,1,1,'none');" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	historical_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=302;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
			(${group_id},101,'confirmed','automatic','{}'),
			(${group_id},102,'confirmed','automatic','{}'),
			(${historical_group},302,'confirmed','automatic','{}');" || return 1

	trace_path="${TEST_TMPDIR}/variant-evaluate-gid-current-gid.trace"
	eval "$(declare -f variants_current_gid | sed 's/^variants_current_gid /test_variants_current_gid_original /')"
	variants_current_gid() {
		printf '%s\n' "$1" >>"${trace_path}"
		test_variants_current_gid_original "$@"
	}
	variants_evaluate_group() {
		printf 'group:%s\n' "$1"
	}

	assert_eq "group:${group_id}" "$(variants_evaluate_gid 101)" || return 1
	assert_not_exists "${trace_path}" || return 1
	assert_eq "group:${group_id}" "$(variants_evaluate_gid 102)" || return 1
	assert_not_exists "${trace_path}" || return 1
	assert_eq "group:${historical_group}" "$(variants_evaluate_gid 301)" || return 1
	assert_eq '301' "$(<"${trace_path}")"
}

test_variant_scoring_does_not_collapse_legacy_chain_fields() {
	local compact policy input output
	compact='{"format_version":1,"tag_scores":{},"title_substring_scores":{},"page_count":{"cap":30,"offset":70},"posted_rank_step":0}'
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,source_gid:101,members:[
		{gid:101,evidence:{automatic_same_book:false},metadata:{title:"A",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:null,parent_gid:null,expunged:false}},
		{gid:102,evidence:{automatic_same_book:true,official_chain:true},metadata:{title:"B",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:101,parent_gid:101,expunged:false}},
		{gid:103,evidence:{automatic_same_book:true,official_chain:true},metadata:{title:"C",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:101,parent_gid:102,expunged:false}},
		{gid:104,evidence:{automatic_same_book:true,official_chain:true},metadata:{title:"D",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:101,parent_gid:103,expunged:false}}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '.canonical_gid == null and .tied_gids == [101,102,103,104] and
		.automatic_canonical_gid == null and .winner_review.choices == [101,102,103,104]' \
		<<<"${output}" >/dev/null || return 1

	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,source_gid:201,members:[
		{gid:201,evidence:{automatic_same_book:false},metadata:{title:"A",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:0,rating:null,rating_count:null,first_gid:null,parent_gid:null,expunged:false}},
		{gid:202,evidence:{automatic_same_book:true,official_chain:true},metadata:{title:"B",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:0,rating:null,rating_count:null,first_gid:201,parent_gid:201,expunged:false}},
		{gid:203,evidence:{automatic_same_book:true,official_chain:true},metadata:{title:"C",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:100,rating:null,rating_count:null,first_gid:201,parent_gid:202,expunged:false}},
		{gid:204,evidence:{automatic_same_book:false},metadata:{title:"E",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:90,rating:null,rating_count:null,first_gid:null,parent_gid:null,expunged:false}}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '.canonical_gid == null and .tied_gids == [203,204] and
		.automatic_canonical_gid == null and .winner_review.reason == "near_tie" and
		.winner_review.choices == [203,204]' <<<"${output}" >/dev/null

	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,source_gid:301,members:[
		{gid:301,evidence:{automatic_same_book:false},metadata:{title:"A",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:null,parent_gid:null,expunged:false}},
		{gid:302,evidence:{automatic_same_book:false,manual_decision:"same_book"},metadata:{title:"B",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:301,parent_gid:301,expunged:false}},
		{gid:303,evidence:{automatic_same_book:false,manual_decision:"same_book"},metadata:{title:"C",title_jpn:null,tags:[],filecount:100,posted:null,favorite_count:null,rating:null,rating_count:null,first_gid:301,parent_gid:302,expunged:false}}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '.canonical_gid == null and .tied_gids == [301,302,303] and
		.automatic_canonical_gid == null and .winner_review.choices == [301,302,303]' \
		<<<"${output}" >/dev/null
}

test_variant_candidate_reviews_list_resolve_merge_and_reject() {
	command -v sqlite3 >/dev/null || return 0
	local older_group newer_group reject_group review_id linked_review_id output repeat before after after_repeat status=0 archive_dir
	prepare_variant_runtime_test candidate-reviews || return 1
	archive_dir="${TEST_TMPDIR}/variant-candidate-reviews-archive"
	mkdir -p "${archive_dir}"
	ARCHIVED_DIR="${archive_dir}"
	export ARCHIVED_DIR
	printf archive >"${ARCHIVED_DIR}/older.7z"
	db_write "UPDATE galleries SET title='Older source', title_jpn='Older Japanese', file_count=10, favorite_count=1, rating_count=1, tags='[\"language:chinese\",\"other:tankoubon\",\"artist:test\"]', thumb='https://example.test/older-live.jpg', file_path='older.7z' WHERE gid=101;
		UPDATE galleries SET title='Newer source', file_count=12, favorite_count=1, rating_count=1, tags='[\"language:chinese\",\"other:tankoubon\",\"artist:test\"]', thumb='https://example.test/newer-live.jpg' WHERE gid=102;
		INSERT INTO galleries (gid,token,title,file_count,favorite_count,rating_count,expunged,tags,thumb) VALUES
			(103,'token-103','Reject source',20,1,1,0,'[\"language:chinese\",\"other:tankoubon\",\"artist:test\"]','https://example.test/reject-source.jpg'),
			(104,'token-104','Different candidate',21,1,1,1,'[\"language:chinese\",\"other:tankoubon\",\"artist:test\"]','https://example.test/different.jpg'),
			(105,'token-105','Merged-group candidate',22,1,1,0,'[\"language:chinese\",\"other:tankoubon\",\"artist:test\"]','https://example.test/merged.jpg');
		INSERT INTO variant_groups(source_gid,desired_rating,latest_feedback_at) VALUES (101,9,'2026-01-01T00:00:00Z');" || return 1
	older_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json) VALUES
		(${older_group},101,'confirmed','automatic',0,'{}');
		INSERT INTO variant_groups(source_gid,desired_rating,review_state,latest_feedback_at) VALUES (102,11,'candidate_pending','2026-02-01T00:00:00Z');" || return 1
	newer_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json) VALUES
		(${newer_group},102,'confirmed','automatic',0,'{}'),
		(${newer_group},101,'candidate','automatic',55,'{\"components\":[{\"name\":\"title\",\"points\":35}],\"contradictions\":[]}'),
		(${newer_group},105,'candidate','automatic',40,'{\"components\":[{\"name\":\"title\",\"points\":20}],\"contradictions\":[]}');
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${newer_group},101,id,1,'{\"components\":[{\"name\":\"title\",\"points\":35}],\"contradictions\":[]}','[102,101]' FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${newer_group},105,id,1,'{\"components\":[{\"name\":\"title\",\"points\":20}],\"contradictions\":[]}','[102,105]' FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${newer_group} AND candidate_gid=101;")" || return 1
	linked_review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${newer_group} AND candidate_gid=105;")" || return 1
	db_write "UPDATE variant_reviews
		SET evidence_json = json_set(
			evidence_json,
			'$.source_snapshot', json('{\"gid\":102,\"title\":\"Newer frozen\",\"filecount\":12,\"expunged\":false,\"thumb\":\"https://example.test/source-frozen.jpg\",\"tags\":[\"artist:test\"]}'),
			'$.candidate_snapshot', json('{\"gid\":101,\"title\":\"Older candidate frozen\",\"title_jpn\":\"Older Japanese\",\"filecount\":10,\"expunged\":false,\"thumb\":\"https://example.test/candidate-frozen.jpg\",\"tags\":[\"artist:test\"]}'),
			'$.normalized', json('{\"creators_source\":[\"artist:test\"],\"creators_candidate\":[\"artist:test\"],\"content_tags_source\":[\"female:test\"],\"content_tags_candidate\":[\"female:test\"]}')
		)
		WHERE id=${review_id};" || return 1

	before="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	output="$(variants_reviews_json pending)" || return 1
	after="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	repeat="$(variants_reviews_json pending)" || return 1
	after_repeat="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq "${before}" "${after_repeat}" || return 1
	assert_eq "${output}" "${repeat}" || return 1
	jq -e '
		.actionable_count == 2 and (.reviews | length) == 2 and
		(.reviews[0] | .id == $review and .source.gid == 102 and .source.title == "Newer source" and
		 .source.thumb == "https://example.test/newer-live.jpg" and
		 .source.historical.title == "Newer frozen" and
		 .source.historical.thumb == "https://example.test/source-frozen.jpg" and
		 .candidate.gid == 101 and .candidate.title == "Older source" and
		 .candidate.thumb == "https://example.test/older-live.jpg" and
		 .candidate.historical.title == "Older candidate frozen" and
		 .candidate.historical.thumb == "https://example.test/candidate-frozen.jpg" and
		 .candidate.archive_state == "archived" and
		 (.source | has("tags") | not) and (.candidate | has("tags") | not) and
		 (.source.metadata_snapshot | has("tags") | not) and
		 (.candidate.metadata_snapshot | has("tags") | not) and
		 (.evidence.source_snapshot | has("tags") | not) and
		 (.evidence.candidate_snapshot | has("tags") | not) and
		 (.evidence.normalized | has("creators_source") | not) and
		 (.evidence.normalized | has("creators_candidate") | not) and
		 (.evidence.normalized | has("content_tags_source") | not) and
		 (.evidence.normalized | has("content_tags_candidate") | not) and
		 (.choices | length) == 2) and
		([.. | objects | has("group_id")] | any | not)
	' --argjson review "${review_id}" <<<"${output}" >/dev/null || return 1
	assert_eq 'artist:test|female:test' "$(db_query "SELECT
		json_extract(evidence_json, '$.source_snapshot.tags[0]'),
		json_extract(evidence_json, '$.normalized.content_tags_source[0]')
		FROM variant_reviews WHERE id=${review_id};")" || return 1

	output="$(variants_resolve_review "${review_id}" same-book)" || return 1
	assert_eq '102|101|artist:test|artist:test' "$(db_query "SELECT
		json_extract(evidence_json, '$.source_snapshot.gid'),
		json_extract(evidence_json, '$.candidate_snapshot.gid'),
		json_extract(evidence_json, '$.source_snapshot.tags[0]'),
		json_extract(evidence_json, '$.candidate_snapshot.tags[0]')
		FROM variant_reviews WHERE id=${review_id};")" || return 1
	jq -e '.resolved == true and .review_id == $review and .decision == "same_book" and .merged_group == true and .reevaluation_queued == true and (has("group_id") | not)' \
		--argjson review "${review_id}" <<<"${output}" >/dev/null || return 1
	assert_eq $'101|11|2026-02-01T00:00:00Z\n102|11|2026-02-01T00:00:00Z' "$(db_query "SELECT
		gid,self_rating,feedbacked_at FROM galleries WHERE gid IN (101,102) ORDER BY gid;")" || return 1
	assert_eq '11|1|candidate_pending|101|confirmed|manual|55|102|confirmed|automatic|0' "$(db_query "SELECT grouped.desired_rating,grouped.is_active,grouped.review_state,
		(SELECT gid FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid LIMIT 1),
		(SELECT membership_state FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid LIMIT 1),
		(SELECT decision_source FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid LIMIT 1),
		(SELECT match_score FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid LIMIT 1),
		(SELECT gid FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid DESC LIMIT 1),
		(SELECT membership_state FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid DESC LIMIT 1),
		(SELECT decision_source FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid DESC LIMIT 1),
		(SELECT match_score FROM gallery_variants WHERE group_id=${older_group} ORDER BY gid DESC LIMIT 1)
		FROM variant_groups AS grouped WHERE grouped.id=${older_group};")" || return 1
	assert_eq '0|candidate_pending|resolved|same_book|1' "$(db_query "SELECT is_active,review_state,
		(SELECT status FROM variant_reviews WHERE id=${review_id}),
		(SELECT decision FROM variant_reviews WHERE id=${review_id}),
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${older_group} AND job_type='evaluate' AND status='queued')
		FROM variant_groups WHERE id=${newer_group};")" || return 1
	variants_evaluate_group "${older_group}" >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS}" "${status}" || return 1
	status=0
	variants_resolve_review "${review_id}" same-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}" || return 1
	variants_resolve_review "${linked_review_id}" different-book >/dev/null || return 1
	assert_eq 'rejected|different_book|resolved|none|none|1' "$(db_query "SELECT
		(SELECT membership_state FROM gallery_variants WHERE group_id=${newer_group} AND gid=105),
		(SELECT decision FROM variant_reviews WHERE id=${linked_review_id}),
		(SELECT status FROM variant_reviews WHERE id=${linked_review_id}),
		(SELECT review_state FROM variant_groups WHERE id=${older_group}),
		(SELECT review_state FROM variant_groups WHERE id=${newer_group}),
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${older_group} AND job_type='evaluate' AND status='queued');")" || return 1

	db_write "INSERT INTO variant_groups(source_gid,desired_rating,review_state) VALUES (103,8,'candidate_pending');" || return 1
	reject_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=103;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json) VALUES
		(${reject_group},103,'confirmed','automatic',0,'{}'),
		(${reject_group},104,'candidate','automatic',20,'{}');
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${reject_group},104,id,1,'{}','[103,104]' FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${reject_group};")" || return 1
	variants_resolve_review "${review_id}" different-book >/dev/null || return 1
	assert_eq 'rejected|manual|20|different_book|resolved|1' "$(db_query "SELECT member.membership_state,member.decision_source,member.match_score,review.decision,review.status,
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${reject_group} AND job_type='evaluate' AND status='queued')
		FROM gallery_variants AS member JOIN variant_reviews AS review ON review.group_id=member.group_id
		WHERE member.group_id=${reject_group} AND member.gid=104;")"
}

test_variant_review_projection_preserves_revision_readiness_and_owner_precedence() {
	command -v sqlite3 >/dev/null || return 0
	local inactive_group active_group review_id active_review winner_review output repeat before after after_repeat
	prepare_variant_runtime_test review-projection-semantics || return 1
	db_write "UPDATE galleries SET file_count=10,favorite_count=1,rating_count=1,
		tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid IN (101,102);
	INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count,current_gid,current_token)
	VALUES
		(301,'token-301','Review source','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(302,'token-302','Unconfirmed candidate','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(303,'token-303','Historical winner source','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,304,'token-304'),
		(304,'token-304','Current winner source','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(401,'token-401','Cycle A','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(402,'token-402','Cycle B','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(411,'token-411','Branch root','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(412,'token-412','Branch child A','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(413,'token-413','Branch child B','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(421,'token-421','Missing target','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,499,'token-499'),
		(431,'token-431','Mismatched target','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL),
		(432,'token-432','Mismatched terminal','[\"language:chinese\",\"other:tankoubon\"]',10,1,1,NULL,NULL);
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
	VALUES(301,11,0,0,'none'),(301,11,1,1,'none'),
		(304,11,1,1,'none'),(401,11,1,1,'none'),(411,11,1,1,'none'),
		(421,11,1,1,'none'),(431,11,1,1,'none');" || return 1
	inactive_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=301 AND is_active=0;')" || return 1
	active_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=301 AND is_active=1;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${active_group},301,'confirmed','automatic','{}'),
			  (${active_group},302,'candidate','automatic','{}'),
			  ((SELECT id FROM variant_groups WHERE source_gid=304),304,'confirmed','automatic','{}');
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${inactive_group},302,id,${VARIANTS_MATCHING_REVISION},'{}','[301,302]'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${active_group},302,id,${VARIANTS_MATCHING_REVISION},'{}','[301,302]'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_evaluations(
		group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,canonical_gid,tied_gids_json)
	SELECT (SELECT id FROM variant_groups WHERE source_gid=304),id,'review_blocked','[]',
		json_array(json_object('gid',304,'score',0)),NULL,json_array(304)
	  FROM variant_policy_revisions WHERE is_active=1;
	UPDATE variant_groups SET active_evaluation_id=(SELECT MAX(id) FROM variant_evaluations
		WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=304))
	 WHERE source_gid=304;
	INSERT INTO variant_reviews(
		review_type,group_id,evaluation_id,policy_revision_id,evidence_json,choices_json)
	SELECT 'winner',(SELECT id FROM variant_groups WHERE source_gid=304),
		(SELECT active_evaluation_id FROM variant_groups WHERE source_gid=304),id,
		json_object('source_snapshot',json_object('gid',303,'title','Frozen predecessor')),'[304]'
	  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${inactive_group};")" || return 1
	active_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${active_group};")" || return 1
	winner_review="$(db_query "SELECT id FROM variant_reviews WHERE review_type='winner';")" || return 1
	db_write "DROP TRIGGER galleries_relation_pairs_insert;
	DROP TRIGGER galleries_relation_pairs_update;
	UPDATE galleries SET current_gid=402,current_token='token-402' WHERE gid=401;
	UPDATE galleries SET current_gid=401,current_token='token-401' WHERE gid=402;
	UPDATE galleries SET parent_gid=411,parent_token='token-411' WHERE gid IN (412,413);
	UPDATE galleries SET current_gid=432,current_token='wrong-token' WHERE gid=431;" || return 1
	assert_eq 'cycle|branch|reference_incomplete|token_mismatch' "$(db_query "SELECT group_concat(blocked_reason,'|') FROM (
		SELECT blocked_reason FROM current_revision_projection
		 WHERE revision_gid IN (401,411,421,431) ORDER BY revision_gid);")" || return 1
	db_write "WITH malformed(source_gid) AS (VALUES(401),(411),(421),(431))
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
	SELECT 'candidate_identity',grouped.id,302,policy.id,${VARIANTS_MATCHING_REVISION},'{}',
		json_array(malformed.source_gid,302)
	  FROM malformed
	  JOIN variant_groups AS grouped ON grouped.source_gid=malformed.source_gid
	  JOIN variant_policy_revisions AS policy ON policy.is_active=1;" || return 1

	local status_parameter old_edge_projection new_edge_projection
	status_parameter="$(db_parameter_text pending)" || return 1
	old_edge_projection="$(db_query_json \
		".parameter set :status ${status_parameter}" \
		"$(variants_revision_projection_sql review)
		 SELECT classified.gid AS revision_gid,
		        (SELECT json_group_array(json_object(
		                   'from_gid',ordered_edge.from_gid,
		                   'to_gid',ordered_edge.to_gid,
		                   'relation',ordered_edge.relation))
		           FROM (
		             SELECT edge.from_gid,edge.to_gid,edge.relation
		               FROM evaluation_relation_edges AS edge
		              WHERE edge.is_valid=1
		                AND edge.relation IN ('parent','current')
		                AND (edge.from_gid=classified.gid
		                  OR edge.to_gid=classified.gid
		                  OR edge.from_gid IN (
		                       SELECT member.gid
		                         FROM evaluation_classified_member AS member
		                        WHERE member.component_gid=classified.component_gid))
		              ORDER BY edge.from_gid,edge.to_gid,edge.relation
		           ) AS ordered_edge) AS edge_provenance
		   FROM evaluation_classified_member AS classified
		  ORDER BY classified.gid;")" || return 1
	new_edge_projection="$(db_query_json \
		".parameter set :status ${status_parameter}" \
		"$(variants_revision_projection_sql review)
		 SELECT revision_gid,edge_provenance
		   FROM revision_projection
		  ORDER BY revision_gid;")" || return 1
	assert_eq "$(jq -cS . <<<"${old_edge_projection}")" \
		"$(jq -cS . <<<"${new_edge_projection}")" || return 1

	before="$(db_query 'SELECT * FROM variant_reviews ORDER BY id;
		SELECT * FROM variant_groups ORDER BY id;
		SELECT * FROM variant_jobs ORDER BY id;
		SELECT * FROM galleries ORDER BY gid;')" || return 1
	output="$(variants_reviews_json pending)" || return 1
	after="$(db_query 'SELECT * FROM variant_reviews ORDER BY id;
		SELECT * FROM variant_groups ORDER BY id;
		SELECT * FROM variant_jobs ORDER BY id;
		SELECT * FROM galleries ORDER BY gid;')" || return 1
	repeat="$(variants_reviews_json pending)" || return 1
	after_repeat="$(db_query 'SELECT * FROM variant_reviews ORDER BY id;
		SELECT * FROM variant_groups ORDER BY id;
		SELECT * FROM variant_jobs ORDER BY id;
		SELECT * FROM galleries ORDER BY gid;')" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq "${before}" "${after_repeat}" || return 1
	assert_eq "${output}" "${repeat}" || return 1
	jq -e --argjson inactive "${review_id}" --argjson active "${active_review}" \
		--argjson winner "${winner_review}" '
		.actionable_count == 2 and (.reviews | length) == 2 and
		([.reviews[].id] == [$active,$winner]) and
		([.reviews[] | select(.id == $active) | .candidate.gid] | .[0]) == 302 and
		([.reviews[] | select(.id == $active) | .covered_review_count] | .[0]) == 2 and
		([.reviews[] | select(.id == $winner) | .source.current.gid] | .[0]) == 304 and
		([.reviews[] | select(.id == $winner) | .source.historical.gid] | .[0]) == 303 and
		([.reviews[] | select(.id == $winner) | .choices[0].gid] | .[0]) == 304 and
		([.reviews[] | select(.id == $inactive or .source_gid == 401 or
			.source_gid == 411 or .source_gid == 421 or .source_gid == 431)] | length) == 0
	' <<<"${output}" >/dev/null || return 1
}

test_variant_identity_decisions_are_monotonic_and_symmetric() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group first_review second_review status=0
	prepare_variant_runtime_test identity-monotonic || return 1
	db_write "INSERT INTO variant_groups(source_gid,desired_rating,review_state)
		VALUES(101,11,'candidate_pending'),(102,11,'candidate_pending');" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json)
		VALUES
		(${first_group},101,'confirmed','automatic',0,'{}'),
		(${first_group},102,'candidate','automatic',20,'{}'),
		(${second_group},102,'confirmed','automatic',0,'{}'),
		(${second_group},101,'candidate','automatic',20,'{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${first_group},102,id,2,'{}','[101,102]'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${second_group},101,id,2,'{}','[102,101]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	first_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${first_group};")" || return 1
	second_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${second_group};")" || return 1
	variants_resolve_review "${first_review}" different-book >/dev/null || return 1
	variants_resolve_review "${second_review}" same-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}" || return 1
	assert_eq "101|102|${first_review}|different_book|2|2|1" "$(db_query "SELECT
		pair.low_gid,pair.high_gid,pair.current_review_id,current.decision,
		(SELECT count(*) FROM variant_groups WHERE is_active=1),
		(SELECT count(*) FROM gallery_variants AS member
		 JOIN variant_groups AS grouped ON grouped.id=member.group_id
		 WHERE grouped.is_active=1 AND member.membership_state='confirmed'),
		(SELECT count(*) FROM variant_reviews
		 WHERE status='pending' AND superseded_at IS NOT NULL)
		FROM gallery_identity_pairs AS pair
		JOIN variant_reviews AS current ON current.id=pair.current_review_id;")" || return 1

	prepare_variant_runtime_test identity-no-split || return 1
	status=0
	db_write "INSERT INTO variant_groups(source_gid,desired_rating,review_state)
		VALUES(101,11,'candidate_pending'),(102,11,'candidate_pending');" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
		(${first_group},101,'confirmed','automatic','{}'),
		(${first_group},102,'candidate','automatic','{}'),
		(${second_group},102,'confirmed','automatic','{}'),
		(${second_group},101,'candidate','automatic','{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${first_group},102,id,2,'{}','[101,102]'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${second_group},101,id,2,'{}','[102,101]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	first_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${first_group};")" || return 1
	second_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${second_group};")" || return 1
	variants_resolve_review "${first_review}" same-book >/dev/null || return 1
	variants_resolve_review "${second_review}" different-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_IDENTITY_CONFLICT_STATUS}" "${status}" || return 1
	assert_eq "${first_review}|same_book|pending|1|2" "$(db_query "SELECT
		pair.current_review_id,current.decision,
		(SELECT status FROM variant_reviews WHERE id=${second_review}),
		(SELECT count(*) FROM variant_groups WHERE is_active=1),
		(SELECT count(*) FROM gallery_variants AS member
		 JOIN variant_groups AS grouped ON grouped.id=member.group_id
		 WHERE grouped.is_active=1 AND member.membership_state='confirmed')
		FROM gallery_identity_pairs AS pair
		JOIN variant_reviews AS current ON current.id=pair.current_review_id;")"

	prepare_variant_runtime_test identity-transitive-conflict || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count)
	VALUES(103,'token-103','Third','[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
		INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(101,11,0),(102,11,1);" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${second_group},101,'confirmed','automatic','{}'),
		      (${second_group},102,'confirmed','automatic','{}'),
		      (${second_group},103,'candidate','automatic','{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${first_group},103,id,2,'{}','[101,103]',
		       'resolved','different_book','2026-01-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
		SELECT 101,103,id FROM variant_reviews WHERE group_id=${first_group};
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${second_group},103,id,2,'{}','[102,103]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	second_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${second_group};")" || return 1
	status=0
	variants_resolve_review "${second_review}" same-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_IDENTITY_CONFLICT_STATUS}" "${status}" || return 1
	assert_eq '101|103|different_book|candidate|pending|2' "$(db_query "SELECT
		pair.low_gid,pair.high_gid,current.decision,
		(SELECT membership_state FROM gallery_variants
		 WHERE group_id=${second_group} AND gid=103),
		(SELECT status FROM variant_reviews WHERE id=${second_review}),
		(SELECT count(*) FROM gallery_variants
		 WHERE group_id=${second_group} AND membership_state='confirmed')
		FROM gallery_identity_pairs AS pair
		JOIN variant_reviews AS current ON current.id=pair.current_review_id;")"
}

test_variant_identity_reconciliation_collapses_and_reopens_class_pairs() {
	command -v sqlite3 >/dev/null || return 0
	local class_a class_b historical representative hidden reopen_review output repeat before after after_repeat job_stamp status=0
	prepare_variant_runtime_test identity-reduction || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count) VALUES
		(103,'token-103','Third','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(104,'token-104','Fourth','[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
		INSERT INTO variant_groups(source_gid,desired_rating,review_state,is_active,identity_active)
		VALUES(101,11,'candidate_pending',1,1),(103,11,'candidate_pending',1,1),
		      (102,11,'candidate_pending',0,0);" || return 1
	class_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	class_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=103;')" || return 1
	historical="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json)
		VALUES
		(${class_a},101,'confirmed','automatic',0,'{}'),
		(${class_a},102,'confirmed','automatic',0,'{}'),
		(${class_a},103,'candidate','automatic',20,'{}'),
		(${class_b},103,'confirmed','automatic',0,'{}'),
		(${class_b},104,'confirmed','automatic',0,'{}'),
		(${class_b},101,'candidate','automatic',20,'{}'),
		(${historical},104,'candidate','automatic',20,'{}');
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json)
		SELECT 'candidate_identity',${class_a},103,id,2,'{}','[101,103]'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json)
		SELECT 'candidate_identity',${class_b},101,id,2,'{}','[103,101]'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json)
		SELECT 'candidate_identity',${historical},104,id,2,'{}','[102,104]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	representative="$(db_query "SELECT MIN(id) FROM variant_reviews;")" || return 1
	hidden="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${class_b};")" || return 1
	reopen_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${historical};")" || return 1

	before="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	output="$(variants_reviews_json pending)" || return 1
	after="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	repeat="$(variants_reviews_json pending)" || return 1
	after_repeat="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq "${before}" "${after_repeat}" || return 1
	assert_eq "${output}" "${repeat}" || return 1
	jq -e '
		.actionable_count == 1 and (.reviews | length) == 1 and
		.reviews[0].id == $representative and
		.reviews[0].covered_review_count == 3 and
		.reviews[0].source_class_size == 2 and
		.reviews[0].candidate_class_size == 2 and
		([.. | objects | has("group_id")] | any | not)
	' --argjson representative "${representative}" <<<"${output}" >/dev/null || return 1
	output="$(variants_resolve_review "${representative}" different-book)" || return 1
	jq -e '.reviews_collapsed == 2 and .groups_unblocked == 2 and
		.merged_group == false and ([.. | objects | has("group_id")] | any | not)' \
		<<<"${output}" >/dev/null || return 1
	assert_eq '0|none|none|2|2' "$(db_query "SELECT
		(SELECT count(*) FROM variant_reviews
		  WHERE review_type='candidate_identity' AND status='pending'
		    AND superseded_at IS NULL),
		(SELECT review_state FROM variant_groups WHERE id=${class_a}),
		(SELECT review_state FROM variant_groups WHERE id=${class_b}),
		(SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued'),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NOT NULL);")" || return 1
	job_stamp="$(db_query "SELECT group_concat(updated_at,'|') FROM (
		SELECT updated_at FROM variant_jobs
		 WHERE job_type='evaluate' AND status='queued' ORDER BY group_id);")" || return 1
	variants_reviews_json pending >/dev/null || return 1
	assert_eq "${job_stamp}" "$(db_query "SELECT group_concat(updated_at,'|') FROM (
		SELECT updated_at FROM variant_jobs
		 WHERE job_type='evaluate' AND status='queued' ORDER BY group_id);")" || return 1
	variants_resolve_review "${hidden}" same-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}" || return 1

	variants_ungroup 1 101 >/dev/null || return 1
	output="$(variants_reviews_json pending)" || return 1
	jq -e '.actionable_count == 1 and (.reviews | length) == 1 and
		.reviews[0].id == $reopen and .reviews[0].covered_review_count == 1 and
		.reviews[0].source_class_size == 1 and .reviews[0].candidate_class_size == 2' \
		--argjson reopen "${reopen_review}" <<<"${output}" >/dev/null || return 1
	assert_eq 'pending||' "$(db_query "SELECT status,COALESCE(superseded_at,''),
		COALESCE(json_extract(evidence_json,'$.identity_projection.reason'),'')
		FROM variant_reviews WHERE id=${reopen_review};")"
}

test_variant_identity_reconciliation_reduces_six_by_twenty_six_queue() {
	command -v sqlite3 >/dev/null || return 0
	local active_group output repeat before after after_repeat
	prepare_variant_runtime_test identity-six-by-twenty-six || return 1
	db_write "WITH RECURSIVE source(gid) AS (
		SELECT 3001 UNION ALL SELECT gid+1 FROM source WHERE gid<3006
	), candidate(gid) AS (
		SELECT 4001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<4026
	)
	INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count)
	SELECT gid,'token-'||gid,'Gallery '||gid,
		'[\"language:chinese\",\"other:tankoubon\"]',10,1,1 FROM source
	UNION ALL
	SELECT gid,'token-'||gid,'Gallery '||gid,
		'[\"language:chinese\",\"other:tankoubon\"]',10,1,1 FROM candidate;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
	VALUES(3001,11,1,'candidate_pending'),(3002,11,0,'candidate_pending'),
	      (3003,11,0,'candidate_pending'),(3004,11,0,'candidate_pending'),
	      (3005,11,0,'candidate_pending'),(3006,11,0,'candidate_pending');" || return 1
	active_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=3001;')" || return 1
	db_write "WITH RECURSIVE source(gid) AS (
		SELECT 3001 UNION ALL SELECT gid+1 FROM source WHERE gid<3006
	)
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
	SELECT ${active_group},gid,'confirmed','automatic','{}' FROM source;
	WITH RECURSIVE candidate(gid) AS (
		SELECT 4001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<4026
	)
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
	SELECT grouped.id,candidate.gid,'candidate','automatic','{}'
	  FROM variant_groups AS grouped CROSS JOIN candidate
	 WHERE grouped.source_gid BETWEEN 3001 AND 3006;
	WITH RECURSIVE candidate(gid) AS (
		SELECT 4001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<4026
	)
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',grouped.id,candidate.gid,policy.id,2,'{}',
	       json_array(grouped.source_gid,candidate.gid)
	  FROM variant_groups AS grouped CROSS JOIN candidate
	  JOIN variant_policy_revisions AS policy ON policy.is_active=1
	 WHERE grouped.source_gid BETWEEN 3001 AND 3006;" || return 1

	before="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	output="$(variants_reviews_json pending)" || return 1
	after="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	repeat="$(variants_reviews_json pending)" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq "${output}" "${repeat}" || return 1
	after_repeat="$(db_query "SELECT id,review_type,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),COALESCE(decision,''),evidence_json
		FROM variant_reviews ORDER BY id;
		SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups ORDER BY id;")" || return 1
	assert_eq "${before}" "${after_repeat}" || return 1
	jq -e '.actionable_count == 26 and (.reviews | length) == 26 and
		all(.reviews[]; .covered_review_count == 6 and
		  .source_class_size == 6 and .candidate_class_size == 1) and
		([.. | objects | has("group_id")] | any | not)' <<<"${output}" >/dev/null || return 1
	assert_eq '156|156|0' "$(db_query "SELECT
		(SELECT count(*) FROM variant_reviews WHERE review_type='candidate_identity'),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NULL),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NOT NULL);")"
}

test_variant_identity_reconciliation_preserves_unknown_review_from_inactive_owner() {
	command -v sqlite3 >/dev/null || return 0
	local group_a group_b merge_review pending_review output before after
	prepare_variant_runtime_test identity-inactive-owner || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count) VALUES
		(103,'token-103','Unknown candidate',
		'[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
		VALUES(101,11,1,'none'),(102,11,1,'none');" || return 1
	group_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	group_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
		(${group_a},101,'confirmed','automatic','{}'),
		(${group_a},102,'candidate','automatic','{}'),
		(${group_b},102,'confirmed','automatic','{}'),
		(${group_b},103,'candidate','automatic','{}');
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${group_a},102,id,${VARIANTS_MATCHING_REVISION},'{}','[101,102]'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${group_b},103,id,${VARIANTS_MATCHING_REVISION},'{}','[102,103]'
	  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	merge_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_a};")" || return 1
	pending_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_b};")" || return 1

	output="$(variants_resolve_review "${merge_review}" same-book)" || return 1
	jq -e '.resolved == true and .merged_group == true' <<<"${output}" >/dev/null || return 1
	assert_eq 'candidate_pending|candidate_pending|1' "$(db_query "SELECT
		(SELECT review_state FROM variant_groups WHERE id=${group_a}),
		(SELECT review_state FROM variant_groups WHERE id=${group_b}),
		(SELECT COUNT(*) FROM variant_identity_actionable_review);")" || return 1

	output="$(variants_reviews_json pending)" || return 1
	jq -e --argjson review "${pending_review}" '
		.actionable_count == 1 and (.reviews | length) == 1 and
		.reviews[0].id == $review and .reviews[0].covered_review_count == 1
	' <<<"${output}" >/dev/null || return 1
	before="$(db_query "SELECT id,review_state,updated_at FROM variant_groups WHERE id IN (${group_a},${group_b}) ORDER BY id; SELECT id,COALESCE(superseded_at,'') FROM variant_reviews ORDER BY id;")" || return 1
	output="$(metrics_emit_payload)" || return 1
	after="$(db_query "SELECT id,review_state,updated_at FROM variant_groups WHERE id IN (${group_a},${group_b}) ORDER BY id; SELECT id,COALESCE(superseded_at,'') FROM variant_reviews ORDER BY id;")" || return 1
	assert_eq "${before}" "${after}" || return 1

	variants_resolve_review "${pending_review}" different-book >/dev/null || return 1
	assert_eq 'none|none|0|1|0' "$(db_query "SELECT
		(SELECT review_state FROM variant_groups WHERE id=${group_a}),
		(SELECT review_state FROM variant_groups WHERE id=${group_b}),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='discover' AND status='queued'),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued'),
		(SELECT COUNT(*) FROM variant_reviews WHERE review_type='candidate_identity'
		  AND status='pending' AND superseded_at IS NULL);")" || return 1
}

test_variant_identity_reconciliation_clears_losing_owner_after_reviews_supersede() {
	command -v sqlite3 >/dev/null || return 0
	local group_a group_b merge_review losing_review output
	prepare_variant_runtime_test identity-losing-owner || return 1
	db_write "INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
		VALUES(101,11,1,'none'),(102,11,1,'none');" || return 1
	group_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	group_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
		(${group_a},101,'confirmed','automatic','{}'),
		(${group_a},102,'candidate','automatic','{}'),
		(${group_b},102,'confirmed','automatic','{}'),
		(${group_b},101,'candidate','automatic','{}');
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${group_a},102,id,${VARIANTS_MATCHING_REVISION},'{}','[101,102]'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',${group_b},101,id,${VARIANTS_MATCHING_REVISION},'{}','[102,101]'
	  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	merge_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_a};")" || return 1
	losing_review="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_b};")" || return 1

	output="$(variants_resolve_review "${merge_review}" same-book)" || return 1
	jq -e '.resolved == true and .merged_group == true' <<<"${output}" >/dev/null || return 1
	assert_eq 'none|none|1|0' "$(db_query "SELECT
		(SELECT review_state FROM variant_groups WHERE id=${group_a}),
		(SELECT review_state FROM variant_groups WHERE id=${group_b}),
		(SELECT superseded_at IS NOT NULL FROM variant_reviews WHERE id=${losing_review}),
		(SELECT COUNT(*) FROM variant_identity_actionable_review);")" || return 1
}

test_variant_identity_reconciliation_gates_cross_group_evaluation_loop() {
	command -v sqlite3 >/dev/null || return 0
	local group_a group_b evaluation_count queued_count stamp pending_review status=0
	prepare_variant_runtime_test identity-worker-loop || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count) VALUES
		(201,'token-201','Loop A','[\"language:chinese\",\"other:tankoubon\"]',10,1,1),
		(202,'token-202','Loop B','[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
		INSERT INTO variant_groups(
			source_gid,desired_rating,review_state,completed_matching_revision,next_discovery_at)
		VALUES
			(201,11,'candidate_pending',${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z'),
			(202,11,'candidate_pending',${VARIANTS_MATCHING_REVISION},'2099-01-01T00:00:00Z');" || return 1
	group_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=201;')" || return 1
	group_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=202;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
			(${group_a},201,'confirmed','automatic','{}'),
			(${group_a},202,'candidate','automatic','{}'),
			(${group_b},202,'confirmed','automatic','{}'),
			(${group_b},201,'candidate','automatic','{}');
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${group_a},202,id,${VARIANTS_MATCHING_REVISION},
			'{}',json_array(201,202),'resolved','different_book','2026-08-30T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
		SELECT 201,202,id FROM variant_reviews
		 WHERE group_id=${group_a} AND status='resolved';
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json)
		SELECT 'candidate_identity',${group_a},202,id,${VARIANTS_MATCHING_REVISION},
			'{}',json_array(201,202) FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
			review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
			evidence_json,choices_json)
		SELECT 'candidate_identity',${group_b},201,id,${VARIANTS_MATCHING_REVISION},
			'{}',json_array(202,201) FROM variant_policy_revisions WHERE is_active=1;" || return 1

	variants_reviews_json pending >/dev/null || return 1
	assert_eq 'candidate_pending|candidate_pending|0|0' "$(db_query "SELECT
		(SELECT review_state FROM variant_groups WHERE id=${group_a}),
		(SELECT review_state FROM variant_groups WHERE id=${group_b}),
		(SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued'),
		(SELECT count(*) FROM variant_reviews WHERE review_type='candidate_identity'
			AND status='pending' AND superseded_at IS NOT NULL);")" || return 1

	pending_review="$(db_query "SELECT id FROM variant_reviews
		WHERE review_type='candidate_identity' AND status='pending'
		ORDER BY id DESC LIMIT 1;")" || return 1
	# A public review-resolution attempt owns reconciliation even when its
	# duplicate pending card is stale by the time the transaction validates it.
	variants_resolve_review "${pending_review}" different-book >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}" || return 1
	assert_eq 'none|none|2|2' "$(db_query "SELECT
		(SELECT review_state FROM variant_groups WHERE id=${group_a}),
		(SELECT review_state FROM variant_groups WHERE id=${group_b}),
		(SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued'),
		(SELECT count(*) FROM variant_reviews WHERE review_type='candidate_identity'
			AND status='pending' AND superseded_at IS NOT NULL);")" || return 1

	export YOMIKO_REMOTE_WRITES_ENABLED=false
	variants_work --max-jobs 20 >/dev/null || return 1
	evaluation_count="$(db_query 'SELECT count(*) FROM variant_evaluations;')" || return 1
	queued_count="$(db_query "SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued';")" || return 1
	assert_eq '2' "${evaluation_count}" || return 1
	assert_eq '0' "${queued_count}" || return 1
	assert_eq '2' "$(db_query "SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='completed';")" || return 1
	variants_work --max-jobs 20 >/dev/null || return 1
	assert_eq "${evaluation_count}" "$(db_query 'SELECT count(*) FROM variant_evaluations;')" || return 1
	assert_eq '0' "$(db_query "SELECT count(*) FROM variant_jobs WHERE job_type='evaluate' AND status='queued';")" || return 1

	# A winner-pending group with only stable superseded identity evidence is
	# not an evaluation transition, and a no-op pass must not refresh its job.
	db_write "INSERT INTO variant_evaluations(
		group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,
		tied_gids_json)
		SELECT ${group_a},id,'review_blocked','[]','[]',json_array(201)
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
			review_type,group_id,evaluation_id,policy_revision_id,evidence_json,choices_json)
		SELECT 'winner',${group_a},grouped.active_evaluation_id,policy.id,'{}',json_array(201)
		  FROM variant_groups AS grouped
		  JOIN variant_policy_revisions AS policy ON policy.is_active=1
		 WHERE grouped.id=${group_a};
		UPDATE variant_groups SET review_state='winner_pending' WHERE id=${group_a};
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status,available_at)
		VALUES('evaluate',${group_a},201,500,'queued','2099-01-01T00:00:00Z');
		UPDATE variant_jobs SET updated_at='2000-01-01T00:00:00Z'
		 WHERE group_id=${group_a} AND job_type='evaluate' AND status='queued';" || return 1
	stamp="$(db_query "SELECT updated_at FROM variant_jobs
		WHERE group_id=${group_a} AND job_type='evaluate' AND status='queued';")" || return 1
	variants_reviews_json pending >/dev/null || return 1
	assert_eq 'winner_pending' "$(db_query "SELECT review_state FROM variant_groups WHERE id=${group_a};")" || return 1
	assert_eq "${stamp}" "$(db_query "SELECT updated_at FROM variant_jobs
		WHERE group_id=${group_a} AND job_type='evaluate' AND status='queued';")" || return 1
	assert_eq '500|2099-01-01T00:00:00Z' "$(db_query "SELECT priority,available_at FROM variant_jobs
		WHERE group_id=${group_a} AND job_type='evaluate' AND status='queued';")"

}

test_variant_evaluation_isolates_unrelated_identity_backlog() {
	command -v sqlite3 >/dev/null || return 0
	local target_group before_reviews after_reviews before_groups after_groups
	local before_jobs after_jobs output
	prepare_variant_runtime_test identity-evaluation-isolation || return 1
	db_write "WITH RECURSIVE source(gid) AS (
		SELECT 6001 UNION ALL SELECT gid+1 FROM source WHERE gid<6006
	), candidate(gid) AS (
		SELECT 7001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<7026
	)
	INSERT INTO galleries(gid,token,title,tags,file_count,favorite_count,rating,rating_count,posted,expunged)
	SELECT 5001,'token-5001','Target winner','[\"language:chinese\",\"other:tankoubon\",\"other:full color\"]',70,1,3,1,100,0
	UNION ALL
	SELECT 5002,'token-5002','Target alternate','[\"language:chinese\",\"other:tankoubon\"]',70,0,3,1,100,1
	UNION ALL
	SELECT gid,'token-'||gid,'Backlog source '||gid,'[\"language:chinese\",\"other:tankoubon\"]',10,1,3,1,100,0 FROM source
	UNION ALL
	SELECT gid,'token-'||gid,'Backlog candidate '||gid,'[\"language:chinese\",\"other:tankoubon\"]',10,1,3,1,100,0 FROM candidate;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
	VALUES(5001,11,1,1,'none'),
		(6001,11,1,1,'candidate_pending'),
		(6002,11,0,0,'candidate_pending'),
		(6003,11,0,0,'candidate_pending'),
		(6004,11,0,0,'candidate_pending'),
		(6005,11,0,0,'candidate_pending'),
		(6006,11,0,0,'candidate_pending');" || return 1
	target_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=5001;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${target_group},5001,'confirmed','automatic','{}'),
		      (${target_group},5002,'confirmed','automatic','{}');
	WITH RECURSIVE source(gid) AS (
		SELECT 6001 UNION ALL SELECT gid+1 FROM source WHERE gid<6006
	)
	INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
	SELECT (SELECT id FROM variant_groups WHERE source_gid=6001),gid,'confirmed','automatic','{}'
	  FROM source;
	WITH RECURSIVE candidate(gid) AS (
		SELECT 7001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<7026
	)
	INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
	SELECT grouped.id,candidate.gid,'candidate','automatic','{}'
	  FROM variant_groups AS grouped CROSS JOIN candidate
	 WHERE grouped.source_gid BETWEEN 6001 AND 6006;
	WITH RECURSIVE candidate(gid) AS (
		SELECT 7001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<7026
	)
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
	SELECT 'candidate_identity',grouped.id,candidate.gid,policy.id,
		${VARIANTS_MATCHING_REVISION},'{}',json_array(grouped.source_gid,candidate.gid)
	  FROM variant_groups AS grouped CROSS JOIN candidate
	  JOIN variant_policy_revisions AS policy ON policy.is_active=1
	 WHERE grouped.source_gid BETWEEN 6001 AND 6006;" || return 1

	before_reviews="$(db_query "SELECT id,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),evidence_json FROM variant_reviews
		WHERE group_id IN (SELECT id FROM variant_groups WHERE source_gid BETWEEN 6001 AND 6006)
		ORDER BY id;")" || return 1
	before_groups="$(db_query "SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups
		WHERE source_gid BETWEEN 6001 AND 6006 ORDER BY id;")" || return 1
	before_jobs="$(db_query "SELECT id,job_type,COALESCE(group_id,''),COALESCE(source_gid,''),
		status,priority,available_at,updated_at FROM variant_jobs
		WHERE group_id=${target_group} OR group_id IN
			(SELECT id FROM variant_groups WHERE source_gid BETWEEN 6001 AND 6006)
		ORDER BY id;")" || return 1

	output="$(variants_evaluate_group "${target_group}")" || return 1
	jq -e '.evaluated == true and .state == "completed" and .canonical_gid == 5001' \
		<<<"${output}" >/dev/null || return 1

	after_reviews="$(db_query "SELECT id,group_id,candidate_gid,status,
		COALESCE(superseded_at,''),evidence_json FROM variant_reviews
		WHERE group_id IN (SELECT id FROM variant_groups WHERE source_gid BETWEEN 6001 AND 6006)
		ORDER BY id;")" || return 1
	after_groups="$(db_query "SELECT id,source_gid,is_active,identity_active,review_state,
		COALESCE(updated_at,'') FROM variant_groups
		WHERE source_gid BETWEEN 6001 AND 6006 ORDER BY id;")" || return 1
	after_jobs="$(db_query "SELECT id,job_type,COALESCE(group_id,''),COALESCE(source_gid,''),
		status,priority,available_at,updated_at FROM variant_jobs
		WHERE group_id=${target_group} OR group_id IN
			(SELECT id FROM variant_groups WHERE source_gid BETWEEN 6001 AND 6006)
		ORDER BY id;")" || return 1
	assert_eq "${before_reviews}" "${after_reviews}" || return 1
	assert_eq "${before_groups}" "${after_groups}" || return 1
	assert_eq "${before_jobs}" "${after_jobs}" || return 1
	assert_eq '0' "$(db_query "SELECT count(*) FROM variant_jobs
		WHERE job_type='evaluate' AND (group_id=${target_group} OR group_id IN
			(SELECT id FROM variant_groups WHERE source_gid BETWEEN 6001 AND 6006));")" || return 1
}

variant_evaluation_durable_snapshot() {
	db_query "SELECT * FROM variant_evaluations ORDER BY id;
		SELECT * FROM gallery_variants ORDER BY group_id,gid;
		SELECT * FROM variant_groups ORDER BY id;
		SELECT * FROM variant_reviews ORDER BY id;
		SELECT * FROM variant_canonical_decisions ORDER BY id;
		SELECT * FROM variant_jobs ORDER BY id;"
}

test_variant_evaluation_winner_blocker_leaves_all_durable_state_unchanged() {
	command -v sqlite3 >/dev/null || return 0
	local group_id before after output status=0
	prepare_variant_runtime_test evaluation-winner-blocker || return 1
	db_write "UPDATE galleries SET file_count=70,posted=NULL,favorite_count=0,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid IN (101,102);
	INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'confirmed','automatic','{}');" || return 1
	variants_evaluate_group "${group_id}" >/dev/null || return 1

	before="$(variant_evaluation_durable_snapshot)" || return 1
	output="$(variants_evaluate_group "${group_id}")" || status=$?
	assert_eq "${VARIANTS_EVALUATION_STALE_STATUS}" "${status}" || return 1
	jq -e '.stale == true and .evaluated == false' \
		<<<"${output}" >/dev/null || return 1
	after="$(variant_evaluation_durable_snapshot)" || return 1
	assert_eq "${before}" "${after}" || return 1
}

test_variant_evaluation_candidate_blocker_with_unconfirmed_endpoint_leaves_all_durable_state_unchanged() {
	command -v sqlite3 >/dev/null || return 0
	local group_id before after output status=0
	prepare_variant_runtime_test evaluation-candidate-blocker || return 1
	db_write "UPDATE galleries SET file_count=70,posted=100,favorite_count=0,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid IN (101,102);
	INSERT INTO variant_groups(source_gid,desired_rating,review_state) VALUES(101,11,'none');" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'candidate','automatic','{}');
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status)
	SELECT 'candidate_identity',${group_id},102,id,${VARIANTS_MATCHING_REVISION},
		'{}','[101,102]','pending'
	  FROM variant_policy_revisions WHERE is_active=1;" || return 1

	before="$(variant_evaluation_durable_snapshot)" || return 1
	output="$(variants_evaluate_group "${group_id}")" || status=$?
	assert_eq "${VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS}" "${status}" || return 1
	jq -e '.blocked_reason == "candidate_review_pending" and .evaluated == false' \
		<<<"${output}" >/dev/null || return 1
	after="$(variant_evaluation_durable_snapshot)" || return 1
	assert_eq "${before}" "${after}" || return 1
}

test_variant_evaluation_stale_expected_evaluation_leaves_all_durable_state_unchanged() {
	command -v sqlite3 >/dev/null || return 0
	local group_id old_evaluation stale_evaluation before after output status=0
	prepare_variant_runtime_test evaluation-stale || return 1
	db_write "UPDATE galleries SET file_count=70,posted=100,favorite_count=0,rating=3,
		rating_count=0,expunged=0,tags='[\"language:chinese\",\"other:tankoubon\",\"other:full color\"]' WHERE gid=101;
	UPDATE galleries SET file_count=70,posted=100,favorite_count=0,rating=3,
		rating_count=0,expunged=1,tags='[\"language:chinese\",\"other:tankoubon\"]' WHERE gid=102;
	INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'confirmed','automatic','{}');" || return 1
	variants_evaluate_group "${group_id}" >/dev/null || return 1
	old_evaluation="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id};")" || return 1
	db_write "INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('evaluate',${group_id},101,2000,'queued');" || return 1
	stale_evaluation=$((old_evaluation + 1))
	before="$(variant_evaluation_durable_snapshot)" || return 1
	output="$(variants_evaluate_group "${group_id}" '' "${stale_evaluation}")" || status=$?
	assert_eq "${VARIANTS_EVALUATION_STALE_STATUS}" "${status}" || return 1
	jq -e '.stale == true and .evaluated == false' <<<"${output}" >/dev/null || return 1
	after="$(variant_evaluation_durable_snapshot)" || return 1
	assert_eq "${before}" "${after}" || return 1
}

test_variant_winner_reviews_create_immutable_automatic_score_evaluation() {
	command -v sqlite3 >/dev/null || return 0
	local group_id review_id old_evaluation output status=0 archive_dir
	prepare_variant_runtime_test winner-reviews || return 1
	archive_dir="${TEST_TMPDIR}/variant-winner-reviews-archive"
	mkdir -p "${archive_dir}"
	ARCHIVED_DIR="${archive_dir}"
	export ARCHIVED_DIR
	printf winner >"${ARCHIVED_DIR}/tie-one.7z"
	db_write "UPDATE galleries SET title='Tie one', thumb='https://example.test/tie-one.jpg', file_path='tie-one.7z',
			tags='[\"language:chinese\",\"other:tankoubon\"]', file_count=10, favorite_count=1, rating_count=1 WHERE gid=101;
		UPDATE galleries SET title='Tie two', thumb='https://example.test/tie-two.jpg',
			tags='[\"language:chinese\",\"other:tankoubon\"]', file_count=10, favorite_count=1, rating_count=1 WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES (101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json) VALUES
		(${group_id},101,'confirmed','automatic','{}'),
		(${group_id},102,'confirmed','automatic','{}');" || return 1
	variants_evaluate_group "${group_id}" >/dev/null || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_id} AND status='pending';")" || return 1
	old_evaluation="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id};")" || return 1

	output="$(variants_reviews_json pending)" || return 1
	jq -e '.reviews[0] | .review_type == "winner" and (.choices | length) == 2 and
		.choices[0].gid == 101 and .choices[0].thumb == "https://example.test/tie-one.jpg" and .choices[0].archive_state == "archived" and
		.choices[1].gid == 102 and .choices[1].thumb == "https://example.test/tie-two.jpg" and .choices[1].archive_state == "not_archived" and
		(.choices[0].variant_score_breakdown.components | type == "object")' <<<"${output}" >/dev/null || return 1

	output="$(variants_resolve_review "${review_id}" winner 102)" || return 1
	jq -e '.resolved == true and .review_type == "winner" and .canonical_gid == 102 and .evaluation_created == true and .reevaluation_queued == false' <<<"${output}" >/dev/null || return 1
	assert_eq "review_blocked|completed|${old_evaluation}|102|-60||resolved|winner|102|102|canonical|1" "$(db_query "SELECT
		(SELECT state FROM variant_evaluations WHERE id=${old_evaluation}),
		new.state,new.supersedes_evaluation_id,new.canonical_gid,
		json_extract(new.member_scores_json,'\$[1].score'),
		json_extract(new.member_scores_json,'\$[1].components.manual_winner_override.points'),
		review.status,review.decision,review.canonical_gid,grouped.canonical_gid,
		(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=102),
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${group_id} AND job_type='reconcile_actions' AND status='queued')
		FROM variant_groups AS grouped
		JOIN variant_evaluations AS new ON new.id=grouped.active_evaluation_id
		JOIN variant_reviews AS review ON review.id=${review_id}
		WHERE grouped.id=${group_id};")" || return 1
	assert_eq '1' "$(db_query "SELECT canonical_decision_id IS NOT NULL FROM variant_evaluations WHERE id=(SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id});")" || return 1
	variants_resolve_review "${review_id}" winner 101 >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}"
}

test_manual_canonical_decision_survives_queued_and_fresh_evaluation() {
	command -v sqlite3 >/dev/null || return 0
	export YOMIKO_REMOTE_WRITES_ENABLED=false
	local group_id review_id old_evaluation job_json output fresh_evaluation
	prepare_variant_runtime_test manual-canonical || return 1
	db_write "UPDATE galleries SET tags='[\"language:chinese\",\"other:tankoubon\"]',
		file_count=10, favorite_count=1, rating_count=1 WHERE gid IN (101,102);
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES (101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
		(${group_id},101,'confirmed','automatic','{}'),
		(${group_id},102,'confirmed','automatic','{}');" || return 1
	variants_evaluate_group "${group_id}" >/dev/null || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_id} AND status='pending';")" || return 1
	old_evaluation="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id};")" || return 1
	db_write "INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('evaluate',${group_id},101,2000,'queued');" || return 1
	assert_eq "${old_evaluation}" "$(db_query "SELECT expected_evaluation_id FROM variant_jobs WHERE group_id=${group_id} AND job_type='evaluate' AND status='queued';")" || return 1

	output="$(variants_resolve_review "${review_id}" winner 102)" || return 1
	jq -e '.resolved == true and .canonical_gid == 102' <<<"${output}" >/dev/null || return 1
	assert_eq 'resolved|winner|102|' "$(db_query "SELECT status,decision,canonical_gid,COALESCE(superseded_at,'') FROM variant_reviews WHERE id=${review_id};")" || return 1
	assert_eq 'active|102|[101,102]' "$(db_query "SELECT status,canonical_gid,member_fingerprint FROM variant_canonical_decisions WHERE group_id=${group_id} AND status='active';")" || return 1
	assert_eq "cancelled|${old_evaluation}|102|102" "$(db_query "SELECT job.status,job.expected_evaluation_id,(SELECT canonical_gid FROM variant_groups WHERE id=${group_id}),(SELECT canonical_gid FROM variant_evaluations WHERE id=(SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id})) FROM variant_jobs AS job WHERE job.group_id=${group_id} AND job.job_type='evaluate';")" || return 1

	# A new evaluation created after the manual decision carries the current
	# generation and must project the durable winner without opening a review.
	db_write "INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('evaluate',${group_id},101,2000,'queued');" || return 1
	job_json="$(variants_worker_claim_job manual-canonical-worker 0)" || return 1
	output="$(variants_worker_handle_evaluate "${job_json}" manual-canonical-worker)" || return 1
	jq -e '.status == "completed" and .result.canonical_gid == 102' <<<"${output}" >/dev/null || return 1
	fresh_evaluation="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id};")" || return 1
	assert_eq '102|none|0|active' "$(db_query "SELECT g.canonical_gid,g.review_state,(SELECT COUNT(*) FROM variant_reviews WHERE group_id=${group_id} AND status='pending'),d.status FROM variant_groups AS g JOIN variant_canonical_decisions AS d ON d.group_id=g.id AND d.status='active' WHERE g.id=${group_id};")" || return 1
	assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_evaluations WHERE group_id=${group_id} AND id=${fresh_evaluation};")" || return 1
	assert_eq "$(db_query "SELECT id FROM variant_canonical_decisions WHERE group_id=${group_id} AND status='active';")" "$(db_query "SELECT canonical_decision_id FROM variant_evaluations WHERE id=${fresh_evaluation};")" || return 1

	# Adding a confirmed member changes the fingerprint and explicitly expires
	# the prior manual decision before normal scoring creates one review.
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_count,favorite_count,rating_count)
		VALUES(103,'token-103','Tie three','[\"language:chinese\",\"other:tankoubon\"]',10,1,1);
		INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},103,'confirmed','automatic','{}');
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('evaluate',${group_id},101,2000,'queued');" || return 1
	job_json="$(variants_worker_claim_job manual-canonical-change-worker 0)" || return 1
	output="$(variants_worker_handle_evaluate "${job_json}" manual-canonical-change-worker)" || return 1
	assert_eq 'superseded|member_set_changed|1' "$(db_query "SELECT d.status,d.supersede_reason,(SELECT COUNT(*) FROM variant_reviews WHERE group_id=${group_id} AND status='pending' AND superseded_at IS NULL) FROM variant_canonical_decisions AS d WHERE d.group_id=${group_id} ORDER BY d.id DESC LIMIT 1;")" || return 1
}

prepare_variant_runtime_test() {
	local name="$1"

	DB_PATH="${TEST_TMPDIR}/variant-runtime-${name}.sqlite3"
	MIGRATIONS_DIR="${TEST_ROOT}/migrations"
	VARIANTS_WORK_LOCK_PATH="${TEST_TMPDIR}/variant-runtime-${name}.lock"
	export DB_PATH MIGRATIONS_DIR VARIANTS_WORK_LOCK_PATH
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES
		(101, 'token-101', 'Source', '[]', 'source.7z'),
		(102, 'token-102', 'Member', '[]', NULL);" || return 1
	if [[ "${name}" == identity-* ]]; then
		db_write "UPDATE galleries
		   SET tags='[\"language:chinese\",\"other:tankoubon\"]',
		       file_count=10, favorite_count=1, rating_count=1
		 WHERE gid IN (101,102);" || return 1
	fi
}

prepare_variant_hath_recovery_test() {
	local name="$1" home_dir="${TEST_TMPDIR}/variant-hath-${1}-home"
	mkdir -p "${home_dir}"
	HOME="${home_dir}"
	export HOME
	# shellcheck disable=SC1091
	source "${TEST_ROOT}/lib/path.sh"
	prepare_variant_runtime_test "${name}" || return 1
	local group_id evaluation_id
	group_id="$(db_write "INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(101,11,1); SELECT last_insert_rowid();")" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES
		(${group_id},101,'confirmed','automatic','{}'),
		(${group_id},102,'confirmed','manual','{}');
		INSERT INTO variant_evaluations(
			group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,canonical_gid)
		SELECT ${group_id},id,'completed','[]','[]',101
		  FROM variant_policy_revisions WHERE is_active=1;
		SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups
		SET canonical_gid=101,active_evaluation_id=${evaluation_id},review_state='none'
		WHERE id=${group_id};" || return 1
}

test_variant_hath_recovery_clears_stale_path_and_obeys_cooldown() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json output trace_path
	prepare_variant_hath_recovery_test due || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	trace_path="${TEST_TMPDIR}/variant-hath-due.trace"
	db_write "UPDATE galleries SET file_path='missing.7z',
		hath_requested_at='2026-08-20T00:00:00Z' WHERE gid=101;
	INSERT INTO variant_actions(group_id,gid,action_type,desired_value,policy_revision_id,
		status,last_error_class,last_error)
	VALUES(${group_id},102,'archive_cleanup','delete',1,'retryable_error',
		'transient','canonical archive is not available');" || return 1
	export YOMIKO_REMOTE_WRITES_ENABLED=true
	export YOMIKO_CANONICAL_FAVORITE_CATEGORY=2
	export YOMIKO_ALTERNATE_FAVORITE_CATEGORY=3
	exh_action_rate() { jq -nc --argjson gid "$1" --arg desired "$3" \
		'{operation:"rating",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'; }
	exh_action_favorite() { jq -nc --argjson gid "$1" --arg desired "$3" \
		'{operation:"favorite",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'; }
	exh_action_hath() {
		printf '%s\n' request >>"${trace_path}"
		jq -nc --argjson gid "$1" \
			'{operation:"hath_request",gid:$gid,desired_value:"request",outcome:"succeeded",mutation_sent:true,message:"fixture"}'
	}
	variants_retention_schedule_recovery >/dev/null || return 1
	assert_eq '' "$(db_query "SELECT COALESCE(file_path,'') FROM galleries WHERE gid=101;")" || return 1
	assert_eq 'superseded' "$(db_query "SELECT status FROM variant_actions WHERE action_type='archive_cleanup';")" || return 1
	assert_eq '2026-08-20T00:00:00Z' "$(db_query 'SELECT hath_requested_at FROM galleries WHERE gid=101;')" || return 1
	claim_json="$(variants_worker_claim_job hath-due-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" hath-due-worker 25)" || return 1
	jq -e '.status=="completed" and .remote_mutations==5' <<<"${output}" >/dev/null || return 1
	assert_eq '1' "$(wc -l <"${trace_path}")" || return 1
	assert_eq '1|1' "$(db_query "SELECT
		(hath_last_attempted_at IS NOT NULL),
		(hath_requested_at IS NOT NULL) FROM galleries WHERE gid=101;")" || return 1
	variants_retention_schedule_recovery >/dev/null || return 1
	assert_eq 'pending|43200' "$(db_query "SELECT action.status,
		CAST(strftime('%s',action.available_at)-strftime('%s',gallery.hath_last_attempted_at) AS INTEGER)
		FROM variant_actions AS action JOIN galleries AS gallery ON gallery.gid=action.gid
		WHERE action.action_type='hath_request' AND action.gid=101;")" || return 1
}

test_variant_hath_tree_suppresses_request_without_completion_marker() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json output trace_path
	prepare_variant_hath_recovery_test tree || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	trace_path="${TEST_TMPDIR}/variant-hath-tree.trace"
	mkdir -p "${HATH_DOWNLOAD_DIR}/nested/[artist] active [101]"
	db_write "UPDATE galleries SET file_path='missing.7z' WHERE gid=101;" || return 1
	export YOMIKO_REMOTE_WRITES_ENABLED=true
	export YOMIKO_CANONICAL_FAVORITE_CATEGORY=2
	export YOMIKO_ALTERNATE_FAVORITE_CATEGORY=3
	exh_action_rate() { jq -nc --argjson gid "$1" --arg desired "$3" \
		'{operation:"rating",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'; }
	exh_action_favorite() { jq -nc --argjson gid "$1" --arg desired "$3" \
		'{operation:"favorite",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'; }
	exh_action_hath() {
		printf '%s\n' request >>"${trace_path}"
		jq -nc --argjson gid "$1" \
			'{operation:"hath_request",gid:$gid,desired_value:"request",outcome:"succeeded",mutation_sent:true,message:"fixture"}'
	}
	variants_retention_schedule_recovery >/dev/null || return 1
	assert_eq 'hath_tree_present' "$(variants_retention_recover_group "${group_id}" | jq -r '.state')" || return 1
	claim_json="$(variants_worker_claim_job hath-tree-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" hath-tree-worker 25)" || return 1
	jq -e '.status=="completed" and .remote_mutations==4' <<<"${output}" >/dev/null || return 1
	[[ ! -e "${trace_path}" ]] || fail 'H@H adapter ran while a Hath-tree directory existed' || return 1
	assert_eq 'succeeded|hath_tree_present' "$(db_query "SELECT status,
		json_extract(result_json,'$.preflight_reason') FROM variant_actions
		WHERE action_type='hath_request' AND gid=101;")"
}

test_variant_retention_uses_bounded_archive_projection_and_rechecks_after_lock() {
	command -v sqlite3 >/dev/null || return 0
	local home_dir="${TEST_TMPDIR}/variant-retention-bounded-home"
	local snapshot expected trace_path output
	mkdir -p "${home_dir}"
	HOME="${home_dir}"
	export HOME
	# shellcheck disable=SC1091
	source "${TEST_ROOT}/lib/path.sh"
	prepare_variant_runtime_test retention-bounded || return 1

	printf direct >"${ARCHIVED_DIR}/direct.7z"
	printf predecessor >"${ARCHIVED_DIR}/predecessor.7z"
	printf blocked >"${ARCHIVED_DIR}/blocked.7z"
	mkdir -p "${ARCHIVED_DIR}/nonregular.7z"
	db_write "INSERT INTO galleries(
		gid,token,title,file_count,tags,file_path,current_gid,current_token,
		parent_gid,parent_token,favorite_count,rating_count)
		VALUES
			(201,'token-201','Direct',10,
			 '[\"language:chinese\",\"other:tankoubon\"]','direct.7z',NULL,NULL,
			 NULL,NULL,1,1),
			(202,'token-202','Predecessor',10,
			 '[\"language:chinese\",\"other:tankoubon\"]','predecessor.7z',203,
			 'token-203',NULL,NULL,1,1),
			(203,'token-203','Terminal',11,
			 '[\"language:chinese\",\"other:tankoubon\"]',NULL,NULL,NULL,202,
			 'token-202',1,1),
			(204,'token-204','Blocked',10,
			 '[\"language:chinese\",\"other:tankoubon\"]','blocked.7z',205,
			 'missing-token',NULL,NULL,1,1),
			(206,'token-206','Missing',10,
			 '[\"language:chinese\",\"other:tankoubon\"]',NULL,NULL,NULL,NULL,
			 NULL,1,1),
			(207,'token-207','Unsafe',10,
			 '[\"language:chinese\",\"other:tankoubon\"]','../unsafe.7z',NULL,NULL,
			 NULL,NULL,1,1),
			(208,'token-208','Non regular',10,
			 '[\"language:chinese\",\"other:tankoubon\"]','nonregular.7z',NULL,NULL,
			 NULL,NULL,1,1);
		INSERT INTO variant_groups(
			id,source_gid,desired_rating,is_active,identity_active,canonical_gid)
		VALUES
			(201,201,11,1,1,NULL),(202,203,11,1,1,NULL),
			(204,204,11,1,1,NULL),(206,206,11,1,1,NULL),
			(207,207,11,1,1,NULL),(208,208,11,1,1,NULL);
		INSERT INTO gallery_variants(
			group_id,gid,membership_state,decision_source,evidence_json,variant_state)
		VALUES
			(201,201,'confirmed','manual','{}','canonical'),
			(202,203,'confirmed','manual','{}','canonical'),
			(204,204,'confirmed','manual','{}','canonical'),
			(206,206,'confirmed','manual','{}','canonical'),
			(207,207,'confirmed','manual','{}','canonical'),
			(208,208,'confirmed','manual','{}','canonical');
		UPDATE variant_groups SET canonical_gid=source_gid
		 WHERE id IN (201,202,204,206,207,208);
		INSERT INTO variant_evaluations(
			group_id,policy_revision_id,state,metadata_snapshot_json,
			member_scores_json,canonical_gid)
		SELECT grouped.id,policy.id,'completed','{}','{}',grouped.canonical_gid
		  FROM variant_groups AS grouped
		  JOIN variant_policy_revisions AS policy ON policy.is_active=1
		 WHERE grouped.id IN (201,202,204,206,207,208);
		UPDATE variant_groups
		   SET active_evaluation_id=(SELECT MAX(evaluation.id)
		                              FROM variant_evaluations AS evaluation
		                             WHERE evaluation.group_id=variant_groups.id)
		 WHERE id IN (201,202,204,206,207,208);" || return 1

	snapshot="$(variants_retention_archive_source_snapshot $'201\n202\n204\n206\n207\n208')" || return 1
	expected=$'201\t201\t201\tdirect.7z\n202\t203\t202\tpredecessor.7z\n204\t204\t204\tblocked.7z\n206\t206\t\t\n207\t207\t207\t../unsafe.7z\n208\t208\t208\tnonregular.7z'
	assert_eq "${expected}" "${snapshot}" || return 1

	# The first snapshot is only a lock target.  Change the recorded path after
	# it returns; the post-lock snapshot must observe the replacement path.
	trace_path="${TEST_TMPDIR}/variant-retention-bounded.trace"
	: >"${trace_path}"
	eval "$(declare -f variants_retention_archive_source_snapshot |
		sed 's/^variants_retention_archive_source_snapshot /test_variants_retention_archive_source_snapshot_original /')"
	variants_retention_archive_source_snapshot() {
		local call_no result
		call_no="$(wc -l <"${trace_path}")"
		call_no=$((call_no + 1))
		printf '%s\n' "${call_no}" >>"${trace_path}"
		result="$(test_variants_retention_archive_source_snapshot_original "$@")" || return
		if [[ "${call_no}" -eq 1 ]]; then
			printf rechecked >"${ARCHIVED_DIR}/rechecked.7z"
			db_write "UPDATE galleries SET file_path='rechecked.7z' WHERE gid=201;" || return
		fi
		printf '%s\n' "${result}"
	}
	output="$(variants_retention_recover_group 201)" || return 1
	assert_eq '2' "$(wc -l <"${trace_path}")" || return 1
	jq -e '.state == "canonical_archive_present" and .file_path == "rechecked.7z"' \
		<<<"${output}" >/dev/null || return 1

	assert_eq 'canonical_archive_present' \
		"$(variants_retention_recover_group 204 | jq -r '.state')" || return 1
	assert_eq 'hath_request_due' \
		"$(variants_retention_recover_group 202 | jq -r '.state')" || return 1
	assert_eq 'hath_request_due' \
		"$(variants_retention_recover_group 206 | jq -r '.state')" || return 1
	assert_eq 'unsafe_or_non_regular_archive_path' \
		"$(variants_retention_recover_group 207 | jq -r '.state')" || return 1
	assert_eq 'unsafe_or_non_regular_archive_path' \
		"$(variants_retention_recover_group 208 | jq -r '.state')" || return 1
	assert_eq 'predecessor.7z' \
		"$(db_query "SELECT file_path FROM galleries WHERE gid=202;")" || return 1
}

test_variant_enqueue_is_atomic_idempotent_and_reopens_only_superseded_actions() {
	command -v sqlite3 >/dev/null || return 0
	local group_id
	prepare_variant_runtime_test enqueue || return 1

	group_id="$(variants_enqueue_feedback 101 11)" || return 1
	assert_eq "${group_id}" "$(variants_enqueue_feedback 101 11)" || return 1
	assert_eq '1|1|10|pending' "$(db_query "SELECT
		(SELECT COUNT(*) FROM variant_groups),
		(SELECT COUNT(*) FROM variant_jobs WHERE job_type = 'discover' AND status = 'queued'),
		desired_value, status FROM variant_actions WHERE action_type = 'rating';")" || return 1

	db_write "UPDATE variant_actions SET status = 'succeeded', completed_at = '2026-01-01T00:00:00Z';" || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1
	assert_eq 'succeeded|2026-01-01T00:00:00Z' "$(db_query "SELECT status, completed_at FROM variant_actions WHERE desired_value = '10';")" || return 1
	variants_enqueue_feedback 101 8 >/dev/null || return 1
	assert_eq 'superseded|1' "$(db_query "SELECT status,completed_at IS NOT NULL FROM variant_actions WHERE desired_value = '10';")" || return 1
	assert_eq 'superseded|pending' "$(db_query "SELECT (SELECT status FROM variant_actions WHERE desired_value = '10'), (SELECT status FROM variant_actions WHERE desired_value = '8');")" || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1
	assert_eq 'pending||superseded' "$(db_query "SELECT status || '|' || COALESCE(completed_at, '') || '|' || (SELECT status FROM variant_actions WHERE desired_value = '8') FROM variant_actions WHERE desired_value = '10';")"
}

test_variant_enqueue_reuses_inactive_confirmed_member_group() {
	command -v sqlite3 >/dev/null || return 0
	local group_id
	prepare_variant_runtime_test reuse || return 1
	group_id="$(variants_enqueue_feedback 101 9)" || return 1
	db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES (${group_id}, 102, 'confirmed', 'manual', '{}'); UPDATE variant_groups SET is_active = 0 WHERE id = ${group_id};" || return 1

	assert_eq "${group_id}" "$(variants_enqueue_feedback 102 11)" || return 1
	assert_eq '1|1|11|10' "$(db_query "SELECT COUNT(*), is_active, desired_rating, (SELECT desired_value FROM variant_actions WHERE gid = 102) FROM variant_groups;")"
}

test_variant_identity_confirmation_projects_rating_before_actions() {
	command -v sqlite3 >/dev/null || return 0
	local group_id review_id output home_dir
	home_dir="${TEST_TMPDIR}/variant-runtime-identity-rating-projection-home"
	HOME="${home_dir}"
	DB_PATH="${HOME}/data/db.sqlite3"
	MIGRATIONS_DIR="${TEST_ROOT}/migrations"
	VARIANTS_WORK_LOCK_PATH="${TEST_TMPDIR}/variant-runtime-identity-rating-projection.lock"
	export HOME DB_PATH MIGRATIONS_DIR VARIANTS_WORK_LOCK_PATH
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, file_path, file_count, favorite_count, rating_count) VALUES
		(101, 'token-101', 'Source', '[\"language:chinese\",\"other:tankoubon\"]', 'source.7z', 10, 1, 1),
		(102, 'token-102', 'Member', '[\"language:chinese\",\"other:tankoubon\"]', NULL, 10, 1, 1);" || return 1
	group_id="$(variants_enqueue_feedback 101 9)" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,
		evidence_json)
		VALUES(${group_id},102,'candidate','automatic',50,'{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json)
		SELECT 'candidate_identity',${group_id},102,id,${VARIANTS_MATCHING_REVISION},
		       '{}','[101,102]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_id};")" || return 1

	variants_resolve_review "${review_id}" same-book >/dev/null || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102)" || return 1
	assert_eq 'rated_non_11' "$(jq -r '.[0].state' <<<"${output}")" || return 1
	assert_eq '9|0' "$(db_query "SELECT
		(SELECT self_rating FROM galleries WHERE gid=102),
		(SELECT COUNT(*) FROM variant_actions
		  WHERE gid=102 AND action_type='rating' AND status<>'superseded');")"
}

test_userscript_local_state_projection_preserves_identity_and_watermarks() {
	command -v sqlite3 >/dev/null || return 0
	local group_id output api_output api_json cli_json home_dir
	home_dir="${TEST_TMPDIR}/userscript-local-state-home"
	HOME="${home_dir}"
	DB_PATH="${HOME}/data/db.sqlite3"
	MIGRATIONS_DIR="${TEST_ROOT}/migrations"
	VARIANTS_WORK_LOCK_PATH="${TEST_TMPDIR}/variant-runtime-userscript-local-state.lock"
	ARCHIVED_DIR="${home_dir}/archived"
	export HOME DB_PATH MIGRATIONS_DIR VARIANTS_WORK_LOCK_PATH ARCHIVED_DIR
	mkdir -p "${ARCHIVED_DIR}"
	printf source >"${ARCHIVED_DIR}/source.7z"
	printf ungrouped >"${ARCHIVED_DIR}/ungrouped.7z"
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, file_path, file_count, favorite_count, rating_count) VALUES
		(101, 'token-101', 'Source', '[\"language:chinese\",\"other:tankoubon\"]', 'source.7z', 10, 1, 1),
		(102, 'token-102', 'Member', '[\"language:chinese\",\"other:tankoubon\"]', NULL, 10, 1, 1),
		(201, 'token-201', 'Ungrouped archive', '[]', 'ungrouped.7z', NULL, NULL, NULL),
		(202, 'token-202', 'Ungrouped request', '[]', NULL, NULL, NULL, NULL);
		UPDATE galleries SET hath_last_attempted_at='2026-09-17T00:00:00Z',
			hath_requested_at='2026-09-17T00:00:01Z' WHERE gid=202;" || return 1

	group_id="$(variants_enqueue_feedback 101 5)" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},102,'confirmed','manual','{}');
		UPDATE galleries SET file_path='source.7z',self_rating=5,
			rated_then_deleted_at=NULL,hath_last_attempted_at=NULL,
			hath_requested_at=NULL WHERE gid=101;
		UPDATE galleries SET file_path=NULL,self_rating=0,
			rated_then_deleted_at=NULL,hath_last_attempted_at=NULL,
			hath_requested_at=NULL WHERE gid=102;" || return 1

	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102 101 999 201 202 102)" || return 1
	jq -e '
		length == 6 and
		.[0].gid == 102 and .[0].state == "downloaded_unrated" and
		.[0].self_rating == 0 and .[0].local_state_relation == "same_book" and
		.[0].local_state_gid == 101 and .[0].evidence_kind == "committed_archive" and
		.[1].gid == 101 and .[1].state == "rated_non_11" and
		.[1].self_rating == 5 and .[1].local_state_relation == "exact" and
		.[2].state == "unknown" and .[2].self_rating == null and
		.[2].local_state_relation == null and
		.[3].gid == 201 and .[3].state == "downloaded_unrated" and
		.[3].acquisition_state == "downloaded" and
		.[3].local_state_relation == "exact" and
		.[3].local_state_gid == 201 and .[3].evidence_kind == "committed_archive" and
		.[4].gid == 202 and .[4].state == "hath_requested" and
		.[4].acquisition_state == "hath_requested" and
		.[4].local_state_relation == "exact" and
		.[4].local_state_gid == 202 and .[4].evidence_kind == "accepted_request" and
		.[5].gid == 102 and .[5].state == "downloaded_unrated"
	' <<<"${output}" >/dev/null || return 1

	# Requests remain exact-GID evidence even inside a confirmed identity class.
	db_write "UPDATE galleries SET file_path=NULL,
		hath_last_attempted_at='2026-09-17T01:00:00Z',
		hath_requested_at='2026-09-17T01:00:01Z' WHERE gid=101;" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102)" || return 1
	jq -e '.[0].state == "no_local_state" and
		.[0].acquisition_state == null and .[0].local_state_relation == null and
		.[0].local_state_gid == null and .[0].evidence_kind == null' \
		<<<"${output}" >/dev/null || return 1
	db_write "UPDATE galleries SET file_path='source.7z',
		hath_last_attempted_at=NULL,hath_requested_at=NULL WHERE gid=101;" || return 1

	# A strictly newer exact attempt wins over related archive evidence; equality
	# with deletion returns to the exact rating branch instead.
	db_write "UPDATE galleries SET self_rating=5,
		rated_then_deleted_at='2026-09-16T00:00:00Z',
		hath_last_attempted_at='2026-09-17T00:00:00Z',
		hath_requested_at=NULL WHERE gid=102;" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102)" || return 1
	jq -e '.[0].state == "hath_requested" and .[0].self_rating == 5 and
		.[0].local_state_relation == "exact" and
		.[0].evidence_kind == "authorized_attempt"' <<<"${output}" >/dev/null || return 1

	db_write "UPDATE galleries SET rated_then_deleted_at='2026-09-17T00:00:00Z',
		hath_requested_at='2026-09-17T00:00:00Z' WHERE gid=102;" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102)" || return 1
	jq -e '.[0].state == "rated_non_11" and .[0].self_rating == 5 and
		.[0].local_state_relation == "same_book"' <<<"${output}" >/dev/null || return 1

	# Rating 11 is the only current canonical-selection state.
	db_write "UPDATE variant_groups SET desired_rating=11,is_active=1,
		canonical_gid=101 WHERE id=${group_id};
		UPDATE galleries SET self_rating=11,file_path='source.7z' WHERE gid=101;
		UPDATE galleries SET self_rating=11,file_path=NULL WHERE gid=102;" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102 101)" || return 1
	jq -e '.[0].state == "rated_11_alternate" and .[0].self_rating == 11 and
		.[1].state == "rated_11_canonical" and .[1].self_rating == 11' <<<"${output}" >/dev/null || return 1

	# Replacement requests belong to the selected winner; the displaced member
	# remains an alternate even while its old archive is still present.
	db_write "UPDATE variant_groups SET canonical_gid=102 WHERE id=${group_id};
		UPDATE galleries SET hath_last_attempted_at='2026-09-17T02:00:00Z',
			hath_requested_at='2026-09-17T02:00:01Z' WHERE gid=102;" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102 101)" || return 1
	jq -e '.[0].state == "hath_requested" and
		.[0].local_state_relation == "exact" and .[0].local_state_gid == 102 and
		.[0].evidence_kind == "accepted_request" and
		.[1].state == "rated_11_alternate"' <<<"${output}" >/dev/null || return 1

	assert_eq '1|1|1|5' "$(db_query "SELECT
		(SELECT identity_active FROM variant_groups WHERE id=${group_id}),
		(SELECT is_active FROM variant_groups WHERE id=${group_id}),
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${group_id} AND job_type='discover' AND status='queued'),
		(SELECT desired_value FROM variant_actions WHERE group_id=${group_id} AND gid=101 AND action_type='rating' AND status <> 'superseded');")" || return 1

	cli_json="$(bash "${TEST_ROOT}/bin/yomiko" gallery-status 102 101 999 201 202 102)" || return 1
	api_output="$(QUERY_STRING='gids=102,101,999,201,202,102' REQUEST_METHOD=GET \
		YOMIKO_BIN="${TEST_ROOT}/bin/yomiko" bash "${TEST_ROOT}/web/api/galleries.sh")" || return 1
	api_json="$(sed -n '/^{/,$p' <<<"${api_output}")" || return 1
	assert_eq '2' "$(jq -r '.projection_version' <<<"${api_json}")" || return 1
	assert_eq "$(jq -S . <<<"${cli_json}")" "$(jq -S '.galleries' <<<"${api_json}")" || return 1
}

test_gallery_status_uses_request_bounded_revision_projection() {
	local command_body
	command_body="$(awk '/^cmd_gallery_status\(\)/ {capture=1} capture {print} /^# yomiko favorite/ {exit}' "${TEST_ROOT}/bin/yomiko")" || return 1
	assert_contains "${command_body}" 'variants_revision_projection_sql status' || return 1
	assert_not_contains "${command_body}" 'current_revision_projection' || return 1
	assert_not_contains "${command_body}" 'archive_source_galleries' || return 1
	assert_contains "${command_body}" 'FROM revision_projection AS revision_projection' || return 1
	assert_contains "${command_body}" 'JOIN archive_source' || return 1
}

test_metrics_uses_request_local_revision_snapshot() {
	local metrics_body
	metrics_body="$(<"${TEST_ROOT}/lib/metrics.sh")" || return 1
	assert_contains "${metrics_body}" 'metrics_request_snapshot_sql' || return 1
	assert_contains "${metrics_body}" 'variants_revision_projection_sql status' || return 1
	assert_contains "${metrics_body}" 'metrics_ready_revision_terminals' || return 1
	assert_contains "${metrics_body}" 'metrics_identity_active_membership' || return 1
	assert_not_contains "${metrics_body}" 'current_revision_projection' || return 1
	assert_not_contains "${metrics_body}" 'scoreable_revision_terminals' || return 1
	assert_not_contains "${metrics_body}" 'variant_identity_actionable_review' || return 1
	assert_not_contains "${metrics_body}" 'variant_identity_review_visibility' || return 1
	assert_not_contains "${metrics_body}" 'variant_identity_group_review_state' || return 1
	assert_not_contains "${metrics_body}" 'yomiko_variant_actionable_reviews' || return 1
	assert_not_contains "${metrics_body}" 'review_state_mismatch' || return 1
}

test_variant_list_uses_request_bounded_revision_projection() {
	local command_body resolver_body
	command_body="$(awk '/^variants_list_json\(\)/ {capture=1} capture {print} /^# Public evaluation/ {exit}' "${TEST_ROOT}/lib/variants.sh")" || return 1
	resolver_body="$(awk '/^variants_list_resolve_gid\(\)/ {capture=1} capture {print} /^}/ {if (capture) {print; exit}}' "${TEST_ROOT}/lib/variants.sh")" || return 1
	assert_contains "${command_body}" 'variants_revision_projection_sql list' || return 1
	assert_contains "${command_body}" 'list_revision_projection' || return 1
	assert_contains "${command_body}" 'list_scoreable_revision_terminals' || return 1
	assert_contains "${command_body}" 'list_variant_jobs' || return 1
	assert_contains "${command_body}" 'list_variant_reviews' || return 1
	assert_contains "${command_body}" 'list_variant_actions' || return 1
	assert_not_contains "${command_body}" 'current_revision_projection' || return 1
	assert_not_contains "${command_body}" 'CREATE TEMP VIEW scoreable_revision_terminals AS' || return 1
	assert_not_contains "${command_body}" 'FROM scoreable_revision_terminals AS' || return 1
	assert_not_contains "${command_body}" 'archive_source_galleries' || return 1
	assert_contains "${resolver_body}" 'variants_revision_projection_sql list' || return 1
	assert_not_contains "${resolver_body}" 'current_revision_projection' || return 1
}

test_variant_ungroup_reseeds_members_and_rebuilds_remainder() {
	command -v sqlite3 >/dev/null || return 0
	local group_id unrelated_group ungroup_json replacement_id source_group_id
	prepare_variant_runtime_test ungroup || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,self_rating,feedbacked_at) VALUES
		(103,'token-103','Third','[]',11,'2026-01-01T00:00:00Z'),
		(104,'token-104','Outside','[]',0,NULL);
		UPDATE galleries SET self_rating=11,feedbacked_at='2026-01-01T00:00:00Z'
		WHERE gid=101;
		UPDATE galleries SET self_rating=0,
			feedbacked_at='2026-01-02T03:04:05.678901+08:00',
			updated_at='2026-01-03T04:05:06.789012+08:00',
			file_path='member.7z'
		WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating,latest_feedback_at)
		VALUES(101,11,'2026-01-01T00:00:00Z');" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,
		variant_state)
		VALUES
		(${group_id},101,'confirmed','automatic','{}','alternate'),
		(${group_id},102,'confirmed','manual','{}','alternate'),
		(${group_id},103,'confirmed','automatic','{}','canonical');
		UPDATE variant_groups SET canonical_gid=103 WHERE id=${group_id};
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${group_id},102,id,1,'{\"reset\":true}','[101,102]',
		       'resolved','same_book','2026-01-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
		SELECT 101,102,id FROM variant_reviews WHERE group_id=${group_id} AND candidate_gid=102;
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority)
		VALUES('discover',${group_id},101,100);
		INSERT INTO variant_actions(group_id,gid,action_type,desired_value,policy_revision_id)
		SELECT ${group_id},102,'favorite_remove','favdel',id
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(104,8,0);" || return 1
	unrelated_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=104;')" || return 1
	db_write "INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${unrelated_group},103,id,1,'{\"keep\":true}','[104,103]',
		       'resolved','different_book','2026-01-02T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
		SELECT 103,104,id FROM variant_reviews WHERE group_id=${unrelated_group};" || return 1

	ungroup_json="$(cmd_variants ungroup 102 --force)" || return 1
	jq -e '.ungrouped == true and .gids == [102] and .pairs_deleted == 1 and
		.reviews_deleted == 1 and .memberships_deleted == 1 and
		.replacement_groups == 1 and .source_groups == 1 and
		.rediscovery_queued == 2' <<<"${ungroup_json}" >/dev/null || return 1
	replacement_id="$(db_query "SELECT id FROM variant_groups WHERE is_active=1 AND source_gid=101;")" || return 1
	source_group_id="$(db_query "SELECT id FROM variant_groups WHERE is_active=1 AND source_gid=102;")" || return 1
	assert_eq '101|11|none|2|101,103|queued|0|2026-01-02T03:04:05.678901+08:00|2026-01-03T04:05:06.789012+08:00|1|0|1|superseded|cancelled' "$(db_query "SELECT
		grouped.source_gid,grouped.desired_rating,grouped.review_state,
		(SELECT count(*) FROM gallery_variants WHERE group_id=grouped.id),
		(SELECT group_concat(gid,',') FROM (SELECT gid FROM gallery_variants
		  WHERE group_id=grouped.id ORDER BY gid)),
		(SELECT status FROM variant_jobs WHERE group_id=grouped.id AND job_type='discover'),
		(SELECT self_rating FROM galleries WHERE gid=102),
		(SELECT COALESCE(feedbacked_at,'') FROM galleries WHERE gid=102),
		(SELECT updated_at FROM galleries WHERE gid=102),
		(SELECT count(*) FROM gallery_variants WHERE gid=102),
		(SELECT count(*) FROM galleries WHERE gid=102
		  AND length(COALESCE(file_path,'')) > 0
		  AND COALESCE(feedbacked_at,'') = ''
		  AND COALESCE(self_rating,0) = 0),
		(SELECT count(*) FROM gallery_identity_pairs WHERE low_gid=103 AND high_gid=104),
		(SELECT status FROM variant_actions WHERE group_id=${group_id}),
		(SELECT status FROM variant_jobs WHERE group_id=${group_id})
		FROM variant_groups AS grouped WHERE grouped.id=${replacement_id};")" || return 1
	assert_eq '102|11|1|102|automatic|ungroup_source|discover|queued|0' "$(db_query "SELECT
		grouped.source_gid,grouped.desired_rating,grouped.is_active,member.gid,
		member.decision_source,json_extract(member.evidence_json,'$.kind'),
		job.job_type,job.status,
		(SELECT count(*) FROM variant_actions WHERE group_id=grouped.id)
		FROM variant_groups AS grouped
		JOIN gallery_variants AS member ON member.group_id=grouped.id
		JOIN variant_jobs AS job ON job.group_id=grouped.id
		WHERE grouped.id=${source_group_id};")" || return 1
	assert_eq '1|0|ok|0' "$(db_query "SELECT
		(SELECT count(*) FROM variant_reviews WHERE json_extract(evidence_json,'$.keep')=1),
		(SELECT count(*) FROM variant_reviews WHERE json_extract(evidence_json,'$.reset')=1),
		(SELECT integrity_check FROM pragma_integrity_check),
		(SELECT count(*) FROM pragma_foreign_key_check);")"

	prepare_variant_runtime_test ungroup-multiple || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,self_rating,feedbacked_at)
		VALUES(103,'token-103','Third','[]',11,'2026-01-01T00:00:00Z');
		UPDATE galleries SET self_rating=8,
			feedbacked_at='2026-02-01T01:02:03.111111Z',
			updated_at='2026-02-02T02:03:04.111111Z' WHERE gid=101;
		UPDATE galleries SET self_rating=10,
			feedbacked_at='2026-03-01T04:05:06.222222+08:00',
			updated_at='2026-03-02T05:06:07.222222+08:00' WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'confirmed','manual','{}'),
		      (${group_id},103,'confirmed','manual','{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${group_id},102,id,2,'{}','[101,102]',
		       'resolved','same_book','2026-01-01T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
		evidence_json,choices_json,status,decision,resolved_at)
		SELECT 'candidate_identity',${group_id},103,id,2,'{}','[101,103]',
		       'resolved','same_book','2026-01-02T00:00:00Z'
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
		SELECT 101,candidate_gid,id FROM variant_reviews WHERE group_id=${group_id};" || return 1
	ungroup_json="$(cmd_variants ungroup 101 102 --force)" || return 1
	jq -e '.ungrouped == true and .gids == [101,102] and .pairs_deleted == 2 and
		.reviews_deleted == 2 and .memberships_deleted == 2 and
		.replacement_groups == 1 and .source_groups == 2 and
		.rediscovery_queued == 3' <<<"${ungroup_json}" >/dev/null || return 1
	assert_eq '103|103|2|0|0|8@2026-02-01T01:02:03.111111Z@2026-02-02T02:03:04.111111Z|10@2026-03-01T04:05:06.222222+08:00@2026-03-02T05:06:07.222222+08:00|ok|0' "$(db_query "SELECT
		grouped.source_gid,(SELECT gid FROM gallery_variants WHERE group_id=grouped.id),
		(SELECT count(*) FROM gallery_variants WHERE gid IN (101,102)),
		(SELECT count(*) FROM gallery_identity_pairs),
		(SELECT count(*) FROM variant_reviews WHERE review_type='candidate_identity'),
		(SELECT self_rating || '@' || feedbacked_at || '@' || updated_at
		   FROM galleries WHERE gid=101),
		(SELECT self_rating || '@' || feedbacked_at || '@' || updated_at
		   FROM galleries WHERE gid=102),
		(SELECT integrity_check FROM pragma_integrity_check),
		(SELECT count(*) FROM pragma_foreign_key_check)
		FROM variant_groups AS grouped
		WHERE grouped.is_active=1 AND grouped.source_gid=103;")" || return 1
	assert_eq '2|101,102|11,11|2|2|0' "$(db_query "SELECT
		count(*),group_concat(source_gid,','),group_concat(desired_rating,','),
		(SELECT count(*) FROM gallery_variants AS member
		  JOIN variant_groups AS active ON active.id=member.group_id
		  WHERE active.is_active=1 AND member.gid IN (101,102)),
		(SELECT count(*) FROM variant_jobs AS job
		  JOIN variant_groups AS active ON active.id=job.group_id
		  WHERE active.is_active=1 AND active.source_gid IN (101,102)
		    AND job.job_type='discover' AND job.status='queued'),
		(SELECT count(*) FROM variant_actions AS action
		  JOIN variant_groups AS active ON active.id=action.group_id
		  WHERE active.is_active=1 AND active.source_gid IN (101,102))
		FROM (SELECT source_gid,desired_rating FROM variant_groups
		  WHERE is_active=1 AND source_gid IN (101,102) ORDER BY source_gid);")"

	prepare_variant_runtime_test ungroup-all || return 1
	db_write "UPDATE galleries SET self_rating=8,
		feedbacked_at='2026-04-01T01:02:03.333333Z',
		updated_at='2026-04-02T02:03:04.333333Z' WHERE gid=101;
		UPDATE galleries SET self_rating=11,
		feedbacked_at='2026-05-01T04:05:06.444444+08:00',
		updated_at='2026-05-02T05:06:07.444444+08:00',
		file_path='member.7z' WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'confirmed','manual','{}');" || return 1
	ungroup_json="$(cmd_variants ungroup 101 102 --force)" || return 1
	jq -e '.ungrouped == true and .replacement_groups == 0 and
		.source_groups == 2 and .rediscovery_queued == 2 and
		.memberships_deleted == 2' <<<"${ungroup_json}" >/dev/null || return 1
	assert_eq '2|1|2|2|0|8@2026-04-01T01:02:03.333333Z@2026-04-02T02:03:04.333333Z|11@2026-05-01T04:05:06.444444+08:00@2026-05-02T05:06:07.444444+08:00|0|ok|0' "$(db_query "SELECT
		(SELECT count(*) FROM variant_groups WHERE is_active=1),
		(SELECT count(*) FROM variant_groups WHERE is_active=0),
		(SELECT count(*) FROM gallery_variants WHERE gid IN (101,102)),
		(SELECT count(*) FROM variant_jobs WHERE status='queued'),
		(SELECT count(*) FROM variant_actions),
		(SELECT self_rating || '@' || feedbacked_at || '@' || updated_at
		   FROM galleries WHERE gid=101),
		(SELECT self_rating || '@' || feedbacked_at || '@' || updated_at
		   FROM galleries WHERE gid=102),
		(SELECT count(*) FROM galleries
		  WHERE gid IN (101,102) AND length(COALESCE(file_path,'')) > 0
		    AND COALESCE(feedbacked_at,'') = ''
		    AND COALESCE(self_rating,0) = 0),
		(SELECT integrity_check FROM pragma_integrity_check),
		(SELECT count(*) FROM pragma_foreign_key_check);")"
	assert_eq '2|101,102|11,11|2|0|ok|0' "$(db_query "SELECT
		count(*),group_concat(source_gid,','),group_concat(desired_rating,','),
		(SELECT count(*) FROM variant_jobs AS job
		  JOIN variant_groups AS active ON active.id=job.group_id
		  WHERE active.is_active=1 AND job.job_type='discover' AND job.status='queued'),
		(SELECT count(*) FROM variant_actions AS action
		  JOIN variant_groups AS active ON active.id=action.group_id
		  WHERE active.is_active=1),
		(SELECT integrity_check FROM pragma_integrity_check),
		(SELECT count(*) FROM pragma_foreign_key_check)
		FROM (SELECT source_gid,desired_rating FROM variant_groups
		  WHERE is_active=1 ORDER BY source_gid);")"
}

test_variant_list_and_work_emit_json_without_consuming_jobs() {
	command -v sqlite3 >/dev/null || return 0
	local enqueue_json list_json score_json work_json locked_json lock_fd evaluation_id
	prepare_variant_runtime_test list-work || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1

	list_json="$(variants_list_json 101 queued)" || return 1
	jq -e '.groups | length == 1 and (.[0] | has("id") | not) and .[0].members[0].gid == 101 and .[0].jobs[0].status == "queued" and .[0].actions[0].desired_value == "10"' <<<"${list_json}" >/dev/null || return 1
	evaluation_id="$(db_write "INSERT INTO variant_evaluations(
		group_id,policy_revision_id,state,metadata_snapshot_json,member_scores_json,canonical_gid)
	SELECT 1,id,'completed','[]','[{\"gid\":101,\"score\":10}]',101
	  FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups
		SET active_evaluation_id=${evaluation_id},canonical_gid=101
		WHERE id=1;" || return 1
	score_json="$(variants_list_json 101)" || return 1
	jq -e '.groups[0].members[0].variant_score_breakdown.gid == 101 and
		(.groups[0].members[0].variant_score_breakdown | type) == "object"' <<<"${score_json}" >/dev/null || return 1
	export YOMIKO_CLI_IN_API_MODE=1
	enqueue_json="$(cmd_variants enqueue 101)" || return 1
	jq -e 'keys == ["variant_queued"] and .variant_queued == true' <<<"${enqueue_json}" >/dev/null || return 1
	[[ ! -e "${VARIANTS_WORK_LOCK_PATH}" ]] || return 1
	work_json="$(variants_work --max-jobs 1 --dry-run)" || return 1
	jq -e '.locked == false and .dry_run == true and (.jobs | length == 1)
	  and .jobs[0].status == "queued" and (.jobs[0] | has("id") | not)
	  and (.jobs[0] | has("group_id") | not)
	  and .budgets.remote_mutations.limit == 25
	  and .budgets.local_cleanups.limit == null
	  and (.preflight | type == "array") and (.errors | type == "array")
	  and (.continuation.may_have_more_jobs | type == "boolean")' <<<"${work_json}" >/dev/null || return 1
	[[ ! -e "${VARIANTS_WORK_LOCK_PATH}" ]] || return 1
	assert_eq 'queued|0' "$(db_query 'SELECT status, attempt_count FROM variant_jobs;')" || return 1
	exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
	flock -n "${lock_fd}" || return 1
	locked_json="$(variants_work --max-jobs=1)" || return 1
	exec {lock_fd}>&-
	jq -e '.locked == true and .dry_run == false and .jobs == []' <<<"${locked_json}" >/dev/null
}

test_remote_write_environment_guard_blocks_mutation_adapters() {
	local output status=0

	unset YOMIKO_REMOTE_WRITES_ENABLED
	assert_success exh_remote_writes_enabled || return 1
	export YOMIKO_REMOTE_WRITES_ENABLED=false
	assert_failure exh_remote_writes_enabled || return 1

	output="$(exh_action_rate 101 token-101 10)" || status=$?
	assert_eq "${EXH_ACTION_CONFIGURATION_STATUS}" "${status}" || return 1
	jq -e '.operation == "rating" and .outcome == "configuration" and
		.mutation_sent == false' <<<"${output}" >/dev/null || return 1

	status=0
	output="$(exh_action_favorite 101 token-101 2)" || status=$?
	assert_eq "${EXH_ACTION_CONFIGURATION_STATUS}" "${status}" || return 1
	jq -e '.operation == "favorite" and .outcome == "configuration" and
		.mutation_sent == false' <<<"${output}" >/dev/null || return 1

	status=0
	output="$(exh_action_hath 101 token-101)" || status=$?
	assert_eq "${EXH_ACTION_CONFIGURATION_STATUS}" "${status}" || return 1
	jq -e '.operation == "hath_request" and .outcome == "configuration" and
		.mutation_sent == false' <<<"${output}" >/dev/null || return 1

	assert_failure exh_rate 101 token-101 10 >/dev/null 2>&1 || return 1
	assert_failure exh_add_favorite 101 token-101 2 >/dev/null 2>&1 || return 1
	assert_failure exh_request_hath_download 101 token-101 >/dev/null 2>&1
}

test_remote_write_deny_mode_prioritizes_local_variant_work() {
	command -v sqlite3 >/dev/null || return 0
	local group_id dry_run_json claim_json
	prepare_variant_runtime_test remote-write-deny || return 1
	group_id="$(variants_enqueue_feedback 101 11)" || return 1
	db_write "INSERT OR IGNORE INTO variant_jobs(
		job_type,group_id,source_gid,priority,status)
		VALUES('reconcile_actions',${group_id},101,2000,'queued');
		UPDATE variant_jobs SET priority=2000
		WHERE group_id=${group_id} AND job_type='reconcile_actions';
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('reconcile_retention',${group_id},101,2000,'queued');" || return 1

	export YOMIKO_REMOTE_WRITES_ENABLED=false
	export YOMIKO_CLI_IN_API_MODE=1
	dry_run_json="$(variants_work --dry-run --max-jobs 1)" || return 1
	jq -e '.jobs[0].job_type == "discover" and
		.budgets.remote_mutations.limit == 0 and
		.budgets.remote_mutations.would_use == 0' <<<"${dry_run_json}" >/dev/null || return 1

	claim_json="$(variants_worker_claim_job remote-write-deny-worker)" || return 1
	jq -e '.job_type == "discover" and .source_gid == 101 and .run_id > 0' \
		<<<"${claim_json}" >/dev/null || return 1
	assert_eq 'queued|queued' "$(db_query "SELECT
		(SELECT status FROM variant_jobs WHERE job_type='reconcile_actions'),
		(SELECT status FROM variant_jobs WHERE job_type='reconcile_retention');")"
}

test_variant_worker_schedules_claims_retries_and_dispatches_evaluation() {
	command -v sqlite3 >/dev/null || return 0
	local schedule_json claim_json retry_delay requeued evaluation_json retry_available_at cancelled_json second_group
	prepare_variant_runtime_test worker || return 1
	db_write "UPDATE galleries SET tags='[\"language:chinese\",\"other:tankoubon\"]',
		file_count=10, favorite_count=1, rating_count=1 WHERE gid IN (101,102);" || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1

	schedule_json="$(variants_worker_schedule_discovery)" || return 1
	jq -e '.due_groups == 1 and .runnable_jobs == 1' <<<"${schedule_json}" >/dev/null || return 1
	claim_json="$(variants_worker_claim_job worker-one)" || return 1
	jq -e '.job_type == "discover" and .source_gid == 101 and .attempt_count == 1 and (.run_id > 0)' <<<"${claim_json}" >/dev/null || return 1
	assert_eq "running|${VARIANTS_MATCHING_REVISION}|worker-one" "$(db_query "SELECT status, matching_revision, lease_owner FROM variant_discovery_runs;")" || return 1

	retry_delay="$(variants_worker_retry_job "$(jq -r '.id' <<<"${claim_json}")" worker-one transient timeout)" || return 1
	assert_eq '300' "${retry_delay}" || return 1
	assert_eq 'queued|retryable|300' "$(db_query "SELECT job.status, run.status, CAST(strftime('%s', job.available_at) - strftime('%s', job.updated_at) AS INTEGER) FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1
	retry_available_at="$(db_query "SELECT available_at FROM variant_jobs WHERE job_type='discover';")" || return 1
	variants_worker_schedule_discovery >/dev/null || return 1
	assert_eq "${retry_available_at}" "$(db_query "SELECT available_at FROM variant_jobs WHERE job_type='discover';")" || return 1
	assert_failure variants_worker_continue_job "$(jq -r '.id' <<<"${claim_json}")" stale-owner null >/dev/null 2>&1 || return 1

	db_write "UPDATE variant_jobs SET available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" || return 1
	claim_json="$(variants_worker_claim_job worker-two)" || return 1
	jq -e '.attempt_count == 2 and .run_id > 0' <<<"${claim_json}" >/dev/null || return 1
	db_write "UPDATE variant_jobs SET lease_expires_at = '2000-01-01T00:00:00Z'; UPDATE variant_discovery_runs SET lease_expires_at = '2000-01-01T00:00:00Z';" || return 1
	requeued="$(variants_worker_requeue_expired_leases)" || return 1
	assert_eq '1' "${requeued}" || return 1
	assert_eq 'queued|retryable||' "$(db_query "SELECT job.status, run.status, COALESCE(job.lease_owner, ''), COALESCE(run.lease_owner, '') FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1

	db_write "UPDATE variant_jobs SET available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" || return 1
	claim_json="$(variants_worker_claim_job worker-three)" || return 1
	variants_worker_fail_job "$(jq -r '.id' <<<"${claim_json}")" worker-three configuration 'fixture stop' >/dev/null || return 1
	assert_eq '1|1' "$(db_query "SELECT job.completed_at IS NOT NULL, run.completed_at IS NULL FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1
	assert_eq 'failed|failed' "$(db_query "SELECT job.status, run.status FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1
	variants_worker_schedule_discovery >/dev/null || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type = 'discover' AND status = 'queued';")" || return 1

	second_group="$(variants_enqueue_feedback 102 8)" || return 1
	claim_json="$(variants_worker_claim_job worker-cancel)" || return 1
	db_write "UPDATE variant_groups SET is_active=0,identity_active=0 WHERE id=${second_group};" || return 1
	cancelled_json="$(variants_worker_handle_discover "${claim_json}" worker-cancel)" || return 1
	jq -e '.status == "cancelled" and .source_gid == 102' <<<"${cancelled_json}" >/dev/null || return 1
	assert_eq 'cancelled|cancelled' "$(db_query "SELECT job.status, run.status FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id=job.id WHERE job.group_id=${second_group};")" || return 1
	db_write "UPDATE variant_jobs SET status='completed',completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE group_id=${second_group} AND job_type='reconcile_actions' AND status='queued';" || return 1

	db_write "INSERT INTO variant_jobs(job_type, group_id, source_gid, priority) VALUES
		('reconcile_actions', 1, 101, 100), ('evaluate', 1, 101, 500);" || return 1
	claim_json="$(variants_worker_claim_job worker-evaluate)" || return 1
	jq -e '.job_type == "evaluate" and .source_gid == 101' <<<"${claim_json}" >/dev/null || return 1
	evaluation_json="$(variants_worker_handle_evaluate "${claim_json}" worker-evaluate)" || return 1
	jq -e '.job_type == "evaluate" and .source_gid == 101 and .status == "completed" and .result.evaluated == true' <<<"${evaluation_json}" >/dev/null || return 1
	assert_eq 'completed|queued' "$(db_query "SELECT (SELECT status FROM variant_jobs WHERE job_type = 'evaluate' AND group_id=1), (SELECT status FROM variant_jobs WHERE job_type = 'reconcile_actions' AND group_id=1);")" || return 1
	assert_eq 'ok' "$(db_query "SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = 'ok' THEN 'ok' ELSE 'failed' END;")"
}

test_variant_evaluation_blocks_incomplete_projection_without_partial_commit() {
	command -v sqlite3 >/dev/null || return 0
	local group_id output status=0 before after
	prepare_variant_runtime_test incomplete-projection || return 1

	for blocked_fixture in scope reference; do
		db_write "DELETE FROM variant_discovery_runs; DELETE FROM variant_jobs;
			DELETE FROM gallery_variants; DELETE FROM variant_groups;
			UPDATE galleries SET first_gid=NULL, first_token=NULL,
				parent_gid=NULL, parent_token=NULL, current_gid=NULL, current_token=NULL,
				tags='[\"language:chinese\",\"other:tankoubon\"]',
				file_count=10, favorite_count=1, rating_count=1
			 WHERE gid IN (101,102);" || return 1
		if [[ "${blocked_fixture}" == reference ]]; then
			db_write "UPDATE galleries SET current_gid=999,
				current_token='missing-token' WHERE gid=102;" || return 1
		else
			db_write "UPDATE galleries SET tags='[\"language:chinese\",\"other:compilation\"]'
			 WHERE gid=102;" || return 1
		fi
		group_id="$(db_write "INSERT INTO variant_groups(source_gid,desired_rating)
			VALUES(101,11); SELECT last_insert_rowid();")" || return 1
		db_write "INSERT INTO gallery_variants(
			group_id,gid,membership_state,decision_source,evidence_json)
			VALUES(${group_id},101,'confirmed','automatic','{}'),
			      (${group_id},102,'confirmed','automatic','{}');" || return 1
		before="$(variant_evaluation_durable_snapshot)" || return 1
		output="$(variants_evaluate_group "${group_id}")" || status=$?
		assert_eq "${VARIANTS_EVALUATION_PROJECTION_BLOCKED_STATUS}" "${status}" || return 1
		jq -e '.blocked == true and .reason == "authoritative_member_projection_incomplete"
			and .confirmed_members == 2 and .scoreable_members == 1' <<<"${output}" >/dev/null || return 1
		after="$(variant_evaluation_durable_snapshot)" || return 1
		assert_eq "${before}" "${after}" || return 1
	done
}

test_variant_worker_backs_off_projection_block_and_orders_discovery_first() {
	command -v sqlite3 >/dev/null || return 0
	local group_id eval_id discover_id claim_json output status=0
	prepare_variant_runtime_test projection-worker || return 1
	db_write "UPDATE galleries SET tags='[\"language:chinese\",\"other:tankoubon\"]',
		file_count=10, favorite_count=1, rating_count=1 WHERE gid=101;
		UPDATE galleries SET tags='[\"language:chinese\",\"other:compilation\"]',
		file_count=10, favorite_count=1, rating_count=1 WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating,completed_matching_revision)
		VALUES(101,11,${VARIANTS_MATCHING_REVISION}-1);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
		VALUES(${group_id},101,'confirmed','automatic','{}'),
		      (${group_id},102,'confirmed','automatic','{}');
		INSERT INTO variant_jobs(
			job_type,group_id,source_gid,priority,status,target_policy_revision_id)
		SELECT 'evaluate',${group_id},101,1000,'queued',id
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
		VALUES('discover',${group_id},101,500,'queued');" || return 1
	eval_id="$(db_query "SELECT id FROM variant_jobs WHERE job_type='evaluate';")" || return 1
	discover_id="$(db_query "SELECT id FROM variant_jobs WHERE job_type='discover';")" || return 1
	claim_json="$(variants_worker_claim_job projection-worker)" || return 1
	assert_eq discover "$(jq -r '.job_type' <<<"${claim_json}")" || return 1
	assert_eq "${discover_id}" "$(jq -r '.id' <<<"${claim_json}")" || return 1
	# Let the dependent evaluation be claimed after the prerequisite has run;
	# the projection is still incomplete, so the handler must durably back off.
	db_write "UPDATE variant_jobs SET status='completed', lease_owner=NULL,
		lease_expires_at=NULL, completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id=${discover_id};
		UPDATE variant_discovery_runs SET status='completed',lease_owner=NULL,
		lease_expires_at=NULL,completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE job_id=${discover_id};" || return 1
	claim_json="$(variants_worker_claim_job projection-worker-eval)" || return 1
	assert_eq "${eval_id}" "$(jq -r '.id' <<<"${claim_json}")" || return 1
	output="$(variants_worker_handle_evaluate "${claim_json}" projection-worker-eval)" || return 1
	jq -e '.status == "projection_blocked" and .retry_in_seconds == 300' <<<"${output}" >/dev/null || return 1
	assert_eq 'queued|transient' "$(db_query "SELECT status,last_error_class FROM variant_jobs WHERE id=${eval_id};")" || return 1
	assert_contains "$(db_query "SELECT last_error FROM variant_jobs WHERE id=${eval_id};")" \
		'incomplete authoritative member projection' || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_evaluations WHERE group_id=${group_id};")" || return 1
}

test_variant_worker_runtime_and_job_outcomes_are_separate() {
	command -v sqlite3 >/dev/null || return 0

	local active_revision status=0 lock_fd
	prepare_variant_runtime_test runtime-outcomes || return 1
	export YOMIKO_REMOTE_WRITES_ENABLED=false
	active_revision="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	db_write "INSERT INTO variant_jobs(job_type,priority,status,target_policy_revision_id)
		VALUES('policy_scoring_sweep',500,'queued',${active_revision});" || return 1

	metrics_runtime_run variant_worker variants_work --max-jobs 1 >/dev/null || return 1
	assert_eq '1|0' "$(db_query "SELECT success_count,failure_count FROM runtime_component_state WHERE component='variant_worker';")" || return 1
	assert_eq '1' "$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='policy_scoring_sweep' AND outcome='completed';")" || return 1

	# An empty queue is still a successful complete invocation.
	metrics_runtime_run variant_worker variants_work --max-jobs 1 >/dev/null || return 1
	assert_eq '2|0' "$(db_query "SELECT success_count,failure_count FROM runtime_component_state WHERE component='variant_worker';")" || return 1

	# Lock contention is a successful no-op, not a runtime failure.
	exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
	flock -n "${lock_fd}" || return 1
	metrics_runtime_run variant_worker variants_work --max-jobs 1 >/dev/null || return 1
	exec {lock_fd}>&-
	assert_eq '3|0' "$(db_query "SELECT success_count,failure_count FROM runtime_component_state WHERE component='variant_worker';")" || return 1

	# A correctly persisted configuration outcome returns success and records only
	# the job event. The override keeps this test focused on the runtime wrapper.
	db_write "INSERT INTO variant_jobs(job_type,priority,status,target_policy_revision_id)
		VALUES('policy_scoring_sweep',500,'queued',${active_revision});" || return 1
	(
		variants_worker_handle_policy_scoring_sweep() {
			local job_json="$1" owner="$2" job_id
			job_id="$(jq -r '.id' <<<"${job_json}")" || return 1
			variants_worker_fail_job "${job_id}" "${owner}" configuration 'fixture configuration failure' >/dev/null || return
			jq -nc '{job_type:"policy_scoring_sweep",source_gid:null,status:"configuration_error"}'
		}
		metrics_runtime_run variant_worker variants_work --max-jobs 1
	) || return 1
	assert_eq '4|0' "$(db_query "SELECT success_count,failure_count FROM runtime_component_state WHERE component='variant_worker';")" || return 1
	assert_eq '1' "$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='policy_scoring_sweep' AND outcome='configuration_error';")" || return 1

	# Handler/orchestration failure leaves the claimed row leased and does not
	# manufacture a terminal event; the invocation itself is the failure.
	db_write "INSERT INTO variant_jobs(job_type,priority,status,target_policy_revision_id)
		VALUES('policy_scoring_sweep',500,'queued',${active_revision});" || return 1
	(
		variants_worker_handle_policy_scoring_sweep() { return 42; }
		metrics_runtime_run variant_worker variants_work --max-jobs 1
	) || status=$?
	assert_eq '42' "${status}" || return 1
	assert_eq '4|1|42' "$(db_query "SELECT success_count,failure_count,last_exit_code FROM runtime_component_state WHERE component='variant_worker';")" || return 1
	assert_eq 'leased' "$(db_query "SELECT status FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='leased';")" || return 1
	assert_eq '1' "$(db_query "SELECT value FROM variant_job_outcome_counters WHERE job_type='policy_scoring_sweep' AND outcome='configuration_error';")" || return 1
}

test_variant_discovery_publishes_complete_snapshot_atomically() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json run_id publish_json source_meta candidate_meta chain_meta popularity
	prepare_variant_runtime_test discovery-publish || return 1
	db_write "UPDATE galleries SET title='Shared Book', title_jpn='共有本',
		tags='[\"language:chinese\",\"other:tankoubon\",\"artist:author\"]'
		WHERE gid=101;" || return 1
	group_id="$(variants_enqueue_feedback 101 11)" || return 1
	claim_json="$(variants_worker_claim_job publish-worker)" || return 1
	run_id="$(jq -r '.run_id' <<<"${claim_json}")"
	db_write "UPDATE variant_jobs SET lease_expires_at='2000-01-01T00:00:00Z';
		UPDATE variant_discovery_runs SET lease_expires_at='2000-01-01T00:00:00Z';" || return 1
	assert_failure variants_discovery_stage_candidate "${run_id}" 999 stale-token '{}' publish-worker >/dev/null 2>&1 || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates WHERE gid=999;")" || return 1
	db_write "UPDATE variant_jobs SET lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes');
		UPDATE variant_discovery_runs SET lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes');" || return 1
	db_write "UPDATE variant_discovery_runs SET phase='publish' WHERE id=${run_id};" || return 1
	source_meta='{"gid":101,"token":"token-101","title":"Shared Book","title_jpn":"共有本","filecount":200,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":100,"filesize":1000,"thumb":"https://example.test/101.jpg","first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	candidate_meta='{"gid":102,"token":"token-102","title":"Shared Book Digital","title_jpn":"共有本","filecount":205,"expunged":true,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.4,"category":"Manga","uploader":"fixture","posted":101,"filesize":1100,"thumb":"https://example.test/102.jpg","first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	chain_meta='{"gid":103,"token":"token-103","title":"Shared Book","title_jpn":"共有本","filecount":201,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.6,"category":"Manga","uploader":"fixture","posted":102,"filesize":1200,"thumb":"https://example.test/103.jpg","first_gid":101,"first_token":"token-101","parent_gid":101,"parent_token":"token-101","current_gid":null,"current_token":null}'
	popularity='{"favorite_count":10,"rating_count":20,"popularity_fetched_at":"2026-08-24T00:00:00Z","error":null}'
	db_write \
		".parameter set :source $(db_parameter_text "${source_meta}")" \
		".parameter set :candidate $(db_parameter_text "${candidate_meta}")" \
		".parameter set :chain $(db_parameter_text "${chain_meta}")" \
		".parameter set :popularity $(db_parameter_text "${popularity}")" \
		"INSERT INTO variant_discovery_candidates(run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,state) VALUES
				(${run_id},101,'token-101',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"seed\",\"gid\":101}]',json(:source),json(:popularity),'complete'),
				(${run_id},102,'token-102',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"search\",\"query\":\"fixture\"}]',json(:candidate),json(:popularity),'complete'),
				(${run_id},103,'token-103',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"uploader_revision\",\"from_gid\":101,\"relation\":\"parent\"}]',json(:chain),json(:popularity),'complete');" || return 1

	publish_json="$(variants_discovery_publish "${run_id}" "$(jq -r '.id' <<<"${claim_json}")" "${group_id}" publish-worker)" || return 1
	# Publication exposes the normalized terminal source after the uploader
	# revision component is projected; the original feedback source remains in
	# the component history but is not the live group pointer.
	jq -e '.status == "completed" and .published == 3 and .pending_reviews == 1 and .evaluation_queued == false and .source_gid == 103' <<<"${publish_json}" >/dev/null || return 1
	assert_eq "completed|completed|${VARIANTS_MATCHING_REVISION}|candidate_pending|candidate|confirmed|11|1|source.7z" "$(db_query "SELECT
		(SELECT status FROM variant_jobs WHERE job_type='discover'),
		(SELECT status FROM variant_discovery_runs), completed_matching_revision,
		review_state,
		(SELECT membership_state FROM gallery_variants WHERE group_id=${group_id} AND gid=102),
		(SELECT membership_state FROM gallery_variants WHERE group_id=${group_id} AND gid=103),
		(SELECT self_rating FROM galleries WHERE gid=103),
		(SELECT COUNT(*) FROM variant_reviews WHERE group_id=${group_id} AND candidate_gid=102 AND matching_revision=${VARIANTS_MATCHING_REVISION}),
		(SELECT file_path FROM galleries WHERE gid=101)
		FROM variant_groups WHERE id=${group_id};")" || return 1
	# Review evidence follows the normalized live source pointer; the original
	# feedback GID remains available in the component history.
	jq -e '.source_snapshot.gid == 103 and .candidate_snapshot.gid == 102 and .score >= 0' <<<"$(db_query "SELECT evidence_json FROM variant_reviews WHERE candidate_gid=102;")" >/dev/null || return 1
	assert_eq 'ok|0' "$(db_query "SELECT (SELECT integrity_check FROM pragma_integrity_check), (SELECT COUNT(*) FROM pragma_foreign_key_check);")"
}

test_variant_discovery_auto_same_book_and_child_canonical() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json run_id publish_json source_meta child_meta popularity evaluation_json
	prepare_variant_runtime_test discovery-auto-same-book || return 1
	group_id="$(variants_enqueue_feedback 101 11)" || return 1
	claim_json="$(variants_worker_claim_job auto-same-book-worker)" || return 1
	run_id="$(jq -r '.run_id' <<<"${claim_json}")"
	db_write "UPDATE variant_discovery_runs SET phase='publish' WHERE id=${run_id};" || return 1
	source_meta='{"gid":101,"token":"token-101","title":"Parent Book","title_jpn":"親本","filecount":200,"expunged":false,"tags":["language:chinese","other:tankoubon"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":100,"filesize":1000,"thumb":"https://example.test/101.jpg","first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	child_meta='{"gid":102,"token":"token-102","title":"Child Book","title_jpn":"子本","filecount":180,"expunged":false,"tags":["language:chinese","other:tankoubon"],"rating":4.0,"category":"Manga","uploader":"fixture","posted":101,"filesize":900,"thumb":"https://example.test/102.jpg","first_gid":101,"first_token":"token-101","parent_gid":103,"parent_token":"token-103","current_gid":null,"current_token":null}'
	chain_meta='{"gid":103,"token":"token-103","title":"Parent Book","title_jpn":"親本","filecount":190,"expunged":false,"tags":["language:chinese","other:tankoubon"],"rating":4.2,"category":"Manga","uploader":"fixture","posted":99,"filesize":950,"thumb":"https://example.test/103.jpg","first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	popularity='{"favorite_count":10,"rating_count":20,"popularity_fetched_at":"2026-08-24T00:05:00Z","error":null}'
	db_write \
		".parameter set :source $(db_parameter_text "${source_meta}")" \
		".parameter set :child $(db_parameter_text "${child_meta}")" \
		".parameter set :chain $(db_parameter_text "${chain_meta}")" \
		".parameter set :popularity $(db_parameter_text "${popularity}")" \
		"INSERT INTO variant_discovery_candidates(run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,state) VALUES
			(${run_id},101,'token-101',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"seed\",\"gid\":101}]',json_set(json(:source),'$.current_gid',103,'$.current_token','token-103'),json(:popularity),'complete'),
			(${run_id},102,'token-102',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"uploader_revision\",\"from_gid\":103,\"relation\":\"parent\"}]',json(:child),json(:popularity),'complete'),
			(${run_id},103,'token-103',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"uploader_revision\",\"from_gid\":101,\"relation\":\"current\"}]',json(:chain),json(:popularity),'complete');" || return 1

	publish_json="$(variants_discovery_publish "${run_id}" "$(jq -r '.id' <<<"${claim_json}")" "${group_id}" auto-same-book-worker)" || return 1
	jq -e '.status == "completed" and .pending_reviews == 0 and .evaluation_queued == true' <<<"${publish_json}" >/dev/null || return 1
	assert_eq 'confirmed|automatic|11|0' "$(db_query "SELECT membership_state,decision_source,
		(SELECT self_rating FROM galleries WHERE gid=102),
		(SELECT COUNT(*) FROM variant_reviews WHERE group_id=${group_id})
		FROM gallery_variants WHERE group_id=${group_id} AND gid=102;")" || return 1

	evaluation_json="$(variants_evaluate_group "${group_id}")" || return 1
	jq -e '.state == "completed" and .canonical_gid == 102 and .automatic_canonical_gid == null' <<<"${evaluation_json}" >/dev/null || return 1
	assert_eq '102|102|canonical|none' "$(db_query "SELECT grouped.canonical_gid,e.canonical_gid,member.variant_state,grouped.review_state
		FROM variant_groups AS grouped
		JOIN variant_evaluations AS e ON e.id=grouped.active_evaluation_id
		JOIN gallery_variants AS member ON member.group_id=grouped.id AND member.gid=102
		WHERE grouped.id=${group_id};")"
}

test_variant_discovery_honors_identity_pairs_in_reverse_direction() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group review_id job_id run_id publish_json
	local source_meta candidate_meta popularity
	prepare_variant_runtime_test discovery-identity-reverse || return 1
	db_write "UPDATE galleries SET title='Shared Book',title_jpn='共有本',
		file_count=200,uploader='fixture',posted=100,
		filesize=1000,rating=4.5,favorite_count=10,rating_count=20,
		tags='[\"language:chinese\",\"other:tankoubon\",\"artist:author\"]'
		WHERE gid IN (101,102);" || return 1
	first_group="$(variants_enqueue_feedback 101 11)" || return 1
	db_write "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json,matching_revision)
		VALUES(${first_group},102,'candidate','automatic',40,'{}',${VARIANTS_MATCHING_REVISION});
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${first_group},102,id,${VARIANTS_MATCHING_REVISION},'{}','[101,102]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${first_group};")" || return 1
	variants_resolve_review "${review_id}" different-book >/dev/null || return 1
	second_group="$(variants_enqueue_feedback 102 11)" || return 1
	db_write "UPDATE variant_jobs SET status='cancelled',lease_owner=NULL,lease_expires_at=NULL,
		completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE status IN ('queued','leased');
		INSERT INTO variant_jobs(
		job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
		VALUES('discover',${second_group},102,1000,'leased','reverse-worker',
		       strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));" || return 1
	job_id="$(db_query "SELECT id FROM variant_jobs WHERE group_id=${second_group} AND status='leased';")" || return 1
	db_write "INSERT INTO variant_discovery_runs(
		group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
		VALUES(${second_group},${job_id},${VARIANTS_MATCHING_REVISION},'publish','running','reverse-worker',
		       strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));" || return 1
	run_id="$(db_query "SELECT id FROM variant_discovery_runs WHERE job_id=${job_id};")" || return 1
	source_meta='{"gid":102,"token":"token-102","title":"Shared Book","title_jpn":"共有本","filecount":200,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":100,"filesize":1000,"thumb":"https://example.test/102.jpg","first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	candidate_meta='{"gid":101,"token":"token-101","title":"Shared Book","title_jpn":"共有本","filecount":201,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":101,"filesize":1001,"thumb":"https://example.test/101.jpg","first_gid":102,"first_token":"token-102","parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}'
	popularity='{"favorite_count":10,"rating_count":20,"popularity_fetched_at":"2026-08-24T00:00:00Z","error":null}'
	db_write \
		".parameter set :source $(db_parameter_text "${source_meta}")" \
		".parameter set :candidate $(db_parameter_text "${candidate_meta}")" \
		".parameter set :popularity $(db_parameter_text "${popularity}")" \
		"INSERT INTO variant_discovery_candidates(
		run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,state)
		VALUES
		(${run_id},102,'token-102',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"seed\",\"gid\":102}]',json(:source),json(:popularity),'complete'),
		(${run_id},101,'token-101',${VARIANTS_MATCHING_REVISION},'[{\"kind\":\"uploader_revision\",\"from_gid\":102,\"relation\":\"first\"}]',json(:candidate),json(:popularity),'complete');" || return 1
	publish_json="$(variants_discovery_publish "${run_id}" "${job_id}" "${second_group}" reverse-worker)" || return 1
	jq -e '.status == "completed" and .pending_reviews == 0 and .evaluation_queued == true' <<<"${publish_json}" >/dev/null || return 1
	assert_eq "rejected|manual|different_book|${review_id}|0|${VARIANTS_MATCHING_REVISION}" "$(db_query "SELECT
		member.membership_state,member.decision_source,current.decision,pair.current_review_id,
		(SELECT count(*) FROM variant_reviews WHERE group_id=${second_group}),
		(SELECT completed_matching_revision FROM variant_groups WHERE id=${second_group})
		FROM gallery_variants AS member
		JOIN gallery_identity_pairs AS pair ON pair.low_gid=101 AND pair.high_gid=102
		JOIN variant_reviews AS current ON current.id=pair.current_review_id
		WHERE member.group_id=${second_group} AND member.gid=101;")"
}

test_variant_discovery_dispatcher_resumes_all_bounded_phases() {
	command -v sqlite3 >/dev/null || return 0
	local group_id iteration output
	prepare_variant_runtime_test discovery-dispatch || return 1
	db_write "UPDATE galleries SET title='Shared Book', title_jpn='共有本',
		tags='[\"language:chinese\",\"other:tankoubon\",\"artist:author\"]'
		WHERE gid=101;" || return 1
	group_id="$(variants_enqueue_feedback 101 11)" || return 1

	# shellcheck disable=SC2317
	exh_api_get_gallery_data_batch() {
		local requested="$1"
		jq -nc --argjson requested "${requested}" '{entries:[$requested[] | . as $item |
			{gid:$item[0],token:$item[1],status:"ok",metadata:{
				gid:$item[0],token:$item[1],title:(if $item[0] == 101 then "Shared Book" else "Shared Book Digital" end),
				title_jpn:"共有本",filecount:(if $item[0] == 101 then 200 else 205 end),
				expunged:false,tags:["language:chinese","other:tankoubon","artist:author"],
				rating:4.5,category:"Manga",uploader:"fixture",posted:100,filesize:1000,
				thumb:("https://example.test/" + ($item[0]|tostring) + ".jpg"),
				first_gid:null,first_token:null,parent_gid:null,parent_token:null,current_gid:null,current_token:null}}]}'
	}
	# shellcheck disable=SC2317
	exh_search_gallery() {
		local _query="$1" mode="$2" _page="$3"
		if [[ "${mode}" == normal ]]; then
			printf '{"mode":"normal","results":[{"gid":102,"token":"token-102"}],"terminal":true,"next_page":null}\n'
		else
			printf '{"mode":"expunged","results":[],"terminal":true,"next_page":null}\n'
		fi
	}
	# shellcheck disable=SC2317
	exh_get_gallery_popularity() {
		local _gid="$1" _token="$2" fetched_at="$3"
		jq -nc --arg fetched_at "${fetched_at}" '{favorite_count:10,rating_count:20,popularity_fetched_at:$fetched_at,error:null}'
	}
	# shellcheck disable=SC2317
	variants_discovery_search_throttle() { :; }

	export YOMIKO_CLI_IN_API_MODE=1
	for iteration in 1 2 3 4 5 6; do
		: "${iteration}"
		output="$(variants_work --max-jobs 1)" || fail "worker iteration ${iteration} failed in phase $(db_query "SELECT phase FROM variant_discovery_runs ORDER BY id DESC LIMIT 1;")" || return 1
		jq -e '.locked == false and .dry_run == false and (.jobs | length == 1)' <<<"${output}" >/dev/null || fail "unexpected worker iteration ${iteration} output: ${output}; state: $(db_query "SELECT job.status, job.available_at, strftime('%Y-%m-%dT%H:%M:%SZ','now'), COALESCE(job.lease_owner,''), run.status, run.phase, COALESCE(run.lease_owner,'') FROM variant_jobs AS job LEFT JOIN variant_discovery_runs AS run ON run.job_id=job.id WHERE job.job_type='discover';")" || return 1
	done
	jq -e '.jobs[0].job_type == "discover" and .jobs[0].status == "completed" and .jobs[0].pending_reviews == 1' <<<"${output}" >/dev/null || fail "unexpected publication output: ${output}" || return 1
	assert_eq "completed|completed|${VARIANTS_MATCHING_REVISION}|candidate_pending|1|${group_id}" "$(db_query "SELECT
		(SELECT status FROM variant_jobs WHERE job_type='discover'),
		(SELECT status FROM variant_discovery_runs), completed_matching_revision,
		review_state,
		(SELECT COUNT(*) FROM variant_reviews WHERE candidate_gid=102 AND status='pending'), id
		FROM variant_groups WHERE id=${group_id};")"
}

test_variant_discovery_matching_and_remote_fixtures() {
	bash "${TEST_ROOT}/tests/fixtures/variant-discovery-matching/smoke.sh" >/dev/null || return 1
	bash "${TEST_ROOT}/tests/fixtures/variant-discovery-remote/smoke.sh" >/dev/null || return 1
	bash "${TEST_ROOT}/tests/fixtures/variant-operational-remote/smoke.sh" >/dev/null || return 1
	bash "${TEST_ROOT}/tests/fixtures/variant-retention/smoke.sh" >/dev/null
}

test_active_domain_vocabulary_has_no_stale_names() {
	local stale
	# Scan only active implementation and fixtures. Historical migrations,
	# docs/TODO mappings, and intentional negative assertions in this test runner
	# are excluded by path. The DROP mapping in 028 and the
	# schema-27 fixture's intentional old-view assertion are filtered below
	# because they are explicit migration-compatibility checks.
	stale="$(rg -n -i \
		--glob '*.sh' --glob '*.jq' --glob '*.sql' \
		-e 'eligible_galleries' \
		-e 'available_galleries' \
		-e 'uploader_revision_(representatives|members)' \
		-e '(^|[^[:alnum:]_])(candidate_eligible|official_chain_visibility|official_chain)([^[:alnum:]_]|$)' \
		-e 'live[[:space:]]+graph' \
		-e 'published[[:space:]]+gallery' \
		-e 'accepted[[:space:]]+discovery[[:space:]]+member' \
		-e 'discovery[[:space:]]+done[[:space:]]+gallery' \
		-e 'revision[[:space:]]+last' \
		-e '(^|[^[:alnum:]_])(low_rep|high_rep)([^[:alnum:]_]|$)' \
		-e 'AS[[:space:]]+eligible([[:space:]]|$)' \
		"${TEST_ROOT}/bin" "${TEST_ROOT}/lib" "${TEST_ROOT}/web" \
		"${TEST_ROOT}/tests/fixtures" \
		2>/dev/null || true)"
	stale="$(awk '
		/DROP VIEW IF EXISTS (available_galleries|eligible_galleries|uploader_revision_representatives|uploader_revision_members);$/ { next }
		/SELECT gid FROM eligible_galleries WHERE component_gid=910001;/ { next }
		/variant-runtime-revision-chain\/smoke\.sh:47:/ { next }
		/variant-runtime-revision-chain\/smoke\.sh:48:/ { next }
		{ print }
	' <<<"${stale}")"
	assert_eq '' "${stale}"
}

test_variant_runtime_revision_chain_consumers() {
	local fixture_root="${TEST_TMPDIR}/variant-runtime-revision-chain-root"
	local migration
	mkdir -p "${fixture_root}/tests/fixtures/variant-runtime-revision-chain" \
		"${fixture_root}/migrations" || return 1
	cp "${TEST_ROOT}/tests/fixtures/variant-runtime-revision-chain/smoke.sh" \
		"${fixture_root}/tests/fixtures/variant-runtime-revision-chain/smoke.sh" || return 1
	ln -s "${TEST_ROOT}/lib" "${fixture_root}/lib" || return 1
	ln -s "${TEST_ROOT}/bin" "${fixture_root}/bin" || return 1
	for migration in "${TEST_ROOT}"/migrations/*.sql; do
		[[ "${migration##*/}" == 030_* ]] || cp "${migration}" "${fixture_root}/migrations/" || return 1
	done
	bash "${fixture_root}/tests/fixtures/variant-runtime-revision-chain/smoke.sh" >/dev/null || return 1
}

test_variant_revision_publication_faults() {
	bash "${TEST_ROOT}/tests/fixtures/variant-revision-publication-faults/smoke.sh" >/dev/null || return 1
}

test_variant_revision_handoff_boundaries() {
	bash "${TEST_ROOT}/tests/fixtures/variant-revision-handoff/smoke.sh" >/dev/null || return 1
}

test_variant_enqueue_normalizes_predecessor_to_terminal() {
	command -v sqlite3 >/dev/null || return 0
	bash "${TEST_ROOT}/tests/fixtures/variant-enqueue-terminal/smoke.sh" >/dev/null || return 1
}

test_variant_operational_actions_converge_and_retain_canonical() {
	command -v sqlite3 >/dev/null || return 0
	local operational_home="${TEST_TMPDIR}/variant-operational-home"
	local group_id evaluation_id claim_json output
	mkdir -p "${operational_home}"
	HOME="${operational_home}"
	export HOME
	# shellcheck disable=SC1091
	source "${TEST_ROOT}/lib/path.sh"
	prepare_variant_runtime_test operational-actions || return 1
	group_id="$(db_write "UPDATE galleries SET file_path='alternate.7z' WHERE gid=102;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(101,11,1);
	SELECT last_insert_rowid();")" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
	  group_id,gid,membership_state,decision_source,evidence_json,
	  variant_state)
	VALUES
	  (${group_id},101,'confirmed','automatic','{}','canonical'),
	  (${group_id},102,'confirmed','manual','{}','alternate');
	INSERT INTO variant_evaluations(
	  group_id,policy_revision_id,state,metadata_snapshot_json,
	  member_scores_json,canonical_gid)
	SELECT ${group_id},id,'completed','[]','[]',101
	  FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups SET canonical_gid=101,
	  active_evaluation_id=${evaluation_id},review_state='none'
	 WHERE id=${group_id};
	INSERT INTO variant_jobs(job_type,group_id,source_gid,priority)
	VALUES('reconcile_actions',${group_id},101,1000);" || return 1
	printf canonical >"${ARCHIVED_DIR}/source.7z"
	printf alternate >"${ARCHIVED_DIR}/alternate.7z"
	export YOMIKO_CANONICAL_FAVORITE_CATEGORY=2
	export YOMIKO_ALTERNATE_FAVORITE_CATEGORY=3
	exh_action_rate() {
		jq -nc --argjson gid "$1" --arg desired "$3" \
			'{operation:"rating",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'
	}
	exh_action_favorite() {
		jq -nc --argjson gid "$1" --arg desired "$3" \
			'{operation:"favorite",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'
	}
	exh_action_hath() {
		fail 'H@H adapter was called despite an existing canonical archive'
		return 1
	}
	claim_json="$(variants_worker_claim_job operational-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" operational-worker 25)" || return 1
	jq -e '.status=="completed" and .remote_mutations==4 and .local_cleanups==1' <<<"${output}" >/dev/null || return 1
	[[ -f "${ARCHIVED_DIR}/source.7z" ]] || fail 'canonical archive was removed' || return 1
	[[ ! -e "${ARCHIVED_DIR}/alternate.7z" ]] || fail 'alternate archive was retained' || return 1
	assert_eq '11|11|1|6' "$(db_query "SELECT
	  (SELECT self_rating FROM galleries WHERE gid=101),
	  (SELECT self_rating FROM galleries WHERE gid=102),
	  (SELECT rated_then_deleted_at IS NOT NULL FROM galleries WHERE gid=102),
	  (SELECT COUNT(*) FROM variant_actions WHERE group_id=${group_id} AND status='succeeded');")" || return 1
	variants_actions_record_manual_hath_success 101 || return 1
	assert_eq '1|1' "$(db_query "SELECT
	 (SELECT hath_requested_at IS NOT NULL FROM galleries WHERE gid=101),
	 json_extract(result_json,'$.manual_command')
	 FROM variant_actions WHERE group_id=${group_id} AND action_type='hath_request';")"
}

test_variant_reconciliation_projection_is_idempotent_and_converges() {
	command -v sqlite3 >/dev/null || return 0
	local home_dir="${TEST_TMPDIR}/variant-reconciliation-home"
	local group_id evaluation_id claim_json output before after
	mkdir -p "${home_dir}"
	HOME="${home_dir}"
	export HOME
	# shellcheck disable=SC1091
	source "${TEST_ROOT}/lib/path.sh"

	prepare_variant_runtime_test reconciliation-noop || return 1
	db_write "UPDATE galleries
	   SET tags='[\"language:chinese\",\"other:tankoubon\"]',
	       file_count=10, favorite_count=1, rating_count=1
	 WHERE gid IN (101,102);" || return 1
	group_id="$(db_write "INSERT INTO variant_groups(
	 source_gid,desired_rating,is_active,latest_feedback_at)
	 VALUES(101,11,1,'2001-01-01T00:00:00Z');
	SELECT last_insert_rowid();")" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
	 group_id,gid,membership_state,decision_source,evidence_json,
	 variant_state)
	 VALUES
		 (${group_id},101,'confirmed','automatic','{}','canonical'),
		 (${group_id},102,'confirmed','manual','{}','alternate');
	INSERT INTO variant_evaluations(
	 group_id,policy_revision_id,state,metadata_snapshot_json,
	 member_scores_json,canonical_gid)
	 SELECT ${group_id},id,'completed','[]','[]',101
	 FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups SET canonical_gid=101,
	 active_evaluation_id=${evaluation_id},review_state='none' WHERE id=${group_id};
	UPDATE galleries SET self_rating=11,feedbacked_at='2001-01-01T00:00:00Z',
	 updated_at='2000-01-01T00:00:00Z' WHERE gid IN (101,102);
	INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status,completed_at)
	 VALUES('reconcile_retention',${group_id},101,500,'completed','2001-01-02T00:00:00Z');" || return 1
	printf canonical >"${ARCHIVED_DIR}/source.7z"
	variants_actions_project "${group_id}" >/dev/null || return 1
	db_write "UPDATE variant_actions SET status='succeeded',
	 completed_at='2001-01-02T00:00:00Z' WHERE group_id=${group_id};" || return 1
	before="$(db_query "SELECT updated_at FROM galleries WHERE gid=101;")" || return 1
	variants_actions_project "${group_id}" >/dev/null || return 1
	after="$(db_query "SELECT updated_at FROM galleries WHERE gid=101;")" || return 1
	assert_eq '2000-01-01T00:00:00Z' "${before}" || return 1
	assert_eq "${before}" "${after}" || return 1
	assert_eq '0' "$(variants_retention_self_heal)" || return 1
	assert_eq '0|1' "$(db_query "SELECT
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention' AND status='queued'),
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention');")" || return 1

	prepare_variant_runtime_test reconciliation-change || return 1
	db_write "UPDATE galleries
	   SET tags='[\"language:chinese\",\"other:tankoubon\"]',
	       file_count=10, favorite_count=1, rating_count=1,
	       file_path=CASE gid WHEN 102 THEN 'alternate.7z' ELSE file_path END
	 WHERE gid IN (101,102);" || return 1
	group_id="$(db_write "INSERT INTO variant_groups(
	 source_gid,desired_rating,is_active,latest_feedback_at)
	 VALUES(101,11,1,'2001-01-01T00:00:00Z');
	SELECT last_insert_rowid();")" || return 1
	evaluation_id="$(db_write "INSERT INTO gallery_variants(
	 group_id,gid,membership_state,decision_source,evidence_json,
	 variant_state)
	 VALUES
		 (${group_id},101,'confirmed','automatic','{}','canonical'),
		 (${group_id},102,'confirmed','manual','{}','alternate');
	INSERT INTO variant_evaluations(
	 group_id,policy_revision_id,state,metadata_snapshot_json,
	 member_scores_json,canonical_gid)
	 SELECT ${group_id},id,'completed','[]','[]',101
	 FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_write "UPDATE variant_groups SET canonical_gid=101,
	 active_evaluation_id=${evaluation_id},review_state='none' WHERE id=${group_id};
	UPDATE galleries SET self_rating=10,feedbacked_at=NULL,
	 updated_at='2000-01-01T00:00:00Z' WHERE gid=101;
	UPDATE galleries SET self_rating=11,feedbacked_at='2001-01-01T00:00:00Z',
	 updated_at='2000-01-01T00:00:00Z' WHERE gid=102;
	INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status,completed_at)
	 VALUES('reconcile_retention',${group_id},101,500,'completed','2001-01-02T00:00:00Z');" || return 1
	printf canonical >"${ARCHIVED_DIR}/source.7z"
	variants_actions_project "${group_id}" >/dev/null || return 1
	db_write "UPDATE variant_actions SET status='succeeded',
	 completed_at='2001-01-02T00:00:00Z' WHERE group_id=${group_id};" || return 1
	assert_eq '11|2001-01-01T00:00:00Z|11|2001-01-01T00:00:00Z' "$(db_query "SELECT
	 (SELECT self_rating FROM galleries WHERE gid=101),
	 (SELECT feedbacked_at FROM galleries WHERE gid=101),
	 (SELECT self_rating FROM galleries WHERE gid=102),
	 (SELECT feedbacked_at FROM galleries WHERE gid=102);")" || return 1
	assert_not_contains "$(db_query "SELECT updated_at FROM galleries WHERE gid=101;")" '2000-01-01T00:00:00Z' || return 1
	assert_eq '1|6' "$(db_query "SELECT
	 (SELECT updated_at='2000-01-01T00:00:00Z' FROM galleries WHERE gid=102),
	 (SELECT COUNT(*) FROM variant_actions WHERE group_id=${group_id} AND status='succeeded');")" || return 1
	assert_eq '1' "$(variants_retention_self_heal)" || return 1
	assert_eq '1|2' "$(db_query "SELECT
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention' AND status='queued'),
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention');")" || return 1
	claim_json="$(variants_worker_claim_job reconciliation-retention-worker)" || return 1
	output="$(variants_worker_handle_reconcile_retention "${claim_json}" reconciliation-retention-worker)" || return 1
	jq -e '.status == "completed" and .canonical_archive == true' <<<"${output}" >/dev/null || return 1
	assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_actions' AND status='queued';")" || return 1
	claim_json="$(variants_worker_claim_job reconciliation-actions-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" reconciliation-actions-worker 25)" || return 1
	jq -e '.status == "completed" and .remote_mutations == 0 and .local_cleanups == 0' <<<"${output}" >/dev/null || return 1
	assert_eq '0|3|0' "$(db_query "SELECT
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention' AND status='queued'),
	 (SELECT COUNT(*) FROM variant_jobs),
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_actions' AND status='queued');")" || return 1
	assert_eq '0' "$(variants_retention_self_heal)" || return 1
	assert_eq '3' "$(db_query 'SELECT COUNT(*) FROM variant_jobs;')" || return 1
}

test_variant_scoring_sweep_batches_and_rejects_stale_revision() {
	command -v sqlite3 >/dev/null || return 0
	local claim_json output active_revision new_revision
	prepare_variant_runtime_test scoring-sweep || return 1
	active_revision="$(db_query "SELECT id FROM variant_policy_revisions WHERE is_active=1;")" || return 1
	db_write "WITH RECURSIVE sequence(value) AS (
	  SELECT 1001 UNION ALL SELECT value+1 FROM sequence WHERE value<1101
	)
	INSERT INTO galleries(gid,token,title,tags)
	  SELECT value,'token-'||value,'Gallery '||value,'[]' FROM sequence;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active)
	  SELECT gid,11,1 FROM galleries WHERE gid BETWEEN 1001 AND 1101;
	INSERT INTO variant_jobs(job_type,priority,status,target_policy_revision_id)
	  VALUES('policy_scoring_sweep',500,'queued',${active_revision});" || return 1

	claim_json="$(variants_worker_claim_job sweep-worker)" || return 1
	output="$(variants_worker_handle_policy_scoring_sweep "${claim_json}" sweep-worker)" || return 1
	jq -e '.status=="continued" and .processed_groups==100' <<<"${output}" >/dev/null || return 1
	assert_eq '100|100' "$(db_query "SELECT
	  (SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate'),
	  json_extract(continuation_cursor_json,'$.last_group_id')
	    - (SELECT MIN(id)-1 FROM variant_groups)
	  FROM variant_jobs WHERE job_type='policy_scoring_sweep';")" || return 1
	claim_json="$(variants_worker_claim_job sweep-worker)" || return 1
	output="$(variants_worker_handle_policy_scoring_sweep "${claim_json}" sweep-worker)" || return 1
	jq -e '.status=="completed" and .processed_groups==1' <<<"${output}" >/dev/null || return 1
	assert_eq '101|completed' "$(db_query "SELECT
	  (SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate'),status
	  FROM variant_jobs WHERE job_type='policy_scoring_sweep';")" || return 1

	db_write "DELETE FROM variant_jobs WHERE job_type='evaluate';
	UPDATE variant_jobs SET status='queued',completed_at=NULL,
	 continuation_cursor_json=NULL,available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');
	INSERT INTO variant_policy_revisions(
	 policy_json,content_hash,matching_hash,scoring_hash,operations_hash,is_active)
	SELECT policy_json,
	 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
	 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
	 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
	 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',0
	FROM variant_policy_revisions WHERE id=${active_revision};
	SELECT last_insert_rowid();" >/dev/null || return 1
	new_revision="$(db_query "SELECT MAX(id) FROM variant_policy_revisions;")" || return 1
	claim_json="$(variants_worker_claim_job stale-sweep-worker)" || return 1
	db_write "UPDATE variant_policy_revisions SET is_active=0 WHERE id=${active_revision};
	UPDATE variant_policy_revisions SET is_active=1,
	 activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=${new_revision};" || return 1
	output="$(variants_worker_handle_policy_scoring_sweep "${claim_json}" stale-sweep-worker)" || return 1
	jq -e '.status=="stale_revision"' <<<"${output}" >/dev/null || return 1
	assert_eq "queued|${new_revision}||0" "$(db_query "SELECT status,target_policy_revision_id,
	 COALESCE(continuation_cursor_json,''),
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate')
	 FROM variant_jobs WHERE job_type='policy_scoring_sweep';")"
}

test_variant_action_remote_budget_caps_at_twenty_five() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json output
	prepare_variant_runtime_test action-budget || return 1
	db_write "WITH RECURSIVE sequence(value) AS (
	  SELECT 2001 UNION ALL SELECT value+1 FROM sequence WHERE value<2030
	)
	INSERT INTO galleries(gid,token,title,tags,file_path)
	  SELECT value,'token-'||value,'Gallery '||value,'[]','gallery-'||value||'.7z' FROM sequence;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(2001,8,1);" || return 1
	group_id="$(db_query "SELECT id FROM variant_groups WHERE source_gid=2001;")" || return 1
	db_write "INSERT INTO gallery_variants(
	 group_id,gid,membership_state,decision_source,evidence_json)
	SELECT ${group_id},gid,'confirmed','automatic','{}'
	  FROM galleries WHERE gid BETWEEN 2001 AND 2030;
	INSERT INTO variant_jobs(job_type,group_id,source_gid,priority)
	VALUES('reconcile_actions',${group_id},2001,1000);" || return 1
	exh_action_rate() {
		jq -nc --argjson gid "$1" --arg desired "$3" \
			'{operation:"rating",gid:$gid,desired_value:$desired,outcome:"succeeded",message:"fixture"}'
	}
	claim_json="$(variants_worker_claim_job budget-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" budget-worker 25)" || return 1
	jq -e '.status=="continued" and .remote_mutations==25 and .local_cleanups==30' <<<"${output}" >/dev/null || return 1
	assert_eq '25|30|5|queued' "$(db_query "SELECT
	 (SELECT COUNT(*) FROM variant_actions WHERE action_type='rating' AND status='succeeded'),
	 (SELECT COUNT(*) FROM variant_actions WHERE action_type='archive_cleanup' AND status='succeeded'),
	 (SELECT COUNT(*) FROM variant_actions WHERE action_type='rating' AND status='pending'),
	 (SELECT status FROM variant_jobs WHERE job_type='reconcile_actions');")" || return 1
	claim_json="$(variants_worker_claim_job budget-worker)" || return 1
	output="$(variants_worker_handle_reconcile_actions "${claim_json}" budget-worker 25)" || return 1
	jq -e '.status=="completed" and .remote_mutations==5 and .local_cleanups==0' <<<"${output}" >/dev/null || return 1
	assert_eq '60|completed' "$(db_query "SELECT
	 (SELECT COUNT(*) FROM variant_actions WHERE status='succeeded'),status
	 FROM variant_jobs WHERE job_type='reconcile_actions';")"
}

test_variant_cli_rejects_invalid_inputs_before_database_access() {
	local home_dir="${TEST_TMPDIR}/variant-cli-input-home"
	local output
	mkdir -p "${home_dir}"

	if output="$(HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" variants enqueue 0 2>&1)"; then
		fail 'variants enqueue accepted zero GID'
		return 1
	fi
	assert_contains "${output}" "Invalid GID '0'" || return 1
	assert_failure env HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" variants list --gid nope >/dev/null 2>&1 || return 1
	assert_failure env HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" variants list --status unknown >/dev/null 2>&1 || return 1
	assert_failure env HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" variants evaluate 0 >/dev/null 2>&1 || return 1
	assert_failure env HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" variants work --max-jobs 0 >/dev/null 2>&1
}

test_high_feedback_is_queued_without_remote_calls_and_obeys_archive_retention() {
	command -v sqlite3 >/dev/null || return 0
	local home_dir="${TEST_TMPDIR}/variant-feedback-home"
	local archive_path output
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/archived" "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/fail-if-called.sh" "${home_dir}/bin/curl"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES (101, 'token', 'Source', '[]', 'source...7z');" || return 1
	archive_path="${home_dir}/archived/source...7z"
	printf 'archive' >"${archive_path}"

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 101 --rating 11)" || return 1
	jq -e 'keys == ["variant_queued"] and .variant_queued == true' <<<"${output}" >/dev/null || return 1
	[[ -f "${archive_path}" ]] || fail 'rating 11 removed the source archive' || return 1
	assert_eq '11||10' "$(db_query "SELECT self_rating, COALESCE(rated_then_deleted_at, ''), (SELECT desired_value FROM variant_actions WHERE gid = 101) FROM galleries WHERE gid = 101;")" || return 1

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 101 --rating 8)" || return 1
	jq -e '.variant_queued == true' <<<"${output}" >/dev/null || return 1
	[[ ! -e "${archive_path}" ]] || fail 'rating 8 retained the source archive' || return 1
	assert_eq '1' "$(db_query "SELECT rated_then_deleted_at IS NOT NULL FROM galleries WHERE gid = 101;")"
}

test_variant_group_downgrade_converges_desired_state() {
	command -v sqlite3 >/dev/null || return 0
	local active_group inactive_group selected_group status=0 before after
	prepare_variant_runtime_test downgrade || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags) VALUES
		(103, 'token-103', 'Candidate', '[]'),
		(104, 'token-104', 'Ungrouped', '[]');
	INSERT INTO variant_groups (source_gid, desired_rating, is_active, identity_active) VALUES (101, 9, 0, 0);
	INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json)
		VALUES (last_insert_rowid(), 102, 'confirmed', 'manual', '{}');" || return 1
	inactive_group="$(db_query 'SELECT id FROM variant_groups;')" || return 1
	db_write "INSERT INTO variant_groups (source_gid, desired_rating) VALUES (101, 11);" || return 1
	active_group="$(db_query 'SELECT id FROM variant_groups WHERE is_active = 1;')" || return 1
	db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES
		(${active_group}, 101, 'confirmed', 'automatic', '{}'),
		(${active_group}, 102, 'confirmed', 'manual', '{}'),
		(${active_group}, 103, 'candidate', 'automatic', '{}');" || return 1
	db_write "INSERT INTO variant_actions (group_id, gid, action_type, desired_value, policy_revision_id) VALUES
		(${active_group}, 101, 'rating', '10', 1),
		(${active_group}, 101, 'favorite_move', '2', 1),
		(${active_group}, 102, 'hath_request', 'request', 1);
	INSERT INTO variant_jobs (job_type, group_id, source_gid, priority) VALUES
		('reconcile_actions', ${active_group}, 101, 10);" || return 1

	selected_group="$(variants_downgrade_feedback 102 5)" || return 1
	assert_eq "${active_group}" "${selected_group}" || return 1
	assert_eq '5|0' "$(db_query "SELECT desired_rating, is_active FROM variant_groups WHERE id = ${active_group};")" || return 1
	assert_eq $'101|5\n102|5' "$(db_query "SELECT gid, self_rating FROM galleries WHERE gid IN (101, 102) ORDER BY gid;")" || return 1
	assert_eq '0|' "$(db_query "SELECT self_rating, COALESCE(feedbacked_at, '') FROM galleries WHERE gid = 103;")" || return 1
	assert_eq $'101|archive_cleanup|delete|pending\n101|favorite_remove|favdel|pending\n101|rating|5|pending\n102|archive_cleanup|delete|pending\n102|favorite_remove|favdel|pending\n102|rating|5|pending' \
		"$(db_query "SELECT gid, action_type, desired_value, status FROM variant_actions WHERE status <> 'superseded' ORDER BY gid, action_type;")" || return 1
	assert_eq '3' "$(db_query "SELECT COUNT(*) FROM variant_actions WHERE status = 'superseded';")" || return 1
	assert_eq "1|${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" "$(db_query "SELECT COUNT(*), MAX(priority) FROM variant_jobs WHERE group_id = ${active_group} AND job_type = 'reconcile_actions' AND status = 'queued';")" || return 1

	variants_downgrade_feedback 101 5 >/dev/null || return 1
	assert_eq '6|1' "$(db_query "SELECT (SELECT COUNT(*) FROM variant_actions WHERE status <> 'superseded'), (SELECT COUNT(*) FROM variant_jobs WHERE group_id = ${active_group} AND job_type = 'reconcile_actions' AND status = 'queued');")" || return 1
	selected_group="$(variants_downgrade_feedback 102 4)" || return 1
	assert_eq "${inactive_group}" "${selected_group}" || return 1

	before="$(db_query "SELECT self_rating, feedbacked_at, updated_at FROM galleries WHERE gid = 104; SELECT COUNT(*) FROM variant_actions; SELECT COUNT(*) FROM variant_jobs;")" || return 1
	variants_downgrade_feedback 104 3 >/dev/null || status=$?
	assert_eq "${VARIANTS_NOT_GROUPED_STATUS}" "${status}" || return 1
	after="$(db_query "SELECT self_rating, feedbacked_at, updated_at FROM galleries WHERE gid = 104; SELECT COUNT(*) FROM variant_actions; SELECT COUNT(*) FROM variant_jobs;")" || return 1
	assert_eq "${before}" "${after}"
}

test_low_feedback_routes_grouped_intent_and_preserves_legacy_fallback() {
	command -v sqlite3 >/dev/null || return 0
	local home_dir="${TEST_TMPDIR}/variant-low-feedback-home"
	local curl_trace="${TEST_TMPDIR}/variant-low-feedback-curl.trace"
	local grouped_archive ungrouped_archive output group_id snapshot
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/archived" "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/feedback-curl.sh" "${home_dir}/bin/curl"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES
		(201, 'token-201', 'Grouped', '[]', 'grouped.7z'),
		(202, 'token-202', 'Member', '[]', NULL),
		(203, 'token-203', 'Ungrouped', '[]', 'ungrouped.7z');" || return 1
	group_id="$(variants_enqueue_feedback 201 9)" || return 1
	db_write "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json) VALUES (${group_id}, 202, 'confirmed', 'manual', '{}');" || return 1
	grouped_archive="${home_dir}/archived/grouped.7z"
	ungrouped_archive="${home_dir}/archived/ungrouped.7z"
	printf archive >"${grouped_archive}"
	printf archive >"${ungrouped_archive}"

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 202 --rating 6)" || return 1
	jq -e 'keys == ["variant_queued"] and .variant_queued == true' <<<"${output}" >/dev/null || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'grouped low feedback made a synchronous curl call' || return 1
	[[ -f "${grouped_archive}" ]] || fail 'grouped low feedback synchronously deleted an archive' || return 1
	assert_eq '6|0|9' "$(db_query "SELECT desired_rating, is_active, (SELECT self_rating FROM galleries WHERE gid = 201) FROM variant_groups WHERE id = ${group_id};")" || return 1

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 203 --rating 4)" || return 1
	jq -e 'keys == ["variant_queued"] and .variant_queued == false' <<<"${output}" >/dev/null || return 1
	assert_eq '2' "$(wc -l <"${curl_trace}")" || return 1
	[[ ! -e "${ungrouped_archive}" ]] || fail 'ungrouped low feedback did not keep legacy deletion behavior' || return 1
	assert_eq '4|1' "$(db_query "SELECT self_rating, rated_then_deleted_at IS NOT NULL FROM galleries WHERE gid = 203;")" || return 1

	snapshot="$(db_query "SELECT desired_rating, is_active, self_rating, feedbacked_at FROM variant_groups JOIN galleries ON galleries.gid = 201 WHERE variant_groups.id = ${group_id}; SELECT COUNT(*) FROM variant_actions; SELECT COUNT(*) FROM variant_jobs;")" || return 1
	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 201 --rating 2 --dry-run)" || return 1
	jq -e 'keys == ["variant_queued"] and .variant_queued == true' <<<"${output}" >/dev/null || return 1
	assert_eq "${snapshot}" "$(db_query "SELECT desired_rating, is_active, self_rating, feedbacked_at FROM variant_groups JOIN galleries ON galleries.gid = 201 WHERE variant_groups.id = ${group_id}; SELECT COUNT(*) FROM variant_actions; SELECT COUNT(*) FROM variant_jobs;")" || return 1
	assert_eq '2' "$(wc -l <"${curl_trace}")"
}

test_parse_gallery_path() {
	local metadata
	metadata="$(exh_parse_path_meta '/downloads/[artist] title [123456-1280x]')" || return 1

	assert_eq '123456' "$(jq -r '.gid' <<<"${metadata}")" || return 1
	assert_eq '[artist] title' "$(jq -r '.fs_compatible_title' <<<"${metadata}")" || return 1
}

test_parse_gallery_path_rejects_invalid_name() {
	local output
	unset YOMIKO_CLI_IN_API_MODE

	if output="$(exh_parse_path_meta '/downloads/not-a-gallery' 2>&1)"; then
		fail 'invalid gallery name was accepted'
		return 1
	fi

	assert_contains "${output}" "Could not parse 'not-a-gallery'"
}

test_archive_filename_validation() {
	local home_dir="${TEST_TMPDIR}/archive-validator-home"
	local newline_name=$'line\nbreak.7z'
	local carriage_return_name=$'carriage\rreturn.7z'

	mkdir -p "${home_dir}"
	HOME="${home_dir}"
	export HOME
	# shellcheck disable=SC1091
	source "${TEST_ROOT}/lib/path.sh"

	assert_success archive_filename_is_safe 'archive.7z' || return 1
	assert_success archive_filename_is_safe '[123][野原ひろみ] 素肌的美少女... [中国翻訳].7z' || return 1
	assert_success archive_filename_is_safe 'a..b.7z' || return 1

	assert_failure archive_filename_is_safe '' || return 1
	assert_failure archive_filename_is_safe '.' || return 1
	assert_failure archive_filename_is_safe '..' || return 1
	assert_failure archive_filename_is_safe '/tmp/archive.7z' || return 1
	assert_failure archive_filename_is_safe 'nested/archive.7z' || return 1
	assert_failure archive_filename_is_safe "${newline_name}" || return 1
	assert_failure archive_filename_is_safe "${carriage_return_name}"
}

test_gallery_metadata_is_normalized() {
	local metadata normalized
	metadata='{"gid":"123","token":"test-token","title":"Test title","category":"Manga","uploader":"test-user","posted":"1722470400","filecount":"12","filesize":"345678","thumb":"https://example.test/thumb.jpg","expunged":false,"tags":["artist:test"],"rating":"4.50","first_gid":"100","first_key":"first-token","parent_gid":"122","parent_key":"parent-token","current_gid":"124","current_key":"current-token"}'

	normalized="$(exh_normalize_gallery_metadata 123 "${metadata}")" || return 1

	assert_eq 'number' "$(jq -r '.gid | type' <<<"${normalized}")" || return 1
	assert_eq '123' "$(jq -r '.gid' <<<"${normalized}")" || return 1
	assert_eq 'false' "$(jq -r 'has("category")' <<<"${normalized}")" || return 1
	assert_eq 'null' "$(jq -r '.title_jpn | type' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.filecount | type' <<<"${normalized}")" || return 1
	assert_eq '12' "$(jq -r '.filecount' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.rating | type' <<<"${normalized}")" || return 1
	assert_eq 'true' "$(jq -r '.rating == 4.5' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.posted | type' <<<"${normalized}")" || return 1
	assert_eq '1722470400' "$(jq -r '.posted' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.filesize | type' <<<"${normalized}")" || return 1
	assert_eq '345678' "$(jq -r '.filesize' <<<"${normalized}")" || return 1
	assert_eq '100:first-token,122:parent-token,124:current-token' "$(jq -r '[.first_gid, .first_token, .parent_gid, .parent_token, .current_gid, .current_token] | "\(.[0]):\(.[1]),\(.[2]):\(.[3]),\(.[4]):\(.[5])"' <<<"${normalized}")"
}

test_gallery_metadata_tolerates_absent_chain_fields() {
	local metadata normalized
	metadata='{"gid":123,"token":"test-token","title":"Test title","category":"Manga","uploader":"test-user","posted":"1722470400","filecount":"12","filesize":345678,"thumb":"https://example.test/thumb.jpg","expunged":false,"tags":["artist:test"],"rating":"4.50"}'

	normalized="$(exh_normalize_gallery_metadata 123 "${metadata}")" || return 1
	jq -e '
		.first_gid == null and .first_token == null
		and .parent_gid == null and .parent_token == null
		and .current_gid == null and .current_token == null
	' <<<"${normalized}" >/dev/null || fail 'missing chain fields were not normalized to null'
}

test_gallery_metadata_rejects_invalid_fields() {
	local valid_metadata
	valid_metadata='{"gid":123,"token":"test-token","title":"Test title","title_jpn":null,"category":"Manga","uploader":"test-user","posted":1722470400,"filecount":12,"filesize":345678,"thumb":"https://example.test/thumb.jpg","expunged":false,"tags":["artist:test"],"rating":4.5}'

	assert_failure exh_normalize_gallery_metadata 124 "${valid_metadata}" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c 'del(.token)' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.filecount = "many"' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.expunged = 0' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.tags = ["valid", null]' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.rating = 5.1' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c 'del(.category)' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.category = "manga"' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.category = "Doujinshi"' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.posted = "yesterday"' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.filesize = -1' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.first_gid = "invalid"' <<<"${valid_metadata}")" >/dev/null 2>&1 || return 1
	assert_failure exh_normalize_gallery_metadata 123 "$(jq -c '.current_key = ""' <<<"${valid_metadata}")" >/dev/null 2>&1
}

test_cookie_conversion() {
	local cookie_path="${TEST_TMPDIR}/cookie-jar.txt"
	local cookie_jar
	local header
	export EXH_COOKIE_PATH="${cookie_path}"

	header="$(cookie_str_to_cookie_jar 'igneous=abc123; ipb_member_id=42')"
	cookie_jar="$(<"${cookie_path}")"

	assert_eq '# Netscape HTTP Cookie File' "${header}" || return 1
	assert_contains "${cookie_jar}" $'.exhentai.org\tTRUE\t/\tFALSE\t2147483647\tigneous\tabc123' || return 1
	assert_contains "${cookie_jar}" $'.exhentai.org\tTRUE\t/\tFALSE\t2147483647\tipb_member_id\t42'
}

assert_cli_usage_error() {
	local expected="$1"
	shift
	local output status=0
	local home_dir="${TEST_TMPDIR}/cli-validation-home"

	output="$(
		HOME="${home_dir}" \
			bash "${TEST_ROOT}/bin/yomiko" "$@" 2>&1
	)" || status=$?

	assert_eq '1' "${status}" || return 1
	assert_contains "${output}" "${expected}"
}

test_cli_rejects_invalid_gids() {
	assert_cli_usage_error "Invalid GID 'abc'" rate abc 5 || return 1
	assert_cli_usage_error "Invalid GID '-1'" hath -1 || return 1
	assert_cli_usage_error "Invalid GID '12x'" favorite 12x 5 || return 1
	assert_cli_usage_error "Invalid GID '1.5'" feedback 1.5 --dry-run || return 1
	assert_cli_usage_error "Invalid GID 'abc'" list 123 abc
}

test_cli_rejects_extra_positional_arguments() {
	assert_cli_usage_error 'Unexpected argument: extra' scan /tmp extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' archive /tmp extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' rate 123 5 extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' hath 123 extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' favorite 123 5 extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' repair-tags extra || return 1
	assert_cli_usage_error 'Unexpected argument: extra' whoami extra
}

test_cli_help_ignores_trailing_arguments() {
	local output

	output="$(HOME="${TEST_TMPDIR}/cli-help-home" bash "${TEST_ROOT}/bin/yomiko" --help hello world)" ||
		return 1
	assert_contains "${output}" 'Usage:' || return 1
	assert_contains "${output}" 'yomiko help'
}

test_cli_unknown_command_uses_stderr() {
	local stdout_path="${TEST_TMPDIR}/unknown-command.stdout"
	local stderr_path="${TEST_TMPDIR}/unknown-command.stderr"
	local status=0

	HOME="${TEST_TMPDIR}/cli-unknown-home" \
		bash "${TEST_ROOT}/bin/yomiko" unknown-command >"${stdout_path}" 2>"${stderr_path}" ||
		status=$?

	assert_eq '1' "${status}" || return 1
	assert_eq '' "$(<"${stdout_path}")" || return 1
	assert_contains "$(<"${stderr_path}")" 'ERROR: Unknown command: unknown-command' || return 1
	assert_contains "$(<"${stderr_path}")" 'Usage:'
}

test_cli_rejects_missing_positional_arguments() {
	assert_cli_usage_error "Missing argument for 'scan'" scan || return 1
	assert_cli_usage_error "Missing argument for 'archive'" archive '' || return 1
	assert_cli_usage_error "Missing argument for 'rate'" rate 123 || return 1
	assert_cli_usage_error "Missing argument for 'hath'" hath || return 1
	assert_cli_usage_error "Missing argument for 'favorite'" favorite 123
}

test_cli_rejects_missing_option_values() {
	assert_cli_usage_error 'Missing value for --cookie.' login --cookie || return 1
	assert_cli_usage_error 'Missing value for --cookie.' login --cookie= || return 1
	assert_cli_usage_error 'Missing value for --cookie.' login --cookie --unknown || return 1
	assert_cli_usage_error 'Missing value for --rating.' feedback 123 --rating || return 1
	assert_cli_usage_error 'Missing value for --rating.' feedback 123 --rating= || return 1
	assert_cli_usage_error 'Missing value for --rating.' feedback 123 --rating --dry-run || return 1
	assert_cli_usage_error 'Missing value for --favorite.' feedback 123 --favorite || return 1
	assert_cli_usage_error 'Missing value for --favorite.' feedback 123 --favorite= || return 1
	assert_cli_usage_error 'Missing value for --max-count.' list --max-count || return 1
	assert_cli_usage_error 'Missing value for --max-count.' list --max-count= || return 1
	assert_cli_usage_error 'Missing value for --max-count.' list --max-count --format json || return 1
	assert_cli_usage_error 'Missing value for --format.' list --format || return 1
	assert_cli_usage_error 'Missing value for --format.' list --format= || return 1
	assert_cli_usage_error 'Missing value for --order-by.' list --order-by || return 1
	assert_cli_usage_error 'Missing value for --order-by.' list --order-by= || return 1
	assert_cli_usage_error 'Missing value for --group-by.' list --group-by || return 1
	assert_cli_usage_error 'Missing value for --group-by.' list --group-by= || return 1
	assert_cli_usage_error 'Missing value for --max-count.' repair-tags --max-count
}

test_cli_rejects_invalid_numeric_option_values() {
	assert_cli_usage_error "Invalid rating '0'" rate 123 0 || return 1
	assert_cli_usage_error "Invalid favorite category '10'" favorite 123 10 || return 1
	assert_cli_usage_error "Invalid rating '12'" feedback 123 --rating 12 || return 1
	assert_cli_usage_error "Invalid favorite category '-1'" feedback 123 --favorite -1 || return 1
	assert_cli_usage_error "Invalid max count '0'" list --max-count 0 || return 1
	assert_cli_usage_error "Invalid max count 'many'" list --max-count many || return 1
	assert_cli_usage_error "Invalid max count '0'" repair-tags --max-count 0 || return 1
	assert_cli_usage_error "Invalid max count '6'" repair-tags --max-count 6
}

test_cli_rejects_unsupported_sort_fields() {
	local order_field
	local unsupported_fields=(
		token title title_jpn file_count expunged tags rating favorite_count
		rating_count popularity_fetched_at file_path self_rating created_at
		updated_at rated_then_deleted_at feedbacked_at
	)

	for order_field in "${unsupported_fields[@]}"; do
		assert_cli_usage_error "Invalid order-by field '${order_field}'." \
			list --order-by "${order_field},asc" || return 1
	done

	assert_cli_usage_error "Invalid order-by field 'token'." \
		list --pending-feedback --order-by token,asc
	assert_cli_usage_error "Invalid order-by field 'artist_gid'." \
		list --order-by artist_gid,asc
	assert_cli_usage_error "Invalid order-by field 'artist_hath_requested_at'." \
		list --order-by artist_hath_requested_at,asc
}

test_cli_accepts_supported_sort_fields() {
	local home_dir="${TEST_TMPDIR}/supported-sort-home"
	local order_field
	local sqlite3_args="${TEST_TMPDIR}/supported-sort-sqlite3-args"

	mkdir -p "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/capture-sqlite3.sh" "${home_dir}/bin/sqlite3"

	for order_field in gid hath_requested_at; do
		SQLITE3_ARGS_PATH="${sqlite3_args}" HOME="${home_dir}" \
			"${TEST_ROOT}/bin/yomiko" list --format json \
			--order-by "${order_field},asc" >/dev/null || return 1
	done

	SQLITE3_ARGS_PATH="${sqlite3_args}" HOME="${home_dir}" \
		"${TEST_ROOT}/bin/yomiko" list --format json --group-by artist >/dev/null || return 1

	assert_cli_usage_error "Invalid group-by value 'title'." \
		list --group-by title || return 1
	assert_cli_usage_error 'Duplicate option: --group-by.' \
		list --group-by artist --group-by artist
}

prepare_archive_test() {
	local test_name="$1"
	local archive_title='[artist] title'
	case "${test_name}" in
	ellipsis)
		archive_title='[artist] title...'
		;;
	invalid-filename)
		archive_title=$'[artist] title\r'
		;;
	esac

	ARCHIVE_TEST_HOME="${TEST_TMPDIR}/archive-${test_name}-home"
	ARCHIVE_TEST_GALLERY="${ARCHIVE_TEST_HOME}/hath/${archive_title} [123]"
	ARCHIVE_TEST_FINAL="${ARCHIVE_TEST_HOME}/archived/[123]${archive_title}.7z"
	ARCHIVE_TEST_SQLITE_TRACE="${ARCHIVE_TEST_HOME}/sqlite.trace"
	ARCHIVE_TEST_SQLITE_ARGS="${ARCHIVE_TEST_HOME}/sqlite.args"
	ARCHIVE_TEST_COMMIT_TARGET_SQLITE_ARGS="${ARCHIVE_TEST_HOME}/sqlite-commit-target.args"

	mkdir -p "${ARCHIVE_TEST_HOME}/bin" "${ARCHIVE_TEST_GALLERY}"
	ln -s "${TEST_ROOT}/tests/fixtures/archive-bin/curl" "${ARCHIVE_TEST_HOME}/bin/curl"
	ln -s "${TEST_ROOT}/tests/fixtures/archive-bin/fd" "${ARCHIVE_TEST_HOME}/bin/fd"
	ln -s "${TEST_ROOT}/tests/fixtures/archive-bin/7z" "${ARCHIVE_TEST_HOME}/bin/7z"
	ln -s "${TEST_ROOT}/tests/fixtures/archive-bin/sqlite3" "${ARCHIVE_TEST_HOME}/bin/sqlite3"
	touch "${ARCHIVE_TEST_GALLERY}/galleryinfo.txt" "${ARCHIVE_TEST_GALLERY}/001.jpg"
}

run_archive_test() {
	HOME="${ARCHIVE_TEST_HOME}" \
		PATH="${ARCHIVE_TEST_HOME}/bin:${PATH}" \
		MOCK_GALLERY_DIR="${ARCHIVE_TEST_GALLERY}" \
		MOCK_FINAL_ARCHIVE="${ARCHIVE_TEST_FINAL}" \
		MOCK_SQLITE_TRACE="${ARCHIVE_TEST_SQLITE_TRACE}" \
		MOCK_SQLITE_ARGS_PATH="${ARCHIVE_TEST_SQLITE_ARGS}" \
		MOCK_SQLITE_COMMIT_TARGET_ARGS_PATH="${ARCHIVE_TEST_COMMIT_TARGET_SQLITE_ARGS}" \
		MOCK_METADATA_FAILURE="${MOCK_METADATA_FAILURE:-0}" \
		MOCK_INVALID_METADATA="${MOCK_INVALID_METADATA:-0}" \
		MOCK_CONVERSION_FAILURE="${MOCK_CONVERSION_FAILURE:-0}" \
		MOCK_COMPRESSION_FAILURE="${MOCK_COMPRESSION_FAILURE:-0}" \
		MOCK_COMMIT_FAILURE="${MOCK_COMMIT_FAILURE:-0}" \
		MOCK_DB_FAILURE="${MOCK_DB_FAILURE:-0}" \
		bash "${TEST_ROOT}/bin/yomiko" archive "${ARCHIVE_TEST_GALLERY}"
}

assert_no_archive_staging() {
	local staging_paths
	staging_paths="$(compgen -G "${ARCHIVE_TEST_HOME}/archived/.yomiko-archive-*" || true)"
	assert_eq '' "${staging_paths}"
}

test_archive_commits_after_database_update() {
	local trace sqlite_args
	prepare_archive_test success

	run_archive_test >/dev/null || return 1
	trace="$(<"${ARCHIVE_TEST_SQLITE_TRACE}")"
	sqlite_args="$(<"${ARCHIVE_TEST_SQLITE_ARGS}")"

	assert_eq 'insert stage_count=1 final_exists=0' "${trace}" || return 1
	assert_contains "${sqlite_args}" '.parameter set :title_jpn null' || return 1
	assert_contains "${sqlite_args}" '.parameter set :file_count 1' || return 1
	assert_contains "${sqlite_args}" '.parameter set :tags "CAST(X'\''5b226172746973743a74657374225d'\'' AS TEXT)"' || return 1
	assert_contains "${sqlite_args}" '.parameter set :rating 4.5' || return 1
	assert_not_contains "${sqlite_args}" ':category' || return 1
	assert_contains "${sqlite_args}" '.parameter set :posted 1722470400' || return 1
	assert_contains "${sqlite_args}" '.parameter set :filesize 123456' || return 1
	assert_contains "${sqlite_args}" '.parameter set :first_gid null' || return 1
	assert_contains "${sqlite_args}" '.parameter set :current_token null' || return 1
	assert_eq 'staged archive' "$(<"${ARCHIVE_TEST_FINAL}")" || return 1
	[[ ! -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'successful archive kept the source gallery' || return 1
	assert_no_archive_staging
}

test_archive_accepts_ellipsis_in_generated_filename() {
	local sqlite_args
	prepare_archive_test ellipsis

	run_archive_test >/dev/null || return 1
	sqlite_args="$(<"${ARCHIVE_TEST_COMMIT_TARGET_SQLITE_ARGS}")"
	assert_contains "${sqlite_args}" \
		".parameter set :file_path $(db_parameter_text '[123][artist] title....7z')" || return 1
	[[ -f "${ARCHIVE_TEST_FINAL}" ]] || fail 'ellipsis archive was not installed' || return 1
	[[ ! -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'ellipsis archive kept the source gallery' || return 1
	assert_no_archive_staging
}

test_archive_rejects_invalid_generated_filename_before_commit() {
	local output status=0
	prepare_archive_test invalid-filename

	output="$(run_archive_test 2>&1)" || status=$?
	assert_eq '6' "${status}" || return 1
	assert_contains "${output}" 'Generated archive filename is unsafe' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'invalid filename removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'invalid filename installed an archive' || return 1
	[[ ! -e "${ARCHIVE_TEST_SQLITE_TRACE}" ]] || fail 'invalid filename updated the database' || return 1
	assert_no_archive_staging
}

test_archive_database_failure_preserves_existing_archive() {
	prepare_archive_test db-failure
	mkdir -p "$(dirname "${ARCHIVE_TEST_FINAL}")"
	printf '%s\n' 'existing archive' >"${ARCHIVE_TEST_FINAL}"
	export MOCK_DB_FAILURE=1

	assert_failure run_archive_test >/dev/null || return 1

	assert_eq 'existing archive' "$(<"${ARCHIVE_TEST_FINAL}")" || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'database failure removed the source gallery' || return 1
	assert_no_archive_staging
}

test_archive_commit_failure_preserves_manifest_for_recovery() {
	local output status=0 stage_dir recovery_output
	prepare_archive_test commit-failure
	export MOCK_COMMIT_FAILURE=1

	output="$(run_archive_test 2>&1)" || status=$?
	assert_eq '70' "${status}" || return 1
	assert_contains "${output}" 'database path/retention handoff failed' || return 1
	[[ -f "${ARCHIVE_TEST_FINAL}" ]] || fail 'commit failure lost the renamed archive' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'commit failure removed the source gallery' || return 1
	stage_dir="$(compgen -G "${ARCHIVE_TEST_HOME}/archived/.yomiko-archive-*" | head -n 1)"
	[[ -f "${stage_dir}/commit.json" ]] || fail 'commit failure lost the recovery manifest' || return 1

	unset MOCK_COMMIT_FAILURE
	recovery_output="$(
		HOME="${ARCHIVE_TEST_HOME}" \
		PATH="${ARCHIVE_TEST_HOME}/bin:${PATH}" \
		DB_PATH="${ARCHIVE_TEST_HOME}/data/db.sqlite3" \
		MIGRATIONS_DIR="${TEST_ROOT}/migrations" \
		YOMIKO_CLI_IN_API_MODE=1 \
		bash -c 'source "${0}/lib/common.sh"; source "${0}/lib/path.sh"; source "${0}/lib/db.sh"; source "${0}/lib/variant_retention.sh"; variants_retention_recover_archive_staging' \
			"${TEST_ROOT}"
	)" || return 1
	assert_eq '1' "${recovery_output}" || return 1
	[[ -f "${ARCHIVE_TEST_FINAL}" ]] || fail 'recovery removed the committed archive' || return 1
	[[ ! -e "${stage_dir}" ]] || fail 'recovery left the committed manifest' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'recovery unexpectedly removed the source gallery' || return 1
}

test_archive_conversion_failure_cleans_staging() {
	prepare_archive_test conversion-failure
	export MOCK_CONVERSION_FAILURE=1

	assert_failure run_archive_test >/dev/null || return 1

	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'conversion failure removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'conversion failure installed an archive' || return 1
	assert_no_archive_staging
}

test_archive_compression_failure_cleans_staging() {
	prepare_archive_test compression-failure
	export MOCK_COMPRESSION_FAILURE=1

	assert_failure run_archive_test >/dev/null || return 1

	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'compression failure removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'compression failure installed an archive' || return 1
	assert_no_archive_staging
}

test_archive_metadata_failure_does_not_convert() {
	prepare_archive_test metadata-failure
	export MOCK_METADATA_FAILURE=1

	assert_failure run_archive_test >/dev/null || return 1

	[[ ! -e "${ARCHIVE_TEST_GALLERY}/001.webp" ]] || fail 'metadata failure started conversion' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'metadata failure removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'metadata failure installed an archive' || return 1
	assert_no_archive_staging
}

test_archive_invalid_metadata_does_not_convert_or_write() {
	prepare_archive_test invalid-metadata
	export MOCK_INVALID_METADATA=1

	assert_failure run_archive_test >/dev/null || return 1

	[[ ! -e "${ARCHIVE_TEST_GALLERY}/001.webp" ]] || fail 'invalid metadata started conversion' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'invalid metadata removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'invalid metadata installed an archive' || return 1
	[[ ! -e "${ARCHIVE_TEST_SQLITE_TRACE}" ]] || fail 'invalid metadata accessed the database' || return 1
	assert_no_archive_staging
}

test_archive_rejects_concurrent_gallery() {
	local lock_fd output status=0
	prepare_archive_test concurrent
	exec {lock_fd}>"/tmp/yomiko-archive-123.lock"
	flock -n "${lock_fd}" || return 1

	output="$(run_archive_test 2>&1)" || status=$?
	exec {lock_fd}>&-

	assert_eq '75' "${status}" || return 1
	assert_contains "${output}" 'Gallery 123 is already being archived.' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'busy archive removed the source gallery' || return 1
	[[ ! -e "${ARCHIVE_TEST_GALLERY}/001.webp" ]] || fail 'busy archive started conversion' || return 1
	[[ ! -e "${ARCHIVE_TEST_FINAL}" ]] || fail 'busy archive installed a final archive' || return 1
	[[ ! -e "${ARCHIVE_TEST_SQLITE_TRACE}" ]] || fail 'busy archive accessed the database' || return 1
	assert_no_archive_staging
}

test_scan_skips_concurrent_gallery() {
	local lock_fd output
	prepare_archive_test concurrent-scan
	ln -s "${TEST_ROOT}/bin/yomiko" "${ARCHIVE_TEST_HOME}/bin/yomiko"
	ln -s "${TEST_ROOT}/lib" "${ARCHIVE_TEST_HOME}/lib"
	exec {lock_fd}>"/tmp/yomiko-archive-123.lock"
	flock -n "${lock_fd}" || return 1

	output="$(
		HOME="${ARCHIVE_TEST_HOME}" \
			PATH="${ARCHIVE_TEST_HOME}/bin:${PATH}" \
			MOCK_SCAN_GALLERYINFO="${ARCHIVE_TEST_GALLERY}/galleryinfo.txt" \
			bash "${TEST_ROOT}/bin/yomiko" scan "${ARCHIVE_TEST_HOME}/hath" 2>&1
	)" || return 1
	exec {lock_fd}>&-

	assert_contains "${output}" 'Gallery 123 is already being archived.' || return 1
	assert_contains "${output}" 'Skipping gallery already being archived' || return 1
	assert_contains "${output}" 'Scan and Archive complete.' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'concurrent scan removed the source gallery'
}

test_scan_rejects_concurrent_scan() {
	local lock_fd output status=0
	prepare_archive_test scan-lock
	exec {lock_fd}>"/tmp/yomiko-scan.lockfile"
	flock -n "${lock_fd}" || return 1

	output="$(
		HOME="${ARCHIVE_TEST_HOME}" \
			PATH="${ARCHIVE_TEST_HOME}/bin:${PATH}" \
			bash "${TEST_ROOT}/bin/yomiko" scan "${ARCHIVE_TEST_HOME}/hath" 2>&1
	)" || status=$?
	exec {lock_fd}>&-

	assert_eq '75' "${status}" || return 1
	assert_contains "${output}" 'A scan is already in progress.' || return 1
	[[ -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'busy scan removed the source gallery'
}

test_metrics_runtime_state_tracks_outcomes_and_does_not_block_work() {
	command -v sqlite3 >/dev/null || return 0

	local status=0 output broken_db
	prepare_variant_runtime_test metrics-runtime || return 1

	metrics_runtime_run scan true || return 1
	metrics_runtime_run variant_worker bash -c 'exit 7' >/dev/null || status=$?
	assert_eq '7' "${status}" || return 1
	assert_eq $'1|0|0|0\n0|1|7|1' "$(db_query "SELECT success_count,failure_count,last_exit_code,last_failure_at IS NOT NULL FROM runtime_component_state WHERE component='scan'; SELECT success_count,failure_count,last_exit_code,last_failure_at IS NOT NULL FROM runtime_component_state WHERE component='variant_worker';")" || return 1

	broken_db="${TEST_TMPDIR}/metrics-runtime-broken"
	mkdir -p "${broken_db}"
	DB_PATH="${broken_db}"
	output="$(metrics_runtime_run scan true 2>&1)" || return 1
	assert_contains "${output}" 'Failed to record scan start' || return 1
	assert_contains "${output}" 'Failed to record scan result' || return 1
}

test_metrics_cli_emits_bounded_prometheus_payload() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-cli-home"
	local output build_version escaped_version family help_count type_count
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(gid,token,title,tags,file_path)
		VALUES(101,'token-101','Source','[]','source.7z');
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
		VALUES(101,11,1,'none');
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json)
	VALUES(1,101,'confirmed','automatic','{}');
	UPDATE variant_groups SET canonical_gid=101 WHERE source_gid=101;
	INSERT INTO variant_jobs(
		job_type,group_id,source_gid,status,attempt_count,last_error_class,last_error)
	VALUES('discover',1,101,'failed',5,'uncertain','raw secret error');
	INSERT INTO variant_actions(
		group_id,gid,action_type,desired_value,policy_revision_id,status,
		attempt_count,last_error_class,last_error)
	VALUES(1,101,'hath_request','secret desired value',1,'retryable_error',5,
		'uncertain','another raw secret error');
	UPDATE galleries SET file_path='unsafe/archive.7z' WHERE gid=101;" || return 1

	build_version=$'release"\\\nline'
	escaped_version="$(metrics_escape_label "${build_version}")"
	output="$(YOMIKO_BUILD_VERSION="${build_version}" bash "${TEST_ROOT}/bin/yomiko" metrics)" || return 1

	assert_contains "${output}" "yomiko_build_info{version=\"${escaped_version}\"} 1" || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scheduler_tick"} 180' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="variant_worker"} 240' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scan"} 900' || return 1
	assert_contains "${output}" 'yomiko_variant_job_errors{job_type="discover",status="failed",error_class="uncertain"} 1' || return 1
	assert_contains "${output}" 'yomiko_variant_job_outcomes_total{job_type="discover",outcome="completed"} 0' || return 1
	assert_eq '30' "$(grep -c '^yomiko_variant_job_outcomes_total{' <<<"${output}")" || return 1
	assert_contains "${output}" 'yomiko_variant_actions{action_type="hath_request",status="retryable_error",error_class="uncertain"} 1' || return 1
	assert_not_contains "${output}" 'yomiko_variant_actionable_reviews' || return 1
	assert_not_contains "${output}" 'invariant="review_state_mismatch"' || return 1
	assert_eq '5' "$(grep -c '^yomiko_variant_review_outcome_audit_records{' <<<"${output}")" || return 1
	assert_eq $'yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="same_book"} 0\nyomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="different_book"} 0\nyomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="superseded"} 0\nyomiko_variant_review_outcome_audit_records{review_type="winner",resolution="winner"} 0\nyomiko_variant_review_outcome_audit_records{review_type="winner",resolution="superseded"} 0' "$(grep '^yomiko_variant_review_outcome_audit_records{' <<<"${output}")" || return 1
	assert_contains "${output}" 'yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="same_book"} 0' || return 1
	assert_contains "${output}" 'yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="different_book"} 0' || return 1
	assert_contains "${output}" 'yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="superseded"} 0' || return 1
	assert_contains "${output}" 'yomiko_variant_review_outcome_audit_records{review_type="winner",resolution="winner"} 0' || return 1
	assert_contains "${output}" 'yomiko_variant_review_outcome_audit_records{review_type="winner",resolution="superseded"} 0' || return 1
	assert_not_contains "${output}" 'yomiko_variant_reviews' || return 1
	assert_not_contains "${output}" 'yomiko_variant_oldest_pending_review_age_seconds' || return 1
	assert_contains "${output}" 'yomiko_variant_invariant_violations{invariant="unsafe_archive_path"} 1' || return 1
	assert_contains "${output}" 'yomiko_gallery_data_quality_records{problem="missing_page_count"} 1' || return 1
	assert_contains "${output}" 'yomiko_gallery_data_quality_records{problem="missing_popularity"} 1' || return 1
	# Schema 27 deliberately excludes incomplete/invalid uploader components
	# from active variant visibility; this fixture omits scoring inputs, so the
	# archived row remains in the ordinary pending-rating partition.
	assert_contains "${output}" 'yomiko_gallery_status{state="rated_variant_canonical"} 0' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="rated_variant_alternate"} 0' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="rated_variant_pending_selection"} 0' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="different_book"} 0' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="pending_rating"} 1' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="hath_requested"} 0' || return 1
	assert_contains "${output}" 'yomiko_gallery_status{state="unclassified"} 0' || return 1
	assert_contains "${output}" 'yomiko_galleries 1' || return 1
	assert_not_contains "${output}" 'raw secret error' || return 1
	assert_not_contains "${output}" 'secret desired value' || return 1
	assert_not_contains "${output}" 'unsafe/archive.7z' || return 1
	assert_not_contains "${output}" 'gid="101"' || return 1

	help_count="$(grep -c '^# HELP ' <<<"${output}")"
	type_count="$(grep -c '^# TYPE ' <<<"${output}")"
	assert_eq '37' "${help_count}" || return 1
	assert_eq '37' "${type_count}" || return 1
	assert_eq '1' "$(grep -c '^# HELP yomiko_variant_review_outcome_audit_records Retained variant review audit records by review type and projected terminal resolution\.$' <<<"${output}")" || return 1
	while read -r family; do
		[[ -n "${family}" ]] || continue
		assert_eq '1' "$(grep -c "^# HELP ${family} " <<<"${output}")" || return 1
		assert_eq '1' "$(grep -c "^# TYPE ${family} " <<<"${output}")" || return 1
	done <<'EOF'
yomiko_build_info
yomiko_database_schema_version
yomiko_database_file_size_bytes
yomiko_runtime_runs_total
yomiko_runtime_last_started_timestamp_seconds
yomiko_runtime_last_success_timestamp_seconds
yomiko_runtime_success_stale_after_seconds
yomiko_runtime_last_failure_timestamp_seconds
yomiko_runtime_last_duration_seconds
yomiko_runtime_last_exit_code
yomiko_variant_jobs
yomiko_variant_job_errors
yomiko_variant_job_outcomes_total
yomiko_variant_runnable_jobs
yomiko_variant_oldest_runnable_job_age_seconds
yomiko_variant_job_max_attempts
yomiko_variant_high_attempt_jobs
yomiko_variant_jobs_created_recent
yomiko_variant_actions
yomiko_variant_runnable_actions
yomiko_variant_oldest_runnable_action_age_seconds
yomiko_variant_oldest_action_state_age_seconds
yomiko_variant_action_max_attempts
yomiko_variant_high_attempt_actions
yomiko_variant_expired_leases
yomiko_variant_discovery_runs
yomiko_variant_discovery_errors
yomiko_variant_oldest_discovery_run_age_seconds
yomiko_variant_discovery_candidates
yomiko_uploader_revision_publication_blocked
yomiko_variant_review_outcome_audit_records
yomiko_variant_groups
yomiko_variant_discovery_due_groups
yomiko_variant_invariant_violations
yomiko_gallery_data_quality_records
yomiko_gallery_status
yomiko_galleries
EOF
}

test_metrics_runtime_stale_after_is_fixed_on_empty_and_populated_databases() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-stale-after-home"
	local output
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1

	output="$(bash "${TEST_ROOT}/bin/yomiko" metrics)" || return 1
	assert_eq '3' "$(grep -c '^yomiko_runtime_success_stale_after_seconds{' <<<"${output}")" || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scheduler_tick"} 180' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="variant_worker"} 240' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scan"} 900' || return 1

	db_write "UPDATE runtime_component_state
		SET success_count=success_count+1,
			last_success_at='2026-09-15T00:00:00Z'
		WHERE component IN ('scheduler_tick','variant_worker','scan');" || return 1
	output="$(bash "${TEST_ROOT}/bin/yomiko" metrics)" || return 1
	assert_eq '3' "$(grep -c '^yomiko_runtime_success_stale_after_seconds{' <<<"${output}")" || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scheduler_tick"} 180' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="variant_worker"} 240' || return 1
	assert_contains "${output}" 'yomiko_runtime_success_stale_after_seconds{component="scan"} 900' || return 1
}

test_metrics_runtime_stale_after_rejects_invalid_renderer_rows() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-stale-after-invalid-home"
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1

	# shellcheck disable=SC2317
	metrics_sql() {
		cat <<'EOF'
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scheduler_tick', '', '', -1
UNION ALL
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'variant_worker', '', '', 240
UNION ALL
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scan', '', '', 900;
EOF
	}
	assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1

	# shellcheck disable=SC2317
	metrics_sql() {
		cat <<'EOF'
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scheduler_tick', '', '', 180
UNION ALL
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scheduler_tick', '', '', 180
UNION ALL
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scan', '', '', 900;
EOF
	}
	assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1

	# shellcheck disable=SC2317
	metrics_sql() {
		cat <<'EOF'
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'variant_worker', '', '', 240
UNION ALL
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', 'scan', '', '', 900;
EOF
	}
	assert_failure metrics_emit_payload >/dev/null 2>&1
}

test_metrics_review_outcome_renderer_requires_fixed_complete_rows() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-review-outcome-renderer-home"
	local shape output
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"

	metrics_test_renderer_sql() {
		cat <<EOF
WITH
components(component, value) AS (
  VALUES ('scheduler_tick', 180), ('variant_worker', 240), ('scan', 900)
),
job_types(job_type) AS (
  VALUES ('discover'), ('evaluate'), ('reconcile_actions'),
         ('reconcile_retention'), ('policy_scoring_sweep')
),
job_statuses(status) AS (
  VALUES ('queued'), ('leased'), ('completed'), ('failed'), ('cancelled')
),
job_outcomes(outcome) AS (
  VALUES ('completed'), ('continued'), ('retryable_error'),
         ('permanent_error'), ('configuration_error'), ('cancelled')
),
blocked_publication_reasons(reason) AS (
  VALUES ('reference_incomplete'), ('scope_incomplete'),
         ('scoring_input_incomplete'), ('token_mismatch'),
         ('relation_conflict'), ('cycle'), ('branch'), ('multiple_terminals')
)
SELECT 23, 'yomiko_runtime_success_stale_after_seconds', component, '', '', value
  FROM components
UNION ALL
SELECT 30, 'yomiko_variant_jobs', job_type, status, '', 0
  FROM job_types CROSS JOIN job_statuses
UNION ALL
SELECT 32, 'yomiko_variant_job_outcomes_total', job_type, outcome, '', 0
  FROM job_types CROSS JOIN job_outcomes
UNION ALL
SELECT 54, 'yomiko_uploader_revision_publication_blocked', reason, '', '', 0
  FROM blocked_publication_reasons
${METRICS_TEST_OUTCOME_ROWS}
;
EOF
	}
	# shellcheck disable=SC2317
	metrics_sql() { metrics_test_renderer_sql; }

	for shape in valid duplicate unknown_type invalid_pair unknown_resolution extra_label missing negative decimal; do
		case "${shape}" in
		valid)
			output="$(metrics_emit_payload)" || return 1
			assert_eq '5' "$(grep -c '^yomiko_variant_review_outcome_audit_records{' <<<"${output}")" || return 1
			;;
		duplicate)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		unknown_type)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'other', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		invalid_pair)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		unknown_resolution)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'other', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		extra_label)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', 'unexpected', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		missing)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		negative)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', -1
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		decimal)
			METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 1.5
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
			assert_failure metrics_emit_payload >/dev/null 2>&1 || return 1
			;;
		esac
		METRICS_TEST_OUTCOME_ROWS="UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'same_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'different_book', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'candidate_identity', 'superseded', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'winner', '', 0
UNION ALL
SELECT 54, 'yomiko_variant_review_outcome_audit_records', 'winner', 'superseded', '', 0"
	done
}

test_metrics_gallery_status_is_exclusive_and_matches_pending_feedback() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-gallery-status-home"
	local output pending_output status_lines status_line state value sum=0
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	db_write "INSERT INTO galleries(
		gid,token,title,tags,file_path,feedbacked_at,self_rating,
		rated_then_deleted_at,hath_requested_at,hath_last_attempted_at
	) VALUES
		(1,'token-1','Canonical','[]',NULL,NULL,0,NULL,NULL,NULL),
		(2,'token-2','Alternate after cleanup','[]',NULL,NULL,0,'2026-09-15T00:00:00Z','2026-09-14T00:00:00Z',NULL),
		(3,'token-3','Pending selection','[]','pending-selection-3.7z',NULL,0,NULL,NULL,NULL),
		(4,'token-4','Different archived','[]','different-4.7z',NULL,0,NULL,NULL,NULL),
		(5,'token-5','Different unarchived','[]',NULL,NULL,0,NULL,NULL,NULL),
		(6,'token-6','Pending archived','[]','pending-6.7z',NULL,0,NULL,NULL,NULL),
		(7,'token-7','Hath requested','[]',NULL,NULL,0,NULL,'2026-09-17T00:00:00Z',NULL),
		(8,'token-8','Hath attempted','[]','',NULL,0,NULL,NULL,'2026-09-17T00:00:00Z'),
		(9,'token-9','Stale pre-cleanup request','[]',NULL,NULL,0,'2026-09-15T00:00:00Z','2026-09-14T00:00:00Z',NULL),
		(10,'token-10','Equal cleanup request','[]',NULL,NULL,0,'2026-09-15T00:00:00Z','2026-09-15T00:00:00Z',NULL),
		(11,'token-11','No acquisition marker','[]','',NULL,0,NULL,NULL,NULL),
		(12,'token-12','Already archived','[]','archived-12.7z','2026-09-15T00:00:00Z',0,NULL,'2026-09-17T00:00:00Z',NULL),
		(13,'token-13','Feedbacked','[]','feedbacked-13.7z','2026-09-15T00:00:00Z',0,NULL,NULL,NULL),
		(14,'token-14','Self rated','[]','self-rated-14.7z',NULL,7,NULL,NULL,NULL),
		(15,'token-15','Inactive pending feedback','[]','inactive-15.7z',NULL,0,NULL,NULL,NULL);
	INSERT INTO variant_groups(id,source_gid,desired_rating,is_active,identity_active,review_state)
	VALUES(1,1,11,1,1,'none'),(2,3,11,1,1,'none'),(3,13,11,0,0,'none');
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json
	) VALUES
		(1,1,'confirmed','automatic','{}'),
		(1,2,'confirmed','manual','{}'),
		(2,3,'confirmed','automatic','{}'),
		(3,13,'confirmed','automatic','{}'),
		(3,15,'candidate','automatic','{}');
	UPDATE variant_groups SET canonical_gid=1 WHERE id=1;
	INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json,
		status,decision,resolved_at
	)
	SELECT 'candidate_identity',1,5,id,${VARIANTS_MATCHING_REVISION},'{}','[4,5]','resolved','different_book','2026-09-15T00:00:00Z'
	  FROM variant_policy_revisions WHERE is_active=1;
	INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
	SELECT 4,5,id FROM variant_reviews
	 WHERE review_type='candidate_identity' AND decision='different_book';" || return 1

	output="$(bash "${TEST_ROOT}/bin/yomiko" metrics)" || return 1
	status_lines="$(grep '^yomiko_gallery_status{' <<<"${output}")"
	assert_eq '7' "$(wc -l <<<"${status_lines}" | tr -d ' ')" || return 1
	assert_eq $'rated_variant_canonical\nrated_variant_alternate\nrated_variant_pending_selection\ndifferent_book\npending_rating\nhath_requested\nunclassified' \
		"$(sed -n 's/^yomiko_gallery_status{state="\([^"]*\)"}.*/\1/p' <<<"${status_lines}")" || return 1
	declare -A status_counts=()
	while IFS= read -r status_line; do
		[[ "${status_line}" =~ ^yomiko_gallery_status\{state=\"([a-z_]+)\"\}\ ([0-9]+)$ ]] || return 1
		state="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[2]}"
		case "${state}" in
		rated_variant_canonical | rated_variant_alternate | rated_variant_pending_selection | \
		different_book | pending_rating | hath_requested | unclassified) ;;
		*) return 1 ;;
		esac
		[[ -z "${status_counts[${state}]+present}" ]] || return 1
		status_counts["${state}"]="${value}"
		sum=$((sum + value))
	done <<<"${status_lines}"
	assert_eq '7' "${#status_counts[@]}" || return 1
	assert_eq '0' "${status_counts[rated_variant_canonical]}" || return 1
	assert_eq '0' "${status_counts[rated_variant_alternate]}" || return 1
	assert_eq '0' "${status_counts[rated_variant_pending_selection]}" || return 1
	assert_eq '2' "${status_counts[different_book]}" || return 1
	assert_eq '3' "${status_counts[pending_rating]}" || return 1
	assert_eq '2' "${status_counts[hath_requested]}" || return 1
	assert_eq '8' "${status_counts[unclassified]}" || return 1
	assert_eq '15' "${sum}" || return 1
	assert_eq 'yomiko_galleries 15' "$(grep '^yomiko_galleries' <<<"${output}")" || return 1
	assert_not_contains "${output}" 'yomiko_gallery_status{state="rejected"}' || return 1
	assert_not_contains "${output}" 'gid=' || return 1
	assert_not_contains "${output}" '7z' || return 1

	pending_output="$(bash "${TEST_ROOT}/bin/yomiko" list --format json --pending-feedback --max-count 50)" || return 1
	assert_eq '4' "$(jq 'length' <<<"${pending_output}")" || return 1
	assert_eq '3,4,6,15' "$(jq -r '[.[].gid] | sort | join(",")' <<<"${pending_output}")" || return 1
}

test_metrics_gallery_status_emits_zero_series_for_empty_database() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/metrics-gallery-status-empty-home"
	local output status_line
	mkdir -p "${home_dir}/migrations" "${home_dir}/data" "${home_dir}/bin"
	cp "${TEST_ROOT}"/migrations/*.sql "${home_dir}/migrations/"
	HOME="${home_dir}"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export HOME DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1

	output="$(bash "${TEST_ROOT}/bin/yomiko" metrics)" || return 1
	assert_eq '7' "$(grep -c '^yomiko_gallery_status{' <<<"${output}")" || return 1
	while IFS= read -r status_line; do
		[[ "${status_line}" =~ ^yomiko_gallery_status\{state=\"(rated_variant_canonical|rated_variant_alternate|rated_variant_pending_selection|different_book|pending_rating|hath_requested|unclassified)\"\}\ 0$ ]] || return 1
	done < <(grep '^yomiko_gallery_status{' <<<"${output}")
	assert_eq 'yomiko_galleries 0' "$(grep '^yomiko_galleries' <<<"${output}")" || return 1
	assert_not_contains "${output}" 'yomiko_variant_oldest_pending_review_age_seconds' || return 1
	assert_eq '37' "$(grep -c '^# HELP ' <<<"${output}")" || return 1
	assert_eq '37' "$(grep -c '^# TYPE ' <<<"${output}")" || return 1
}

test_metrics_api_authentication_and_failure_redaction() {
	local token_file="${TEST_TMPDIR}/metrics-token"
	local fixture="${TEST_ROOT}/tests/fixtures/metrics-yomiko.sh"
	local log_file="${TEST_TMPDIR}/metrics-api.log"
	local response
	printf '%s\n' 'metrics-test-token' >"${token_file}"

	response="$(
		YOMIKO_METRICS_TOKEN_FILE="${token_file}" \
		HTTP_AUTHORIZATION='Bearer metrics-test-token' REQUEST_METHOD=GET \
		YOMIKO_BIN="${fixture}" \
		bash "${TEST_ROOT}/web/api/metrics.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 200 OK' || return 1
	assert_contains "${response}" 'Content-Type: text/plain; version=0.0.4; charset=utf-8' || return 1
	assert_contains "${response}" 'fixture_metric 1' || return 1
	assert_not_contains "${response}" 'Access-Control-Allow-Origin' || return 1

	response="$(
		YOMIKO_METRICS_TOKEN_FILE="${token_file}" HTTP_AUTHORIZATION='Bearer wrong-token' \
		REQUEST_METHOD=GET YOMIKO_BIN="${fixture}" \
		bash "${TEST_ROOT}/web/api/metrics.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 401 Unauthorized' || return 1
	assert_contains "${response}" 'WWW-Authenticate: Bearer' || return 1
	assert_not_contains "${response}" 'fixture_metric' || return 1

	response="$(
		REQUEST_METHOD=GET YOMIKO_BIN="${fixture}" \
		bash "${TEST_ROOT}/web/api/metrics.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 503 Service Unavailable' || return 1
	assert_not_contains "${response}" 'fixture_metric' || return 1

	response="$(REQUEST_METHOD=POST bash "${TEST_ROOT}/web/api/metrics.sh")" || return 1
	assert_contains "${response}" 'Status: 405 Method Not Allowed' || return 1
	assert_contains "${response}" 'Allow: GET' || return 1

	response="$(
		YOMIKO_METRICS_TOKEN_FILE="${token_file}" \
		HTTP_AUTHORIZATION='Bearer metrics-test-token' REQUEST_METHOD=GET \
		METRICS_FIXTURE_FAILURE=1 YOMIKO_BIN="${fixture}" \
		bash "${TEST_ROOT}/web/api/metrics.sh" 2>"${log_file}"
	)" || return 1
	assert_contains "${response}" 'Status: 500 Internal Server Error' || return 1
	assert_contains "${response}" 'Metrics collection failed' || return 1
	assert_not_contains "${response}" 'internal metrics failure' || return 1
	assert_contains "$(<"${log_file}")" 'internal metrics failure'
}

test_repair_tags_is_dry_run_safe_and_resumable() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/repair-tags-home"
	local curl_trace="${TEST_TMPDIR}/repair-tags-curl.trace"
	local output gid status=0
	mkdir -p "${home_dir}/bin" "${home_dir}/data" "${home_dir}/migrations"
	cp "${TEST_ROOT}"/migrations/00[1-3]_*.sql "${home_dir}/migrations/"
	DB_PATH="${home_dir}/data/db.sqlite3"
	MIGRATIONS_DIR="${home_dir}/migrations"
	export DB_PATH MIGRATIONS_DIR
	db_init >/dev/null || return 1
	for gid in 123 124 125 126 127 128; do
		db_write "INSERT INTO galleries (gid, token, title, tags) VALUES (${gid}, 'test-token', 'Test title', NULL);" || return 1
	done
	ln -s "${TEST_ROOT}/tests/fixtures/archive-bin/curl" "${home_dir}/bin/curl"

	output="$(
		HOME="${home_dir}" \
			PATH="${home_dir}/bin:${PATH}" \
			MOCK_CURL_TRACE="${curl_trace}" \
			bash "${TEST_ROOT}/bin/yomiko" repair-tags --force 2>&1
	)" || status=$?
	assert_eq '1' "${status}" || return 1
	assert_contains "${output}" 'Tag repair requires database schema migration 004 or newer.' || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'pre-migration repair made API requests' || return 1

	cp "${TEST_ROOT}/migrations/004_validate_gallery_tags.sql" "${home_dir}/migrations/"
	db_init >/dev/null || return 1
	status=0
	output="$(
		HOME="${home_dir}" \
			PATH="${home_dir}/bin:${PATH}" \
			MOCK_CURL_TRACE="${curl_trace}" \
			bash "${TEST_ROOT}/bin/yomiko" repair-tags </dev/null 2>&1
	)" || status=$?
	assert_eq '1' "${status}" || return 1
	assert_contains "${output}" 'Migration 004 prevents new invalid tags but does not backfill legacy null values.' || return 1
	assert_contains "${output}" 'Tag repair cancelled. Use --force for non-interactive execution.' || return 1
	assert_eq '6' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE tags IS NULL;')" || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'unconfirmed repair made API requests' || return 1

	output="$(
		HOME="${home_dir}" \
			PATH="${home_dir}/bin:${PATH}" \
			MOCK_METADATA_FAILURE=1 \
			bash "${TEST_ROOT}/bin/yomiko" repair-tags --dry-run
	)" || return 1
	assert_contains "${output}" 'Gallery records needing tag repair: 6.' || return 1
	assert_contains "${output}" 'Would attempt tag repair for 5 gallery record(s) in this run.' || return 1
	assert_eq '6' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE tags IS NULL;')" || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'repair dry run made API requests' || return 1

	output="$(
		HOME="${home_dir}" \
			PATH="${home_dir}/bin:${PATH}" \
			MOCK_CURL_TRACE="${curl_trace}" \
			bash "${TEST_ROOT}/bin/yomiko" repair-tags --force
	)" || return 1
	assert_contains "${output}" 'Gallery records needing tag repair: 6.' || return 1
	assert_contains "${output}" 'Tag repair complete: 5 repaired, 0 failed, 1 remaining.' || return 1
	assert_eq '5' "$(wc -l <"${curl_trace}")" || return 1
	assert_eq '["artist:test"]' "$(db_query 'SELECT tags FROM galleries WHERE gid = 123;')" || return 1

	output="$(
		HOME="${home_dir}" \
			PATH="${home_dir}/bin:${PATH}" \
			MOCK_CURL_TRACE="${curl_trace}" \
			bash "${TEST_ROOT}/bin/yomiko" repair-tags --max-count 1 --force
	)" || return 1
	assert_contains "${output}" 'Gallery records needing tag repair: 1.' || return 1
	assert_contains "${output}" 'Tag repair complete: 1 repaired, 0 failed, 0 remaining.' || return 1
	assert_eq '6' "$(wc -l <"${curl_trace}")"
}

test_origin_matching() {
	export HTTP_HOST='localhost:8080'

	assert_success api_origin_matches_host 'http://localhost:8080' || return 1
	assert_success api_origin_matches_host 'https://localhost:8080' || return 1
	assert_failure api_origin_matches_host 'https://example.com' || return 1
	assert_failure api_origin_matches_host 'http://localhost:8081'
}

test_cors_headers_for_matching_origin() {
	export HTTP_HOST='localhost:8080'
	export HTTP_ORIGIN='http://localhost:8080'
	export HTTP_ACCESS_CONTROL_REQUEST_HEADERS='X-Test'

	local headers
	headers="$(api_cors_headers)"

	assert_contains "${headers}" 'Access-Control-Allow-Origin: http://localhost:8080' || return 1
	assert_contains "${headers}" 'Access-Control-Allow-Headers: X-Test' || return 1
	assert_contains "${headers}" 'Access-Control-Max-Age: 86400'
}

test_api_command_output_is_not_returned() {
	local endpoint="$1"
	local method="$2"
	local query="$3"
	local log_file="${TEST_TMPDIR}/${endpoint}.log"
	local response
	local home_dir="${TEST_TMPDIR}/home"

	mkdir -p "${home_dir}/bin"
	ln -sf "${TEST_ROOT}/tests/fixtures/failing-yomiko.sh" "${home_dir}/bin/yomiko"

	response="$(
		HOME="${home_dir}" \
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/failing-yomiko.sh" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD="${method}" \
		QUERY_STRING="${query}" \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/${endpoint}" 2>"${log_file}"
	)" || return 1

	if [[ "${response}" == *'internal command output must stay server-side'* ]]; then
		fail "${endpoint} returned internal command output"
		return 1
	fi

	assert_contains "${response}" '"success": false' || return 1
	assert_contains "$(<"${log_file}")" 'internal command output must stay server-side'
}

test_feedback_api_returns_variant_queue_fields_and_rejects_malformed_cli_json() {
	local response body
	local fixture="${TEST_ROOT}/tests/fixtures/feedback-result-yomiko.sh"

	response="$(
		MOCK_FEEDBACK_RESULT=high \
		YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='gid=101&rating=11' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/feedback.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e '.success == true and .variant_queued == true and (has("variant_group_id") | not)' <<<"${body}" >/dev/null || return 1

	response="$(
		MOCK_FEEDBACK_RESULT=low \
		YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='gid=101&rating=7' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/feedback.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e '.success == true and .variant_queued == false and (has("variant_group_id") | not)' <<<"${body}" >/dev/null || return 1

	response="$(
		MOCK_FEEDBACK_RESULT=malformed \
		YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='gid=101&rating=11' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/feedback.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1

	response="$(
		MOCK_REVIEW_RESULT=legacy YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/reviews.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1
	assert_contains "${response}" '"success": false'
}

test_variant_review_apis_list_validate_auth_resolve_and_report_stale() {
	local response body trace="${TEST_TMPDIR}/review-api.args"
	local fixture="${TEST_ROOT}/tests/fixtures/reviews-yomiko.sh"

	response="$(
		YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='status=pending' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/reviews.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e 'type == "object" and keys == ["actionable_count", "reviews", "success"] and .success == true and (.reviews | length) == 1 and .reviews[0].id == 7' <<<"${body}" >/dev/null || return 1
	[[ "${body}" != *$'\n'* ]] || fail 'review API response body was not compact' || return 1

	response="$(
		YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='status=unknown' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/reviews.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 400 Bad Request' || return 1

	response="$(
		MOCK_REVIEW_RESULT=malformed YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/reviews.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1

	local invalid_result
	for invalid_result in invalid-count extra-key duplicate-key multiline json5; do
		response="$(
			MOCK_REVIEW_RESULT="${invalid_result}" YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='' HTTP_ORIGIN='' \
			bash "${TEST_ROOT}/web/api/reviews.sh" 2>/dev/null
		)" || return 1
		assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1
		assert_not_contains "${response}" 'Status: 200 OK' || return 1
	done

	response="$(
		MOCK_REVIEW_RESULT=private-key YOMIKO_BIN="${fixture}" REQUEST_METHOD=GET QUERY_STRING='' HTTP_ORIGIN='' \
			bash "${TEST_ROOT}/web/api/reviews.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1
	assert_not_contains "${response}" 'Status: 200 OK' || return 1

	response="$(
		MOCK_REVIEW_ARGS_PATH="${trace}" YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='review_id=7&decision=same-book' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/review_resolve.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e '.success == true and .resolved == true and .review_id == 7' <<<"${body}" >/dev/null || return 1
	jq -e '.canonical_gid == null and (has("selected_gid") | not)' <<<"${body}" >/dev/null || return 1
	assert_eq 'variants resolve 7 --decision same-book' "$(<"${trace}")" || return 1

	response="$(
		MOCK_REVIEW_RESULT=legacy YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='review_id=7&decision=same-book' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/review_resolve.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1

	response="$(
		YOMIKO_BIN="${fixture}" YOMIKO_API_TOKEN='test-token' HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='review_id=7&decision=winner' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/review_resolve.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 400 Bad Request' || return 1
	assert_contains "${response}" 'Missing gid query parameter for winner decision' || return 1

	response="$(
		MOCK_REVIEW_RESULT=stale YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='review_id=7&decision=winner&gid=102' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/review_resolve.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 409 Conflict' || return 1
	assert_contains "${response}" 'Review is stale or already resolved'
}

test_pending_feedback_api_returns_display_fields() {
	local response body

	response="$(
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD='GET' \
		QUERY_STRING='max_count=1' \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh"
	)" || return 1
	body="${response#*$'\n\n'}"

	jq -e '
		.success == true
		and .galleries == [{
			gid: 123456,
			title: "Displayed title",
			title_jpn: "Displayed Japanese title",
			file_count: 42,
			file_path: "gallery.7z"
		}]
	' <<<"${body}" >/dev/null || fail 'pending feedback API returned fields outside the display payload'
}

test_pending_feedback_api_defaults_to_oldest_hath_request_by_artist() {
	local args_file="${TEST_TMPDIR}/pending-feedback-api-args"

	MOCK_LIST_ARGS_PATH="${args_file}" \
	YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
	REQUEST_METHOD='GET' \
	QUERY_STRING='max_count=20' \
	HTTP_ORIGIN='' \
	bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh" >/dev/null || return 1

	assert_contains "$(<"${args_file}")" \
		'list --format json --pending-feedback --max-count 20 --group-by artist --order-by hath_requested_at,asc'
}

test_pending_feedback_api_forwards_supported_sorts() {
	local args_file="${TEST_TMPDIR}/pending-feedback-api-hath-order-args"
	local order_by

	for order_by in gid,asc hath_requested_at,desc; do
		MOCK_LIST_ARGS_PATH="${args_file}" \
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD='GET' \
		QUERY_STRING="order_by=${order_by}" \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh" >/dev/null || return 1

		assert_contains "$(<"${args_file}")" \
			"list --format json --pending-feedback --max-count 50 --group-by artist --order-by ${order_by}" || return 1
	done
}

test_pending_feedback_api_rejects_non_queue_sort_fields() {
	local response order_by

	for order_by in token,asc artist_gid,asc artist_hath_requested_at,asc; do
		response="$(
			YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/fail-if-called.sh" \
			REQUEST_METHOD='GET' \
			QUERY_STRING="order_by=${order_by}" \
			HTTP_ORIGIN='' \
			bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh"
		)" || return 1

		assert_contains "${response}" 'Status: 400 Bad Request' || return 1
		assert_contains "${response}" "Unsupported field: ${order_by%%,*}" || return 1
	done
}

test_pending_feedback_list_builds_artist_group_query() {
	local home_dir="${TEST_TMPDIR}/artist-sort-home"
	local sqlite3_args="${TEST_TMPDIR}/artist-sort-sqlite3-args"

	mkdir -p "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/capture-sqlite3.sh" "${home_dir}/bin/sqlite3"

	SQLITE3_ARGS_PATH="${sqlite3_args}" \
	HOME="${home_dir}" \
	"${TEST_ROOT}/bin/yomiko" list --format json --pending-feedback --max-count 50 \
		--group-by artist --order-by gid,desc >/dev/null || return 1

	local query
	query="$(<"${sqlite3_args}")"
	assert_contains "${query}" 'json_each' || return 1
	assert_contains "${query}" 'WITH artist_galleries AS' || return 1
	assert_contains "${query}" 'SELECT galleries.*' || return 1
	assert_contains "${query}" 'ORDER BY artist_galleries.artist_sort_key ASC, artist_galleries.gid DESC' || return 1
	assert_not_contains "${query}" 'artist_group_order' || return 1
	assert_not_contains "${query}" 'OVER (PARTITION BY artist_sort_key)' || return 1
	assert_not_contains "${query}" 'MIN(' || return 1
	assert_not_contains "${query}" 'MAX(' || return 1
}

test_pending_feedback_artist_group_sort_is_stable_after_boundary_removal() {
	command -v sqlite3 >/dev/null || return 0

	local home_dir="${TEST_TMPDIR}/artist-group-behavior-home"
	local DB_PATH="${home_dir}/data/db.sqlite3"
	mkdir -p "${home_dir}/data"

	db_write "
		CREATE TABLE galleries (
			gid INTEGER PRIMARY KEY,
			title TEXT NOT NULL,
			tags TEXT,
			file_path TEXT,
			self_rating INTEGER DEFAULT 0,
			feedbacked_at TEXT,
			rated_then_deleted_at TEXT,
			hath_requested_at TEXT,
			updated_at TEXT
		);
		INSERT INTO galleries(gid,title,tags,file_path,hath_requested_at,updated_at) VALUES
			(100, 'A100', '[\"artist: Artist A\"]', '100.7z', '2026-08-01', '2026-08-01'),
			(300, 'A300', '[\"artist: Artist A\"]', '300.7z', '2026-08-03', '2026-08-03'),
			(500, 'A500', '[\"artist: Artist A\"]', '500.7z', '2026-08-05', '2026-08-05'),
			(200, 'B200', '[\"artist: Artist B\"]', '200.7z', '2026-08-02', '2026-08-02'),
			(400, 'B400', '[\"artist: Artist B\"]', '400.7z', '2026-08-04', '2026-08-04'),
			(450, 'B450', '[\"artist: Artist B\"]', '450.7z', '2026-08-04', '2026-08-04');
	" || return 1

	list_gids() {
		local order_by="$1"
		local max_count="${2:-50}"
		HOME="${home_dir}" bash "${TEST_ROOT}/bin/yomiko" list --format json \
			--pending-feedback --group-by artist --order-by "${order_by}" \
			--max-count "${max_count}" | jq -r '[.[].gid] | join(",")'
	}

	assert_eq '100,300,500,200,400,450' "$(list_gids gid,asc)" || return 1
	assert_eq '500,300,100,450,400,200' "$(list_gids gid,desc)" || return 1
	assert_eq '100,300,500,200,400,450' "$(list_gids hath_requested_at,asc)" || return 1
	assert_eq '500,300,100,450,400,200' "$(list_gids hath_requested_at,desc)" || return 1
	assert_eq '100,300,500,200' "$(list_gids gid,asc 4)" || return 1

	db_write "UPDATE galleries SET feedbacked_at = 'done' WHERE gid = 100;" || return 1
	assert_eq '300,500,200,400,450' "$(list_gids gid,asc)" || return 1

	db_write "UPDATE galleries SET feedbacked_at = NULL WHERE gid = 100; UPDATE galleries SET feedbacked_at = 'done' WHERE gid = 500;" || return 1
	assert_eq '300,100,450,400,200' "$(list_gids gid,desc)" || return 1
}

test_pending_feedback_list_builds_unrated_query() {
	local home_dir="${TEST_TMPDIR}/pending-feedback-home"
	local sqlite3_args="${TEST_TMPDIR}/pending-feedback-sqlite3-args"
	local query

	mkdir -p "${home_dir}/bin"
	ln -s "${TEST_ROOT}/tests/fixtures/capture-sqlite3.sh" "${home_dir}/bin/sqlite3"

	SQLITE3_ARGS_PATH="${sqlite3_args}" \
		HOME="${home_dir}" \
		"${TEST_ROOT}/bin/yomiko" list --format json --pending-feedback --max-count 50 >/dev/null ||
		return 1

	query="$(<"${sqlite3_args}")"
	assert_contains "${query}" "length(COALESCE(file_path, '')) > 0" || return 1
	assert_contains "${query}" "COALESCE(feedbacked_at, '') = ''" || return 1
	assert_contains "${query}" 'COALESCE(self_rating, 0) = 0' || return 1
	assert_contains "${query}" 'rated_then_deleted_at IS NULL'
}

test_pending_feedback_api_caps_max_count() {
	local response

	response="$(
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD='GET' \
		QUERY_STRING='max_count=50' \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 200 OK' || return 1

	response="$(
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD='GET' \
		QUERY_STRING='max_count=51' \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/pending_feedback_galleries.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 400 Bad Request' || return 1
	assert_contains "${response}" 'Maximum allowed value is 50.'
}

test_archive_download_accepts_ellipsis_and_rejects_symlink() {
	local home_dir="${TEST_TMPDIR}/archive-download-home"
	local archive_name='[123456][artist] title...7z'
	local archive_path="${home_dir}/archived/${archive_name}"
	local target_path="${home_dir}/outside-target.7z"
	local response body

	mkdir -p "${home_dir}/archived" "${home_dir}/lib"
	ln -s "${TEST_ROOT}/lib/path.sh" "${home_dir}/lib/path.sh"

	printf '%s' 'ellipsis archive payload' >"${archive_path}"
	response="$(
		HOME="${home_dir}" \
		MOCK_LIST_FILE_PATH="${archive_name}" \
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD=GET QUERY_STRING='gid=123456' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/archive_download.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	assert_contains "${response}" 'Status: 200 OK' || return 1
	assert_contains "${response}" "Content-Disposition: attachment; filename=\"${archive_name}\"" || return 1
	assert_eq 'ellipsis archive payload' "${body}" || return 1

	printf '%s' 'symlink target content' >"${target_path}"
	rm -- "${archive_path}"
	ln -s "${target_path}" "${archive_path}"
	response="$(
		HOME="${home_dir}" \
		MOCK_LIST_FILE_PATH="${archive_name}" \
		YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/list-yomiko.sh" \
		REQUEST_METHOD=GET QUERY_STRING='gid=123456' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/archive_download.sh"
	)" || return 1
	assert_contains "${response}" 'Status: 404 Not Found' || return 1
	assert_not_contains "${response}" 'symlink target content'
}

test_mutation_api_requires_auth() {
	local endpoint method query response spec
	local home_dir="${TEST_TMPDIR}/auth-home"
	local specs=(
		'update_cookies.sh|POST|'
		'hath_download.sh|PUT|gid=123456'
		'feedback.sh|PUT|gid=123456&rating=5'
		'review_resolve.sh|PUT|review_id=7&decision=same-book'
	)

	mkdir -p "${home_dir}/bin"
	ln -sf "${TEST_ROOT}/tests/fixtures/failing-yomiko.sh" "${home_dir}/bin/yomiko"

	for spec in "${specs[@]}"; do
		IFS='|' read -r endpoint method query <<<"${spec}"
		response="$(
			HOME="${home_dir}" \
			YOMIKO_BIN="${TEST_ROOT}/tests/fixtures/failing-yomiko.sh" \
			YOMIKO_API_TOKEN='' \
			HTTP_AUTHORIZATION='' \
			REQUEST_METHOD="${method}" \
			QUERY_STRING="${query}" \
			HTTP_ORIGIN='' \
			bash "${TEST_ROOT}/web/api/${endpoint}"
		)" || return 1

		assert_contains "${response}" 'Status: 503 Service Unavailable' || return 1
		assert_contains "${response}" 'Mutation API is not configured' || return 1
	done

	response="$(
		HOME="${home_dir}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer wrong-token' \
		REQUEST_METHOD='PUT' \
		QUERY_STRING='gid=123456' \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/hath_download.sh"
	)" || return 1

	assert_contains "${response}" 'Status: 401 Unauthorized' || return 1
	assert_contains "${response}" 'Authentication required'
}

render_userscript() {
	local bind_address="$1"
	local http_host="$2"
	local userscript_name="${3:-Yomiko}"
	local build_version="${4:-unknown}"

	YOMIKO_API_TOKEN='test-token' \
		YOMIKO_BIND_ADDRESS="${bind_address}" \
		YOMIKO_USERSCRIPT_NAME="${userscript_name}" \
		YOMIKO_BUILD_VERSION="${build_version}" \
		REQUEST_METHOD='GET' \
		HTTP_HOST="${http_host}" \
		HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/install_userscript.sh"
}

test_install_userscript_injects_build_metadata() {
	local release_userscript debug_userscript

	release_userscript="$(render_userscript '127.0.0.1' 'localhost:62080' 'Yomiko' '1.0.0-rc.2')" || return 1
	debug_userscript="$(render_userscript '127.0.0.1' 'localhost:62080' 'Yomiko (Debug)' 'dev')" || return 1

	assert_contains "${release_userscript}" '// @name         Yomiko' || return 1
	assert_contains "${release_userscript}" '// @version      1.4.0' || return 1
	assert_contains "${release_userscript}" '// @description  Reading makes a full man (server 1.0.0-rc.2)' || return 1
	assert_contains "${debug_userscript}" '// @name         Yomiko (Debug)' || return 1
	assert_contains "${debug_userscript}" '// @description  Reading makes a full man (server dev)'
}

test_install_userscript_injects_api_token() {
	local local_userscript remote_userscript

	assert_contains "$(<"${TEST_ROOT}/web/yomiko.user.js")" \
		"const API_TOKEN = '__YOMIKO_API_TOKEN__';" || return 1

	local_userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1
	remote_userscript="$(render_userscript '0.0.0.0' 'remote.example:62080')" || return 1

	assert_contains "${local_userscript}" "const API_TOKEN = 'test-token';" || return 1
	assert_contains "${remote_userscript}" "const API_TOKEN = 'test-token';" || return 1
	assert_contains "${local_userscript}" '// @icon         http://localhost:62080/favicon.webp'
}

test_userscript_mutations_send_auth() {
	local userscript

	userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1

	assert_contains "${userscript}" '/api/update_cookies.sh' || return 1
	assert_contains "${userscript}" "return { Authorization: \`Bearer \${API_TOKEN}\` };" || return 1
	assert_contains "${userscript}" 'headers: mutationHeaders(),'
}

test_userscript_cookie_refresh_uses_cross_tab_guard() {
	local userscript

	userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1

	assert_contains "${userscript}" 'const COOKIE_REFRESH_INTERVAL_MS = 2 * 60 * 60 * 1000;' || return 1
	assert_contains "${userscript}" "const COOKIE_REFRESH_ATTEMPTED_AT_KEY = 'yomiko-cookie-refresh-attempted-at';" || return 1
	assert_contains "${userscript}" 'localStorage.getItem(COOKIE_REFRESH_ATTEMPTED_AT_KEY)' || return 1
	assert_contains "${userscript}" 'localStorage.setItem(COOKIE_REFRESH_ATTEMPTED_AT_KEY, String(attemptedAt))' || return 1
	assert_contains "${userscript}" 'await sleep(cookieRefreshDelay());' || return 1
	assert_contains "${userscript}" 'const apiHealthy = await refreshCookiesIfDue();' || return 1
	assert_contains "${userscript}" 'void runCookieRefreshLoop();'
}

test_userscript_gallery_polling_uses_configured_interval() {
	local userscript

	userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1

	assert_contains "${userscript}" 'const GALLERY_POLL_INTERVAL_MS = 500;' || return 1
	assert_contains "${userscript}" 'await sleep(GALLERY_POLL_INTERVAL_MS);'
	assert_contains "${userscript}" 'api.searchParams.set('\''gids'\'', gids.join('\'','\''));' || return 1
	assert_not_contains "${userscript}" "api.searchParams.set('fields'" || return 1
	assert_contains "${userscript}" 'data-yomiko-state="hath_requested"' || return 1
	assert_contains "${userscript}" 'data-yomiko-state="downloaded_unrated"' || return 1
	assert_contains "${userscript}" 'data-yomiko-state="rated_non_11"' || return 1
	assert_contains "${userscript}" 'data-yomiko-state="rated_11_canonical"' || return 1
	assert_contains "${userscript}" 'data-yomiko-state="rated_11_alternate"' || return 1
	assert_contains "${userscript}" 'projection_version !== undefined' || return 1
	assert_contains "${userscript}" '評分 ${selfRating}' || return 1
	assert_contains "${userscript}" "hath_requested: '請求過ㄌ'" || return 1
	assert_not_contains "${userscript}" '同本已請求' || return 1
	assert_contains "${userscript}" 'const seenGids = new Set();' || return 1
	assert_contains "${userscript}" 'const state = gallery?.state;' || return 1
	assert_not_contains "${userscript}" 'hasDomRating'
}

# Intentionally do not grep or otherwise test web/feedback.html markup,
# layout, styling, or inline page behavior here. Future webpage-only changes do
# not need shell-suite tests; keep API contracts and server behavior covered.

run_entrypoint() {
	local enable_web="$1"
	local trace_path="$2"
	local api_token="${3:-}"
	local data_dir="${4:-${trace_path}.data}"
	local fixture_home="${TEST_ROOT}/tests/fixtures/entrypoint-home"

	if [[ "${enable_web}" == "default" ]]; then
		env -u YOMIKO_ENABLE_WEB \
			HOME="${fixture_home}" \
			PATH="${fixture_home}/bin:${PATH}" \
			YOMIKO_API_TOKEN="${api_token}" \
			YOMIKO_ENTRYPOINT_DATA_DIR="${data_dir}" \
			YOMIKO_ENTRYPOINT_TOKEN_TRACE="${trace_path}.token" \
			YOMIKO_ENTRYPOINT_TRACE="${trace_path}" \
			bash "${TEST_ROOT}/entrypoint.sh"
	else
		HOME="${fixture_home}" \
			PATH="${fixture_home}/bin:${PATH}" \
			YOMIKO_API_TOKEN="${api_token}" \
			YOMIKO_ENTRYPOINT_DATA_DIR="${data_dir}" \
			YOMIKO_ENTRYPOINT_TOKEN_TRACE="${trace_path}.token" \
			YOMIKO_ENTRYPOINT_TRACE="${trace_path}" \
			YOMIKO_ENABLE_WEB="${enable_web}" \
			bash "${TEST_ROOT}/entrypoint.sh"
	fi
}

test_entrypoint_enables_web_by_default() {
	local trace_path="${TEST_TMPDIR}/entrypoint-default.log"
	local second_trace_path="${TEST_TMPDIR}/entrypoint-default-second.log"
	local data_dir="${TEST_TMPDIR}/entrypoint-default-data"
	local output persisted_token second_output trace

	output="$(run_entrypoint default "${trace_path}" '' "${data_dir}")" || return 1
	trace="$(<"${trace_path}")"
	persisted_token="$(<"${data_dir}/api-token")"

	assert_contains "${output}" 'Generated and persisted a new Yomiko API token.' || return 1
	assert_contains "${output}" 'Starting Yomiko web server on 0.0.0.0:80.' || return 1
	[[ "${persisted_token}" =~ ^[0-9a-f]{64}$ ]] || fail 'generated API token is not 64 lowercase hexadecimal characters' || return 1
	assert_eq '600' "$(stat -c '%a' "${data_dir}/api-token")" || return 1
	assert_eq "${persisted_token}" "$(<"${trace_path}.token")" || return 1
	assert_contains "${trace}" 'db_init' || return 1
	assert_contains "${trace}" 'cron' || return 1
	assert_contains "${trace}" 'httpd' || return 1

	second_output="$(run_entrypoint default "${second_trace_path}" '' "${data_dir}")" || return 1
	assert_contains "${second_output}" 'Loaded persisted Yomiko API token.' || return 1
	assert_eq "${persisted_token}" "$(<"${second_trace_path}.token")"
}

test_entrypoint_persists_configured_api_token() {
	local trace_path="${TEST_TMPDIR}/entrypoint-configured-token.log"
	local data_dir="${TEST_TMPDIR}/entrypoint-configured-token-data"
	local output

	output="$(run_entrypoint default "${trace_path}" 'configured-test-token' "${data_dir}")" || return 1

	assert_contains "${output}" 'Using configured Yomiko API token; persisted in application data.' || return 1
	assert_eq 'configured-test-token' "$(<"${data_dir}/api-token")" || return 1
	assert_eq 'configured-test-token' "$(<"${trace_path}.token")" || return 1
	assert_eq '600' "$(stat -c '%a' "${data_dir}/api-token")"
}

test_entrypoint_can_disable_web() {
	local trace_path="${TEST_TMPDIR}/entrypoint-no-web.log"
	local data_dir="${TEST_TMPDIR}/entrypoint-no-web-data"
	local output trace

	output="$(run_entrypoint false "${trace_path}" 'configured-but-unused' "${data_dir}")" || return 1
	trace="$(<"${trace_path}")"

	assert_contains "${output}" 'Starting Yomiko in CLI-only mode.' || return 1
	[[ ! -e "${data_dir}/api-token" ]] || fail 'CLI-only mode created an API token' || return 1
	assert_contains "${trace}" 'db_init' || return 1
	assert_contains "${trace}" 'cron' || return 1
	if [[ "${trace}" == *'httpd'* ]]; then
		fail 'entrypoint started httpd with YOMIKO_ENABLE_WEB=false'
		return 1
	fi
}

test_entrypoint_rejects_invalid_web_setting() {
	local trace_path="${TEST_TMPDIR}/entrypoint-invalid.log"
	local output

	if output="$(run_entrypoint invalid "${trace_path}" 2>&1)"; then
		fail 'entrypoint accepted an invalid YOMIKO_ENABLE_WEB value'
		return 1
	fi

	assert_contains "${output}" "YOMIKO_ENABLE_WEB must be 'true' or 'false'" || return 1
	[[ ! -e "${trace_path}" ]] || fail 'entrypoint initialized state before validating YOMIKO_ENABLE_WEB'
}

run_test 'logging emits diagnostics outside API mode' test_logging_without_api_mode
run_test 'logging is quiet in API mode' test_logging_in_api_mode
run_test 'memory limits convert to ulimit units' test_memory_limit_to_kb
run_test 'database text parameters use tokenizer-safe encoding' test_db_parameter_text_encoding
run_test 'database text parameters round-trip through SQLite' test_db_parameter_text_round_trips_through_sqlite
run_test 'database queries stream large payloads through stdin' test_db_query_streams_large_payload_through_stdin
run_test 'database writer gates live in container temporary storage' test_db_writer_gate_lives_in_container_tmp
run_test 'database query connections enforce foreign keys' test_db_query_connections_enable_foreign_keys
run_test 'database queries preserve SQLite failures' test_db_queries_preserve_sqlite_failures
run_test 'database writers wait for direct writers while readers skip the gate' test_db_write_waits_for_direct_writer_and_readers_skip_gate
run_test 'database writer timeout preserves atomicity and reports component' test_db_write_timeout_preserves_atomicity_and_reports_component
run_test 'database writer gate serializes writers and reports owner on timeout' test_db_writer_gate_serializes_writers_and_times_out_with_owner
run_test 'database initialization applies atomic migrations' test_db_init_applies_atomic_migrations
run_test 'database initialization backs up before each pending migration' test_db_init_backs_up_before_each_pending_migration
run_test 'migration backup failure stops database initialization' test_db_init_stops_when_migration_backup_fails
run_test 'new database initialization skips migration backups' test_db_init_skips_migration_backups_for_new_database
run_test 'failed database migrations roll back and can retry' test_db_init_rolls_back_failed_migration
run_test 'migration logs stay quiet in API mode' test_db_init_suppresses_migration_logs_in_api_mode
run_test 'gallery tag validation permits only valid repair values' test_gallery_tag_validation_migration_allows_repair_only_to_valid_arrays
run_test 'gallery variant migration upgrades a schema-004 database' test_gallery_variant_migration_upgrades_schema_004
run_test 'fresh gallery variant schema seeds policy and enforces invariants' test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants
run_test 'revision traversal indexes migrate from schema-029 and remain idempotent' test_revision_traversal_indexes_migrate_from_schema_029
run_test 'discovery revision archive vocabulary migration replaces schema-27 views' test_discovery_revision_archive_vocabulary_migration_replaces_schema_27_views
run_test 'discovery revision archive policy migration retargets and recovers hashes' test_discovery_revision_archive_policy_migration_retargets_and_recovers_hashes
run_test 'revision evidence vocabulary migration rewrites persisted JSON' test_revision_evidence_vocabulary_migration_rewrites_persisted_json
run_test 'active domain vocabulary has no stale names' test_active_domain_vocabulary_has_no_stale_names
run_test 'variant review product lifecycle projects terminal outcomes' test_variant_review_product_lifecycle_projects_terminal_outcomes
run_test 'variant job outcome counters are transactional and non-backfilled' test_variant_job_outcome_counters_are_transactional_and_non_backfilled
run_test 'metrics identity repair migration backfills terminals and group projection' test_metrics_identity_repair_migration_backfills_terminals_and_group_projection
run_test 'Priority 1 domain naming migration preserves rating and rewrites snapshots' test_priority_1_domain_naming_migration_preserves_rating_and_rewrites_snapshots
run_test 'Priority 1 domain naming migration rejects conflicting JSON atomically' test_priority_1_domain_naming_migration_rejects_conflicting_json_atomically
run_test 'Priority 1 startup discovery coalescing is idempotent' test_priority_1_startup_discovery_coalescing_is_idempotent
run_test 'Priority 1 startup leaves finalized non-due groups alone' test_priority_1_startup_does_not_schedule_already_finalized_non_due_groups
run_test 'Priority 1 policy finalization rolls back and retries' test_priority_1_policy_finalization_rolls_back_and_retries
run_test 'Manga scope compaction purges safe targets and retains required history' test_manga_scope_compaction_purges_safe_targets_and_retains_required_history
run_test 'Manga scope compaction blocks local archive purge and rolls back' test_manga_scope_compaction_blocks_local_archive_purge_and_rolls_back
run_test 'manual score adjustment migration normalizes and queues refresh' test_manual_score_adjustment_migration_normalizes_and_queues_refresh
run_test 'variant job diagnostics migration and view expose current blockers' test_variant_job_diagnostics_migration_and_view
run_test 'Hath retry migration backfills attempt watermarks and unblocks cleanup' test_variant_hath_retry_migration_backfills_watermarks_and_unblocks_cleanup
run_test 'gallery chain visibility migration preserves custom scoring and queues rediscovery' test_gallery_chain_visibility_migration_preserves_custom_scoring_and_queues_rediscovery
run_test 'gallery chain visibility migration rolls back and retries' test_gallery_chain_visibility_migration_rolls_back_and_retries
run_test 'gallery variant migration rolls back atomically and retries' test_gallery_variant_migration_rolls_back_and_retries
run_test 'page-count scoring migration upgrades only the default policy' test_page_count_scoring_migration_upgrades_only_the_default_policy
run_test 'gallery identity-pair migration backfills symmetric decisions and rejects conflicts' test_gallery_identity_pair_migration_backfills_and_rejects_conflicts
run_test 'historical variant backfill upgrades schema 008 without remote work' test_historical_variant_backfill_upgrades_schema_008
run_test 'historical variant backfill rolls back atomically and retries' test_historical_variant_backfill_rolls_back_and_retries
run_test 'active historical low ratings project actions after evaluation' test_active_historical_low_rating_projects_actions_after_evaluation
run_test 'variant policy validation is strict, canonical, and Unicode-safe' test_variant_policy_validation_is_strict_canonical_and_unicode_safe
run_test 'native Unicode normalization matches reference compatibility fixtures' test_variant_unicode_normalizer_matches_reference_fixtures
run_test 'variant policy preview is immutable and activation reuses and coalesces' test_variant_policy_check_does_not_mutate_and_activation_reuses_and_coalesces
run_test 'variant score components are deterministic and preserve missing evidence' test_variant_scoring_components_are_deterministic
run_test 'variant scoring floors decimal boundaries exactly' test_variant_scoring_uses_exact_decimal_flooring
run_test 'variant scoring honors updated policy weights' test_variant_scoring_honors_updated_policy_weights
run_test 'variant winner review uses an exclusive thirty-point near-tie gap' test_variant_near_tie_review_uses_exclusive_thirty_point_gap
run_test 'variant scoring ignores legacy chain authority fields' test_variant_scoring_does_not_collapse_legacy_chain_fields
run_test 'variant evaluations persist winners and route ties to review' test_variant_evaluation_persists_unique_winner_and_routes_tie_review
run_test 'variant evaluation isolates unrelated identity backlog' test_variant_evaluation_isolates_unrelated_identity_backlog
run_test 'variant evaluation winner blocker leaves all durable state unchanged' test_variant_evaluation_winner_blocker_leaves_all_durable_state_unchanged
run_test 'variant evaluation candidate blocker with unconfirmed endpoint leaves all durable state unchanged' test_variant_evaluation_candidate_blocker_with_unconfirmed_endpoint_leaves_all_durable_state_unchanged
run_test 'variant evaluation stale expected evaluation leaves all durable state unchanged' test_variant_evaluation_stale_expected_evaluation_leaves_all_durable_state_unchanged
run_test 'candidate reviews list frozen cards, merge same-book groups, and persist rejection labels' test_variant_candidate_reviews_list_resolve_merge_and_reject
run_test 'review projection preserves revision readiness and active-owner precedence' test_variant_review_projection_preserves_revision_readiness_and_owner_precedence
run_test 'gallery identity decisions are symmetric, monotonic, and reject implicit splits' test_variant_identity_decisions_are_monotonic_and_symmetric
run_test 'identity reconciliation collapses class-pair work and reopens it after ungroup' test_variant_identity_reconciliation_collapses_and_reopens_class_pairs
run_test 'identity reconciliation reduces a six-by-twenty-six raw queue to class pairs' test_variant_identity_reconciliation_reduces_six_by_twenty_six_queue
run_test 'identity reconciliation preserves an unknown review owned by an inactive group' test_variant_identity_reconciliation_preserves_unknown_review_from_inactive_owner
run_test 'identity reconciliation clears losing owners after reviews supersede' test_variant_identity_reconciliation_clears_losing_owner_after_reviews_supersede
run_test 'identity reconciliation gates cross-group evaluation loops' test_variant_identity_reconciliation_gates_cross_group_evaluation_loop
run_test 'winner reviews preserve automatic scores and canonical projections' test_variant_winner_reviews_create_immutable_automatic_score_evaluation
run_test 'manual canonical decisions survive queued and fresh evaluation' test_manual_canonical_decision_survives_queued_and_fresh_evaluation
run_test 'variant evaluate GID lookup prefers direct active groups and preserves historical fallback' test_variant_evaluate_gid_prefers_direct_group_lookup
run_test 'variant enqueue is atomic, idempotent, and reopens only superseded actions' test_variant_enqueue_is_atomic_idempotent_and_reopens_only_superseded_actions
run_test 'variant enqueue reuses an inactive confirmed-member group' test_variant_enqueue_reuses_inactive_confirmed_member_group
run_test 'identity confirmation projects class rating before actions' test_variant_identity_confirmation_projects_rating_before_actions
run_test 'userscript local-state projection preserves identity and watermarks' test_userscript_local_state_projection_preserves_identity_and_watermarks
run_test 'gallery status uses request-bounded revision projection' test_gallery_status_uses_request_bounded_revision_projection
run_test 'metrics uses a request-local revision snapshot' test_metrics_uses_request_local_revision_snapshot
run_test 'variant list uses request-bounded revision projection' test_variant_list_uses_request_bounded_revision_projection
run_test 'variant Hath recovery clears stale paths and obeys cooldown' test_variant_hath_recovery_clears_stale_path_and_obeys_cooldown
run_test 'variant Hath-tree presence suppresses requests without completion markers' test_variant_hath_tree_suppresses_request_without_completion_marker
run_test 'variant retention uses bounded archive projection and rechecks after lock' test_variant_retention_uses_bounded_archive_projection_and_rechecks_after_lock
run_test 'variant ungroup reseeds selected members and rebuilds the remainder' test_variant_ungroup_reseeds_members_and_rebuilds_remainder
run_test 'variant list/work JSON preserves queued work and honors the worker lock' test_variant_list_and_work_emit_json_without_consuming_jobs
run_test 'remote-write environment guard blocks every mutation adapter before transport' test_remote_write_environment_guard_blocks_mutation_adapters
run_test 'remote-write deny mode skips action and retention jobs for local variant work' test_remote_write_deny_mode_prioritizes_local_variant_work
run_test 'variant worker schedules stale groups, leases safely, retries, and dispatches evaluation' test_variant_worker_schedules_claims_retries_and_dispatches_evaluation
run_test 'variant evaluation blocks incomplete projections without partial commit' test_variant_evaluation_blocks_incomplete_projection_without_partial_commit
run_test 'variant worker backs off projection blocks and orders discovery first' test_variant_worker_backs_off_projection_block_and_orders_discovery_first
run_test 'variant worker runtime and job outcomes remain separate' test_variant_worker_runtime_and_job_outcomes_are_separate
run_test 'variant discovery publishes one complete snapshot and routes reviews atomically' test_variant_discovery_publishes_complete_snapshot_atomically
run_test 'variant discovery auto-confirms strict identity matches and selects the child canonical' test_variant_discovery_auto_same_book_and_child_canonical
run_test 'variant discovery honors canonical identity pairs in the reverse direction' test_variant_discovery_honors_identity_pairs_in_reverse_direction
run_test 'variant discovery dispatcher resumes every bounded phase' test_variant_discovery_dispatcher_resumes_all_bounded_phases
run_test 'variant discovery matching and remote adapters pass fixed fixtures' test_variant_discovery_matching_and_remote_fixtures
run_test 'variant runtime revision-chain consumers normalize terminals and gate archive cleanup' test_variant_runtime_revision_chain_consumers
run_test 'variant revision publication faults preserve live state and retry safely' test_variant_revision_publication_faults
run_test 'variant revision handoff boundaries preserve exact-GID history' test_variant_revision_handoff_boundaries
run_test 'variant CLI enqueue resolves predecessor self-rating to the terminal' test_variant_enqueue_normalizes_predecessor_to_terminal
run_test 'variant operational actions converge while retaining the rating-11 canonical archive' test_variant_operational_actions_converge_and_retain_canonical
run_test 'variant reconciliation projection is idempotent and converges after retention handoff' test_variant_reconciliation_projection_is_idempotent_and_converges
run_test 'variant scoring sweep batches one hundred groups and rejects a stale revision' test_variant_scoring_sweep_batches_and_rejects_stale_revision
run_test 'variant action reconciliation enforces the twenty-five-call remote budget' test_variant_action_remote_budget_caps_at_twenty_five
run_test 'variant CLI rejects invalid enqueue/list/work inputs' test_variant_cli_rejects_invalid_inputs_before_database_access
run_test 'high feedback queues work and applies rating-specific archive retention' test_high_feedback_is_queued_without_remote_calls_and_obeys_archive_retention
run_test 'variant group downgrade converges local intent, actions, and reconciliation' test_variant_group_downgrade_converges_desired_state
run_test 'low feedback routes grouped intent and preserves ungrouped and dry-run behavior' test_low_feedback_routes_grouped_intent_and_preserves_legacy_fallback
run_test 'gallery path metadata is parsed' test_parse_gallery_path
run_test 'invalid gallery paths are rejected' test_parse_gallery_path_rejects_invalid_name
run_test 'archive filename validation is component-aware' test_archive_filename_validation
run_test 'runtime metrics track outcomes without blocking work' test_metrics_runtime_state_tracks_outcomes_and_does_not_block_work
run_test 'metrics CLI emits bounded Prometheus payload' test_metrics_cli_emits_bounded_prometheus_payload
run_test 'runtime freshness thresholds are fixed on empty and populated databases' test_metrics_runtime_stale_after_is_fixed_on_empty_and_populated_databases
run_test 'runtime freshness renderer rejects invalid threshold rows' test_metrics_runtime_stale_after_rejects_invalid_renderer_rows
run_test 'review outcome renderer requires fixed complete rows' test_metrics_review_outcome_renderer_requires_fixed_complete_rows
run_test 'gallery status metrics use an exclusive partition and match pending feedback' test_metrics_gallery_status_is_exclusive_and_matches_pending_feedback
run_test 'gallery status metrics emit zero-valued states for an empty database' test_metrics_gallery_status_emits_zero_series_for_empty_database
run_test 'metrics API authenticates and redacts failures' test_metrics_api_authentication_and_failure_redaction
run_test 'remote gallery metadata is normalized' test_gallery_metadata_is_normalized
run_test 'remote gallery metadata permits galleries without chain links' test_gallery_metadata_tolerates_absent_chain_fields
run_test 'invalid remote gallery metadata is rejected' test_gallery_metadata_rejects_invalid_fields
run_test 'cookie strings become Netscape cookie jars' test_cookie_conversion
run_test 'CLI commands reject invalid GIDs' test_cli_rejects_invalid_gids
run_test 'CLI commands reject extra positional arguments' test_cli_rejects_extra_positional_arguments
run_test 'CLI help ignores trailing arguments' test_cli_help_ignores_trailing_arguments
run_test 'CLI unknown-command diagnostics use stderr' test_cli_unknown_command_uses_stderr
run_test 'CLI commands reject missing positional arguments' test_cli_rejects_missing_positional_arguments
run_test 'CLI options reject missing values' test_cli_rejects_missing_option_values
run_test 'CLI numeric options reject invalid values' test_cli_rejects_invalid_numeric_option_values
run_test 'CLI rejects unsupported gallery sort fields' test_cli_rejects_unsupported_sort_fields
run_test 'CLI accepts public sort fields and artist grouping' test_cli_accepts_supported_sort_fields
run_test 'archive commits only after its database update' test_archive_commits_after_database_update
run_test 'archives accept ellipses in generated filenames' test_archive_accepts_ellipsis_in_generated_filename
run_test 'invalid generated archive filenames stop before commit' test_archive_rejects_invalid_generated_filename_before_commit
run_test 'archive database failures preserve existing archives' test_archive_database_failure_preserves_existing_archive
run_test 'archive commit failures preserve a recoverable rename manifest' test_archive_commit_failure_preserves_manifest_for_recovery
run_test 'archive conversion failures clean staging' test_archive_conversion_failure_cleans_staging
run_test 'archive compression failures clean staging' test_archive_compression_failure_cleans_staging
run_test 'archive metadata failures do not start conversion' test_archive_metadata_failure_does_not_convert
run_test 'invalid archive metadata does not convert or write' test_archive_invalid_metadata_does_not_convert_or_write
run_test 'archive rejects concurrent work for the same gallery' test_archive_rejects_concurrent_gallery
run_test 'scan skips galleries already being archived' test_scan_skips_concurrent_gallery
run_test 'scan rejects a concurrent scan' test_scan_rejects_concurrent_scan
run_test 'tag repair is dry-run safe and resumable' test_repair_tags_is_dry_run_safe_and_resumable
run_test 'API origins match the current host' test_origin_matching
run_test 'CORS headers reflect a matching origin' test_cors_headers_for_matching_origin
run_test 'cookie API does not return CLI failures' test_api_command_output_is_not_returned update_cookies.sh POST ''
run_test 'Hath API does not return CLI failures' test_api_command_output_is_not_returned hath_download.sh PUT 'gid=123456'
run_test 'feedback API does not return CLI failures' test_api_command_output_is_not_returned feedback.sh PUT 'gid=123456&rating=5'
run_test 'review list API does not return CLI failures' test_api_command_output_is_not_returned reviews.sh GET 'status=pending'
run_test 'review mutation API does not return CLI failures' test_api_command_output_is_not_returned review_resolve.sh PUT 'review_id=7&decision=same-book'
run_test 'feedback API exposes queue state without group IDs and rejects malformed CLI JSON' test_feedback_api_returns_variant_queue_fields_and_rejects_malformed_cli_json
run_test 'variant review APIs list, validate, authenticate, resolve, and report stale decisions' test_variant_review_apis_list_validate_auth_resolve_and_report_stale
run_test 'gallery API does not return CLI failures' test_api_command_output_is_not_returned galleries.sh GET 'gids=123456'
run_test 'pending gallery API does not return CLI failures' test_api_command_output_is_not_returned pending_feedback_galleries.sh GET 'max_count=1'
run_test 'pending gallery API returns display fields' test_pending_feedback_api_returns_display_fields
run_test 'pending gallery API defaults to oldest Hath request by artist' test_pending_feedback_api_defaults_to_oldest_hath_request_by_artist
run_test 'pending gallery API forwards supported sorts' test_pending_feedback_api_forwards_supported_sorts
run_test 'pending gallery API rejects non-queue sort fields' test_pending_feedback_api_rejects_non_queue_sort_fields
run_test 'pending gallery list builds artist-group sort query' test_pending_feedback_list_builds_artist_group_query
run_test 'pending gallery artist groups stay stable after boundary removal' test_pending_feedback_artist_group_sort_is_stable_after_boundary_removal
run_test 'pending gallery list builds unrated query' test_pending_feedback_list_builds_unrated_query
run_test 'pending gallery API caps max_count' test_pending_feedback_api_caps_max_count
run_test 'archive downloads accept ellipses and reject symlinks' test_archive_download_accepts_ellipsis_and_rejects_symlink
run_test 'mutation APIs require authentication' test_mutation_api_requires_auth
run_test 'userscript installer injects build metadata' test_install_userscript_injects_build_metadata
run_test 'userscript installer injects API tokens' test_install_userscript_injects_api_token
run_test 'userscript mutation clients send authentication' test_userscript_mutations_send_auth
run_test 'userscript cookie refresh uses cross-tab guard' test_userscript_cookie_refresh_uses_cross_tab_guard
run_test 'userscript gallery polling uses configured interval' test_userscript_gallery_polling_uses_configured_interval
run_test 'entrypoint enables web by default' test_entrypoint_enables_web_by_default
run_test 'entrypoint persists configured API tokens' test_entrypoint_persists_configured_api_token
run_test 'entrypoint can disable web' test_entrypoint_can_disable_web
run_test 'entrypoint rejects invalid web settings' test_entrypoint_rejects_invalid_web_setting

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"
((failed == 0))
