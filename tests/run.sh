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
source "${TEST_ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/lib/variants.sh"
# shellcheck disable=SC1091
source "${TEST_ROOT}/web/api/_middleware.sh"

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

test_db_query_connections_enable_foreign_keys() {
	command -v sqlite3 >/dev/null || return 0

	local json
	DB_PATH="${TEST_TMPDIR}/foreign-keys.sqlite3"
	export DB_PATH

	db_query '
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
	assert_eq '23' "${status}"
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
	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES (1, 'token', 'title', NULL);" || return 1

	cp "${TEST_ROOT}/migrations/004_validate_gallery_tags.sql" "${migration_dir}/"
	output="$(db_init)" || return 1
	assert_contains "${output}" 'Applying migration version 4: 004_validate_gallery_tags.sql...' || return 1
	assert_eq '1' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE tags IS NULL;')" || return 1

	assert_failure db_query "UPDATE galleries SET tags = NULL WHERE gid = 1;" >/dev/null 2>&1 || return 1
	assert_failure db_query \
		".parameter set :tags $(db_parameter_text '{"artist":"test"}')" \
		"UPDATE galleries SET tags = :tags WHERE gid = 1;" >/dev/null 2>&1 || return 1

	db_query \
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
	local metadata_columns variant_tables
	metadata_columns="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('category', 'uploader', 'posted', 'filesize', 'thumb', 'first_gid', 'first_key', 'parent_gid', 'parent_key', 'current_gid', 'current_key') ORDER BY cid);")" || return 1
	variant_tables="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'table' AND name IN ('variant_policy_revisions', 'variant_groups', 'gallery_variants', 'variant_evaluations', 'variant_jobs', 'variant_actions', 'variant_reviews') ORDER BY name);")" || return 1

	assert_eq 'category,uploader,posted,filesize,thumb,first_gid,first_key,parent_gid,parent_key,current_gid,current_key' "${metadata_columns}" || return 1
	assert_eq 'gallery_variants,variant_actions,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
}

test_gallery_variant_migration_upgrades_schema_004() {
	command -v sqlite3 >/dev/null || return 0

	local output
	prepare_gallery_variant_migration_test upgrade
	cp "${TEST_ROOT}"/migrations/00[1-4]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_query "INSERT INTO galleries (gid, token, title, tags, self_rating) VALUES (123, 'token', 'title', '[]', 8);" || return 1

	cp "${TEST_ROOT}/migrations/005_gallery_variants.sql" "${MIGRATIONS_DIR}/"
	output="$(db_init)" || return 1

	assert_contains "${output}" 'Applying migration version 5: 005_gallery_variants.sql...' || return 1
	assert_eq '5' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_eq '123|token|title|8' "$(db_query 'SELECT gid, token, title, self_rating FROM galleries WHERE gid = 123;')" || return 1
	assert_gallery_variant_schema
}

test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants() {
	command -v sqlite3 >/dev/null || return 0

	local policy_json
	prepare_gallery_variant_migration_test fresh
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1

	assert_eq '5' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_variant_schema || return 1
	assert_eq '1|1|64|64|64|64' "$(db_query 'SELECT COUNT(*), SUM(is_active), length(content_hash), length(matching_hash), length(scoring_hash), length(operations_hash) FROM variant_policy_revisions;')" || return 1
	assert_eq '95cfec1154b96ff2dbd8ac5569e7e841e78645d71470b763d2cf4735c23f1e3b|a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e|70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69|7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d' \
		"$(db_query 'SELECT content_hash, matching_hash, scoring_hash, operations_hash FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	policy_json="$(db_query 'SELECT policy_json FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	assert_eq 'language:chinese|other:tankoubon|100|100|365|25' "$(jq -r '[.matching.required_scope_tags[0], .matching.required_scope_tags[1], .scoring.tag_weights["other:full color"], .scoring.tag_weights["other:uncensored"], .operations.annual_rediscovery_days, .operations.gdata_batch_size] | join("|")' <<<"${policy_json}")" || return 1
	assert_failure db_query 'UPDATE variant_policy_revisions SET scoring_hash = lower(hex(randomblob(32))) WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	assert_failure db_query 'DELETE FROM variant_policy_revisions WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	db_query "INSERT INTO variant_policy_revisions (policy_json, content_hash, matching_hash, scoring_hash, operations_hash) SELECT policy_json, printf('%064d', 2), printf('%064d', 3), printf('%064d', 4), printf('%064d', 5) FROM variant_policy_revisions WHERE is_active = 1;" || return 1
	assert_failure db_query "UPDATE variant_policy_revisions SET is_active = 1, activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE content_hash = printf('%064d', 2);" >/dev/null 2>&1 || return 1

	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES (1, 'one', 'one', '[]'), (2, 'two', 'two', '[]');" || return 1
	db_query 'INSERT INTO variant_groups (id, source_gid, desired_rating) VALUES (1, 1, 8), (2, 2, 8);' || return 1
	assert_eq '1' "$(db_query 'PRAGMA foreign_keys;')" || return 1
	assert_failure db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES (1, 999, 'confirmed', 'automatic', '{}', '{}');" >/dev/null 2>&1 || return 1
	db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES (1, 1, 'confirmed', 'automatic', '{}', '{}');" || return 1
	assert_failure db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES (2, 1, 'confirmed', 'automatic', '{}', '{}');" >/dev/null 2>&1 || return 1

	db_query "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" || return 1
	assert_failure db_query "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" >/dev/null 2>&1 || return 1
	db_query "UPDATE variant_jobs SET status = 'completed', completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE group_id = 1 AND job_type = 'discover';" || return 1
	db_query "INSERT INTO variant_jobs (job_type, group_id, source_gid) VALUES ('discover', 1, 1);" || return 1
	assert_eq '2' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE group_id = 1 AND job_type = 'discover';")" || return 1
	db_query "INSERT INTO variant_jobs (job_type) VALUES ('policy_scoring_sweep');" || return 1
	assert_failure db_query "INSERT INTO variant_jobs (job_type) VALUES ('policy_scoring_sweep');" >/dev/null 2>&1 || return 1
	assert_eq 'ok' "$(db_query 'PRAGMA foreign_key_check; SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = '\''ok'\'' THEN '\''ok'\'' ELSE '\''failed'\'' END;')"
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
	assert_gallery_variant_schema
}

prepare_variant_runtime_test() {
	local name="$1"

	DB_PATH="${TEST_TMPDIR}/variant-runtime-${name}.sqlite3"
	MIGRATIONS_DIR="${TEST_ROOT}/migrations"
	VARIANTS_WORK_LOCK_PATH="${TEST_TMPDIR}/variant-runtime-${name}.lock"
	export DB_PATH MIGRATIONS_DIR VARIANTS_WORK_LOCK_PATH
	db_init >/dev/null || return 1
	db_query "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES
		(101, 'token-101', 'Source', '[]', 'source.7z'),
		(102, 'token-102', 'Member', '[]', NULL);" || return 1
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

	db_query "UPDATE variant_actions SET status = 'succeeded', completed_at = '2026-01-01T00:00:00Z';" || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1
	assert_eq 'succeeded|2026-01-01T00:00:00Z' "$(db_query "SELECT status, completed_at FROM variant_actions WHERE desired_value = '10';")" || return 1
	variants_enqueue_feedback 101 8 >/dev/null || return 1
	assert_eq 'superseded|pending' "$(db_query "SELECT (SELECT status FROM variant_actions WHERE desired_value = '10'), (SELECT status FROM variant_actions WHERE desired_value = '8');")" || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1
	assert_eq 'pending||superseded' "$(db_query "SELECT status || '|' || COALESCE(completed_at, '') || '|' || (SELECT status FROM variant_actions WHERE desired_value = '8') FROM variant_actions WHERE desired_value = '10';")"
}

test_variant_enqueue_reuses_inactive_confirmed_member_group() {
	command -v sqlite3 >/dev/null || return 0
	local group_id
	prepare_variant_runtime_test reuse || return 1
	group_id="$(variants_enqueue_feedback 101 9)" || return 1
	db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES (${group_id}, 102, 'confirmed', 'manual', '{}', '{}'); UPDATE variant_groups SET is_active = 0 WHERE id = ${group_id};" || return 1

	assert_eq "${group_id}" "$(variants_enqueue_feedback 102 11)" || return 1
	assert_eq '1|1|11|10' "$(db_query "SELECT COUNT(*), is_active, desired_rating, (SELECT desired_value FROM variant_actions WHERE gid = 102) FROM variant_groups;")"
}

test_variant_list_and_work_emit_json_without_consuming_jobs() {
	command -v sqlite3 >/dev/null || return 0
	local list_json work_json locked_json lock_fd
	prepare_variant_runtime_test list-work || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1

	list_json="$(variants_list_json 101 queued)" || return 1
	jq -e '.groups | length == 1 and .[0].members[0].gid == 101 and .[0].jobs[0].status == "queued" and .[0].actions[0].desired_value == "10"' <<<"${list_json}" >/dev/null || return 1
	export YOMIKO_CLI_IN_API_MODE=1
	work_json="$(variants_work --max-jobs 1 --dry-run)" || return 1
	jq -e '.locked == false and .dry_run == true and (.jobs | length == 1) and .jobs[0].status == "queued"' <<<"${work_json}" >/dev/null || return 1
	assert_eq 'queued|0' "$(db_query 'SELECT status, attempt_count FROM variant_jobs;')" || return 1
	exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
	flock -n "${lock_fd}" || return 1
	locked_json="$(variants_work --max-jobs=1)" || return 1
	exec {lock_fd}>&-
	jq -e '.locked == true and .dry_run == false and .jobs == []' <<<"${locked_json}" >/dev/null
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
	db_query "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES (101, 'token', 'Source', '[]', 'source.7z');" || return 1
	archive_path="${home_dir}/archived/source.7z"
	printf 'archive' >"${archive_path}"

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 101 --rating 11)" || return 1
	jq -e '.variant_queued == true and (.variant_group_id | type == "number")' <<<"${output}" >/dev/null || return 1
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
	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES
		(103, 'token-103', 'Candidate', '[]'),
		(104, 'token-104', 'Ungrouped', '[]');
	INSERT INTO variant_groups (source_gid, desired_rating, is_active) VALUES (101, 9, 0);
	INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json)
		VALUES (last_insert_rowid(), 102, 'confirmed', 'manual', '{}', '{}');" || return 1
	inactive_group="$(db_query 'SELECT id FROM variant_groups;')" || return 1
	db_query "INSERT INTO variant_groups (source_gid, desired_rating) VALUES (101, 11);" || return 1
	active_group="$(db_query 'SELECT id FROM variant_groups WHERE is_active = 1;')" || return 1
	db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES
		(${active_group}, 101, 'confirmed', 'automatic', '{}', '{}'),
		(${active_group}, 102, 'confirmed', 'manual', '{}', '{}'),
		(${active_group}, 103, 'candidate', 'automatic', '{}', '{}');" || return 1
	db_query "INSERT INTO variant_actions (group_id, gid, action_type, desired_value, decision_revision_id) VALUES
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
	db_query "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES
		(201, 'token-201', 'Grouped', '[]', 'grouped.7z'),
		(202, 'token-202', 'Member', '[]', NULL),
		(203, 'token-203', 'Ungrouped', '[]', 'ungrouped.7z');" || return 1
	group_id="$(variants_enqueue_feedback 201 9)" || return 1
	db_query "INSERT INTO gallery_variants (group_id, gid, membership_state, decision_source, evidence_json, metadata_snapshot_json) VALUES (${group_id}, 202, 'confirmed', 'manual', '{}', '{}');" || return 1
	grouped_archive="${home_dir}/archived/grouped.7z"
	ungrouped_archive="${home_dir}/archived/ungrouped.7z"
	printf archive >"${grouped_archive}"
	printf archive >"${ungrouped_archive}"

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 202 --rating 6)" || return 1
	jq -e --argjson group_id "${group_id}" '.variant_queued == true and .variant_group_id == $group_id' <<<"${output}" >/dev/null || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'grouped low feedback made a synchronous curl call' || return 1
	[[ -f "${grouped_archive}" ]] || fail 'grouped low feedback synchronously deleted an archive' || return 1
	assert_eq '6|0|6' "$(db_query "SELECT desired_rating, is_active, (SELECT self_rating FROM galleries WHERE gid = 201) FROM variant_groups WHERE id = ${group_id};")" || return 1

	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 203 --rating 4)" || return 1
	jq -e '.variant_queued == false and .variant_group_id == null' <<<"${output}" >/dev/null || return 1
	assert_eq '2' "$(wc -l <"${curl_trace}")" || return 1
	[[ ! -e "${ungrouped_archive}" ]] || fail 'ungrouped low feedback did not keep legacy deletion behavior' || return 1
	assert_eq '4|1' "$(db_query "SELECT self_rating, rated_then_deleted_at IS NOT NULL FROM galleries WHERE gid = 203;")" || return 1

	snapshot="$(db_query "SELECT desired_rating, is_active, self_rating, feedbacked_at FROM variant_groups JOIN galleries ON galleries.gid = 201 WHERE variant_groups.id = ${group_id}; SELECT COUNT(*) FROM variant_actions; SELECT COUNT(*) FROM variant_jobs;")" || return 1
	output="$(HOME="${home_dir}" PATH="${home_dir}/bin:${PATH}" MOCK_CURL_TRACE="${curl_trace}" YOMIKO_CLI_IN_API_MODE=1 bash "${TEST_ROOT}/bin/yomiko" feedback 201 --rating 2 --dry-run)" || return 1
	jq -e --argjson group_id "${group_id}" '.variant_queued == true and .variant_group_id == $group_id' <<<"${output}" >/dev/null || return 1
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

test_gallery_metadata_is_normalized() {
	local metadata normalized
	metadata='{"gid":"123","token":"test-token","title":"Test title","category":"Manga","uploader":"test-user","posted":"1722470400","filecount":"12","filesize":"345678","thumb":"https://example.test/thumb.jpg","expunged":false,"tags":["artist:test"],"rating":"4.50","first_gid":"100","first_key":"first-token","parent_gid":"122","parent_key":"parent-token","current_gid":"124","current_key":"current-token"}'

	normalized="$(exh_normalize_gallery_metadata 123 "${metadata}")" || return 1

	assert_eq 'number' "$(jq -r '.gid | type' <<<"${normalized}")" || return 1
	assert_eq '123' "$(jq -r '.gid' <<<"${normalized}")" || return 1
	assert_eq 'null' "$(jq -r '.title_jpn | type' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.filecount | type' <<<"${normalized}")" || return 1
	assert_eq '12' "$(jq -r '.filecount' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.rating | type' <<<"${normalized}")" || return 1
	assert_eq 'true' "$(jq -r '.rating == 4.5' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.posted | type' <<<"${normalized}")" || return 1
	assert_eq '1722470400' "$(jq -r '.posted' <<<"${normalized}")" || return 1
	assert_eq 'number' "$(jq -r '.filesize | type' <<<"${normalized}")" || return 1
	assert_eq '345678' "$(jq -r '.filesize' <<<"${normalized}")" || return 1
	assert_eq '100:first-token,122:parent-token,124:current-token' "$(jq -r '[.first_gid, .first_key, .parent_gid, .parent_key, .current_gid, .current_key] | "\(.[0]):\(.[1]),\(.[2]):\(.[3]),\(.[4]):\(.[5])"' <<<"${normalized}")"
}

test_gallery_metadata_tolerates_absent_chain_fields() {
	local metadata normalized
	metadata='{"gid":123,"token":"test-token","title":"Test title","category":"Manga","uploader":"test-user","posted":"1722470400","filecount":"12","filesize":345678,"thumb":"https://example.test/thumb.jpg","expunged":false,"tags":["artist:test"],"rating":"4.50"}'

	normalized="$(exh_normalize_gallery_metadata 123 "${metadata}")" || return 1
	jq -e '
		.first_gid == null and .first_key == null
		and .parent_gid == null and .parent_key == null
		and .current_gid == null and .current_key == null
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

prepare_archive_test() {
	ARCHIVE_TEST_HOME="${TEST_TMPDIR}/archive-$1-home"
	ARCHIVE_TEST_GALLERY="${ARCHIVE_TEST_HOME}/hath/[artist] title [123]"
	ARCHIVE_TEST_FINAL="${ARCHIVE_TEST_HOME}/archived/[123][artist] title.7z"
	ARCHIVE_TEST_SQLITE_TRACE="${ARCHIVE_TEST_HOME}/sqlite.trace"
	ARCHIVE_TEST_SQLITE_ARGS="${ARCHIVE_TEST_HOME}/sqlite.args"

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
		MOCK_METADATA_FAILURE="${MOCK_METADATA_FAILURE:-0}" \
		MOCK_INVALID_METADATA="${MOCK_INVALID_METADATA:-0}" \
		MOCK_CONVERSION_FAILURE="${MOCK_CONVERSION_FAILURE:-0}" \
		MOCK_COMPRESSION_FAILURE="${MOCK_COMPRESSION_FAILURE:-0}" \
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
	assert_contains "${sqlite_args}" '.parameter set :category "CAST(X'\''4d616e6761'\'' AS TEXT)"' || return 1
	assert_contains "${sqlite_args}" '.parameter set :posted 1722470400' || return 1
	assert_contains "${sqlite_args}" '.parameter set :filesize 123456' || return 1
	assert_contains "${sqlite_args}" '.parameter set :first_gid null' || return 1
	assert_contains "${sqlite_args}" '.parameter set :current_key null' || return 1
	assert_eq 'staged archive' "$(<"${ARCHIVE_TEST_FINAL}")" || return 1
	[[ ! -d "${ARCHIVE_TEST_GALLERY}" ]] || fail 'successful archive kept the source gallery' || return 1
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
		db_query "INSERT INTO galleries (gid, token, title, tags) VALUES (${gid}, 'test-token', 'Test title', NULL);" || return 1
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
	jq -e '.success == true and .variant_queued == true and .variant_group_id == 42' <<<"${body}" >/dev/null || return 1

	response="$(
		MOCK_FEEDBACK_RESULT=low \
		YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='gid=101&rating=7' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/feedback.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e '.success == true and .variant_queued == false and .variant_group_id == null' <<<"${body}" >/dev/null || return 1

	response="$(
		MOCK_FEEDBACK_RESULT=malformed \
		YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' \
		HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='gid=101&rating=11' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/feedback.sh" 2>/dev/null
	)" || return 1
	assert_contains "${response}" 'Status: 502 Bad Gateway' || return 1
	assert_contains "${response}" '"success": false'
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
	assert_contains "${query}" 'COALESCE(self_rating, 0) = 0'
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

test_mutation_api_requires_auth() {
	local endpoint method query response spec
	local home_dir="${TEST_TMPDIR}/auth-home"
	local specs=(
		'update_cookies.sh|POST|'
		'hath_download.sh|PUT|gid=123456'
		'feedback.sh|PUT|gid=123456&rating=5'
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
	assert_contains "${release_userscript}" '// @version      1.2.0' || return 1
	assert_contains "${release_userscript}" '// @description  Reading makes a full man (server 1.0.0-rc.2)' || return 1
	assert_contains "${debug_userscript}" '// @name         Yomiko (Debug)' || return 1
	assert_contains "${debug_userscript}" '// @description  Reading makes a full man (server dev)'
}

test_install_userscript_injects_api_token() {
	local local_userscript remote_userscript

	local_userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1
	remote_userscript="$(render_userscript '0.0.0.0' 'remote.example:62080')" || return 1

	assert_contains "${local_userscript}" 'const API_TOKEN = "test-token";' || return 1
	assert_contains "${remote_userscript}" 'const API_TOKEN = "test-token";' || return 1
	assert_contains "${local_userscript}" '// @icon         http://localhost:62080/favicon.webp'
}

test_frontend_mutations_send_auth() {
	local userscript feedback_page

	userscript="$(render_userscript '127.0.0.1' 'localhost:62080')" || return 1
	feedback_page="$(<"${TEST_ROOT}/web/feedback.html")"

	assert_contains "${userscript}" '/api/update_cookies.sh' || return 1
	assert_contains "${userscript}" "return { Authorization: \`Bearer \${API_TOKEN}\` };" || return 1
	assert_contains "${userscript}" 'headers: mutationHeaders(),' || return 1
	assert_contains "${feedback_page}" "fetch(\`/api/feedback.sh?\${query}\`" || return 1
	assert_contains "${feedback_page}" 'method: '\''PUT'\''' || return 1
	assert_contains "${feedback_page}" "Authorization: \`Bearer \${this.apiToken}\`"
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
}

test_feedback_page_uses_pending_gallery_api() {
	local feedback_page
	feedback_page="$(<"${TEST_ROOT}/web/feedback.html")"

	assert_contains "${feedback_page}" "fetch('/api/pending_feedback_galleries.sh?max_count=20')"
}

test_feedback_page_persists_api_token() {
	local feedback_page
	feedback_page="$(<"${TEST_ROOT}/web/feedback.html")"

	assert_contains "${feedback_page}" "showApiToken ? 'text' : 'password'" || return 1
	assert_contains "${feedback_page}" "@click=\"showApiToken = !showApiToken\"" || return 1
	assert_contains "${feedback_page}" 'toast.success' || return 1
	assert_contains "${feedback_page}" "showToast('API token loaded for this page.', 'success')" || return 1
	assert_contains "${feedback_page}" "localStorage.getItem('yomiko-api-token')" || return 1
	assert_contains "${feedback_page}" "localStorage.setItem('yomiko-api-token', this.apiToken)" || return 1
	assert_contains "${feedback_page}" "localStorage.removeItem('yomiko-api-token')"
}

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
run_test 'database query connections enforce foreign keys' test_db_query_connections_enable_foreign_keys
run_test 'database queries preserve SQLite failures' test_db_queries_preserve_sqlite_failures
run_test 'database initialization applies atomic migrations' test_db_init_applies_atomic_migrations
run_test 'failed database migrations roll back and can retry' test_db_init_rolls_back_failed_migration
run_test 'migration logs stay quiet in API mode' test_db_init_suppresses_migration_logs_in_api_mode
run_test 'gallery tag validation permits only valid repair values' test_gallery_tag_validation_migration_allows_repair_only_to_valid_arrays
run_test 'gallery variant migration upgrades a schema-004 database' test_gallery_variant_migration_upgrades_schema_004
run_test 'fresh gallery variant schema seeds policy and enforces invariants' test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants
run_test 'gallery variant migration rolls back atomically and retries' test_gallery_variant_migration_rolls_back_and_retries
run_test 'variant enqueue is atomic, idempotent, and reopens only superseded actions' test_variant_enqueue_is_atomic_idempotent_and_reopens_only_superseded_actions
run_test 'variant enqueue reuses an inactive confirmed-member group' test_variant_enqueue_reuses_inactive_confirmed_member_group
run_test 'variant list/work JSON preserves queued work and honors the worker lock' test_variant_list_and_work_emit_json_without_consuming_jobs
run_test 'variant CLI rejects invalid enqueue/list/work inputs' test_variant_cli_rejects_invalid_inputs_before_database_access
run_test 'high feedback queues work and applies rating-specific archive retention' test_high_feedback_is_queued_without_remote_calls_and_obeys_archive_retention
run_test 'variant group downgrade converges local intent, actions, and reconciliation' test_variant_group_downgrade_converges_desired_state
run_test 'low feedback routes grouped intent and preserves ungrouped and dry-run behavior' test_low_feedback_routes_grouped_intent_and_preserves_legacy_fallback
run_test 'gallery path metadata is parsed' test_parse_gallery_path
run_test 'invalid gallery paths are rejected' test_parse_gallery_path_rejects_invalid_name
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
run_test 'archive commits only after its database update' test_archive_commits_after_database_update
run_test 'archive database failures preserve existing archives' test_archive_database_failure_preserves_existing_archive
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
run_test 'feedback API exposes variant queue fields and rejects malformed CLI JSON' test_feedback_api_returns_variant_queue_fields_and_rejects_malformed_cli_json
run_test 'gallery API does not return CLI failures' test_api_command_output_is_not_returned galleries.sh GET 'gids=123456'
run_test 'pending gallery API does not return CLI failures' test_api_command_output_is_not_returned pending_feedback_galleries.sh GET 'max_count=1'
run_test 'pending gallery API returns display fields' test_pending_feedback_api_returns_display_fields
run_test 'pending gallery list builds unrated query' test_pending_feedback_list_builds_unrated_query
run_test 'pending gallery API caps max_count' test_pending_feedback_api_caps_max_count
run_test 'mutation APIs require authentication' test_mutation_api_requires_auth
run_test 'userscript installer injects build metadata' test_install_userscript_injects_build_metadata
run_test 'userscript installer injects API tokens' test_install_userscript_injects_api_token
run_test 'frontend mutation clients send authentication' test_frontend_mutations_send_auth
run_test 'userscript cookie refresh uses cross-tab guard' test_userscript_cookie_refresh_uses_cross_tab_guard
run_test 'userscript gallery polling uses configured interval' test_userscript_gallery_polling_uses_configured_interval
run_test 'feedback page uses pending gallery API' test_feedback_page_uses_pending_gallery_api
run_test 'feedback page persists API token' test_feedback_page_persists_api_token
run_test 'entrypoint enables web by default' test_entrypoint_enables_web_by_default
run_test 'entrypoint persists configured API tokens' test_entrypoint_persists_configured_api_token
run_test 'entrypoint can disable web' test_entrypoint_can_disable_web
run_test 'entrypoint rejects invalid web settings' test_entrypoint_rejects_invalid_web_setting

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"
((failed == 0))
