#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT
export HOME="${TEMP_ROOT}/home"
mkdir -p "${HOME}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant enqueue terminal smoke: static contract ok (sqlite3 unavailable)'
  exit 0
fi

# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"

export DB_PATH="${HOME}/data/db.sqlite3"
export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1
cp "${ROOT}"/migrations/*.sql "${HOME}/migrations/"
db_init >/dev/null

db_write "
  INSERT INTO galleries(
    gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
    uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
    current_gid,current_token,self_rating,favorite_count,rating_count)
  VALUES
    (901001,'enqueue-token-1','Enqueue predecessor','',10,0,'[]',4.0,'',
     'enqueue',901001,100,'thumb-1',901001,'enqueue-token-1',NULL,NULL,
     901002,'enqueue-token-2',0,0,0),
    (901002,'enqueue-token-2','Enqueue terminal','',11,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.2,'',
     'enqueue',901002,110,'thumb-2',901001,'enqueue-token-1',901001,'enqueue-token-1',
     901003,'enqueue-token-3',0,1,1),
    (901003,'enqueue-token-3','Enqueue terminal','',12,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.3,'',
     'enqueue',901003,120,'thumb-3',901001,'enqueue-token-1',901002,'enqueue-token-2',
     NULL,NULL,9,1,1);
  INSERT INTO variant_groups(
    source_gid,desired_rating,is_active,identity_active,review_state)
    VALUES(901003,11,1,1,'none');
  INSERT INTO gallery_variants(
    group_id,gid,membership_state,decision_source,evidence_json)
    VALUES(last_insert_rowid(),901003,'confirmed','automatic','{}');
"

assert_eq() {
  [[ "$1" == "$2" ]] || {
    printf 'expected %s, got %s\n' "$1" "$2" >&2
    return 1
  }
}

assert_eq '901003' "$(db_query "SELECT terminal_gid
  FROM uploader_revision_representatives WHERE revision_gid=901001;")"

# The predecessor is unrated, but its current terminal carries the durable
# intent. CLI enqueue must resolve before reading self_rating or it rejects the
# valid current intent as rating 0.
enqueue_output="$("${ROOT}/bin/yomiko" variants enqueue 901001)"
jq -e '.variant_queued == true' <<<"${enqueue_output}" >/dev/null
assert_eq '0|9|901003|9|901003' "$(db_query "
  SELECT
    (SELECT self_rating FROM galleries WHERE gid=901001),
    (SELECT self_rating FROM galleries WHERE gid=901003),
    (SELECT source_gid FROM variant_groups),
    (SELECT desired_rating FROM variant_groups),
    (SELECT source_gid FROM variant_jobs
      WHERE job_type='discover' AND status='queued'
      ORDER BY id DESC LIMIT 1);")"

printf 'variant enqueue terminal smoke: ok\n'
