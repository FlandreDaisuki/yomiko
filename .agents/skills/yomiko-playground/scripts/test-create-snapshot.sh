#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DISPATCHER="$SCRIPT_DIR/yomiko"
TEST_ROOT="$(mktemp -d /tmp/yomiko-snapshot-create-test.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

PRODUCTION_DIR="$TEST_ROOT/production"
FAKE_BIN="$TEST_ROOT/bin"
DOCKER_LOG="$TEST_ROOT/docker.log"
DOCKER_STATE="$TEST_ROOT/docker.state"
mkdir -p "$PRODUCTION_DIR/data" "$FAKE_BIN"
touch "$PRODUCTION_DIR/compose.yaml"

python3 - "$PRODUCTION_DIR/data/db.sqlite3" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.executescript("""
CREATE TABLE _schema_version(version INTEGER NOT NULL);
INSERT INTO _schema_version VALUES (42);
CREATE TABLE galleries(id INTEGER NOT NULL);
INSERT INTO galleries VALUES (1), (2), (3);
""")
connection.commit()
connection.close()
PY
printf 'fixture-cookie-jar\n' >"$PRODUCTION_DIR/data/cookie-jar.txt"

source_file_state() {
	python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
stat = path.stat()
digest = hashlib.sha256(path.read_bytes()).hexdigest()
print(f"{stat.st_mode & 0o777}:{stat.st_size}:{stat.st_mtime_ns}:{digest}")
PY
}

SOURCE_DB="$PRODUCTION_DIR/data/db.sqlite3"
SOURCE_COOKIE="$PRODUCTION_DIR/data/cookie-jar.txt"
SOURCE_DB_STATE="$(source_file_state "$SOURCE_DB")"
SOURCE_COOKIE_STATE="$(source_file_state "$SOURCE_COOKIE")"
[[ ! -e "$SOURCE_DB-wal" && ! -e "$SOURCE_DB-shm" ]]

cat >"$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case "$1" in
compose)
	shift
	if [[ "$1" == version ]]; then
		printf 'Docker Compose version fixture\n'
		exit 0
	fi
	shift 4
	case "$1" in
	ps)
		[[ ! -e "$FAKE_DOCKER_STATE" ]] || printf 'fixture\n'
		;;
	up)
		if [[ "$FAKE_SCENARIO" == start_failure ]]; then
			exit 1
		fi
		touch "$FAKE_DOCKER_STATE"
		;;
	down)
		rm -f -- "$FAKE_DOCKER_STATE"
		;;
	*) exit 92 ;;
	esac
	;;
exec)
	shift 2
	case "$1" in
	test)
		test -s "$FAKE_PRODUCTION_DIR/data/cookie-jar.txt"
		;;
	sqlite3)
		SQLITE_PATH="$2"
		SQLITE_COMMAND="$3"
		if [[ "$SQLITE_PATH" == /home/yomiko/data/db.sqlite3 ]]; then
			SQLITE_PATH="$FAKE_PRODUCTION_DIR/data/db.sqlite3"
		fi
		if [[ "$SQLITE_COMMAND" == .backup* ]]; then
			[[ "$FAKE_SCENARIO" != backup_failure ]] || exit 1
			SNAPSHOT_PATH="${SQLITE_COMMAND#".backup '"}"
			SNAPSHOT_PATH="${SNAPSHOT_PATH%\'}"
			python3 - "$SQLITE_PATH" "$SNAPSHOT_PATH" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(sys.argv[1])
destination = sqlite3.connect(sys.argv[2])
source.backup(destination)
destination.close()
source.close()
PY
		else
			python3 - "$SQLITE_PATH" "$SQLITE_COMMAND" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
print(connection.execute(sys.argv[2]).fetchone()[0])
connection.close()
PY
		fi
		;;
	rm)
		shift
		rm "$@"
		;;
	*) exit 93 ;;
	esac
	;;
cp)
	SOURCE_PATH="${2#fixture:}"
	if [[ "$SOURCE_PATH" == /home/yomiko/data/cookie-jar.txt ]]; then
		SOURCE_PATH="$FAKE_PRODUCTION_DIR/data/cookie-jar.txt"
	fi
	cp -- "$SOURCE_PATH" "$3"
	;;
*) exit 91 ;;
esac
DOCKER
chmod 0755 "$FAKE_BIN/docker"

for SCENARIO in snapshot_success backup_failure start_failure already_running; do
	DESTINATION="$TEST_ROOT/playground-$SCENARIO"
	: >"$DOCKER_LOG"
	rm -f -- "$DOCKER_STATE"
	if [[ "$SCENARIO" == already_running ]]; then
		touch "$DOCKER_STATE"
	fi
	(
		cd "$SOURCE_ROOT"
		PATH="$FAKE_BIN:$PATH" \
		FAKE_DOCKER_LOG="$DOCKER_LOG" \
		FAKE_DOCKER_STATE="$DOCKER_STATE" \
		FAKE_PRODUCTION_DIR="$PRODUCTION_DIR" \
		FAKE_SCENARIO="$SCENARIO" \
		YOMIKO_PRODUCTION_DIR="$PRODUCTION_DIR" \
			"$DISPATCHER" create "$DESTINATION" >"$TEST_ROOT/create.log"
	)

	[[ "$(stat -c '%a' "$DESTINATION")" == 700 ]]
	[[ "$(stat -c '%a' "$DESTINATION/data")" == 700 ]]
	[[ "$(stat -c '%a' "$DESTINATION/data/db.sqlite3")" == 600 ]]
	[[ "$(stat -c '%a' "$DESTINATION/data/cookie-jar.txt")" == 600 ]]
	[[ "$(stat -c '%a' "$DESTINATION/data/metrics-token")" == 600 ]]
	[[ "$(stat -c '%a' "$DESTINATION/.yomiko-playground.env")" == 600 ]]
	grep -Fq 'integrity_check ok' "$TEST_ROOT/create.log"
	grep -Fxq 'YOMIKO_REMOTE_WRITES_ENABLED=false' "$DESTINATION/.yomiko-playground.env"
	[[ "$(cat "$DESTINATION/data/cookie-jar.txt")" == fixture-cookie-jar ]]
	if grep -Fq 'fixture-cookie-jar' "$TEST_ROOT/create.log"; then
		printf 'ERROR: Cookie contents appeared in create output\n' >&2
		exit 1
	fi
	if [[ "$SCENARIO" == snapshot_success ]]; then
		grep -Fq 'Taking a consistent online snapshot' "$TEST_ROOT/create.log"
		if grep -Fq 'falling back to host Python' "$TEST_ROOT/create.log"; then
			exit 1
		fi
		grep -Fq ' down' "$DOCKER_LOG"
		[[ ! -e "$DOCKER_STATE" ]]
	elif [[ "$SCENARIO" == already_running ]]; then
		if grep -Eq ' (up|down)( |$)' "$DOCKER_LOG"; then
			exit 1
		fi
		[[ -e "$DOCKER_STATE" ]]
	else
		grep -Fq 'falling back to host Python' "$TEST_ROOT/create.log"
		grep -Fq ' down' "$DOCKER_LOG"
		[[ ! -e "$DOCKER_STATE" ]]
	fi

	python3 - "$DESTINATION/data/db.sqlite3" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert connection.execute("SELECT MAX(version) FROM _schema_version").fetchone()[0] == 42
assert connection.execute("SELECT COUNT(*) FROM galleries").fetchone()[0] == 3
connection.close()
PY
done

[[ "$(source_file_state "$SOURCE_DB")" == "$SOURCE_DB_STATE" ]]
[[ "$(source_file_state "$SOURCE_COOKIE")" == "$SOURCE_COOKIE_STATE" ]]
[[ ! -e "$SOURCE_DB-wal" && ! -e "$SOURCE_DB-shm" ]]

printf 'playground snapshot and fallback checks passed\n'
