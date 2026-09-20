#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${SCRIPT_DIR}/yomiko"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yomiko-dispatcher-test.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

PLAYGROUND_DIR="${TEST_ROOT}/yomiko-playground.test"
FAKE_BIN="${TEST_ROOT}/bin"
DOCKER_LOG="${TEST_ROOT}/docker.log"
mkdir -p "${PLAYGROUND_DIR}/docker" "${FAKE_BIN}"
touch "${PLAYGROUND_DIR}/.yomiko-playground.env"
touch "${PLAYGROUND_DIR}/docker/docker-compose.playground.yaml"

cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
	printf '<%s>' "${argument}" >>"${FAKE_DOCKER_LOG}"
done
printf '\n' >>"${FAKE_DOCKER_LOG}"
EOF
chmod 0755 "${FAKE_BIN}/docker"

run_dispatcher() {
	PATH="${FAKE_BIN}:${PATH}" FAKE_DOCKER_LOG="${DOCKER_LOG}" \
		"${DISPATCHER}" --playground "${PLAYGROUND_DIR}" "$@"
}

run_dispatcher test --filter 'identity reconciliation' --trace
run_dispatcher sql 'SELECT 1;'
run_dispatcher exec bin/yomiko --help

grep -Fq '<build><yomiko.test>' "${DOCKER_LOG}"
grep -Fq '<--env><YOMIKO_TEST_FILTER=identity reconciliation><yomiko.test><bash><-x></home/yomiko/tests/run.sh>' "${DOCKER_LOG}"
grep -Fq '<exec><--no-tty><yomiko.playground><sqlite3></home/yomiko/data/db.sqlite3><SELECT 1;>' "${DOCKER_LOG}"
grep -Fq '<exec><--no-tty><yomiko.playground><bin/yomiko><--help>' "${DOCKER_LOG}"

if run_dispatcher test --filter '' >/dev/null 2>&1; then
	printf 'ERROR: empty test filter unexpectedly succeeded\n' >&2
	exit 1
fi
if run_dispatcher metrics unknown >/dev/null 2>&1; then
	printf 'ERROR: unknown metrics action unexpectedly succeeded\n' >&2
	exit 1
fi

printf 'yomiko dispatcher checks passed\n'
