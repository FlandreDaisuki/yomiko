#!/usr/bin/env bash
set -euo pipefail

YOMIKO_ENABLE_WEB_VALUE="${YOMIKO_ENABLE_WEB:-true}"
case "${YOMIKO_ENABLE_WEB_VALUE}" in
true | false) ;;
*)
	echo "ERROR: YOMIKO_ENABLE_WEB must be 'true' or 'false'." >&2
	exit 1
	;;
esac

persist_api_token() {
	local token_path="$1"
	local api_token="$2"
	local token_tmp

	mkdir -p "$(dirname "${token_path}")"
	token_tmp="$(mktemp "${token_path}.tmp.XXXXXX")"
	chmod 600 "${token_tmp}"
	printf '%s\n' "${api_token}" >"${token_tmp}"
	mv "${token_tmp}" "${token_path}"
}

configure_api_token() {
	local token_path="${DATA_DIR}/api-token"
	local api_token="${YOMIKO_API_TOKEN:-}"
	local persisted_token=''

	if [[ "${api_token}" == *$'\n'* || "${api_token}" == *$'\r'* ]]; then
		printf 'ERROR: YOMIKO_API_TOKEN must not contain line breaks.\n' >&2
		return 1
	fi

	if [[ -n "${api_token}" ]]; then
		if [[ -f "${token_path}" ]]; then
			persisted_token="$(<"${token_path}")"
		fi
		if [[ "${persisted_token}" != "${api_token}" ]]; then
			persist_api_token "${token_path}" "${api_token}"
		fi
		printf 'Using configured Yomiko API token; persisted in application data.\n'
	elif [[ -f "${token_path}" ]]; then
		api_token="$(<"${token_path}")"
		if [[ -z "${api_token}" ]]; then
			printf 'ERROR: Persisted Yomiko API token is empty: %s\n' "${token_path}" >&2
			return 1
		fi
		printf 'Loaded persisted Yomiko API token.\n'
	else
		api_token="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
		if [[ ! "${api_token}" =~ ^[0-9a-f]{64}$ ]]; then
			printf 'ERROR: Failed to generate a Yomiko API token.\n' >&2
			return 1
		fi
		persist_api_token "${token_path}" "${api_token}"
		printf 'Generated and persisted a new Yomiko API token.\n'
	fi

	chmod 600 "${token_path}"
	export YOMIKO_API_TOKEN="${api_token}"
}

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/path.sh" ]] && source "${HOME}/lib/path.sh"

# shellcheck disable=SC1091
[[ -f "${HOME}/lib/db.sh" ]] && source "${HOME}/lib/db.sh"
db_init

if [[ "${YOMIKO_ENABLE_WEB_VALUE}" == "true" ]]; then
	configure_api_token
	printf 'Starting Yomiko web server on 0.0.0.0:80.\n'
	"${CRONJOB_DIR}/cron-simulate" &
	exec httpd -f -v -p '0.0.0.0:80' -h "${HOME}/web" -c "${HOME}/server/httpd.conf"
else
	printf 'Starting Yomiko in CLI-only mode.\n'
	exec "${CRONJOB_DIR}/cron-simulate"
fi
