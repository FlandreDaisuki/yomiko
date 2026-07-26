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

test_db_escape() {
	local escaped

	escaped="$(db_escape "O'Reilly")"
	assert_eq "\"'O''Reilly'\"" "${escaped}" || return 1
	assert_eq "\"'plain'\"" "$(db_escape 'plain')"
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
	assert_cli_usage_error 'Missing value for --order-by.' list --order-by=
}

test_cli_rejects_invalid_numeric_option_values() {
	assert_cli_usage_error "Invalid rating '0'" rate 123 0 || return 1
	assert_cli_usage_error "Invalid favorite category '10'" favorite 123 10 || return 1
	assert_cli_usage_error "Invalid rating '12'" feedback 123 --rating 12 || return 1
	assert_cli_usage_error "Invalid favorite category '-1'" feedback 123 --favorite -1 || return 1
	assert_cli_usage_error "Invalid max count '0'" list --max-count 0 || return 1
	assert_cli_usage_error "Invalid max count 'many'" list --max-count many
}

prepare_archive_test() {
	ARCHIVE_TEST_HOME="${TEST_TMPDIR}/archive-$1-home"
	ARCHIVE_TEST_GALLERY="${ARCHIVE_TEST_HOME}/hath/[artist] title [123]"
	ARCHIVE_TEST_FINAL="${ARCHIVE_TEST_HOME}/archived/[123][artist] title.7z"
	ARCHIVE_TEST_SQLITE_TRACE="${ARCHIVE_TEST_HOME}/sqlite.trace"

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
		MOCK_METADATA_FAILURE="${MOCK_METADATA_FAILURE:-0}" \
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
	local trace
	prepare_archive_test success

	run_archive_test >/dev/null || return 1
	trace="$(<"${ARCHIVE_TEST_SQLITE_TRACE}")"

	assert_eq 'insert stage_count=1 final_exists=0' "${trace}" || return 1
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
run_test 'db_escape quotes SQL string values' test_db_escape
run_test 'gallery path metadata is parsed' test_parse_gallery_path
run_test 'invalid gallery paths are rejected' test_parse_gallery_path_rejects_invalid_name
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
run_test 'archive rejects concurrent work for the same gallery' test_archive_rejects_concurrent_gallery
run_test 'scan skips galleries already being archived' test_scan_skips_concurrent_gallery
run_test 'scan rejects a concurrent scan' test_scan_rejects_concurrent_scan
run_test 'API origins match the current host' test_origin_matching
run_test 'CORS headers reflect a matching origin' test_cors_headers_for_matching_origin
run_test 'cookie API does not return CLI failures' test_api_command_output_is_not_returned update_cookies.sh POST ''
run_test 'Hath API does not return CLI failures' test_api_command_output_is_not_returned hath_download.sh PUT 'gid=123456'
run_test 'feedback API does not return CLI failures' test_api_command_output_is_not_returned feedback.sh PUT 'gid=123456&rating=5'
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
