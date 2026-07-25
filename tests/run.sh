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
	local fixture_home="${TEST_ROOT}/tests/fixtures/entrypoint-home"

	if [[ "${enable_web}" == "default" ]]; then
		env -u YOMIKO_ENABLE_WEB \
			HOME="${fixture_home}" \
			PATH="${fixture_home}/bin:${PATH}" \
			YOMIKO_ENTRYPOINT_TRACE="${trace_path}" \
			bash "${TEST_ROOT}/entrypoint.sh"
	else
		HOME="${fixture_home}" \
			PATH="${fixture_home}/bin:${PATH}" \
			YOMIKO_ENTRYPOINT_TRACE="${trace_path}" \
			YOMIKO_ENABLE_WEB="${enable_web}" \
			bash "${TEST_ROOT}/entrypoint.sh"
	fi
}

test_entrypoint_enables_web_by_default() {
	local trace_path="${TEST_TMPDIR}/entrypoint-default.log"
	local trace

	run_entrypoint default "${trace_path}" || return 1
	trace="$(<"${trace_path}")"

	assert_contains "${trace}" 'db_init' || return 1
	assert_contains "${trace}" 'cron' || return 1
	assert_contains "${trace}" 'httpd'
}

test_entrypoint_can_disable_web() {
	local trace_path="${TEST_TMPDIR}/entrypoint-no-web.log"
	local trace

	run_entrypoint false "${trace_path}" || return 1
	trace="$(<"${trace_path}")"

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
run_test 'entrypoint can disable web' test_entrypoint_can_disable_web
run_test 'entrypoint rejects invalid web settings' test_entrypoint_rejects_invalid_web_setting

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"
((failed == 0))
