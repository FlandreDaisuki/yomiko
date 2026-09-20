#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PLAYGROUND_HELPER="${SKILL_DIR}/assets/playground"
PROMETHEUS_DIR="${YOMIKO_PROMETHEUS_DIR:-${HOME}/docker/prometheus}"
PROMETHEUS_CONTAINER="${YOMIKO_PROMETHEUS_CONTAINER:-prometheus}"
PROMETHEUS_COMPOSE_FILE="${YOMIKO_PROMETHEUS_COMPOSE_FILE:-${PROMETHEUS_DIR}/compose.yaml}"
PROMETHEUS_CONFIG_FILE="${YOMIKO_PROMETHEUS_CONFIG_FILE:-${PROMETHEUS_DIR}/prometheus.yml}"
METRICS_JOB='yomiko-playground'
METRICS_SECRET='yomiko_playground_metrics_token'
METRICS_COPY='/tmp/yomiko-playground-metrics-token'
COMPOSE_BEGIN='# BEGIN YOMIKO PLAYGROUND METRICS SECRET'
COMPOSE_END='# END YOMIKO PLAYGROUND METRICS SECRET'
PROMETHEUS_BEGIN='# BEGIN YOMIKO PLAYGROUND METRICS JOB'
PROMETHEUS_END='# END YOMIKO PLAYGROUND METRICS JOB'

usage() {
	cat <<'EOF'
Usage: playground-metrics.sh <enable|status|disable> PLAYGROUND_DIR [--keep-playground]

Enable or remove the temporary Prometheus scrape for an existing Yomiko
playground. The script never prints token contents. PLAYGROUND_DIR must be a
directory created by create_playground.sh.

Environment overrides:
  YOMIKO_PROMETHEUS_DIR       Prometheus deployment directory
  YOMIKO_PROMETHEUS_CONTAINER Prometheus container name (default: prometheus)
  YOMIKO_PROMETHEUS_COMPOSE_FILE
  YOMIKO_PROMETHEUS_CONFIG_FILE

disable removes the temporary Prometheus configuration and stops the
playground by default. Use --keep-playground to restore Prometheus while
leaving the playground running.
EOF
}

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

read_playground_env() {
	local key="$1"
	sed -n "s/^${key}=//p" "${PLAYGROUND_ENV}" | sed -n '1p'
}

file_has_marker() {
	local marker="$1"
	local file="$2"
	awk -v marker="${marker}" 'index($0, marker) { found=1 } END { exit(found ? 0 : 1) }' \
		"${file}"
}

sha256_of() {
	sha256sum "$1" | awk '{print $1}'
}

state_value() {
	local key="$1"
	sed -n "s/^${key}=//p" "${STATE_FILE}" | sed -n '1p'
}

yaml_single_quote() {
	local value="$1"
	value="${value//\'/\'\'}"
	printf "'%s'" "${value}"
}

prometheus_compose() {
	docker compose --project-directory "${PROMETHEUS_DIR}" \
		-f "${PROMETHEUS_COMPOSE_FILE}" "$@"
}

validate_playground() {
	[[ -d "${PLAYGROUND_DIR}" ]] || die "Playground directory not found: ${PLAYGROUND_DIR}"
	PLAYGROUND_DIR="$(cd -- "${PLAYGROUND_DIR}" && pwd)"
	PLAYGROUND_ENV="${PLAYGROUND_DIR}/.yomiko-playground.env"
	[[ -f "${PLAYGROUND_ENV}" ]] || die "Missing playground environment file: ${PLAYGROUND_ENV}"
	[[ -x "${PLAYGROUND_HELPER}" ]] || die "Missing skill playground helper: ${PLAYGROUND_HELPER}"
	TOKEN_SOURCE="${PLAYGROUND_DIR}/data/metrics-token"
	[[ -s "${TOKEN_SOURCE}" ]] || die "Playground metrics token is missing or empty"

	PLAYGROUND_CONTAINER="$(read_playground_env YOMIKO_PLAYGROUND_CONTAINER)"
	PLAYGROUND_NETWORK="$(read_playground_env YOMIKO_PLAYGROUND_NETWORK)"
	[[ "${PLAYGROUND_CONTAINER}" =~ ^[a-zA-Z0-9_.-]+$ ]] || \
		die 'Invalid YOMIKO_PLAYGROUND_CONTAINER in playground environment'
	[[ "${PLAYGROUND_NETWORK}" =~ ^[a-zA-Z0-9_.-]+$ ]] || \
		die 'Invalid YOMIKO_PLAYGROUND_NETWORK in playground environment'

	STATE_DIR="${PLAYGROUND_DIR}/.yomiko-playground-metrics"
	STATE_FILE="${STATE_DIR}/state"
	COMPOSE_BACKUP="${STATE_DIR}/compose.yaml.orig"
	PROMETHEUS_BACKUP="${STATE_DIR}/prometheus.yml.orig"
}

validate_prometheus_files() {
	[[ -f "${PROMETHEUS_COMPOSE_FILE}" ]] || \
		die "Prometheus Compose file not found: ${PROMETHEUS_COMPOSE_FILE}"
	[[ -f "${PROMETHEUS_CONFIG_FILE}" ]] || \
		die "Prometheus config not found: ${PROMETHEUS_CONFIG_FILE}"
	[[ "${PROMETHEUS_COMPOSE_FILE}" == "${PROMETHEUS_DIR}"/* ]] || \
		die 'Prometheus Compose file must be inside YOMIKO_PROMETHEUS_DIR'
	[[ "${PROMETHEUS_CONFIG_FILE}" == "${PROMETHEUS_DIR}"/* ]] || \
		die 'Prometheus config must be inside YOMIKO_PROMETHEUS_DIR'
}

playground_up() {
	YOMIKO_NETWORK_PEER_CONTAINER="${PROMETHEUS_CONTAINER}" \
		YOMIKO_PLAYGROUND_ROOT="${PLAYGROUND_DIR}" \
		"${PLAYGROUND_HELPER}" up >/dev/null
}

repair_playground_token_permissions() {
	local yomiko_uid yomiko_gid
	yomiko_uid="$(docker exec "${PLAYGROUND_CONTAINER}" id -u)"
	yomiko_gid="$(docker exec "${PLAYGROUND_CONTAINER}" id -g)"
	docker exec -u 0 "${PLAYGROUND_CONTAINER}" chown \
		"${yomiko_uid}:${yomiko_gid}" /home/yomiko/data/metrics-token
	docker exec -u 0 "${PLAYGROUND_CONTAINER}" chmod 0640 \
		/home/yomiko/data/metrics-token
}

network_peer_is_connected() {
	docker network inspect "${PLAYGROUND_NETWORK}" \
		--format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null |
		awk -v name="${PROMETHEUS_CONTAINER}" '$0 == name { found=1 } END { exit(found ? 0 : 1) }'
}

verify_network_peer() {
	network_peer_is_connected || \
		die "Prometheus is not connected to playground network ${PLAYGROUND_NETWORK}"
}

copy_token_into_prometheus() {
	local prometheus_uid prometheus_gid
	prometheus_uid="$(docker exec "${PROMETHEUS_CONTAINER}" id -u)"
	prometheus_gid="$(docker exec "${PROMETHEUS_CONTAINER}" id -g)"
	docker exec -u 0 "${PROMETHEUS_CONTAINER}" cp \
		/run/secrets/${METRICS_SECRET} "${METRICS_COPY}"
	docker exec -u 0 "${PROMETHEUS_CONTAINER}" chown \
		"${prometheus_uid}:${prometheus_gid}" "${METRICS_COPY}"
	docker exec -u 0 "${PROMETHEUS_CONTAINER}" chmod 0640 "${METRICS_COPY}"
}

reload_prometheus() {
	docker exec "${PROMETHEUS_CONTAINER}" wget -qO- --post-data='' \
		http://127.0.0.1:9090/-/reload >/dev/null
}

verify_target() {
	local response
	response="$(docker exec "${PROMETHEUS_CONTAINER}" wget -qO- \
		'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22yomiko-playground%22%7D')"
	if [[ "${response}" != *'"status":"success"'* ||
		"${response}" != *'"job":"yomiko-playground"'* ||
		"${response}" != *'"1"'* ]]; then
		die 'Prometheus did not report up=1 for the playground target'
	fi
	printf 'Prometheus target up: 1\n'
}

patch_compose_file() {
	local temporary yaml_path
	temporary="$(mktemp "${PROMETHEUS_COMPOSE_FILE}.tmp.XXXXXX")"
	yaml_path="$(yaml_single_quote "${TOKEN_SOURCE}")"
	if ! awk \
		-v secret="${METRICS_SECRET}" \
		-v token_path="${yaml_path}" \
		-v begin="${COMPOSE_BEGIN}" \
		-v end="${COMPOSE_END}" '
		$0 == "  yomiko_metrics_token:" { in_prod_secret=1 }
		in_prod_secret && $0 ~ /^    file:/ {
			print
			print "  " begin
			print "  " secret ":"
			print "    file: " token_path
			print "  " end
			in_prod_secret=0
			secret_added=1
			next
		}
		$0 == "      - yomiko_metrics_token" {
			print
			print "      - " secret
			service_added=1
			next
		}
		{ print }
		END {
			if (!secret_added || !service_added) exit 42
		}
	' "${PROMETHEUS_COMPOSE_FILE}" >"${temporary}"; then
		rm -f -- "${temporary}"
		die 'Could not find the expected production metrics secret/service entries in Prometheus Compose'
	fi
	chmod --reference="${PROMETHEUS_COMPOSE_FILE}" "${temporary}"
	mv -- "${temporary}" "${PROMETHEUS_COMPOSE_FILE}"
}

append_prometheus_job() {
	local temporary
	if ! awk '$0 == "scrape_configs:" { found=1 } END { exit(found ? 0 : 1) }' \
		"${PROMETHEUS_CONFIG_FILE}"; then
		die 'Prometheus config has no scrape_configs section'
	fi
	if awk -v job="job_name: \"${METRICS_JOB}\"" 'index($0, job) { found=1 } END { exit(found ? 0 : 1) }' \
		"${PROMETHEUS_CONFIG_FILE}"; then
		die 'Playground Prometheus job already exists without managed state'
	fi
	temporary="$(mktemp "${PROMETHEUS_CONFIG_FILE}.tmp.XXXXXX")"
	cat -- "${PROMETHEUS_CONFIG_FILE}" >"${temporary}"
	if [[ -s "${temporary}" ]] && [[ "$(tail -c 1 "${temporary}")" != $'\n' ]]; then
		printf '\n' >>"${temporary}"
	fi
	{
		printf '%s\n' "${PROMETHEUS_BEGIN}"
		printf '  - job_name: "%s"\n' "${METRICS_JOB}"
		printf '    scrape_interval: 30s\n'
		printf '    scrape_timeout: 10s\n'
		printf '    metrics_path: /metrics\n'
		printf '    scheme: http\n'
		printf '    authorization:\n'
		printf '      type: Bearer\n'
		printf '      credentials_file: %s\n' "${METRICS_COPY}"
		printf '    body_size_limit: 1MB\n'
		printf '    sample_limit: 500\n'
		printf '    static_configs:\n'
		printf '      - targets: ["%s:80"]\n' "${PLAYGROUND_CONTAINER}"
		printf '%s\n' "${PROMETHEUS_END}"
	} >>"${temporary}"
	chmod --reference="${PROMETHEUS_CONFIG_FILE}" "${temporary}"
	mv -- "${temporary}" "${PROMETHEUS_CONFIG_FILE}"
}

write_state() {
	local compose_hash prometheus_hash
	compose_hash="$(sha256_of "${PROMETHEUS_COMPOSE_FILE}")"
	prometheus_hash="$(sha256_of "${PROMETHEUS_CONFIG_FILE}")"
	{
		printf 'COMPOSE_SHA256=%s\n' "${compose_hash}"
		printf 'PROMETHEUS_SHA256=%s\n' "${prometheus_hash}"
	} >"${STATE_FILE}"
	chmod 0600 "${STATE_FILE}"
}

assert_managed_state() {
	[[ -f "${STATE_FILE}" ]] || \
		die "No managed playground metrics state found: ${STATE_FILE}"
	local expected_compose expected_prometheus
	expected_compose="$(state_value COMPOSE_SHA256)"
	expected_prometheus="$(state_value PROMETHEUS_SHA256)"
	[[ "${expected_compose}" == "$(sha256_of "${PROMETHEUS_COMPOSE_FILE}")" ]] || \
		die 'Prometheus Compose changed after playground metrics were enabled; inspect before disabling'
	[[ "${expected_prometheus}" == "$(sha256_of "${PROMETHEUS_CONFIG_FILE}")" ]] || \
		die 'Prometheus config changed after playground metrics were enabled; inspect before disabling'
	file_has_marker "${COMPOSE_BEGIN}" "${PROMETHEUS_COMPOSE_FILE}" || \
		die 'Managed playground secret marker is missing from Prometheus Compose'
	file_has_marker "${PROMETHEUS_BEGIN}" "${PROMETHEUS_CONFIG_FILE}" || \
		die 'Managed playground job marker is missing from Prometheus config'
}

enable_metrics() {
	if [[ -e "${STATE_DIR}" && ! -f "${STATE_FILE}" ]]; then
		die "Incomplete playground metrics state exists; inspect ${STATE_DIR} before continuing"
	fi
	if [[ -f "${STATE_FILE}" ]]; then
		assert_managed_state
	else
		if file_has_marker "${COMPOSE_BEGIN}" "${PROMETHEUS_COMPOSE_FILE}" ||
			file_has_marker "${PROMETHEUS_BEGIN}" "${PROMETHEUS_CONFIG_FILE}"; then
			die 'Managed markers exist without playground metrics state; refusing to adopt unknown changes'
		fi
		if awk -v secret="  ${METRICS_SECRET}:" 'index($0, secret) { found=1 } END { exit(found ? 0 : 1) }' \
			"${PROMETHEUS_COMPOSE_FILE}" ||
			awk -v job="job_name: \"${METRICS_JOB}\"" 'index($0, job) { found=1 } END { exit(found ? 0 : 1) }' \
			"${PROMETHEUS_CONFIG_FILE}"; then
			die 'Playground metrics configuration already exists without managed state'
		fi
		mkdir -m 700 -- "${STATE_DIR}"
		cp -p -- "${PROMETHEUS_COMPOSE_FILE}" "${COMPOSE_BACKUP}"
		cp -p -- "${PROMETHEUS_CONFIG_FILE}" "${PROMETHEUS_BACKUP}"
		patch_compose_file
		append_prometheus_job
		write_state
		prometheus_compose config --quiet
		prometheus_compose run --rm --no-deps --entrypoint promtool prometheus \
			check config /etc/prometheus/prometheus.yml
	fi

	playground_up
	repair_playground_token_permissions
	verify_network_peer
	prometheus_compose up -d
	playground_up
	verify_network_peer
	copy_token_into_prometheus
	reload_prometheus
	verify_target
	printf 'Playground metrics enabled; dashboard UID: yomiko-playground-overview\n'
}

disable_metrics() {
	assert_managed_state
	cp -p -- "${COMPOSE_BACKUP}" "${PROMETHEUS_COMPOSE_FILE}"
	cp -p -- "${PROMETHEUS_BACKUP}" "${PROMETHEUS_CONFIG_FILE}"
	prometheus_compose config --quiet
	docker exec -u 0 "${PROMETHEUS_CONTAINER}" rm -f -- "${METRICS_COPY}" >/dev/null 2>&1 || true
	prometheus_compose up -d
	rm -f -- "${STATE_FILE}" "${COMPOSE_BACKUP}" "${PROMETHEUS_BACKUP}"
	rmdir -- "${STATE_DIR}"
	if [[ "${KEEP_PLAYGROUND}" == true ]]; then
		playground_up
		printf 'Temporary Prometheus metrics removed; playground remains running\n'
	else
		YOMIKO_NETWORK_PEER_CONTAINER="${PROMETHEUS_CONTAINER}" \
			YOMIKO_PLAYGROUND_ROOT="${PLAYGROUND_DIR}" \
			"${PLAYGROUND_HELPER}" down
		printf 'Temporary Prometheus metrics removed; playground stopped\n'
	fi
}

status_metrics() {
	if [[ -f "${STATE_FILE}" ]]; then
		assert_managed_state
		printf 'Playground metrics state: enabled\n'
		if docker inspect "${PROMETHEUS_CONTAINER}" >/dev/null 2>&1; then
			verify_target
		else
			printf 'Prometheus container is not present\n'
		fi
	elif awk -v secret="  ${METRICS_SECRET}:" 'index($0, secret) { found=1 } END { exit(found ? 0 : 1) }' \
		"${PROMETHEUS_COMPOSE_FILE}" ||
		awk -v job="job_name: \"${METRICS_JOB}\"" 'index($0, job) { found=1 } END { exit(found ? 0 : 1) }' \
		"${PROMETHEUS_CONFIG_FILE}"; then
		printf 'Playground metrics state: unmanaged existing configuration\n' >&2
		printf 'Refusing to adopt it automatically; inspect and remove it manually first.\n' >&2
		return 1
	else
		printf 'Playground metrics state: disabled\n'
	fi
	printf 'Dashboard UID: yomiko-playground-overview\n'
}

ACTION="${1:-}"
PLAYGROUND_ARGUMENT="${2:-}"
KEEP_PLAYGROUND=false
if [[ -z "${ACTION}" || -z "${PLAYGROUND_ARGUMENT}" ]]; then
	usage >&2
	exit 2
fi
shift 2
while (($# > 0)); do
	case "$1" in
	--keep-playground)
		KEEP_PLAYGROUND=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'ERROR: Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

case "${ACTION}" in
enable | status | disable) ;;
*)
	printf 'ERROR: Unknown action: %s\n' "${ACTION}" >&2
	usage >&2
	exit 2
	;;
esac
if [[ "${ACTION}" != disable && "${KEEP_PLAYGROUND}" == true ]]; then
	die '--keep-playground is valid only with disable'
fi

for command_name in awk cat chmod cp docker mktemp mv rmdir sed sha256sum tail; do
	require_command "${command_name}"
done
docker compose version >/dev/null

PLAYGROUND_DIR="${PLAYGROUND_ARGUMENT}"
validate_playground
validate_prometheus_files
case "${ACTION}" in
enable) enable_metrics ;;
status) status_metrics ;;
disable) disable_metrics ;;
esac
