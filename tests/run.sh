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
	local expected_discovery_tables="${1:-1}" metadata_columns variant_tables
	metadata_columns="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('category', 'uploader', 'posted', 'filesize', 'thumb', 'first_gid', 'first_key', 'parent_gid', 'parent_key', 'current_gid', 'current_key') ORDER BY cid);")" || return 1
variant_tables="$(db_query \
		"SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'table' AND name IN ('gallery_identity_pairs', 'variant_policy_revisions', 'variant_groups', 'gallery_variants', 'variant_evaluations', 'variant_jobs', 'variant_actions', 'variant_reviews', 'variant_discovery_runs', 'variant_discovery_candidates') ORDER BY name);")" || return 1

	assert_eq 'category,uploader,posted,filesize,thumb,first_gid,first_key,parent_gid,parent_key,current_gid,current_key' "${metadata_columns}" || return 1
	if [[ "${expected_discovery_tables}" -eq 1 ]]; then
		assert_eq 'gallery_identity_pairs,gallery_variants,variant_actions,variant_discovery_candidates,variant_discovery_runs,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
	else
		assert_eq 'gallery_variants,variant_actions,variant_evaluations,variant_groups,variant_jobs,variant_policy_revisions,variant_reviews' "${variant_tables}"
	fi
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
	assert_gallery_variant_schema 0
}

test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants() {
	command -v sqlite3 >/dev/null || return 0

	local policy_json
	prepare_gallery_variant_migration_test fresh
	cp "${TEST_ROOT}"/migrations/*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1

	assert_eq '11' "$(db_query 'SELECT MAX(version) FROM _schema_version;')" || return 1
	assert_gallery_variant_schema || return 1
	assert_eq '3|1|64|64|64|64' "$(db_query 'SELECT (SELECT COUNT(*) FROM variant_policy_revisions), SUM(is_active), length(content_hash), length(matching_hash), length(scoring_hash), length(operations_hash) FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	assert_eq 'e5be1191ab859a44e2823ce35c125ebf93459585be6feb1705d43f4fb3365e2f|a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e|5b0a943e7aaa8dab63b06b8eb792fd6d3c41a25141e5c697ee2e65625a00847b|7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d' \
		"$(db_query 'SELECT content_hash, matching_hash, scoring_hash, operations_hash FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	policy_json="$(db_query 'SELECT policy_json FROM variant_policy_revisions WHERE is_active = 1;')" || return 1
	assert_eq 'language:chinese|other:tankoubon|100|100|30|70|365|25' "$(jq -r '[.matching.required_scope_tags[0], .matching.required_scope_tags[1], .scoring.tag_scores["other:full color"], .scoring.tag_scores["other:uncensored"], .scoring.page_count.cap, .scoring.page_count.offset, .operations.annual_rediscovery_days, .operations.gdata_batch_size] | join("|")' <<<"${policy_json}")" || return 1
	assert_eq '1' "$(jq -r '.format_version' <<<"${policy_json}")" || return 1
	assert_eq '70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69|0|' "$(db_query "SELECT scoring_hash, is_active, json_extract(policy_json, '$.format_version') FROM variant_policy_revisions WHERE content_hash = '95cfec1154b96ff2dbd8ac5569e7e841e78645d71470b763d2cf4735c23f1e3b';")" || return 1
	assert_eq 'favorite_count|rating_count|popularity_fetched_at' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM pragma_table_info('galleries') WHERE name IN ('favorite_count','rating_count','popularity_fetched_at') ORDER BY cid);")" || return 1
	assert_eq 'scoring_revision_id' "$(db_query "SELECT name FROM pragma_table_info('variant_jobs') WHERE name='scoring_revision_id';")" || return 1
	assert_eq 'lease_owner|lease_expires_at|lease_job_id|last_error_class' "$(db_query "SELECT group_concat(name, '|') FROM (SELECT name FROM pragma_table_info('variant_actions') WHERE name IN ('lease_owner','lease_expires_at','lease_job_id','last_error_class') ORDER BY cid);")" || return 1
	assert_eq 'superseded_at' "$(db_query "SELECT name FROM pragma_table_info('variant_reviews') WHERE name='superseded_at';")" || return 1
	assert_failure db_query 'UPDATE variant_policy_revisions SET scoring_hash = lower(hex(randomblob(32))) WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	assert_failure db_query 'DELETE FROM variant_policy_revisions WHERE is_active = 1;' >/dev/null 2>&1 || return 1
	db_query "INSERT INTO variant_policy_revisions (policy_json, content_hash, matching_hash, scoring_hash, operations_hash) SELECT policy_json, printf('%064d', 2), printf('%064d', 3), printf('%064d', 4), printf('%064d', 5) FROM variant_policy_revisions WHERE is_active = 1;" || return 1
	assert_failure db_query "UPDATE variant_policy_revisions SET is_active = 1, activated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE content_hash = printf('%064d', 2);" >/dev/null 2>&1 || return 1

	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES (1, 'one', 'one', '[]'), (2, 'two', 'two', '[]');" || return 1
	assert_failure db_query 'UPDATE galleries SET favorite_count = -1 WHERE gid = 1;' >/dev/null 2>&1 || return 1
	assert_failure db_query 'UPDATE galleries SET rating_count = -1 WHERE gid = 1;' >/dev/null 2>&1 || return 1
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
	assert_gallery_variant_schema 0
}

test_page_count_scoring_migration_upgrades_only_the_default_policy() {
	command -v sqlite3 >/dev/null || return 0

	local active_revision
	prepare_gallery_variant_migration_test page-count-default
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	active_revision="$(db_query 'SELECT id FROM variant_policy_revisions WHERE is_active=1;')" || return 1
	db_query "INSERT INTO galleries(gid,token,title,tags) VALUES(77,'token-77','Page score','[]');
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
	variants_policy_load_active >/dev/null || return 1

	prepare_gallery_variant_migration_test page-count-custom
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_query "INSERT INTO variant_policy_revisions(
		policy_json,content_hash,matching_hash,scoring_hash,operations_hash
	) SELECT policy_json,printf('%064d',91),matching_hash,printf('%064d',92),operations_hash
		FROM variant_policy_revisions WHERE is_active=1;
	UPDATE variant_policy_revisions SET is_active=0 WHERE is_active=1;
	UPDATE variant_policy_revisions SET is_active=1 WHERE content_hash=printf('%064d',91);" || return 1
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	assert_eq '10|3|0000000000000000000000000000000000000000000000000000000000000091|0' "$(db_query "SELECT
		(SELECT MAX(version) FROM _schema_version),
		(SELECT COUNT(*) FROM variant_policy_revisions),
		content_hash,
		json_type(policy_json,'$.scoring.page_count') IS NOT NULL
		FROM variant_policy_revisions WHERE is_active=1;")"
}

test_gallery_identity_pair_migration_backfills_and_rejects_conflicts() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group output status=0
	prepare_gallery_variant_migration_test identity-pairs
	cp "${TEST_ROOT}"/migrations/00[1-9]_*.sql "${MIGRATIONS_DIR}/"
	cp "${TEST_ROOT}/migrations/010_page_count_scoring.sql" "${MIGRATIONS_DIR}/"
	db_init >/dev/null || return 1
	db_query "INSERT INTO galleries(gid,token,title,tags) VALUES
		(1,'one','One','[]'),(2,'two','Two','[]'),
		(3,'three','Three','[]'),(4,'four','Four','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(1,8,0);" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=1;')" || return 1
	db_query "INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(2,8,0);" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=2;')" || return 1
	db_query "INSERT INTO variant_reviews(
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
	assert_failure db_query "INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id) VALUES(2,1,1);" >/dev/null 2>&1 || return 1
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
	db_query "INSERT INTO galleries(gid,token,title,tags) VALUES
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
	db_query "INSERT INTO galleries(
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
	db_query "INSERT INTO galleries(gid, token, title, tags, self_rating)
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
	group_id="$(db_query "INSERT INTO variant_groups(
		source_gid, desired_rating, is_active, review_state
	) VALUES(101, 4, 1, 'none');
	SELECT last_insert_rowid();")" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id, gid, membership_state, decision_source,
		evidence_json, metadata_snapshot_json, variant_state
	) VALUES
		(${group_id},101,'confirmed','automatic','{}','{}','canonical'),
		(${group_id},102,'confirmed','manual','{}','{}','alternate');" || return 1
	evaluation_id="$(db_query "INSERT INTO variant_evaluations(
		group_id, policy_revision_id, state, metadata_snapshot_json,
		member_scores_json, selected_canonical_gid
	) SELECT ${group_id}, id, 'completed', '[]', '[]', 101
		FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_query "UPDATE variant_groups
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
	assert_eq '4|1|1' "$(db_query "SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${changed}" | variants_policy_activate -)" || return 1
	jq -e --argjson revision "${first_revision}" '.revision_id == $revision and .changed == false and .scoring_sweep_queued == false' <<<"${output}" >/dev/null || return 1
	assert_eq '4|1' "$(db_query "SELECT COUNT(*), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${again}" | variants_policy_activate -)" || return 1
	jq -e '.changed == true and .scoring_sweep_queued == false and .scoring_sweep_coalesced == true' <<<"${output}" >/dev/null || return 1
	assert_eq '5|1' "$(db_query "SELECT COUNT(*), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")" || return 1

	output="$(printf '%s' "${initial}" | variants_policy_activate -)" || return 1
	jq -e '.revision_id == 3 and .changed == true and .scoring_sweep_coalesced == true' <<<"${output}" >/dev/null || return 1
	assert_eq '5|1|1' "$(db_query "SELECT COUNT(*), SUM(is_active), (SELECT COUNT(*) FROM variant_jobs WHERE job_type='policy_scoring_sweep' AND status='queued') FROM variant_policy_revisions;")"
}

test_variant_scoring_components_are_deterministic() {
	local compact policy input output
	compact="$(variants_policy_validate_compact '{"format_version":1,"tag_scores":{"other:full color":100},"title_substring_scores":{"ＳＴＲＡＳＳＥ":7},"page_count":{"cap":30,"offset":70},"posted_rank_step":2}')" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"Straße Straße",title_jpn:"ＳＴＲＡＳＳＥ",tags:["other:full color","other:full colorful"],filecount:80,posted:100,favorite_count:19,rating:4.9,rating_count:3,popularity_fetched_at:"2026-01-01T00:00:00Z",expunged:true},metadata_raw:"one"},
		{gid:2,metadata:{title:"plain",title_jpn:null,tags:[],filecount:50,posted:200,favorite_count:99999,rating:5,rating_count:1000,popularity_fetched_at:null,expunged:false},metadata_raw:"two"},
		{gid:3,metadata:{title:"plain",title_jpn:null,tags:null,filecount:null,posted:200,favorite_count:null,rating:null,rating_count:null,popularity_fetched_at:null,expunged:true},metadata_raw:"three"}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1

	jq -e '
		.selected_canonical_gid == 2 and .tied_gids == [2] and
		(.member_scores[0].score == 122) and
		(.member_scores[0].components.exact_tags.matches | length == 1) and
		(.member_scores[0].components.title_substrings.matches | length == 1) and
		(.member_scores[0].components.title_substrings.matches[0].matched_fields == ["title","title_jpn"]) and
		(.member_scores[0].components.posted_rank | .rank == 1 and .points == 2) and
		(.member_scores[0].components.page_count | .raw_count == 80 and .points == 10) and
		(.member_scores[0].components.favorite_popularity | .raw_count == 19 and .points == 1) and
		(.member_scores[0].components.rating_confidence | .raw_rating == 4.9 and .raw_count == 3 and .points == 2) and
		(.member_scores[0].components.expunged.points == 0) and
		(.member_scores[1].score == 984) and
		(.member_scores[1].components.page_count | .raw_count == 50 and .points == -20) and
		(.member_scores[1].components.favorite_popularity.points == 500) and
		(.member_scores[1].components.rating_confidence.points == 500) and
		(.member_scores[1].components.posted_rank.rank == 2) and
		(.member_scores[2].score == 4) and
		(.member_scores[2].components.page_count | .raw_count == null and .points == 0) and
		(.member_scores[2].components.favorite_popularity | .raw_count == null and .points == 0) and
		(.member_scores[2].components.rating_confidence | .raw_count == null and .points == 0) and
		(.member_scores[2].components.posted_rank.rank == 2) and
		(.member_scores[2].components.expunged.points == 0)
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

test_variant_near_tie_review_uses_exclusive_five_point_gap() {
	local compact policy input output
	compact="$(variants_policy_validate_compact '{"format_version":1,"tag_scores":{},"title_substring_scores":{},"posted_rank_step":0}')" || return 1
	policy="$(variants_policy_expand "${compact}")" || return 1
	input="$(jq -cn --argjson policy "${policy}" '{policy:$policy,members:[
		{gid:1,metadata:{title:"top",tags:[],posted:null,favorite_count:100,rating:null,rating_count:null,expunged:false},metadata_raw:"one"},
		{gid:2,metadata:{title:"four behind",tags:[],posted:null,favorite_count:60,rating:null,rating_count:null,expunged:false},metadata_raw:"two"},
		{gid:3,metadata:{title:"five behind",tags:[],posted:null,favorite_count:50,rating:null,rating_count:null,expunged:false},metadata_raw:"three"}
	]}')" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1

	jq -e '
		.selected_canonical_gid == null and .tied_gids == [1,2] and
		(.winner_review | .reason == "near_tie" and .score_gap == 4 and
		 .score_gap_exclusive == 5 and .choices == [1,2])
	' <<<"${output}" >/dev/null || return 1

	input="$(jq -c '.members[1].metadata.favorite_count = 50' <<<"${input}")" || return 1
	output="$(printf '%s' "${input}" | variants_score_members_json)" || return 1
	jq -e '
		.selected_canonical_gid == 1 and .tied_gids == [1] and
		(.winner_review | .reason == null and .score_gap == 5 and .choices == [1])
	' <<<"${output}" >/dev/null
}

test_variant_evaluation_persists_unique_winner_and_routes_tie_review() {
	command -v sqlite3 >/dev/null || return 0
	local result group_id tie_group near_group
	prepare_variant_runtime_test evaluate || return 1
	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES
		(201, 'token-201', 'Winner', '[]'), (202, 'token-202', 'Alternate', '[]'),
		(203, 'token-203', 'Tie one', '[]'), (204, 'token-204', 'Tie two', '[]');
	INSERT INTO variant_groups (source_gid, desired_rating) VALUES (201, 11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=201;')" || return 1
	db_query "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json) VALUES
		(${group_id},201,'confirmed','automatic','{}','{\"title\":\"Winner\",\"title_jpn\":null,\"tags\":[\"other:full color\"],\"posted\":100,\"favorite_count\":0,\"rating\":3,\"rating_count\":0,\"popularity_fetched_at\":null,\"expunged\":false}'),
		(${group_id},202,'confirmed','automatic','{}','{\"title\":\"Alternate\",\"title_jpn\":null,\"tags\":[],\"posted\":100,\"favorite_count\":0,\"rating\":3,\"rating_count\":0,\"popularity_fetched_at\":null,\"expunged\":true}');" || return 1
	result="$(variants_evaluate_gid 202)" || return 1
	jq -e '.state == "completed" and .selected_canonical_gid == 201 and .top_score == 101 and (has("group_id") | not)' <<<"${result}" >/dev/null || return 1
	assert_eq '201|none|completed|201|canonical|101|202|alternate|2' "$(db_query "SELECT g.canonical_gid,g.review_state,e.state,e.selected_canonical_gid,(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=201),(SELECT variant_score FROM gallery_variants WHERE group_id=${group_id} AND gid=201),(SELECT gid FROM gallery_variants WHERE group_id=${group_id} AND gid=202),(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=202),json_array_length(e.metadata_snapshot_json) FROM variant_groups g JOIN variant_evaluations e ON e.id=g.active_evaluation_id WHERE g.id=${group_id};")" || return 1
	assert_failure db_query "UPDATE variant_evaluations SET state='review_blocked' WHERE group_id=${group_id};" >/dev/null 2>&1 || return 1

	db_query "INSERT INTO variant_groups (source_gid, desired_rating) VALUES (203, 11);" || return 1
	tie_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=203;')" || return 1
	db_query "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json) VALUES
		(${tie_group},203,'confirmed','automatic','{}','{\"title\":\"Tie one\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":null,\"rating\":null,\"rating_count\":null,\"popularity_fetched_at\":null,\"expunged\":false}'),
		(${tie_group},204,'confirmed','automatic','{}','{\"title\":\"Tie two\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":null,\"rating\":null,\"rating_count\":null,\"popularity_fetched_at\":null,\"expunged\":true}');" || return 1
	result="$(variants_evaluate_group "${tie_group}")" || return 1
	jq -e '.state == "review_blocked" and .selected_canonical_gid == null and .tied_gids == [203,204] and .top_score == 0' <<<"${result}" >/dev/null || return 1
	assert_eq 'winner_pending||review_blocked|203,204|winner|pending|203,204|undetermined,undetermined' "$(db_query "SELECT g.review_state,COALESCE(g.canonical_gid,''),e.state,(SELECT group_concat(value,',') FROM json_each(e.tied_gids_json)),r.review_type,r.status,(SELECT group_concat(value,',') FROM json_each(r.choices_json)),(SELECT group_concat(variant_state,',') FROM (SELECT variant_state FROM gallery_variants WHERE group_id=${tie_group} ORDER BY gid)) FROM variant_groups g JOIN variant_evaluations e ON e.id=g.active_evaluation_id JOIN variant_reviews r ON r.evaluation_id=e.id WHERE g.id=${tie_group};")"

	db_query "INSERT INTO galleries (gid, token, title, tags) VALUES
		(205, 'token-205', 'Near top', '[]'), (206, 'token-206', 'Near runner-up', '[]');
	INSERT INTO variant_groups (source_gid, desired_rating) VALUES (205, 11);" || return 1
	near_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=205;')" || return 1
	db_query "INSERT INTO gallery_variants (group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json) VALUES
		(${near_group},205,'confirmed','automatic','{}','{\"title\":\"Near top\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":100,\"rating\":null,\"rating_count\":null,\"popularity_fetched_at\":null,\"expunged\":false}'),
		(${near_group},206,'confirmed','automatic','{}','{\"title\":\"Near runner-up\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":60,\"rating\":null,\"rating_count\":null,\"popularity_fetched_at\":null,\"expunged\":false}');" || return 1
	result="$(variants_evaluate_group "${near_group}")" || return 1
	jq -e '.state == "review_blocked" and .selected_canonical_gid == null and .tied_gids == [205,206] and (.winner_review | .reason == "near_tie" and .score_gap == 4 and .score_gap_exclusive == 5)' <<<"${result}" >/dev/null || return 1
	assert_eq 'near_tie|4|5|205,206' "$(db_query "SELECT json_extract(evidence_json,'$.reason'),json_extract(evidence_json,'$.score_gap'),json_extract(evidence_json,'$.score_gap_exclusive'),(SELECT group_concat(value,',') FROM json_each(choices_json)) FROM variant_reviews WHERE group_id=${near_group};")"
}

test_variant_candidate_reviews_list_resolve_merge_and_reject() {
	command -v sqlite3 >/dev/null || return 0
	local older_group newer_group reject_group review_id linked_review_id output status=0
	prepare_variant_runtime_test candidate-reviews || return 1
	db_query "UPDATE galleries SET title='Older source', title_jpn='Older Japanese', category='Manga', file_count=10, tags='[\"artist:test\"]', thumb='https://example.test/older-live.jpg', file_path='older.7z' WHERE gid=101;
		UPDATE galleries SET title='Newer source', category='Manga', file_count=12, tags='[\"artist:test\"]', thumb='https://example.test/newer-live.jpg' WHERE gid=102;
		INSERT INTO galleries (gid,token,title,category,file_count,expunged,tags,thumb) VALUES
			(103,'token-103','Reject source','Manga',20,0,'[]','https://example.test/reject-source.jpg'),
			(104,'token-104','Different candidate','Manga',21,1,'[]','https://example.test/different.jpg'),
			(105,'token-105','Merged-group candidate','Manga',22,0,'[]','https://example.test/merged.jpg');
		INSERT INTO variant_groups(source_gid,desired_rating,latest_feedback_at) VALUES (101,9,'2026-01-01T00:00:00Z');" || return 1
	older_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_query "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json) VALUES
		(${older_group},101,'confirmed','automatic',0,'{}','{\"title\":\"Older frozen\",\"title_jpn\":\"Older Japanese\",\"category\":\"Manga\",\"filecount\":10,\"expunged\":false,\"tags\":[\"artist:test\"]}');
		INSERT INTO variant_groups(source_gid,desired_rating,review_state,latest_feedback_at) VALUES (102,11,'candidate_pending','2026-02-01T00:00:00Z');" || return 1
	newer_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_query "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json) VALUES
		(${newer_group},102,'confirmed','automatic',0,'{}','{\"title\":\"Newer frozen\",\"category\":\"Manga\",\"filecount\":12,\"expunged\":false,\"tags\":[\"artist:test\"],\"thumb\":\"https://example.test/source-frozen.jpg\"}'),
		(${newer_group},101,'candidate','automatic',55,'{\"components\":[{\"name\":\"title\",\"points\":35}],\"contradictions\":[]}','{\"title\":\"Older candidate frozen\",\"category\":\"Manga\",\"filecount\":10,\"expunged\":false,\"tags\":[\"artist:test\"],\"thumb\":\"https://example.test/candidate-frozen.jpg\"}'),
		(${newer_group},105,'candidate','automatic',40,'{\"components\":[{\"name\":\"title\",\"points\":20}],\"contradictions\":[]}','{\"title\":\"Merged-group candidate\",\"category\":\"Manga\",\"filecount\":22,\"expunged\":false,\"tags\":[]}');
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${newer_group},101,id,1,'{\"components\":[{\"name\":\"title\",\"points\":35}],\"contradictions\":[]}','[102,101]' FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${newer_group},105,id,1,'{\"components\":[{\"name\":\"title\",\"points\":20}],\"contradictions\":[]}','[102,105]' FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${newer_group} AND candidate_gid=101;")" || return 1
	linked_review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${newer_group} AND candidate_gid=105;")" || return 1
	db_query "UPDATE variant_reviews
		SET evidence_json = json_set(
			evidence_json,
			'$.source_snapshot', json('{\"tags\":[\"artist:test\"]}'),
			'$.candidate_snapshot', json('{\"tags\":[\"artist:test\"]}'),
			'$.normalized', json('{\"creators_source\":[\"artist:test\"],\"creators_candidate\":[\"artist:test\"],\"content_tags_source\":[\"female:test\"],\"content_tags_candidate\":[\"female:test\"]}')
		)
		WHERE id=${review_id};" || return 1

	output="$(variants_reviews_json pending)" || return 1
	jq -e '
		(.reviews | length) == 2 and
		(.reviews[0] | .id == $review and .source.gid == 102 and .source.title == "Newer frozen" and
		 .source.thumb == "https://example.test/source-frozen.jpg" and
		 .candidate.gid == 101 and .candidate.title == "Older candidate frozen" and
		 .candidate.thumb == "https://example.test/candidate-frozen.jpg" and
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
	jq -e '.resolved == true and .review_id == $review and .decision == "same_book" and .merged_group == true and .reevaluation_queued == true and (has("group_id") | not)' \
		--argjson review "${review_id}" <<<"${output}" >/dev/null || return 1
	assert_eq '11|1|candidate_pending|101|confirmed|manual|10054|102|confirmed|automatic|0' "$(db_query "SELECT grouped.desired_rating,grouped.is_active,grouped.review_state,
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

	db_query "INSERT INTO variant_groups(source_gid,desired_rating,review_state) VALUES (103,8,'candidate_pending');" || return 1
	reject_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=103;')" || return 1
	db_query "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json) VALUES
		(${reject_group},103,'confirmed','automatic',0,'{}','{}'),
		(${reject_group},104,'candidate','automatic',20,'{}','{}');
		INSERT INTO variant_reviews(review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${reject_group},104,id,1,'{}','[103,104]' FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${reject_group};")" || return 1
	variants_resolve_review "${review_id}" different-book >/dev/null || return 1
	assert_eq 'rejected|manual|-9979|different_book|resolved|1' "$(db_query "SELECT member.membership_state,member.decision_source,member.match_score,review.decision,review.status,
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${reject_group} AND job_type='evaluate' AND status='queued')
		FROM gallery_variants AS member JOIN variant_reviews AS review ON review.group_id=member.group_id
		WHERE member.group_id=${reject_group} AND member.gid=104;")"
}

test_variant_identity_decisions_are_monotonic_and_symmetric() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group first_review second_review status=0
	prepare_variant_runtime_test identity-monotonic || return 1
	db_query "INSERT INTO variant_groups(source_gid,desired_rating,review_state)
		VALUES(101,11,'candidate_pending'),(102,11,'candidate_pending');" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json)
		VALUES
		(${first_group},101,'confirmed','automatic',0,'{}','{}'),
		(${first_group},102,'candidate','automatic',20,'{}','{}'),
		(${second_group},102,'confirmed','automatic',0,'{}','{}'),
		(${second_group},101,'candidate','automatic',20,'{}','{}');
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
	db_query "INSERT INTO variant_groups(source_gid,desired_rating,review_state)
		VALUES(101,11,'candidate_pending'),(102,11,'candidate_pending');" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES
		(${first_group},101,'confirmed','automatic','{}','{}'),
		(${first_group},102,'candidate','automatic','{}','{}'),
		(${second_group},102,'confirmed','automatic','{}','{}'),
		(${second_group},101,'candidate','automatic','{}','{}');
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
	db_query "INSERT INTO galleries(gid,token,title,tags) VALUES(103,'token-103','Third','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(101,11,0),(102,11,1);" || return 1
	first_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	second_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES(${second_group},101,'confirmed','automatic','{}','{}'),
		      (${second_group},102,'confirmed','automatic','{}','{}'),
		      (${second_group},103,'candidate','automatic','{}','{}');
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
	local class_a class_b historical representative hidden reopen_review output stamp job_stamp status=0
	prepare_variant_runtime_test identity-reduction || return 1
	db_query "INSERT INTO galleries(gid,token,title,tags) VALUES
		(103,'token-103','Third','[]'),(104,'token-104','Fourth','[]');
		INSERT INTO variant_groups(source_gid,desired_rating,review_state,is_active)
		VALUES(101,11,'candidate_pending',1),(103,11,'candidate_pending',1),
		      (102,11,'candidate_pending',0);" || return 1
	class_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	class_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=103;')" || return 1
	historical="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=102;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json)
		VALUES
		(${class_a},101,'confirmed','automatic',0,'{}','{}'),
		(${class_a},102,'confirmed','automatic',0,'{}','{}'),
		(${class_a},103,'candidate','automatic',20,'{}','{}'),
		(${class_b},103,'confirmed','automatic',0,'{}','{}'),
		(${class_b},104,'confirmed','automatic',0,'{}','{}'),
		(${class_b},101,'candidate','automatic',20,'{}','{}'),
		(${historical},104,'candidate','automatic',20,'{}','{}');
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

	output="$(variants_reviews_json pending)" || return 1
	jq -e '
		.actionable_count == 1 and (.reviews | length) == 1 and
		.reviews[0].id == $representative and
		.reviews[0].covered_review_count == 3 and
		.reviews[0].source_class_size == 2 and
		.reviews[0].candidate_class_size == 2 and
		([.. | objects | has("group_id")] | any | not)
	' --argjson representative "${representative}" <<<"${output}" >/dev/null || return 1
	stamp="$(db_query "SELECT superseded_at FROM variant_reviews WHERE id=${hidden};")" || return 1
	variants_reviews_json pending >/dev/null || return 1
	assert_eq "${stamp}" "$(db_query "SELECT superseded_at FROM variant_reviews WHERE id=${hidden};")" || return 1

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
	local active_group output
	prepare_variant_runtime_test identity-six-by-twenty-six || return 1
	db_query "WITH RECURSIVE source(gid) AS (
		SELECT 3001 UNION ALL SELECT gid+1 FROM source WHERE gid<3006
	), candidate(gid) AS (
		SELECT 4001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<4026
	)
	INSERT INTO galleries(gid,token,title,tags)
	SELECT gid,'token-'||gid,'Gallery '||gid,'[]' FROM source
	UNION ALL
	SELECT gid,'token-'||gid,'Gallery '||gid,'[]' FROM candidate;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active,review_state)
	VALUES(3001,11,1,'candidate_pending'),(3002,11,0,'candidate_pending'),
	      (3003,11,0,'candidate_pending'),(3004,11,0,'candidate_pending'),
	      (3005,11,0,'candidate_pending'),(3006,11,0,'candidate_pending');" || return 1
	active_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=3001;')" || return 1
	db_query "WITH RECURSIVE source(gid) AS (
		SELECT 3001 UNION ALL SELECT gid+1 FROM source WHERE gid<3006
	)
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
	SELECT ${active_group},gid,'confirmed','automatic','{}','{}' FROM source;
	WITH RECURSIVE candidate(gid) AS (
		SELECT 4001 UNION ALL SELECT gid+1 FROM candidate WHERE gid<4026
	)
	INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
	SELECT grouped.id,candidate.gid,'candidate','automatic','{}','{}'
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

	output="$(variants_reviews_json pending)" || return 1
	jq -e '.actionable_count == 26 and (.reviews | length) == 26 and
		all(.reviews[]; .covered_review_count == 6 and
		  .source_class_size == 6 and .candidate_class_size == 1) and
		([.. | objects | has("group_id")] | any | not)' <<<"${output}" >/dev/null || return 1
	assert_eq '156|26|130' "$(db_query "SELECT
		(SELECT count(*) FROM variant_reviews WHERE review_type='candidate_identity'),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NULL),
		(SELECT count(*) FROM variant_reviews WHERE status='pending' AND superseded_at IS NOT NULL);")"
}

test_variant_winner_reviews_create_immutable_override_evaluation() {
	command -v sqlite3 >/dev/null || return 0
	local group_id review_id old_evaluation output status=0
	prepare_variant_runtime_test winner-reviews || return 1
	db_query "UPDATE galleries SET title='Tie one', thumb='https://example.test/tie-one.jpg', file_path='tie-one.7z' WHERE gid=101;
		UPDATE galleries SET title='Tie two', thumb='https://example.test/tie-two.jpg' WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES (101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_query "INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json) VALUES
		(${group_id},101,'confirmed','automatic','{}','{\"title\":\"Tie one\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":0,\"rating\":3,\"rating_count\":0,\"expunged\":false}'),
		(${group_id},102,'confirmed','automatic','{}','{\"title\":\"Tie two\",\"title_jpn\":null,\"tags\":[],\"posted\":null,\"favorite_count\":0,\"rating\":3,\"rating_count\":0,\"expunged\":false}');" || return 1
	variants_evaluate_group "${group_id}" >/dev/null || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${group_id} AND status='pending';")" || return 1
	old_evaluation="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${group_id};")" || return 1

	output="$(variants_reviews_json pending)" || return 1
	jq -e '.reviews[0] | .review_type == "winner" and (.choices | length) == 2 and
		.choices[0].gid == 101 and .choices[0].thumb == "https://example.test/tie-one.jpg" and .choices[0].archive_state == "archived" and
		.choices[1].gid == 102 and .choices[1].thumb == "https://example.test/tie-two.jpg" and .choices[1].archive_state == "not_archived" and
		(.choices[0].variant_score_breakdown.components | type == "object")' <<<"${output}" >/dev/null || return 1

	output="$(variants_resolve_review "${review_id}" winner 102)" || return 1
	jq -e '.resolved == true and .review_type == "winner" and .selected_gid == 102 and .evaluation_created == true and .reevaluation_queued == false' <<<"${output}" >/dev/null || return 1
	assert_eq "review_blocked|completed|${old_evaluation}|102|9999|9999|resolved|winner|102|102|canonical|1" "$(db_query "SELECT
		(SELECT state FROM variant_evaluations WHERE id=${old_evaluation}),
		new.state,new.supersedes_evaluation_id,new.selected_canonical_gid,
		json_extract(new.member_scores_json,'\$[1].score'),
		json_extract(new.member_scores_json,'\$[1].components.manual_winner_override.points'),
		review.status,review.decision,review.selected_gid,grouped.canonical_gid,
		(SELECT variant_state FROM gallery_variants WHERE group_id=${group_id} AND gid=102),
		(SELECT COUNT(*) FROM variant_jobs WHERE group_id=${group_id} AND job_type='reconcile_actions' AND status='queued')
		FROM variant_groups AS grouped
		JOIN variant_evaluations AS new ON new.id=grouped.active_evaluation_id
		JOIN variant_reviews AS review ON review.id=${review_id}
		WHERE grouped.id=${group_id};")" || return 1
	variants_resolve_review "${review_id}" winner 101 >/dev/null 2>&1 || status=$?
	assert_eq "${VARIANTS_REVIEW_STALE_STATUS}" "${status}"
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

test_variant_ungroup_reseeds_members_and_rebuilds_remainder() {
	command -v sqlite3 >/dev/null || return 0
	local group_id unrelated_group ungroup_json replacement_id source_group_id
	prepare_variant_runtime_test ungroup || return 1
	db_query "INSERT INTO galleries(gid,token,title,tags,self_rating,feedbacked_at) VALUES
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
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,
		metadata_snapshot_json,variant_state)
		VALUES
		(${group_id},101,'confirmed','automatic','{}','{}','alternate'),
		(${group_id},102,'confirmed','manual','{}','{}','alternate'),
		(${group_id},103,'confirmed','automatic','{}','{}','canonical');
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
		INSERT INTO variant_actions(group_id,gid,action_type,desired_value,decision_revision_id)
		SELECT ${group_id},102,'favorite_remove','favdel',id
		  FROM variant_policy_revisions WHERE is_active=1;
		INSERT INTO variant_groups(source_gid,desired_rating,is_active)
		VALUES(104,8,0);" || return 1
	unrelated_group="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=104;')" || return 1
	db_query "INSERT INTO variant_reviews(
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
	db_query "INSERT INTO galleries(gid,token,title,tags,self_rating,feedbacked_at)
		VALUES(103,'token-103','Third','[]',11,'2026-01-01T00:00:00Z');
		UPDATE galleries SET self_rating=8,
			feedbacked_at='2026-02-01T01:02:03.111111Z',
			updated_at='2026-02-02T02:03:04.111111Z' WHERE gid=101;
		UPDATE galleries SET self_rating=10,
			feedbacked_at='2026-03-01T04:05:06.222222+08:00',
			updated_at='2026-03-02T05:06:07.222222+08:00' WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES(${group_id},101,'confirmed','automatic','{}','{}'),
		      (${group_id},102,'confirmed','manual','{}','{}'),
		      (${group_id},103,'confirmed','manual','{}','{}');
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
	db_query "UPDATE galleries SET self_rating=8,
		feedbacked_at='2026-04-01T01:02:03.333333Z',
		updated_at='2026-04-02T02:03:04.333333Z' WHERE gid=101;
		UPDATE galleries SET self_rating=11,
		feedbacked_at='2026-05-01T04:05:06.444444+08:00',
		updated_at='2026-05-02T05:06:07.444444+08:00',
		file_path='member.7z' WHERE gid=102;
		INSERT INTO variant_groups(source_gid,desired_rating) VALUES(101,11);" || return 1
	group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=101;')" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
		VALUES(${group_id},101,'confirmed','automatic','{}','{}'),
		      (${group_id},102,'confirmed','manual','{}','{}');" || return 1
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
	local enqueue_json list_json work_json locked_json lock_fd
	prepare_variant_runtime_test list-work || return 1
	variants_enqueue_feedback 101 11 >/dev/null || return 1

	list_json="$(variants_list_json 101 queued)" || return 1
	jq -e '.groups | length == 1 and (.[0] | has("id") | not) and .[0].members[0].gid == 101 and .[0].jobs[0].status == "queued" and .[0].actions[0].desired_value == "10"' <<<"${list_json}" >/dev/null || return 1
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
	db_query "INSERT OR IGNORE INTO variant_jobs(
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
	variants_enqueue_feedback 101 11 >/dev/null || return 1

	schedule_json="$(variants_worker_schedule_discovery)" || return 1
	jq -e '.due_groups == 1 and .runnable_jobs == 1' <<<"${schedule_json}" >/dev/null || return 1
	claim_json="$(variants_worker_claim_job worker-one)" || return 1
	jq -e '.job_type == "discover" and .source_gid == 101 and .attempt_count == 1 and (.run_id > 0)' <<<"${claim_json}" >/dev/null || return 1
	assert_eq 'running|2|worker-one' "$(db_query "SELECT status, matching_revision, lease_owner FROM variant_discovery_runs;")" || return 1

	retry_delay="$(variants_worker_retry_job "$(jq -r '.id' <<<"${claim_json}")" worker-one transient timeout)" || return 1
	assert_eq '300' "${retry_delay}" || return 1
	assert_eq 'queued|retryable|300' "$(db_query "SELECT job.status, run.status, CAST(strftime('%s', job.available_at) - strftime('%s', job.updated_at) AS INTEGER) FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1
	retry_available_at="$(db_query "SELECT available_at FROM variant_jobs WHERE job_type='discover';")" || return 1
	variants_worker_schedule_discovery >/dev/null || return 1
	assert_eq "${retry_available_at}" "$(db_query "SELECT available_at FROM variant_jobs WHERE job_type='discover';")" || return 1
	assert_failure variants_worker_continue_job "$(jq -r '.id' <<<"${claim_json}")" stale-owner null >/dev/null 2>&1 || return 1

	db_query "UPDATE variant_jobs SET available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" || return 1
	claim_json="$(variants_worker_claim_job worker-two)" || return 1
	jq -e '.attempt_count == 2 and .run_id > 0' <<<"${claim_json}" >/dev/null || return 1
	db_query "UPDATE variant_jobs SET lease_expires_at = '2000-01-01T00:00:00Z'; UPDATE variant_discovery_runs SET lease_expires_at = '2000-01-01T00:00:00Z';" || return 1
	requeued="$(variants_worker_requeue_expired_leases)" || return 1
	assert_eq '1' "${requeued}" || return 1
	assert_eq 'queued|retryable||' "$(db_query "SELECT job.status, run.status, COALESCE(job.lease_owner, ''), COALESCE(run.lease_owner, '') FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1

	db_query "UPDATE variant_jobs SET available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" || return 1
	claim_json="$(variants_worker_claim_job worker-three)" || return 1
	variants_worker_fail_job "$(jq -r '.id' <<<"${claim_json}")" worker-three configuration 'fixture stop' >/dev/null || return 1
	assert_eq 'failed|failed' "$(db_query "SELECT job.status, run.status FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id = job.id WHERE job.job_type = 'discover';")" || return 1
	variants_worker_schedule_discovery >/dev/null || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type = 'discover' AND status = 'queued';")" || return 1

	second_group="$(variants_enqueue_feedback 102 8)" || return 1
	claim_json="$(variants_worker_claim_job worker-cancel)" || return 1
	db_query "UPDATE variant_groups SET is_active=0 WHERE id=${second_group};" || return 1
	cancelled_json="$(variants_worker_handle_discover "${claim_json}" worker-cancel)" || return 1
	jq -e '.status == "cancelled" and .source_gid == 102' <<<"${cancelled_json}" >/dev/null || return 1
	assert_eq 'cancelled|cancelled' "$(db_query "SELECT job.status, run.status FROM variant_jobs AS job JOIN variant_discovery_runs AS run ON run.job_id=job.id WHERE job.group_id=${second_group};")" || return 1

	db_query "INSERT INTO variant_jobs(job_type, group_id, source_gid, priority) VALUES
		('reconcile_actions', 1, 101, 100), ('evaluate', 1, 101, 500);" || return 1
	claim_json="$(variants_worker_claim_job worker-evaluate)" || return 1
	jq -e '.job_type == "evaluate" and .source_gid == 101' <<<"${claim_json}" >/dev/null || return 1
	evaluation_json="$(variants_worker_handle_evaluate "${claim_json}" worker-evaluate)" || return 1
	jq -e '.job_type == "evaluate" and .source_gid == 101 and .status == "completed" and .result.evaluated == true' <<<"${evaluation_json}" >/dev/null || return 1
	assert_eq 'completed|queued' "$(db_query "SELECT (SELECT status FROM variant_jobs WHERE job_type = 'evaluate'), (SELECT status FROM variant_jobs WHERE job_type = 'reconcile_actions');")" || return 1
	assert_eq 'ok' "$(db_query "SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check) = 'ok' THEN 'ok' ELSE 'failed' END;")"
}

test_variant_discovery_publishes_complete_snapshot_atomically() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json run_id publish_json source_meta candidate_meta chain_meta popularity
	prepare_variant_runtime_test discovery-publish || return 1
	db_query "UPDATE galleries SET title='Shared Book', title_jpn='共有本',
		tags='[\"language:chinese\",\"other:tankoubon\",\"artist:author\"]'
		WHERE gid=101;" || return 1
	group_id="$(variants_enqueue_feedback 101 11)" || return 1
	claim_json="$(variants_worker_claim_job publish-worker)" || return 1
	run_id="$(jq -r '.run_id' <<<"${claim_json}")"
	db_query "UPDATE variant_jobs SET lease_expires_at='2000-01-01T00:00:00Z';
		UPDATE variant_discovery_runs SET lease_expires_at='2000-01-01T00:00:00Z';" || return 1
	assert_failure variants_discovery_stage_candidate "${run_id}" 999 stale-token '{}' publish-worker >/dev/null 2>&1 || return 1
	assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_discovery_candidates WHERE gid=999;")" || return 1
	db_query "UPDATE variant_jobs SET lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes');
		UPDATE variant_discovery_runs SET lease_expires_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes');" || return 1
	db_query "UPDATE variant_discovery_runs SET phase='publish' WHERE id=${run_id};" || return 1
	source_meta='{"gid":101,"token":"token-101","title":"Shared Book","title_jpn":"共有本","filecount":200,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":100,"filesize":1000,"thumb":"https://example.test/101.jpg","first_gid":null,"first_key":null,"parent_gid":null,"parent_key":null,"current_gid":null,"current_key":null}'
	candidate_meta='{"gid":102,"token":"token-102","title":"Shared Book Digital","title_jpn":"共有本","filecount":205,"expunged":true,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.4,"category":"Manga","uploader":"fixture","posted":101,"filesize":1100,"thumb":"https://example.test/102.jpg","first_gid":null,"first_key":null,"parent_gid":null,"parent_key":null,"current_gid":null,"current_key":null}'
	chain_meta='{"gid":103,"token":"token-103","title":"Shared Book","title_jpn":"共有本","filecount":201,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.6,"category":"Manga","uploader":"fixture","posted":102,"filesize":1200,"thumb":"https://example.test/103.jpg","first_gid":101,"first_key":"token-101","parent_gid":null,"parent_key":null,"current_gid":null,"current_key":null}'
	popularity='{"favorite_count":10,"rating_count":20,"popularity_fetched_at":"2026-08-24T00:00:00Z","error":null}'
	db_query \
		".parameter set :source $(db_parameter_text "${source_meta}")" \
		".parameter set :candidate $(db_parameter_text "${candidate_meta}")" \
		".parameter set :chain $(db_parameter_text "${chain_meta}")" \
		".parameter set :popularity $(db_parameter_text "${popularity}")" \
		"INSERT INTO variant_discovery_candidates(run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,state) VALUES
			 (${run_id},101,'token-101',2,'[{\"kind\":\"seed\",\"gid\":101}]',json(:source),json(:popularity),'complete'),
			 (${run_id},102,'token-102',2,'[{\"kind\":\"search\",\"query\":\"fixture\"}]',json(:candidate),json(:popularity),'complete'),
			 (${run_id},103,'token-103',2,'[{\"kind\":\"official_chain\",\"from_gid\":101,\"relation\":\"first\"}]',json(:chain),json(:popularity),'complete');" || return 1

	publish_json="$(variants_discovery_publish "${run_id}" "$(jq -r '.id' <<<"${claim_json}")" "${group_id}" publish-worker)" || return 1
	jq -e '.status == "completed" and .published == 3 and .pending_reviews == 1 and .evaluation_queued == false and .source_gid == 101' <<<"${publish_json}" >/dev/null || return 1
	assert_eq 'completed|completed|2|candidate_pending|candidate|confirmed|1|source.7z' "$(db_query "SELECT
		(SELECT status FROM variant_jobs WHERE job_type='discover'),
		(SELECT status FROM variant_discovery_runs), completed_matching_revision,
		review_state,
		(SELECT membership_state FROM gallery_variants WHERE group_id=${group_id} AND gid=102),
		(SELECT membership_state FROM gallery_variants WHERE group_id=${group_id} AND gid=103),
		(SELECT COUNT(*) FROM variant_reviews WHERE group_id=${group_id} AND candidate_gid=102 AND matching_revision=2),
		(SELECT file_path FROM galleries WHERE gid=101)
		FROM variant_groups WHERE id=${group_id};")" || return 1
	jq -e '.source_snapshot.gid == 101 and .candidate_snapshot.gid == 102 and .score >= 0' <<<"$(db_query "SELECT evidence_json FROM variant_reviews WHERE candidate_gid=102;")" >/dev/null || return 1
	assert_eq 'ok|0' "$(db_query "SELECT (SELECT integrity_check FROM pragma_integrity_check), (SELECT COUNT(*) FROM pragma_foreign_key_check);")"
}

test_variant_discovery_honors_identity_pairs_in_reverse_direction() {
	command -v sqlite3 >/dev/null || return 0
	local first_group second_group review_id job_id run_id publish_json
	local source_meta candidate_meta popularity
	prepare_variant_runtime_test discovery-identity-reverse || return 1
	db_query "UPDATE galleries SET title='Shared Book',title_jpn='共有本',
		tags='[\"language:chinese\",\"other:tankoubon\",\"artist:author\"]'
		WHERE gid IN (101,102);" || return 1
	first_group="$(variants_enqueue_feedback 101 11)" || return 1
	db_query "INSERT INTO gallery_variants(
		group_id,gid,membership_state,decision_source,match_score,evidence_json,metadata_snapshot_json)
		VALUES(${first_group},102,'candidate','automatic',40,'{}','{}');
		INSERT INTO variant_reviews(
		review_type,group_id,candidate_gid,policy_revision_id,matching_revision,evidence_json,choices_json)
		SELECT 'candidate_identity',${first_group},102,id,2,'{}','[101,102]'
		  FROM variant_policy_revisions WHERE is_active=1;" || return 1
	review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=${first_group};")" || return 1
	variants_resolve_review "${review_id}" different-book >/dev/null || return 1
	second_group="$(variants_enqueue_feedback 102 11)" || return 1
	db_query "UPDATE variant_jobs SET status='cancelled',lease_owner=NULL,lease_expires_at=NULL,
		completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE status IN ('queued','leased');
		INSERT INTO variant_jobs(
		job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
		VALUES('discover',${second_group},102,1000,'leased','reverse-worker',
		       strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));" || return 1
	job_id="$(db_query "SELECT id FROM variant_jobs WHERE group_id=${second_group} AND status='leased';")" || return 1
	db_query "INSERT INTO variant_discovery_runs(
		group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
		VALUES(${second_group},${job_id},2,'publish','running','reverse-worker',
		       strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));" || return 1
	run_id="$(db_query "SELECT id FROM variant_discovery_runs WHERE job_id=${job_id};")" || return 1
	source_meta='{"gid":102,"token":"token-102","title":"Shared Book","title_jpn":"共有本","filecount":200,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":100,"filesize":1000,"thumb":"https://example.test/102.jpg","first_gid":null,"first_key":null,"parent_gid":null,"parent_key":null,"current_gid":null,"current_key":null}'
	candidate_meta='{"gid":101,"token":"token-101","title":"Shared Book","title_jpn":"共有本","filecount":201,"expunged":false,"tags":["language:chinese","other:tankoubon","artist:author"],"rating":4.5,"category":"Manga","uploader":"fixture","posted":101,"filesize":1001,"thumb":"https://example.test/101.jpg","first_gid":102,"first_key":"token-102","parent_gid":null,"parent_key":null,"current_gid":null,"current_key":null}'
	popularity='{"favorite_count":10,"rating_count":20,"popularity_fetched_at":"2026-08-24T00:00:00Z","error":null}'
	db_query \
		".parameter set :source $(db_parameter_text "${source_meta}")" \
		".parameter set :candidate $(db_parameter_text "${candidate_meta}")" \
		".parameter set :popularity $(db_parameter_text "${popularity}")" \
		"INSERT INTO variant_discovery_candidates(
		run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,state)
		VALUES
		(${run_id},102,'token-102',2,'[{\"kind\":\"seed\",\"gid\":102}]',json(:source),json(:popularity),'complete'),
		(${run_id},101,'token-101',2,'[{\"kind\":\"official_chain\",\"from_gid\":102,\"relation\":\"first\"}]',json(:candidate),json(:popularity),'complete');" || return 1
	publish_json="$(variants_discovery_publish "${run_id}" "${job_id}" "${second_group}" reverse-worker)" || return 1
	jq -e '.status == "completed" and .pending_reviews == 0 and .evaluation_queued == true' <<<"${publish_json}" >/dev/null || return 1
	assert_eq "rejected|manual|different_book|${review_id}|0|2" "$(db_query "SELECT
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
	db_query "UPDATE galleries SET title='Shared Book', title_jpn='共有本',
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
				first_gid:null,first_key:null,parent_gid:null,parent_key:null,current_gid:null,current_key:null}}]}'
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
	assert_eq "completed|completed|2|candidate_pending|1|${group_id}" "$(db_query "SELECT
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
	group_id="$(db_query "UPDATE galleries SET file_path='alternate.7z' WHERE gid=102;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(101,11,1);
	SELECT last_insert_rowid();")" || return 1
	evaluation_id="$(db_query "INSERT INTO gallery_variants(
	  group_id,gid,membership_state,decision_source,evidence_json,
	  metadata_snapshot_json,variant_state)
	VALUES
	  (${group_id},101,'confirmed','automatic','{}','{}','canonical'),
	  (${group_id},102,'confirmed','manual','{}','{}','alternate');
	INSERT INTO variant_evaluations(
	  group_id,policy_revision_id,state,metadata_snapshot_json,
	  member_scores_json,selected_canonical_gid)
	SELECT ${group_id},id,'completed','[]','[]',101
	  FROM variant_policy_revisions WHERE is_active=1;
	SELECT last_insert_rowid();")" || return 1
	db_query "UPDATE variant_groups SET canonical_gid=101,
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

test_variant_scoring_sweep_batches_and_rejects_stale_revision() {
	command -v sqlite3 >/dev/null || return 0
	local claim_json output active_revision new_revision
	prepare_variant_runtime_test scoring-sweep || return 1
	active_revision="$(db_query "SELECT id FROM variant_policy_revisions WHERE is_active=1;")" || return 1
	db_query "WITH RECURSIVE sequence(value) AS (
	  SELECT 1001 UNION ALL SELECT value+1 FROM sequence WHERE value<1101
	)
	INSERT INTO galleries(gid,token,title,tags)
	  SELECT value,'token-'||value,'Gallery '||value,'[]' FROM sequence;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active)
	  SELECT gid,8,1 FROM galleries WHERE gid BETWEEN 1001 AND 1101;
	INSERT INTO variant_jobs(job_type,priority,status,scoring_revision_id)
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

	db_query "DELETE FROM variant_jobs WHERE job_type='evaluate';
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
	db_query "UPDATE variant_policy_revisions SET is_active=0 WHERE id=${active_revision};
	UPDATE variant_policy_revisions SET is_active=1,
	 activated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=${new_revision};" || return 1
	output="$(variants_worker_handle_policy_scoring_sweep "${claim_json}" stale-sweep-worker)" || return 1
	jq -e '.status=="stale_revision"' <<<"${output}" >/dev/null || return 1
	assert_eq "queued|${new_revision}||0" "$(db_query "SELECT status,scoring_revision_id,
	 COALESCE(continuation_cursor_json,''),
	 (SELECT COUNT(*) FROM variant_jobs WHERE job_type='evaluate')
	 FROM variant_jobs WHERE job_type='policy_scoring_sweep';")"
}

test_variant_action_remote_budget_caps_at_twenty_five() {
	command -v sqlite3 >/dev/null || return 0
	local group_id claim_json output
	prepare_variant_runtime_test action-budget || return 1
	db_query "WITH RECURSIVE sequence(value) AS (
	  SELECT 2001 UNION ALL SELECT value+1 FROM sequence WHERE value<2030
	)
	INSERT INTO galleries(gid,token,title,tags)
	  SELECT value,'token-'||value,'Gallery '||value,'[]' FROM sequence;
	INSERT INTO variant_groups(source_gid,desired_rating,is_active) VALUES(2001,8,1);" || return 1
	group_id="$(db_query "SELECT id FROM variant_groups WHERE source_gid=2001;")" || return 1
	db_query "INSERT INTO gallery_variants(
	 group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
	SELECT ${group_id},gid,'confirmed','automatic','{}','{}'
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
	db_query "INSERT INTO galleries (gid, token, title, tags, file_path) VALUES (101, 'token', 'Source', '[]', 'source.7z');" || return 1
	archive_path="${home_dir}/archived/source.7z"
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
	jq -e 'keys == ["variant_queued"] and .variant_queued == true' <<<"${output}" >/dev/null || return 1
	[[ ! -e "${curl_trace}" ]] || fail 'grouped low feedback made a synchronous curl call' || return 1
	[[ -f "${grouped_archive}" ]] || fail 'grouped low feedback synchronously deleted an archive' || return 1
	assert_eq '6|0|6' "$(db_query "SELECT desired_rating, is_active, (SELECT self_rating FROM galleries WHERE gid = 201) FROM variant_groups WHERE id = ${group_id};")" || return 1

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
	jq -e '.success == true and (.reviews | length) == 1 and .reviews[0].id == 7' <<<"${body}" >/dev/null || return 1

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

	response="$(
		MOCK_REVIEW_ARGS_PATH="${trace}" YOMIKO_BIN="${fixture}" \
		YOMIKO_API_TOKEN='test-token' HTTP_AUTHORIZATION='Bearer test-token' \
		REQUEST_METHOD=PUT QUERY_STRING='review_id=7&decision=same-book' HTTP_ORIGIN='' \
		bash "${TEST_ROOT}/web/api/review_resolve.sh"
	)" || return 1
	body="${response#*$'\n\n'}"
	jq -e '.success == true and .resolved == true and .review_id == 7' <<<"${body}" >/dev/null || return 1
	assert_eq 'variants resolve 7 --decision same-book' "$(<"${trace}")" || return 1

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
run_test 'database query connections enforce foreign keys' test_db_query_connections_enable_foreign_keys
run_test 'database queries preserve SQLite failures' test_db_queries_preserve_sqlite_failures
run_test 'database initialization applies atomic migrations' test_db_init_applies_atomic_migrations
run_test 'failed database migrations roll back and can retry' test_db_init_rolls_back_failed_migration
run_test 'migration logs stay quiet in API mode' test_db_init_suppresses_migration_logs_in_api_mode
run_test 'gallery tag validation permits only valid repair values' test_gallery_tag_validation_migration_allows_repair_only_to_valid_arrays
run_test 'gallery variant migration upgrades a schema-004 database' test_gallery_variant_migration_upgrades_schema_004
run_test 'fresh gallery variant schema seeds policy and enforces invariants' test_gallery_variant_fresh_schema_seeds_policy_and_enforces_invariants
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
run_test 'variant winner review uses an exclusive five-point near-tie gap' test_variant_near_tie_review_uses_exclusive_five_point_gap
run_test 'variant evaluations persist winners and route ties to review' test_variant_evaluation_persists_unique_winner_and_routes_tie_review
run_test 'candidate reviews list frozen cards, merge same-book groups, and persist rejection labels' test_variant_candidate_reviews_list_resolve_merge_and_reject
run_test 'gallery identity decisions are symmetric, monotonic, and reject implicit splits' test_variant_identity_decisions_are_monotonic_and_symmetric
run_test 'identity reconciliation collapses class-pair work and reopens it after ungroup' test_variant_identity_reconciliation_collapses_and_reopens_class_pairs
run_test 'identity reconciliation reduces a six-by-twenty-six raw queue to class pairs' test_variant_identity_reconciliation_reduces_six_by_twenty_six_queue
run_test 'winner reviews create immutable override evaluations and canonical projections' test_variant_winner_reviews_create_immutable_override_evaluation
run_test 'variant enqueue is atomic, idempotent, and reopens only superseded actions' test_variant_enqueue_is_atomic_idempotent_and_reopens_only_superseded_actions
run_test 'variant enqueue reuses an inactive confirmed-member group' test_variant_enqueue_reuses_inactive_confirmed_member_group
run_test 'variant ungroup reseeds selected members and rebuilds the remainder' test_variant_ungroup_reseeds_members_and_rebuilds_remainder
run_test 'variant list/work JSON preserves queued work and honors the worker lock' test_variant_list_and_work_emit_json_without_consuming_jobs
run_test 'remote-write environment guard blocks every mutation adapter before transport' test_remote_write_environment_guard_blocks_mutation_adapters
run_test 'remote-write deny mode skips action and retention jobs for local variant work' test_remote_write_deny_mode_prioritizes_local_variant_work
run_test 'variant worker schedules stale groups, leases safely, retries, and dispatches evaluation' test_variant_worker_schedules_claims_retries_and_dispatches_evaluation
run_test 'variant discovery publishes one complete snapshot and routes reviews atomically' test_variant_discovery_publishes_complete_snapshot_atomically
run_test 'variant discovery honors canonical identity pairs in the reverse direction' test_variant_discovery_honors_identity_pairs_in_reverse_direction
run_test 'variant discovery dispatcher resumes every bounded phase' test_variant_discovery_dispatcher_resumes_all_bounded_phases
run_test 'variant discovery matching and remote adapters pass fixed fixtures' test_variant_discovery_matching_and_remote_fixtures
run_test 'variant operational actions converge while retaining the rating-11 canonical archive' test_variant_operational_actions_converge_and_retain_canonical
run_test 'variant scoring sweep batches one hundred groups and rejects a stale revision' test_variant_scoring_sweep_batches_and_rejects_stale_revision
run_test 'variant action reconciliation enforces the twenty-five-call remote budget' test_variant_action_remote_budget_caps_at_twenty_five
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
run_test 'review list API does not return CLI failures' test_api_command_output_is_not_returned reviews.sh GET 'status=pending'
run_test 'review mutation API does not return CLI failures' test_api_command_output_is_not_returned review_resolve.sh PUT 'review_id=7&decision=same-book'
run_test 'feedback API exposes queue state without group IDs and rejects malformed CLI JSON' test_feedback_api_returns_variant_queue_fields_and_rejects_malformed_cli_json
run_test 'variant review APIs list, validate, authenticate, resolve, and report stale decisions' test_variant_review_apis_list_validate_auth_resolve_and_report_stale
run_test 'gallery API does not return CLI failures' test_api_command_output_is_not_returned galleries.sh GET 'gids=123456'
run_test 'pending gallery API does not return CLI failures' test_api_command_output_is_not_returned pending_feedback_galleries.sh GET 'max_count=1'
run_test 'pending gallery API returns display fields' test_pending_feedback_api_returns_display_fields
run_test 'pending gallery list builds unrated query' test_pending_feedback_list_builds_unrated_query
run_test 'pending gallery API caps max_count' test_pending_feedback_api_caps_max_count
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
