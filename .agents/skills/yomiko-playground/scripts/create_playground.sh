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
PRODUCTION_STARTED=false

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

production_compose() {
	docker compose \
		--project-directory "${PRODUCTION_DIR}" \
		-f "${PRODUCTION_DIR}/compose.yaml" "$@"
}

stop_temporary_production() {
	if [[ "${PRODUCTION_STARTED}" == true ]]; then
		printf 'Stopping temporarily started production Yomiko...\n'
		production_compose down || return 1
		PRODUCTION_STARTED=false
	fi
}

cleanup() {
	local exit_status=$?
	trap - EXIT
	cleanup_container_snapshot
	if ! stop_temporary_production; then
		printf 'ERROR: Could not shut down temporarily started production Yomiko.\n' >&2
		exit_status=1
	fi
	exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

production_running_container() {
	production_compose ps -q yomiko
}

require_production_stopped() {
	if [[ -n "$(production_running_container)" ]]; then
		printf 'ERROR: Production Yomiko started during the host snapshot.\n' >&2
		exit 1
	fi
}

snapshot_from_container() {
	if ! docker exec "${PRODUCTION_CONTAINER}" test -s "${PRODUCTION_COOKIE_PATH}"; then
		printf 'ERROR: Production cookie jar is missing or empty in the container.\n' >&2
		return 1
	fi
	CONTAINER_SNAPSHOT="/tmp/yomiko-playground-$PPID-$RANDOM.sqlite3"
	printf 'Taking a consistent online snapshot of the production database...\n'
	docker exec "${PRODUCTION_CONTAINER}" \
		sqlite3 /home/yomiko/data/db.sqlite3 ".backup '${CONTAINER_SNAPSHOT}'" || return 1

	integrity="$(docker exec "${PRODUCTION_CONTAINER}" \
		sqlite3 "${CONTAINER_SNAPSHOT}" 'PRAGMA integrity_check;')" || return 1
	if [[ "${integrity}" != 'ok' ]]; then
		printf 'ERROR: Production database snapshot failed integrity_check:\n%s\n' \
			"${integrity}" >&2
		return 1
	fi
	schema_version="$(docker exec "${PRODUCTION_CONTAINER}" \
		sqlite3 "${CONTAINER_SNAPSHOT}" \
		'SELECT COALESCE(MAX(version), 0) FROM _schema_version;')" || return 1
	gallery_count="$(docker exec "${PRODUCTION_CONTAINER}" \
		sqlite3 "${CONTAINER_SNAPSHOT}" \
		'SELECT COUNT(*) FROM galleries;')" || return 1
	docker cp \
		"${PRODUCTION_CONTAINER}:${CONTAINER_SNAPSHOT}" \
		"${DESTINATION}/data/db.sqlite3" || return 1
	printf 'Copying production cookie jar for authenticated read-only requests...\n'
	docker cp \
		"${PRODUCTION_CONTAINER}:${PRODUCTION_COOKIE_PATH}" \
		"${DESTINATION}/data/cookie-jar.txt" || return 1
	cleanup_container_snapshot
	CONTAINER_SNAPSHOT=''
}

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
if [[ ! -x "${SOURCE_ROOT}/bin/yomiko" ]]; then
	printf 'ERROR: Current Git worktree is not a Yomiko source tree: %s\n' \
		"${SOURCE_ROOT}" >&2
	exit 1
fi
if [[ ! -f "${PRODUCTION_DIR}/compose.yaml" ]]; then
	printf 'ERROR: Production Compose file not found: %s/compose.yaml\n' \
		"${PRODUCTION_DIR}" >&2
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

PRODUCTION_CONTAINER="$(production_running_container)"
if [[ -z "${PRODUCTION_CONTAINER}" ]]; then
	printf 'Production Yomiko is stopped; starting it temporarily for the snapshot...\n'
	PRODUCTION_STARTED=true
	if production_compose up -d --no-deps --no-build --no-recreate --pull never yomiko; then
		PRODUCTION_CONTAINER="$(production_running_container)"
	fi
fi

if [[ -z "${PRODUCTION_CONTAINER}" ]] || ! snapshot_from_container; then
	if [[ "${PRODUCTION_STARTED}" != true ]]; then
		printf 'ERROR: Could not snapshot the running production Yomiko container.\n' >&2
		exit 1
	fi
	cleanup_container_snapshot
	CONTAINER_SNAPSHOT=''
	if ! stop_temporary_production; then
		printf 'ERROR: Could not shut down temporarily started production Yomiko.\n' >&2
		exit 1
	fi
	printf 'Container snapshot unavailable; falling back to host Python.\n'
	OFFLINE_PRODUCTION_DB="${PRODUCTION_DIR}/data/db.sqlite3"
	OFFLINE_COOKIE_JAR="${PRODUCTION_DIR}/data/cookie-jar.txt"
	if [[ ! -s "${OFFLINE_PRODUCTION_DB}" || ! -r "${OFFLINE_PRODUCTION_DB}" ]]; then
		printf 'ERROR: Production database is missing, empty, or unreadable: %s\n' \
			"${OFFLINE_PRODUCTION_DB}" >&2
		exit 1
	fi
	if [[ ! -s "${OFFLINE_COOKIE_JAR}" || ! -r "${OFFLINE_COOKIE_JAR}" ]]; then
		printf 'ERROR: Production cookie jar is missing, empty, or unreadable: %s\n' \
			"${OFFLINE_COOKIE_JAR}" >&2
		exit 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ERROR: Required command not found for host snapshot: python3\n' >&2
		exit 1
	fi
	rm -f -- "${DESTINATION}/data/db.sqlite3" "${DESTINATION}/data/cookie-jar.txt"
	require_production_stopped
	printf 'Taking a consistent read-only SQLite backup of the production database...\n'
	database_summary="$(python3 - "${OFFLINE_PRODUCTION_DB}" \
		"${DESTINATION}/data/db.sqlite3" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

source_path = Path(sys.argv[1]).resolve(strict=True)
destination_path = Path(sys.argv[2])
source = sqlite3.connect(f"{source_path.as_uri()}?mode=ro", uri=True)
try:
	fd = os.open(destination_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
	os.close(fd)
	destination = sqlite3.connect(destination_path)
	try:
		source.backup(destination)
		integrity = destination.execute("PRAGMA integrity_check").fetchone()[0]
		if integrity != "ok":
			raise RuntimeError(f"integrity_check failed: {integrity}")
		schema_version = destination.execute(
			"SELECT COALESCE(MAX(version), 0) FROM _schema_version"
		).fetchone()[0]
		gallery_count = destination.execute("SELECT COUNT(*) FROM galleries").fetchone()[0]
		print(f"{integrity}\t{schema_version}\t{gallery_count}")
	finally:
		destination.close()
finally:
	source.close()
PY
	)"
	IFS=$'\t' read -r integrity schema_version gallery_count <<<"${database_summary}"
	if [[ "${integrity}" != 'ok' ]]; then
		printf 'ERROR: Production database snapshot failed integrity_check:\n%s\n' \
			"${integrity}" >&2
		exit 1
	fi
	require_production_stopped
	printf 'Copying production cookie jar for authenticated read-only requests...\n'
	cp -- "${OFFLINE_COOKIE_JAR}" "${DESTINATION}/data/cookie-jar.txt"
	require_production_stopped
fi
if ! stop_temporary_production; then
	printf 'ERROR: Could not shut down temporarily started production Yomiko.\n' >&2
	exit 1
fi
chmod 600 "${DESTINATION}/data/db.sqlite3"
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
metrics_token="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
if [[ ! "${api_token}" =~ ^[0-9a-f]{64}$ ||
	! "${metrics_token}" =~ ^[0-9a-f]{64}$ ]]; then
	printf 'ERROR: Failed to generate playground tokens.\n' >&2
	exit 1
fi
printf '%s\n' "${metrics_token}" >"${DESTINATION}/data/metrics-token"
chmod 600 "${DESTINATION}/data/metrics-token"
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
	printf 'YOMIKO_METRICS_TOKEN_FILE=/home/yomiko/data/metrics-token\n'
	printf 'YOMIKO_IMAGE=%s.debug\n' "${playground_id}"
	# Normal playgrounds do not need access to production observability.
	# Metrics observation supplies a command-scoped peer override when requested.
	printf 'YOMIKO_NETWORK_PEER_CONTAINER=\n'
	printf 'YOMIKO_PLAYGROUND_NETWORK=%s_default\n' "${playground_id}"
	printf 'YOMIKO_PLAYGROUND_CONTAINER=%s.debug\n' "${playground_id}"
	printf 'YOMIKO_TEST_IMAGE=%s.test\n' "${playground_id}"
	printf 'YOMIKO_TEST_CONTAINER=%s.test\n' "${playground_id}"
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
	printf 'From the worktree root, start it with:\n'
	printf './.agents/skills/yomiko-playground/scripts/yomiko --playground %q up\n' \
		"${DESTINATION}"
fi
