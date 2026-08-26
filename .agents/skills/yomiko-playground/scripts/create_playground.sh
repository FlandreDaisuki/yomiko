#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PRODUCTION_DIR="${YOMIKO_PRODUCTION_DIR:-${HOME}/docker/yomiko}"
PRODUCTION_COOKIE_PATH='/home/yomiko/data/cookie-jar.txt'
START_PLAYGROUND=false
DESTINATION=''
CONTAINER_SNAPSHOT=''
PRODUCTION_CONTAINER=''

usage() {
	cat <<'EOF'
Usage: create_playground.sh [--start] [DESTINATION]

Create an isolated copy of the current Yomiko worktree with a consistent
production database snapshot and production cookie jar for authenticated
read-only requests. DESTINATION must not already exist. Without it, a private
directory is created below /tmp.
EOF
}

cleanup_container_snapshot() {
	if [[ -n "${CONTAINER_SNAPSHOT}" && -n "${PRODUCTION_CONTAINER}" ]]; then
		docker exec "${PRODUCTION_CONTAINER}" rm -f -- "${CONTAINER_SNAPSHOT}" \
			>/dev/null 2>&1 || true
	fi
}
trap cleanup_container_snapshot EXIT

while (($# > 0)); do
	case "$1" in
	--start)
		START_PLAYGROUND=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--*)
		printf 'ERROR: Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*)
		if [[ -n "${DESTINATION}" ]]; then
			printf 'ERROR: Only one destination may be supplied.\n' >&2
			exit 2
		fi
		DESTINATION="$1"
		shift
		;;
	esac
done

for required_command in docker git od rsync; do
	if ! command -v "${required_command}" >/dev/null 2>&1; then
		printf 'ERROR: Required command not found: %s\n' "${required_command}" >&2
		exit 1
	fi
done
docker compose version >/dev/null

SOURCE_ROOT="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null)" || {
	printf 'ERROR: Run this command from inside the Yomiko Git worktree.\n' >&2
	exit 1
}
if [[ ! -f "${SOURCE_ROOT}/docker/docker-compose.debug.yaml" || \
	! -x "${SOURCE_ROOT}/bin/yomiko" ]]; then
	printf 'ERROR: Current Git worktree is not a Yomiko source tree: %s\n' \
		"${SOURCE_ROOT}" >&2
	exit 1
fi
if [[ ! -f "${PRODUCTION_DIR}/compose.yaml" ]]; then
	printf 'ERROR: Production Compose file not found: %s/compose.yaml\n' \
		"${PRODUCTION_DIR}" >&2
	exit 1
fi

PRODUCTION_CONTAINER="$(
	docker compose \
		--project-directory "${PRODUCTION_DIR}" \
		-f "${PRODUCTION_DIR}/compose.yaml" \
		ps -q yomiko
)"
if [[ -z "${PRODUCTION_CONTAINER}" ]]; then
	printf 'ERROR: The production Yomiko service is not running.\n' >&2
	exit 1
fi
if ! docker exec "${PRODUCTION_CONTAINER}" \
	test -s "${PRODUCTION_COOKIE_PATH}"; then
	printf 'ERROR: Production cookie jar is missing or empty: %s\n' \
		"${PRODUCTION_COOKIE_PATH}" >&2
	exit 1
fi

if [[ -n "${DESTINATION}" ]]; then
	if [[ -e "${DESTINATION}" ]]; then
		printf 'ERROR: Destination already exists: %s\n' "${DESTINATION}" >&2
		exit 1
	fi
	mkdir -m 700 -- "${DESTINATION}"
	DESTINATION="$(cd -- "${DESTINATION}" && pwd)"
else
	DESTINATION="$(mktemp -d "${TMPDIR:-/tmp}/yomiko-playground.XXXXXX")"
	chmod 700 "${DESTINATION}"
fi

printf 'Copying current worktree to %s...\n' "${DESTINATION}"
rsync --archive \
	--exclude='/.git/' \
	--exclude='/archived/' \
	--exclude='/data/' \
	--exclude='/hath/' \
	--exclude='/logs/' \
	"${SOURCE_ROOT}/" "${DESTINATION}/"
chmod 700 "${DESTINATION}"
mkdir -m 700 \
	"${DESTINATION}/archived" \
	"${DESTINATION}/data" \
	"${DESTINATION}/hath" \
	"${DESTINATION}/logs"

CONTAINER_SNAPSHOT="/tmp/yomiko-playground-$PPID-$RANDOM.sqlite3"
printf 'Taking a consistent online snapshot of the production database...\n'
docker exec "${PRODUCTION_CONTAINER}" \
	sqlite3 /home/yomiko/data/db.sqlite3 ".backup '${CONTAINER_SNAPSHOT}'"

integrity="$(
	docker exec "${PRODUCTION_CONTAINER}" \
		sqlite3 "${CONTAINER_SNAPSHOT}" 'PRAGMA integrity_check;'
)"
if [[ "${integrity}" != 'ok' ]]; then
	printf 'ERROR: Production database snapshot failed integrity_check:\n%s\n' \
		"${integrity}" >&2
	exit 1
fi
schema_version="$(
	docker exec "${PRODUCTION_CONTAINER}" sqlite3 "${CONTAINER_SNAPSHOT}" \
		'SELECT COALESCE(MAX(version), 0) FROM _schema_version;'
)"
gallery_count="$(
	docker exec "${PRODUCTION_CONTAINER}" sqlite3 "${CONTAINER_SNAPSHOT}" \
		'SELECT COUNT(*) FROM galleries;'
)"
docker cp \
	"${PRODUCTION_CONTAINER}:${CONTAINER_SNAPSHOT}" \
	"${DESTINATION}/data/db.sqlite3"
chmod 600 "${DESTINATION}/data/db.sqlite3"
cleanup_container_snapshot
CONTAINER_SNAPSHOT=''

printf 'Copying production cookie jar for authenticated read-only requests...\n'
docker cp \
	"${PRODUCTION_CONTAINER}:${PRODUCTION_COOKIE_PATH}" \
	"${DESTINATION}/data/cookie-jar.txt"
chmod 600 "${DESTINATION}/data/cookie-jar.txt"

install -m 0644 \
	"${SKILL_DIR}/assets/docker-compose.playground.yaml" \
	"${DESTINATION}/docker/docker-compose.playground.yaml"
install -m 0755 \
	"${SKILL_DIR}/assets/playground" \
	"${DESTINATION}/playground"

playground_id="$(basename -- "${DESTINATION}" | tr '[:upper:]_.' '[:lower:]--')"
playground_id="${playground_id//[^a-z0-9-]/-}"
api_token="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
port=62080
if command -v ss >/dev/null 2>&1; then
	while [[ -n "$(ss -H -ltn "sport = :${port}" 2>/dev/null)" ]]; do
		port=$((port + 1))
		if ((port > 62180)); then
			printf 'ERROR: No available playground port from 62080 through 62180.\n' >&2
			exit 1
		fi
	done
fi

{
	printf 'COMPOSE_PROJECT_NAME=%s\n' "${playground_id}"
	printf 'HOST_ARCHIVED_DIR=../archived\n'
	printf 'HOST_HATH_DOWNLOAD_DIR=../hath\n'
	printf 'YOMIKO_API_TOKEN=%s\n' "${api_token}"
	printf 'YOMIKO_BIND_ADDRESS=127.0.0.1\n'
	printf 'YOMIKO_IMAGE=%s.debug\n' "${playground_id}"
	printf 'YOMIKO_PLAYGROUND_CONTAINER=%s.debug\n' "${playground_id}"
	printf 'YOMIKO_PORT=%s\n' "${port}"
	printf 'YOMIKO_REMOTE_WRITES_ENABLED=false\n'
} >"${DESTINATION}/.yomiko-playground.env"
chmod 600 "${DESTINATION}/.yomiko-playground.env"

printf 'Playground created: %s\n' "${DESTINATION}"
printf 'Production snapshot: schema %s, %s galleries, integrity_check ok\n' \
	"${schema_version}" "${gallery_count}"
printf 'Planned URL: http://127.0.0.1:%s\n' "${port}"

if [[ "${START_PLAYGROUND}" == true ]]; then
	"${DESTINATION}/playground" up
else
	printf 'Start it with: cd %q && ./playground up\n' "${DESTINATION}"
fi
