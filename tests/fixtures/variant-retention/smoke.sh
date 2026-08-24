#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT
export HOME="${TEMP_ROOT}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_retention.sh"

mkdir -p \
  "${HATH_DOWNLOAD_DIR}/nested/[artist] title [123-1280x]" \
  "${HATH_DOWNLOAD_DIR}/other/[artist] title [124]" \
  "${HATH_DOWNLOAD_DIR}/malformed-directory"

variants_retention_hath_tree_contains_gid 123
variants_retention_hath_tree_contains_gid 124
if variants_retention_hath_tree_contains_gid 999; then
  exit 1
fi

printf canonical >"${ARCHIVED_DIR}/canonical.7z"
printf alternate >"${ARCHIVED_DIR}/alternate.7z"
variants_retention_archive_is_regular canonical.7z
if variants_retention_archive_is_regular '../canonical.7z'; then
  exit 1
fi
ln -s canonical.7z "${ARCHIVED_DIR}/link.7z"
if variants_retention_archive_is_regular link.7z; then
  exit 1
fi

variants_retention_delete_alternate canonical.7z alternate.7z
[[ -f "${ARCHIVED_DIR}/canonical.7z" ]]
[[ ! -e "${ARCHIVED_DIR}/alternate.7z" ]]

printf alternate >"${ARCHIVED_DIR}/alternate.7z"
if variants_retention_delete_alternate missing.7z alternate.7z; then
  exit 1
fi
[[ -f "${ARCHIVED_DIR}/alternate.7z" ]]

if variants_retention_delete_alternate canonical.7z '../alternate.7z'; then
  exit 1
fi
[[ -f "${ARCHIVED_DIR}/alternate.7z" ]]

lock_fd=""
variants_hath_lock_acquire 123 lock_fd
[[ "${lock_fd}" =~ ^[0-9]+$ ]]
if variants_hath_lock_acquire 123 second_lock_fd; then
  exit 1
else
  [[ "$?" -eq 75 ]]
fi
variants_hath_lock_release "${lock_fd}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant retention smoke: filesystem/lock ok (sqlite3 unavailable)'
  exit 0
fi

export DB_PATH="${HOME}/data/db.sqlite3"
export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1
db_init >/dev/null
db_query "INSERT INTO galleries(gid,token,title,tags,file_path) VALUES
  (123,'token-123','Canonical','[]','canonical.7z');
INSERT INTO galleries(gid,token,title,tags,file_path) VALUES
  (124,'token-124','Alternate','[]','alternate.7z');
INSERT INTO variant_groups(source_gid,desired_rating) VALUES(123,11);
INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
  VALUES(last_insert_rowid(),123,'confirmed','automatic','{}','{}');
UPDATE variant_groups SET canonical_gid=123 WHERE id=last_insert_rowid();" || exit 1

queued="$(variants_retention_queue_for_gid 123)"
[[ "${queued}" == 1 ]]
[[ "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention' AND status='queued';")" == 1 ]]

db_query "UPDATE variant_jobs SET status='completed',completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');"
healed="$(variants_retention_self_heal)"
[[ "${healed}" == 0 ]]

# Simulate the final-rename / enqueue crash window by removing all evidence of
# a retention handoff while leaving the canonical archive committed.
db_query "DELETE FROM variant_jobs WHERE job_type='reconcile_retention';"
healed="$(variants_retention_self_heal)"
[[ "${healed}" == 1 ]]
[[ "$(db_query "SELECT COUNT(*) FROM variant_jobs WHERE job_type='reconcile_retention' AND status='queued';")" == 1 ]]

rm -- "${ARCHIVED_DIR}/canonical.7z"
db_query "UPDATE variant_jobs SET status='completed',completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');"
[[ "$(variants_retention_self_heal)" == 0 ]]

echo 'variant retention smoke: ok'
