#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT
export HOME="${TEMP_ROOT}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/path.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/db.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variants.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_unicode.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_policy.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_scoring.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_matching.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_discovery.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_worker.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_retention.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/variant_actions.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/metrics.sh"

# Keep this fixture useful in the small host image used for shell-only checks.
# The optional SQLite section below is the executable projection contract in
# CI/playgrounds; the assertions above and below still catch authority drift
# when sqlite3 is unavailable.
[[ "${VARIANTS_MATCHING_REVISION}" -eq 6 ]]
fixed_matching="$(variants_policy_fixed_matching)"
jq -e '
  (.automatic_evidence_kinds == ["exact_file"])
  and (has("official_chain") | not)
  and (has("official_chain_visibility") | not)
  and ([.visible_contradictions[] | select(startswith("uploader_revision_"))] | length == 8)
' <<<"${fixed_matching}" >/dev/null
if rg -n 'gallery_variants.*metadata_snapshot_json' \
  "${ROOT}/lib/variants.sh" "${ROOT}/lib/variant_actions.sh" \
  "${ROOT}/lib/variant_retention.sh"; then
  exit 1
fi
rg -n 'revision_members|current_revision_projection|scoreable_revision_terminals|archive_source_galleries' \
  "${ROOT}/lib/variants.sh" "${ROOT}/lib/variant_actions.sh" \
  "${ROOT}/lib/variant_retention.sh" >/dev/null

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo 'variant runtime revision-chain smoke: static contract ok (sqlite3 unavailable)'
  exit 0
fi

export DB_PATH="${HOME}/data/db.sqlite3"
export MIGRATIONS_DIR="${ROOT}/migrations"
export YOMIKO_CLI_IN_API_MODE=1
db_init >/dev/null
assert_eq() { [[ "$1" == "$2" ]] || { printf 'expected %s, got %s\n' "$1" "$2" >&2; return 1; }; }

# Compare only the requested rows from the request-bounded projection with the
# authoritative global projection.  The global view is a fixture oracle only;
# production gallery-status must never reference it.
status_projection_rows() {
  local requested_gids='[' gid
  for gid in "$@"; do
    requested_gids+="${gid},"
  done
  requested_gids="${requested_gids%,}]"
  db_query \
    ".parameter set :requested_gids $(db_parameter_text "${requested_gids}")" \
    "$(variants_revision_projection_sql status)
     SELECT revision_gid || '|' || terminal_gid || '|' || component_gid || '|' ||
            component_size || '|' || ready || '|' || is_terminal || '|' ||
            COALESCE(blocked_reason,'')
       FROM revision_projection
      WHERE revision_gid IN (SELECT CAST(value AS INTEGER)
                               FROM json_each(:requested_gids))
      ORDER BY revision_gid;"
}

global_status_projection_rows() {
  local requested_gids='[' gid
  for gid in "$@"; do
    requested_gids+="${gid},"
  done
  requested_gids="${requested_gids%,}]"
  db_query \
    ".parameter set :requested_gids $(db_parameter_text "${requested_gids}")" \
    "SELECT revision_gid || '|' || terminal_gid || '|' || component_gid || '|' ||
            component_size || '|' || ready || '|' || is_terminal || '|' ||
            COALESCE(blocked_reason,'')
       FROM current_revision_projection
      WHERE revision_gid IN (SELECT CAST(value AS INTEGER)
                               FROM json_each(:requested_gids))
      ORDER BY revision_gid;"
}

old_archive_name='revision-100.7z'
old_archive="${ARCHIVED_DIR}/${old_archive_name}"
printf 'old archive' >"${old_archive}"
db_write "
  INSERT INTO galleries
    (gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
     uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
     current_gid,current_token,favorite_count,rating_count)
  VALUES
    (100,'token-100','Revision 100','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'${old_archive_name}',
     'uploader',100,100,'thumb-100',100,'token-100',NULL,NULL,101,'token-101',0,0),
    (101,'token-101','Revision 101','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',101,100,'thumb-101',100,'token-100',100,'token-100',102,'token-102',0,0),
    (102,'token-102','Revision 102','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',102,100,'thumb-102',100,'token-100',101,'token-101',NULL,NULL,0,0),
    (201,'token-201','Revision 201','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',201,100,'thumb-201',201,'token-201',NULL,NULL,203,'token-203',0,0),
    (203,'token-203','Revision 203','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',203,100,'thumb-203',201,'token-201',201,'token-201',206,'token-206',0,0),
    (206,'token-206','Revision 206','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',206,100,'thumb-206',201,'token-201',203,'token-203',NULL,NULL,0,0),
    (309,'token-309','Revision 309','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',309,100,'thumb-309',309,'token-309',NULL,NULL,322,'token-322',0,0),
    (322,'token-322','Revision 322','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'uploader',322,100,'thumb-322',309,'token-309',309,'token-309',NULL,NULL,0,0),
    (200,'token-200','Other book','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'other',200,100,'thumb-200',NULL,NULL,NULL,NULL,NULL,NULL,0,0);
  INSERT INTO variant_groups(source_gid,desired_rating,canonical_gid)
    VALUES(102,11,NULL),(206,11,NULL),(322,11,NULL);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,source_gid,'confirmed','automatic','{}'
      FROM variant_groups WHERE source_gid IN (102,206,322);
  UPDATE variant_groups SET canonical_gid=source_gid
   WHERE source_gid IN (102,206,322);
"

# Every supported chain shape has exactly one live terminal membership.  This
# catches both multi-hop revision-projection resolution and the one-hop regression
# where a refreshed GID was left as an active member alongside its terminal.
assert_eq '102,206,322' "$(db_query "SELECT group_concat(gid, ',')
  FROM gallery_variants WHERE membership_state='confirmed' ORDER BY gid;")"

# A singleton has no provider `first` field, but remains a valid component;
# the classifier must not manufacture a chain identity to make it scoreable.
db_write "INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    first_gid,first_token,parent_gid,parent_token,current_gid,current_token,
    favorite_count,rating_count)
  VALUES(900060,'singleton-token','Singleton without first',10,0,
    '[\"language:chinese\",\"other:tankoubon\"]',4.0,'singleton',900060,10,
    'singleton-thumb',NULL,NULL,NULL,NULL,NULL,NULL,1,1);"
assert_eq '1|900060|1|1|' "$(db_query "SELECT ready || '|' || terminal_gid || '|' ||
    component_size || '|' || is_terminal || '|' || COALESCE((SELECT first_gid
      FROM galleries WHERE gid=900060),'')
    FROM current_revision_projection WHERE revision_gid=900060;")"
assert_eq '900060' "$(db_query "SELECT gid FROM scoreable_revision_terminals WHERE gid=900060;")"

# One valid chain has one terminal, while its predecessor remains the exact
# effective archive until the terminal receives its own archive.
assert_eq '100,101,102|102|100' "$(db_query "
  SELECT (SELECT group_concat(revision_gid, ',') FROM (
             SELECT revision_gid FROM current_revision_projection
              WHERE component_gid=(SELECT component_gid FROM current_revision_projection WHERE revision_gid=100)
              ORDER BY revision_gid
           )),
         (SELECT gid FROM scoreable_revision_terminals WHERE revision_gid=102),
         (SELECT archive_gid FROM archive_source_galleries WHERE gid=102);
")"

# Requested order and duplicate GIDs are part of the public contract.  The
# bounded projection may deduplicate its internal seed, but the final rows
# must remain exact, ordered, and duplicated as requested.
ordered_status_json="$(${ROOT}/bin/yomiko gallery-status 102 100 999 102)"
jq -e '
  length == 4 and
  [.[].gid] == [102,100,999,102] and
  .[0].local_state_gid == 100 and .[0].local_state_relation == "same_book" and
  .[1].local_state_gid == 100 and .[1].local_state_relation == "exact" and
  .[2].state == "unknown" and .[3].gid == 102
' <<<"${ordered_status_json}" >/dev/null

# A confirmed identity-group member can supply archive evidence even when the
# requested GID has no committed archive of its own.  This is separate from
# provider-revision fallback: the group is intentionally made of two isolated
# galleries, so the bounded revision component contains only the request.
identity_archive_name='identity-fallback-501.7z'
printf 'identity fallback archive' >"${ARCHIVED_DIR}/${identity_archive_name}"
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    favorite_count,rating_count,file_path)
  VALUES
    (500,'token-500','Identity fallback target',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'identity',500,10,
     'thumb-500',1,1,NULL),
    (501,'token-501','Identity fallback archive',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'identity',501,10,
     'thumb-501',1,1,'${identity_archive_name}');
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,canonical_gid)
    VALUES(500,11,1,1,NULL);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,500,'confirmed','manual','{}' FROM variant_groups WHERE source_gid=500;
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,501,'confirmed','manual','{}' FROM variant_groups WHERE source_gid=500;
  UPDATE variant_groups SET canonical_gid=500 WHERE source_gid=500;
"
identity_status_json="$(${ROOT}/bin/yomiko gallery-status 500 500 501 999)"
jq -e '
  length == 4 and
  .[0].gid == 500 and .[0].state == "rated_11_canonical" and
  .[0].local_state_relation == "same_book" and .[0].local_state_gid == 501 and
  .[0].evidence_kind == "committed_archive" and
  .[1].gid == 500 and .[1].local_state_gid == 501 and
  .[2].gid == 501 and .[2].local_state_relation == "exact" and
  .[3].state == "unknown"
' <<<"${identity_status_json}" >/dev/null

# A blocked/pre-publication target still exposes a confirmed identity class's
# committed archive.  The missing target is a real reference_incomplete edge,
# but the archive fallback remains presentation-only and read-only.
blocked_archive_name='blocked-fallback-701.7z'
printf 'blocked fallback archive' >"${ARCHIVED_DIR}/${blocked_archive_name}"
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    current_gid,current_token,favorite_count,rating_count,file_path)
  VALUES
    (700,'token-700','Blocked target',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'blocked',700,10,
     'thumb-700',799,'token-799',1,1,NULL),
    (701,'token-701','Blocked archive',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'blocked',701,10,
     'thumb-701',NULL,NULL,1,1,'${blocked_archive_name}');
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,canonical_gid)
    VALUES(700,11,1,1,NULL);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,700,'confirmed','manual','{}' FROM variant_groups WHERE source_gid=700;
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,701,'confirmed','manual','{}' FROM variant_groups WHERE source_gid=700;
  UPDATE variant_groups SET canonical_gid=700 WHERE source_gid=700;
"
blocked_status_json="$(${ROOT}/bin/yomiko gallery-status 700)"
jq -e '.|length == 1 and .[0].gid == 700 and
  .[0].state == "rated_11_canonical" and
  .[0].local_state_relation == "same_book" and .[0].local_state_gid == 701 and
  .[0].evidence_kind == "committed_archive"' <<<"${blocked_status_json}" >/dev/null
assert_eq "$(global_status_projection_rows 500 700 999)" \
  "$(status_projection_rows 500 700 999)"
db_write "
  UPDATE variant_groups SET canonical_gid=NULL WHERE source_gid IN (500,700);
  DELETE FROM gallery_variants
   WHERE gid IN (500,501,700,701);
  DELETE FROM variant_groups WHERE source_gid IN (500,700);
  DELETE FROM galleries WHERE gid IN (500,501,700,701);
"
rm -f -- "${ARCHIVED_DIR}/${identity_archive_name}" \
       "${ARCHIVED_DIR}/${blocked_archive_name}"

# A completed terminal evaluation may still use the predecessor as the
# effective archive while the replacement is being acquired.  That fallback
# must not authorize destructive cleanup of the predecessor.  Once the
# terminal archive is committed, the same projection must expose exactly one
# cleanup action for the old exact GID.
group_id="$(db_query "SELECT id FROM variant_groups WHERE source_gid=102;")"
evaluation_id="$(db_write "INSERT INTO variant_evaluations(
    group_id, policy_revision_id, state, metadata_snapshot_json,
    member_scores_json, canonical_gid
  ) SELECT ${group_id}, id, 'completed', '[]', '[]', 102
      FROM variant_policy_revisions WHERE is_active=1;
  SELECT last_insert_rowid();")"
db_write "UPDATE variant_groups
             SET active_evaluation_id=${evaluation_id}, canonical_gid=102,
                 is_active=1, identity_active=1
           WHERE id=${group_id};"
variants_actions_project "${group_id}" >/dev/null
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=${group_id} AND gid=100 AND action_type='archive_cleanup';")"
# A non-empty database path is not a committed archive.  Removing the exact
# predecessor file must keep the archive-source projection and cleanup handoff
# closed until a regular file is present again.
rm -- "${old_archive}"
committed_without_predecessor="$(variants_retention_committed_archive_gids_json)"
jq -e 'index(100) | not' <<<"${committed_without_predecessor}" >/dev/null
variants_actions_project "${group_id}" >/dev/null
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=${group_id} AND gid=100 AND action_type='archive_cleanup';")"
printf 'old archive' >"${old_archive}"
terminal_archive_name='revision-102.7z'
printf 'terminal archive' >"${ARCHIVED_DIR}/${terminal_archive_name}"
db_write "UPDATE galleries SET file_path='${terminal_archive_name}' WHERE gid=102;"
variants_actions_project "${group_id}" >/dev/null
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_actions
  WHERE group_id=${group_id} AND gid=100 AND action_type='archive_cleanup';")"

# A remote action that was already in flight for the predecessor is obsolete
# after terminal normalization.  Its lease is released and the stale worker's
# later finish becomes a no-op; the desired terminal action is projected
# independently.
db_write "INSERT OR IGNORE INTO variant_jobs(
    job_type,group_id,source_gid,status)
  VALUES('reconcile_actions',${group_id},102,'queued');
  INSERT INTO variant_actions(
    group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,
    status,lease_owner,lease_expires_at,lease_job_id)
  SELECT ${group_id},active_evaluation_id,100,'rating','10',variant_policy_revisions.id,
         'in_flight','race-worker',strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'),
         (SELECT id FROM variant_jobs
           WHERE group_id=${group_id} AND job_type='reconcile_actions' LIMIT 1)
    FROM variant_groups CROSS JOIN variant_policy_revisions
   WHERE variant_groups.id=${group_id} AND variant_policy_revisions.is_active=1;"
variants_actions_project "${group_id}" >/dev/null
assert_eq 'superseded||' "$(db_query "SELECT status || '|' || COALESCE(lease_owner,'') || '|' ||
  COALESCE(lease_job_id,'') FROM variant_actions
  WHERE group_id=${group_id} AND gid=100 AND action_type='rating'
  ORDER BY id DESC LIMIT 1;")"

# Low feedback addressed to a predecessor follows the current revision projection
# for group intent, while the predecessor's exact self-rating remains history.
db_write "
  INSERT INTO galleries
    (gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,
     uploader,posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
     current_gid,current_token,favorite_count,rating_count)
  VALUES
    (300,'token-300','Revision 300','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'third',300,100,'thumb-300',300,'token-300',NULL,NULL,301,'token-301',0,0),
    (301,'token-301','Revision 301','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'',
     'third',301,100,'thumb-301',300,'token-300',300,'token-300',NULL,NULL,0,0);
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
    VALUES(301,11,1,0);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES(last_insert_rowid(),301,'confirmed','automatic','{}');
  UPDATE variant_groups SET canonical_gid=301
   WHERE source_gid=301;
"
# Current list/evaluation addressing accepts any revision GID, but returns and
# mutates only the scoreable revision terminal.  Stub the expensive scorer here;
# the assertion is specifically about the public resolver boundary.
assert_eq '102' "$(variants_current_gid 100)"
list_from_predecessor="$(variants_list_json 100)"
jq -e '.groups | length == 1 and .[0].source_gid == 102 and
  ([.[0].members[].gid] == [102]) and
  .[0].members[0].uploader_revision.revision_gid == 102 and
  .[0].members[0].uploader_revision.terminal_gid == 102 and
  .[0].members[0].uploader_revision.component_gids == [100,101,102]' \
  <<<"${list_from_predecessor}" >/dev/null
list_from_terminal="$(variants_list_json 102)"
jq -e '.groups | length == 1 and .[0].source_gid == 102 and
  ([.[0].members[].gid] == [102])' <<<"${list_from_terminal}" >/dev/null
list_from_unknown="$(variants_list_json 999999999)"
jq -e '.groups == []' <<<"${list_from_unknown}" >/dev/null
variants_evaluate_group() { printf '{"evaluated":true,"gid":%s}\n' "$1"; }
evaluate_from_predecessor="$(variants_evaluate_gid 100)"
jq -e '.evaluated == true and .gid == 1' <<<"${evaluate_from_predecessor}" >/dev/null

# A manual winner review may retain the predecessor in its frozen choice list;
# selecting that historical choice still updates the current decision to the
# scoreable revision terminal.
winner_review_id="$(db_write "INSERT INTO variant_reviews(
  review_type,group_id,evaluation_id,policy_revision_id,evidence_json,choices_json)
  SELECT 'winner',${group_id},active_evaluation_id,variant_policy_revisions.id,'{}','[100,102]'
    FROM variant_groups CROSS JOIN variant_policy_revisions
   WHERE variant_groups.id=${group_id} AND variant_policy_revisions.is_active=1;
  SELECT last_insert_rowid();")"
winner_output="$(variants_resolve_review "${winner_review_id}" winner 100)"
jq -e --argjson winner_review_id "${winner_review_id}" '
  .resolved == true and .review_id == $winner_review_id and
  .decision == "winner" and .canonical_gid == 102
' <<<"${winner_output}" >/dev/null
list_with_review="$(variants_list_json 102)"
jq -e '.groups | length == 1 and .[0].reviews == []' <<<"${list_with_review}" >/dev/null
assert_eq 'resolved|102|102' "$(db_query ".parameter set :review_id ${winner_review_id}" \
  "SELECT status,canonical_gid,
          (SELECT canonical_gid FROM variant_canonical_decisions
            WHERE source_review_id=:review_id AND status='active')
     FROM variant_reviews WHERE id=:review_id;")"

# The old revision resolves to the current terminal for status/identity, but
# its archive and acquisition evidence remain exact to GID 100.
status_json="$("${ROOT}/bin/yomiko" gallery-status 100 102)"
jq -e '
  .[0].gid == 100 and .[0].identity_confirmed == 1 and
  .[0].identity_class_gid == 102 and .[0].local_state_relation == "exact" and
  .[0].local_state_gid == 100 and .[1].gid == 102 and
  .[1].identity_confirmed == 1 and .[1].local_state_relation == "exact" and
  .[1].local_state_gid == 102
' <<<"${status_json}" >/dev/null

# Exercise the manual class/pair boundary with the normalized terminal GID.
# The old revision is deliberately used only by the status assertion above;
# current identity pairs address 102 and 200, never 100 and 200.
db_write "
  INSERT INTO variant_groups(source_gid,desired_rating) VALUES(200,8);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES((SELECT id FROM variant_groups WHERE source_gid=200),200,'confirmed','automatic','{}');
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES((SELECT id FROM variant_groups WHERE source_gid=102),200,'candidate','automatic','{}');
  INSERT INTO variant_reviews(
    review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
    evidence_json,choices_json)
    SELECT 'candidate_identity',(SELECT id FROM variant_groups WHERE source_gid=102),
           200,id,6,
           json_object(
             'source_snapshot',json_object('gid',100,'title','Frozen predecessor'),
             'candidate_snapshot',json_object('gid',200,'title','Frozen candidate')),
           '[\"same_book\",\"different_book\"]'
      FROM variant_policy_revisions WHERE is_active=1;
  UPDATE galleries SET title='Live terminal' WHERE gid=102;
  UPDATE galleries SET title='Live candidate' WHERE gid=200;
"
review_id="$(db_query "SELECT id FROM variant_reviews WHERE candidate_gid=200 ORDER BY id DESC LIMIT 1;")"
db_write "
  INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
    VALUES(102,200,${review_id});
"
pair_projection="$(db_write "BEGIN; $(variants_identity_reconcile_sql)
  SELECT low_class_gid || '|' || high_class_gid
    FROM identity_pending_candidate WHERE review_id=${review_id};
  COMMIT;")"
assert_eq '102|200' "${pair_projection}"
review_output="$(variants_reviews_json pending)"
jq -e --argjson review_id "${review_id}" '
  (.reviews | length) == 1 and .reviews[0].id == $review_id and
  .reviews[0].source.gid == 102 and
  .reviews[0].source.current.title == "Live terminal" and
  .reviews[0].source.historical.gid == 100 and
  .reviews[0].source.historical.title == "Frozen predecessor" and
  .reviews[0].candidate.current.title == "Live candidate" and
  .reviews[0].candidate.historical.gid == 200 and
  .reviews[0].candidate.historical.title == "Frozen candidate" and
  ([.. | objects | has("group_id")] | any | not)
' <<<"${review_output}" >/dev/null
resolved="$(variants_resolve_review "${review_id}" same-book)"
jq -e --argjson review_id "${review_id}" '
  .resolved == true and .review_id == $review_id and
  .decision == "same_book" and .merged_group == true
' <<<"${resolved}" >/dev/null
assert_eq '3|2|same_book|102,200' "$(db_query "
  SELECT
    (SELECT COUNT(*) FROM variant_groups WHERE identity_active=1),
    (SELECT COUNT(*) FROM variant_groups WHERE identity_active=0),
    (SELECT review.decision FROM variant_reviews AS review WHERE review.id=${review_id}),
    (SELECT group_concat(gid, ',') FROM (
       SELECT gid FROM gallery_variants
       WHERE group_id=(SELECT id FROM variant_groups WHERE identity_active=1)
          AND membership_state='confirmed' ORDER BY gid));
")"
assert_eq '102,200' "$(db_query "SELECT low_gid || ',' || high_gid
  FROM gallery_identity_pairs WHERE current_review_id=${review_id};")"

# Low feedback addressed to a predecessor follows the current revision projection
# for group intent, while the predecessor's exact self-rating remains history.
# Keep this after the merge assertion: the explicit feedback intentionally
# reactivates its previously inactive identity owner, which is a separate
# lifecycle transition from the deterministic pair survivor check above.
cli_feedback_output="$("${ROOT}/bin/yomiko" feedback 300 --rating 6 2>/dev/null)"
jq -e '.variant_queued == true' <<<"${cli_feedback_output}" >/dev/null
low_feedback_group="$(variants_downgrade_feedback 300 6)"
assert_eq '6|0|6' "$(db_query ".parameter set :group_id ${low_feedback_group}" \
  "SELECT desired_rating,
          COALESCE((SELECT self_rating FROM galleries WHERE gid=300),0),
          (SELECT self_rating FROM galleries WHERE gid=301)
     FROM variant_groups WHERE id=:group_id;")"

# Ungrouping any exact revision detaches the normalized terminal as a whole
# chain unit.  The predecessor GIDs were never current memberships and must
# not be silently reseeded as independent identity groups.
ungroup_output="$(variants_ungroup 1 100)"
jq -e '
  .ungrouped == true and .gids == [102] and
  .replacement_groups == 1 and .source_groups == 1 and
  .memberships_deleted == 1
' <<<"${ungroup_output}" >/dev/null
assert_eq '102|200|0|0' "$(db_query "
  SELECT
    (SELECT group_concat(member.gid, ',')
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id=member.group_id
      WHERE grouped.identity_active=1 AND member.gid=102),
    (SELECT group_concat(member.gid, ',')
       FROM gallery_variants AS member
       JOIN variant_groups AS grouped ON grouped.id=member.group_id
      WHERE grouped.identity_active=1 AND member.gid=200),
    (SELECT COUNT(*) FROM gallery_variants WHERE gid IN (100,101)),
    (SELECT COUNT(*) FROM gallery_identity_pairs
      WHERE low_gid=102 OR high_gid=102);
")"

# Candidate reviews may retain a predecessor GID in their frozen request while
# all membership and pair mutations target its scoreable revision terminal.
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    first_gid,first_token,current_gid,current_token,favorite_count,rating_count)
  VALUES
    (500,'token-500','Same-book owner',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'manual',500,100,'thumb-500',
     500,'token-500',NULL,NULL,1,1);
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
    VALUES(500,11,1,1);
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES((SELECT id FROM variant_groups WHERE source_gid=500),500,'confirmed','automatic','{}'),
          ((SELECT id FROM variant_groups WHERE source_gid=500),102,'candidate','automatic','{}');
  INSERT INTO variant_reviews(
    review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
    evidence_json,choices_json)
    SELECT 'candidate_identity',(SELECT id FROM variant_groups WHERE source_gid=500),
           100,id,6,
           json_object('source_snapshot',json_object('gid',500,'title','Same-book owner',
                                                      'tags',json_array('language:chinese')),
                       'candidate_snapshot',json_object('gid',100,'title','Frozen predecessor',
                                                        'tags',json_array('language:chinese')),
                       'origins',json_array('manual:predecessor')),
           '[\"same_book\",\"different_book\"]'
      FROM variant_policy_revisions WHERE is_active=1;
"
candidate_same_review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=500) ORDER BY id DESC LIMIT 1;")"
candidate_same_output="$(variants_resolve_review "${candidate_same_review_id}" same-book)"
jq -e '.resolved == true and .decision == "same_book"' <<<"${candidate_same_output}" >/dev/null
assert_eq 'confirmed|manual|102' "$(db_query "SELECT membership_state,decision_source,gid
  FROM gallery_variants AS member JOIN variant_groups AS grouped
    ON grouped.id=member.group_id
 WHERE grouped.identity_active=1 AND member.gid=102 LIMIT 1;")"
assert_eq '100|102|manual:predecessor' "$(db_query ".parameter set :review_id ${candidate_same_review_id}" \
  "SELECT candidate_gid,
          json_extract(evidence_json,'$.resolved_candidate_gid'),
          json_extract(evidence_json,'$.origins[0]')
     FROM variant_reviews WHERE id=:review_id;")"

db_write "
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES((SELECT id FROM variant_groups WHERE source_gid=200),102,'candidate','automatic','{}');
  INSERT INTO variant_reviews(
    review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
    evidence_json,choices_json)
    SELECT 'candidate_identity',(SELECT id FROM variant_groups WHERE source_gid=200),
           100,id,6,
           json_object('source_snapshot',json_object('gid',200,'title','Other book'),
                       'candidate_snapshot',json_object('gid',100,'title','Frozen predecessor'),
                       'origins',json_array('manual:predecessor-different')),
           '[\"same_book\",\"different_book\"]'
      FROM variant_policy_revisions WHERE is_active=1;
"
candidate_different_review_id="$(db_query "SELECT id FROM variant_reviews WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=200) ORDER BY id DESC LIMIT 1;")"
candidate_different_output="$(variants_resolve_review "${candidate_different_review_id}" different-book)"
jq -e '.resolved == true and .decision == "different_book"' <<<"${candidate_different_output}" >/dev/null
assert_eq 'rejected|manual|102' "$(db_query "SELECT membership_state,decision_source,gid
  FROM gallery_variants WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=200)
    AND gid=102;")"
assert_eq '102,200' "$(db_query "SELECT low_gid || ',' || high_gid FROM gallery_identity_pairs
  WHERE current_review_id=${candidate_different_review_id};")"

# Schema 27 keeps relation pairs atomic at runtime. A missing token is not a
# partially known provider fact and must never enter the live gallery table.
if db_write "INSERT INTO galleries(gid,token,title,current_gid,current_token)
              VALUES(900099,'token-900099','Invalid pair',900100,NULL);" \
  >/dev/null 2>&1; then
  printf 'relation-pair guard accepted a half-null reference\n' >&2
  exit 1
fi
assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE gid=900099;')"

# A fetched relation target is identified by its token as well as its GID.
# Both insertion orderings are guarded: a source cannot point at a fetched
# target with a different token, and a target refresh cannot invalidate an
# existing source relation.
db_write "INSERT INTO galleries(gid,token,title,tags)
              VALUES(900100,'token-900100','Fetched target','[]');"
if db_write "INSERT INTO galleries(
                gid,token,title,tags,current_gid,current_token)
              VALUES(900101,'token-900101','Mismatched source','[]',
                     900100,'stale-token');" >/dev/null 2>&1; then
  printf 'relation-pair guard accepted a fetched target token mismatch on insert\n' >&2
  exit 1
fi
assert_eq '0' "$(db_query 'SELECT COUNT(*) FROM galleries WHERE gid=900101;')"
db_write "INSERT INTO galleries(
                gid,token,title,tags,current_gid,current_token)
              VALUES(900102,'token-900102','Valid source','[]',
                     900100,'token-900100');"
if db_write "UPDATE galleries SET token='rotated-token' WHERE gid=900100;" \
  >/dev/null 2>&1; then
  printf 'relation-pair guard accepted a fetched target token mismatch on update\n' >&2
  exit 1
fi
assert_eq 'token-900100' "$(db_query 'SELECT token FROM galleries WHERE gid=900100;')"

# Keep malformed staging facts in the fixture only.  Production metadata
# refreshes reject these pairs at the gallery trigger boundary, but the
# read-only projection still has to classify persisted/in-flight staging facts
# consistently when they are present in an older database.
db_write "DROP TRIGGER galleries_relation_pairs_insert;
           DROP TRIGGER galleries_relation_pairs_update;
  INSERT INTO galleries(gid,token,title,tags,current_gid,current_token)
    VALUES
      (900098,'token-900098','Incomplete pair','[]',900097,NULL),
      (900099,'token-900099','Missing reference','[]',9000999,'token-9000999'),
      (900101,'token-900101','Token mismatch','[]',900100,'stale-token');
  CREATE TRIGGER galleries_relation_pairs_insert
  BEFORE INSERT ON galleries
  WHEN (NEW.first_gid IS NULL) <> (NEW.first_token IS NULL)
    OR (NEW.parent_gid IS NULL) <> (NEW.parent_token IS NULL)
    OR (NEW.current_gid IS NULL) <> (NEW.current_token IS NULL)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.first_gid
                  AND target.token IS NOT NEW.first_token)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.parent_gid
                  AND target.token IS NOT NEW.parent_token)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.current_gid
                  AND target.token IS NOT NEW.current_token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.first_gid = NEW.gid
                  AND source.first_token IS NOT NEW.token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.parent_gid = NEW.gid
                  AND source.parent_token IS NOT NEW.token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.current_gid = NEW.gid
                  AND source.current_token IS NOT NEW.token)
  BEGIN
      SELECT RAISE(ABORT, 'uploader revision relation has a token mismatch');
  END;
  CREATE TRIGGER galleries_relation_pairs_update
  BEFORE UPDATE OF token, first_gid, first_token, parent_gid, parent_token,
                        current_gid, current_token ON galleries
  WHEN (NEW.first_gid IS NULL) <> (NEW.first_token IS NULL)
    OR (NEW.parent_gid IS NULL) <> (NEW.parent_token IS NULL)
    OR (NEW.current_gid IS NULL) <> (NEW.current_token IS NULL)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.first_gid
                  AND target.token IS NOT NEW.first_token)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.parent_gid
                  AND target.token IS NOT NEW.parent_token)
    OR EXISTS (SELECT 1 FROM galleries AS target
                WHERE target.gid = NEW.current_gid
                  AND target.token IS NOT NEW.current_token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.gid <> NEW.gid
                  AND source.first_gid = NEW.gid
                  AND source.first_token IS NOT NEW.token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.gid <> NEW.gid
                  AND source.parent_gid = NEW.gid
                  AND source.parent_token IS NOT NEW.token)
    OR EXISTS (SELECT 1 FROM galleries AS source
                WHERE source.gid <> NEW.gid
                  AND source.current_gid = NEW.gid
                  AND source.current_token IS NOT NEW.token)
  BEGIN
      SELECT RAISE(ABORT, 'uploader revision relation has a token mismatch');
  END;
"

# The revision-component classifier rejects malformed components without manufacturing
# a scoreable revision terminal. `first` is consistency evidence only; parent/current
# edges define the component and terminal projection.
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    current_gid,current_token,favorite_count,rating_count)
  VALUES
    (900011,'token-900011','Cycle A',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'cycle',900011,10,'thumb',
     900012,'token-900012',1,1),
    (900012,'token-900012','Cycle B',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'cycle',900012,10,'thumb',
     900011,'token-900011',1,1),
    (900021,'token-900021','Branch root',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'branch',900021,10,'thumb',
     NULL,NULL,1,1),
    (900022,'token-900022','Branch child A',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'branch',900022,10,'thumb',
     NULL,NULL,1,1),
    (900023,'token-900023','Branch child B',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'branch',900023,10,'thumb',
     NULL,NULL,1,1);
  UPDATE galleries
     SET parent_gid=900021, parent_token='token-900021'
   WHERE gid IN (900022,900023);
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    first_gid,first_token,current_gid,current_token,favorite_count,rating_count)
  VALUES
    (900031,'token-900031','First conflict source',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'conflict',900031,10,'thumb',
     900035,'token-900035',900034,'token-900034',1,1),
    (900034,'token-900034','First conflict terminal',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'conflict',900034,10,'thumb',
     NULL,NULL,NULL,NULL,1,1),
    (900035,'token-900035','First-only unrelated',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'conflict',900035,10,'thumb',
     NULL,NULL,NULL,NULL,1,1);
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    first_gid,first_token,current_gid,current_token,favorite_count,rating_count)
  VALUES
    (900040,'token-900040','Shared first root',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'shared-first',900040,10,'thumb',
     NULL,NULL,NULL,NULL,1,1),
    (900041,'token-900041','Shared first A',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'shared-first',900041,10,'thumb',
     900040,'token-900040',NULL,NULL,1,1),
    (900042,'token-900042','Shared first B',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'shared-first',900042,10,'thumb',
     900040,'token-900040',NULL,NULL,1,1);
"
assert_eq 'cycle' "$(db_query "SELECT blocked_reason FROM current_revision_projection
  WHERE revision_gid=900011;")"
assert_eq 'branch' "$(db_query "SELECT blocked_reason FROM current_revision_projection
  WHERE revision_gid=900021;")"
assert_eq 'relation_conflict' "$(db_query "SELECT blocked_reason FROM current_revision_projection
  WHERE revision_gid=900031;")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM scoreable_revision_terminals
  WHERE gid IN (900011,900021,900031);")"
assert_eq '3' "$(db_query "SELECT COUNT(DISTINCT component_gid) FROM current_revision_projection
  WHERE revision_gid IN (900040,900041,900042);")"
assert_eq '3' "$(db_query "SELECT COUNT(*) FROM scoreable_revision_terminals
  WHERE gid IN (900040,900041,900042);")"
assert_eq "$(global_status_projection_rows 900011 900021 900031 900040 900041 900042 900098 900099 900101)" \
  "$(status_projection_rows 900011 900021 900031 900040 900041 900042 900098 900099 900101)"
assert_eq 'cycle|branch|relation_conflict|relation_conflict|reference_incomplete|token_mismatch' \
  "$(db_query "SELECT group_concat(blocked_reason, '|') FROM (
       SELECT blocked_reason FROM current_revision_projection
        WHERE revision_gid IN (900011,900021,900031,900098,900099,900101)
        ORDER BY revision_gid);")" \
  || return 1
db_write 'DELETE FROM galleries WHERE gid BETWEEN 900011 AND 900042
                    OR gid IN (900098,900099,900101);'

# A complete publication refreshes every staged GID, promotes only the
# terminal, keeps the predecessor archive as the archive-source fallback, and
# coalesces one rating-11 evaluation in the same writer transaction.
printf 'core predecessor archive' >"${ARCHIVED_DIR}/core-predecessor.7z"
db_write "
  INSERT INTO galleries(
    gid,token,title,title_jpn,file_count,expunged,tags,rating,file_path,uploader,
    posted,filesize,thumb,first_gid,first_token,parent_gid,parent_token,
    current_gid,current_token,favorite_count,rating_count)
  VALUES
    (900001,'core-token-1','Core predecessor','',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'core-predecessor.7z','core',
     900001,100,'thumb-core-1',900001,'core-token-1',NULL,NULL,
     900002,'core-token-2',1,1);
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
    VALUES(900001,11,1,1,'none');
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES(last_insert_rowid(),900001,'confirmed','automatic','{}');
  -- Seed a legacy cross-chain-looking different_book endpoint on the old
  -- revision. Publication must drop the current pair after the provider
  -- component promotes 900002, while retaining this resolved review as
  -- immutable history.
  INSERT INTO galleries(gid,token,title,tags)
    VALUES(900002,'core-token-2','Pending core terminal','[]');
  INSERT INTO variant_reviews(
    review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
    evidence_json,choices_json,status,decision,resolved_at)
    SELECT 'candidate_identity',(SELECT id FROM variant_groups WHERE source_gid=900001),
           900002,id,${VARIANTS_MATCHING_REVISION},'{}','[900001,900002]',
           'resolved','different_book','2026-09-19T00:00:00Z'
      FROM variant_policy_revisions WHERE is_active=1;
  INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
    SELECT 900001,900002,MAX(id) FROM variant_reviews
     WHERE group_id=(SELECT id FROM variant_groups WHERE source_gid=900001);
"
core_group_id="$(db_query "SELECT id FROM variant_groups WHERE source_gid=900001;")"
core_resolved_review_before="$(db_query "SELECT status || '|' || decision || '|' ||
  COALESCE(superseded_at,'') || '|' || evidence_json
  FROM variant_reviews
  WHERE group_id=${core_group_id} AND candidate_gid=900002;")"
core_job_id="$(db_write "INSERT INTO variant_jobs(
    job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
  VALUES('discover',${core_group_id},900001,500,'leased','core-owner',
         strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
  SELECT last_insert_rowid();")"
core_run_id="$(db_write "INSERT INTO variant_discovery_runs(
    group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
  VALUES(${core_group_id},${core_job_id},${VARIANTS_MATCHING_REVISION},'publish','running',
         'core-owner',strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
  SELECT last_insert_rowid();")"
db_write "
  INSERT INTO variant_discovery_candidates(
    run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,
    evidence_json,state)
  VALUES
    (${core_run_id},900001,'core-token-1',${VARIANTS_MATCHING_REVISION},
     json('[{\"kind\":\"seed\",\"gid\":900001}]'),
     json_object('gid',900001,'token','core-token-1','title','Core predecessor',
       'title_jpn','','filecount',10,'expunged',0,
       'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.0,
       'uploader','core','posted',900001,'filesize',100,'thumb','thumb-core-1',
       'first_gid',900001,'first_token','core-token-1',
       'parent_gid',NULL,'parent_token',NULL,
       'current_gid',900002,'current_token','core-token-2'),
     json_object('favorite_count',10,'rating_count',20,
                 'popularity_fetched_at','2026-09-19T00:00:00Z'),
     json_object('in_scope',1,'score',1),'complete'),
    (${core_run_id},900002,'core-token-2',${VARIANTS_MATCHING_REVISION},
     json('[{\"kind\":\"uploader_revision\",\"from_gid\":900001,
            \"relation\":\"current\"}]'),
     json_object('gid',900002,'token','core-token-2','title','Core terminal',
       'title_jpn','','filecount',11,'expunged',0,
       'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.2,
       'uploader','core','posted',900002,'filesize',110,'thumb','thumb-core-2',
       'first_gid',900001,'first_token','core-token-1',
       'parent_gid',900001,'parent_token','core-token-1',
       'current_gid',NULL,'current_token',NULL),
     json_object('favorite_count',12,'rating_count',22,
                 'popularity_fetched_at','2026-09-19T00:00:00Z'),
     json_object('in_scope',1,'score',2),'complete');
"
core_publish_output="$(variants_discovery_publish "${core_run_id}" "${core_job_id}" \
  "${core_group_id}" core-owner)"
jq -e '
  .status == "completed" and .source_gid == 900002 and
  .evaluation_queued == true
' <<<"${core_publish_output}" >/dev/null
assert_eq '900002' "$(db_query "SELECT source_gid FROM variant_groups WHERE id=${core_group_id};")"
assert_eq '900002' "$(db_query "SELECT group_concat(gid, ',') FROM gallery_variants
  WHERE group_id=${core_group_id} AND membership_state='confirmed';")"
assert_eq '900001' "$(db_query "SELECT archive_gid FROM archive_source_galleries
  WHERE gid=900002;")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM pragma_table_info('gallery_variants')
  WHERE name='metadata_snapshot_json';")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=${core_group_id} AND job_type='evaluate' AND status='queued';")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM gallery_identity_pairs
  WHERE low_gid=900001 AND high_gid=900002;")"
assert_eq 'different_book' "$(db_query "SELECT decision FROM variant_reviews
  WHERE group_id=${core_group_id} AND candidate_gid=900002
  ORDER BY id DESC LIMIT 1;")"
assert_eq "${core_resolved_review_before}" "$(db_query "SELECT status || '|' || decision || '|' ||
  COALESCE(superseded_at,'') || '|' || evidence_json
  FROM variant_reviews
  WHERE group_id=${core_group_id} AND candidate_gid=900002;")"

# A historical different-book decision between two revisions of the same
# uploader component must not split or block that component.  Keep the
# resolved row as frozen history, while a current pending pair is projected
# as same-class and therefore cannot become a different-book class pair.
run_same_component_different_book_check() {
  local saved_db_path="${DB_PATH}" boundary_db="${TEMP_ROOT}/same-component-different-book.sqlite3"
  local historical_review
  DB_PATH="${boundary_db}"
  db_init >/dev/null
  db_write "INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
      favorite_count,rating_count)
    VALUES
      (102,'boundary-token-102','Boundary predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'boundary',102,10,
       'boundary-102',1,1),
      (103,'boundary-token-103','Boundary terminal',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,'boundary',103,11,
       'boundary-103',2,2);
    UPDATE galleries SET current_gid=103,current_token='boundary-token-103'
      WHERE gid=102;
    UPDATE galleries SET first_gid=102,first_token='boundary-token-102',
      parent_gid=102,parent_token='boundary-token-102'
      WHERE gid=103;
    INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
      VALUES(102,11,1,1);
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,evidence_json)
      VALUES(last_insert_rowid(),102,'confirmed','automatic','{}'),
            (last_insert_rowid(),103,'candidate','automatic','{}');
    INSERT INTO variant_reviews(
      review_type,group_id,candidate_gid,policy_revision_id,matching_revision,
      evidence_json,choices_json,status,decision,resolved_at)
      SELECT 'candidate_identity',(SELECT id FROM variant_groups WHERE source_gid=102),
        103,id,${VARIANTS_MATCHING_REVISION},'{}','[102,103]',
        'resolved','different_book','2026-09-19T00:00:00Z'
        FROM variant_policy_revisions WHERE is_active=1;
    INSERT INTO gallery_identity_pairs(low_gid,high_gid,current_review_id)
      SELECT 102,103,last_insert_rowid();
    "
  historical_review="$(db_query "SELECT id FROM variant_reviews WHERE status='resolved';")"
  db_write "BEGIN IMMEDIATE; $(variants_identity_reconcile_sql) COMMIT;"
  assert_eq '103|103|resolved|different_book|1' "$(db_query "SELECT
      low_projection.terminal_gid || '|' || high_projection.terminal_gid || '|' ||
      review.status || '|' || review.decision || '|' ||
      (low_projection.component_gid = high_projection.component_gid)
    FROM gallery_identity_pairs AS pair
    JOIN variant_reviews AS review ON review.id=pair.current_review_id
    JOIN current_revision_projection AS low_projection
      ON low_projection.revision_gid=pair.low_gid
    JOIN current_revision_projection AS high_projection
      ON high_projection.revision_gid=pair.high_gid
    WHERE review.id=${historical_review};")"
  DB_PATH="${saved_db_path}"
}
run_same_component_different_book_check

# Overlapping active groups must collapse as one connected owner.  The shared
# uploader component (940002 -> 940005) links A={940001,940002} and
# B={940005,940003}; B's other component must follow the same owner instead of
# becoming orphaned.
db_write "
  INSERT INTO galleries(
    gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
    current_gid,current_token,favorite_count,rating_count)
  VALUES
    (940001,'overlap-x','Overlap X',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'overlap',1,10,'x',NULL,NULL,1,1),
    (940002,'overlap-y','Overlap Y',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'overlap',2,10,'y',940005,'overlap-y-terminal',1,1),
    (940005,'overlap-y-terminal','Overlap Y terminal',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'overlap',5,10,'yt',NULL,NULL,1,1),
    (940003,'overlap-z','Overlap Z',10,0,
     '[\"language:chinese\",\"other:tankoubon\"]',4.0,'overlap',3,10,'z',NULL,NULL,1,1);
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,latest_feedback_at)
    VALUES(940001,11,1,1,'2026-09-19T00:00:00Z'),
    (940005,8,1,1,'2026-09-20T00:00:00Z');
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,940001,'confirmed','automatic','{}' FROM variant_groups WHERE source_gid=940001;
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,940002,'confirmed','automatic','{}' FROM variant_groups WHERE source_gid=940001;
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,940005,'confirmed','automatic','{}' FROM variant_groups WHERE source_gid=940005;
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    SELECT id,940003,'confirmed','manual','{\"owner\":\"loser\"}' FROM variant_groups WHERE source_gid=940005;
  INSERT INTO gallery_variants(
    group_id,gid,membership_state,decision_source,match_score,evidence_json,
    variant_score,decided_at)
    SELECT id,940003,'candidate','manual',77,'{\"owner\":\"survivor\"}',66,
           '2026-09-01T00:00:00Z'
      FROM variant_groups WHERE source_gid=940001;
"
overlap_a="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=940001;')"
overlap_b="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=940005;')"
overlap_job="$(db_write "INSERT INTO variant_jobs(
    job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
  VALUES('discover',${overlap_a},940001,500,'leased','overlap-owner',
         strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
  INSERT INTO variant_jobs(job_type,group_id,source_gid,priority,status)
    VALUES('discover',${overlap_b},940005,300,'queued');
  SELECT id FROM variant_jobs WHERE group_id=${overlap_a} AND job_type='discover';")"
overlap_run="$(db_write "INSERT INTO variant_discovery_runs(
    group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
  SELECT ${overlap_a},${overlap_job},${VARIANTS_MATCHING_REVISION},'publish','running',
         'overlap-owner',strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes');
  SELECT last_insert_rowid();")"
db_write "
  INSERT INTO variant_discovery_candidates(
    run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,
    evidence_json,state)
  VALUES
    (${overlap_run},940001,'overlap-x',${VARIANTS_MATCHING_REVISION},
     json('[{\"kind\":\"seed\",\"gid\":940001}]'),
     json_object('gid',940001,'token','overlap-x','title','Overlap X',
       'title_jpn','','filecount',10,'expunged',0,
       'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.0,
       'uploader','overlap','posted',1,'filesize',10,'thumb','x',
       'first_gid',NULL,'first_token',NULL,'parent_gid',NULL,'parent_token',NULL,
       'current_gid',NULL,'current_token',NULL),
     json_object('favorite_count',10,'rating_count',20),
     json_object('in_scope',1,'score',1),'complete'),
    (${overlap_run},940002,'overlap-y',${VARIANTS_MATCHING_REVISION},
     json('[{\"kind\":\"seed\",\"gid\":940002}]'),
     json_object('gid',940002,'token','overlap-y','title','Overlap Y',
       'title_jpn','','filecount',10,'expunged',0,
       'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.0,
       'uploader','overlap','posted',2,'filesize',10,'thumb','y',
       'first_gid',NULL,'first_token',NULL,'parent_gid',NULL,'parent_token',NULL,
       'current_gid',940005,'current_token','overlap-y-terminal'),
     json_object('favorite_count',11,'rating_count',21),
     json_object('in_scope',1,'score',2),'complete'),
    (${overlap_run},940005,'overlap-y-terminal',${VARIANTS_MATCHING_REVISION},
     json('[{\"kind\":\"uploader_revision\",\"from_gid\":940002,\"relation\":\"current\"}]'),
     json_object('gid',940005,'token','overlap-y-terminal','title','Overlap Y terminal',
       'title_jpn','','filecount',10,'expunged',0,
       'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.0,
       'uploader','overlap','posted',5,'filesize',10,'thumb','yt',
       'first_gid',NULL,'first_token',NULL,'parent_gid',940002,'parent_token','overlap-y',
       'current_gid',NULL,'current_token',NULL),
     json_object('favorite_count',13,'rating_count',23),
     json_object('in_scope',1,'score',4),'complete');
"
variants_discovery_publish "${overlap_run}" "${overlap_job}" "${overlap_a}" overlap-owner >/dev/null
assert_eq '940001,940003,940005' "$(db_query "SELECT group_concat(gid, ',') FROM gallery_variants
  WHERE group_id=${overlap_a} AND membership_state='confirmed' ORDER BY gid;")"
assert_eq 'confirmed|manual|77|{"owner":"survivor"}' "$(db_query "SELECT membership_state,decision_source,match_score,evidence_json
  FROM gallery_variants WHERE group_id=${overlap_a} AND gid=940003;")"
assert_eq '0' "$(db_query "SELECT identity_active FROM variant_groups WHERE id=${overlap_b};")"
assert_eq '0' "$(db_query "SELECT COUNT(*) FROM gallery_variants
  WHERE group_id=${overlap_b} AND membership_state='confirmed'
    AND EXISTS (SELECT 1 FROM variant_groups
                 WHERE id=gallery_variants.group_id AND identity_active=1);")"
assert_eq '8|2026-09-20T00:00:00Z' "$(db_query "SELECT desired_rating,latest_feedback_at
  FROM variant_groups WHERE id=${overlap_a};")"
assert_eq '1' "$(db_query "SELECT COUNT(*) FROM variant_jobs
  WHERE group_id=${overlap_a} AND job_type='reconcile_actions' AND status='queued';")"
if variants_discovery_publish "${overlap_run}" "${overlap_job}" "${overlap_a}" overlap-owner \
  >/dev/null 2>&1; then
  printf 'completed overlap publication was not idempotently fenced\n' >&2
  exit 1
fi
assert_eq '940001,940003,940005' "$(db_query "SELECT group_concat(gid, ',') FROM gallery_variants
  WHERE group_id=${overlap_a} AND membership_state='confirmed' ORDER BY gid;")"

# A refreshed GID with a different token is rejected before the live upsert;
# the leased run/job and the existing gallery token remain unchanged.
bad_job_id="$(db_write "INSERT INTO variant_jobs(
    job_type,group_id,source_gid,priority,status,lease_owner,lease_expires_at)
  VALUES('discover',${core_group_id},900002,500,'leased','bad-owner',
         strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
  SELECT last_insert_rowid();")"
bad_run_id="$(db_write "INSERT INTO variant_discovery_runs(
    group_id,job_id,matching_revision,phase,status,lease_owner,lease_expires_at)
  VALUES(${core_group_id},${bad_job_id},${VARIANTS_MATCHING_REVISION},'publish','running',
         'bad-owner',strftime('%Y-%m-%dT%H:%M:%SZ','now','+15 minutes'));
  SELECT last_insert_rowid();")"
db_write "INSERT INTO variant_discovery_candidates(
    run_id,gid,token,matching_revision,origin_json,gdata_json,popularity_json,
    evidence_json,state)
  VALUES(${bad_run_id},900002,'wrong-token',${VARIANTS_MATCHING_REVISION},
    json('[{\"kind\":\"seed\",\"gid\":900002}]'),
    json_object('gid',900002,'token','wrong-token','title','Wrong token',
      'title_jpn','','filecount',11,'expunged',0,
      'tags',json('[\"language:chinese\",\"other:tankoubon\"]'),'rating',4.2,
      'uploader','core','posted',900002,'filesize',110,'thumb','thumb-core-2',
      'first_gid',NULL,'first_token',NULL,'parent_gid',NULL,'parent_token',NULL,
      'current_gid',NULL,'current_token',NULL),
    json_object('favorite_count',12,'rating_count',22,
      'popularity_fetched_at','2026-09-19T00:00:00Z'),
    json_object('in_scope',1,'score',2),'complete');"
if variants_discovery_publish "${bad_run_id}" "${bad_job_id}" \
  "${core_group_id}" bad-owner >/dev/null 2>&1; then
  printf 'publication accepted a GID with a different token\n' >&2
  exit 1
fi
assert_eq 'wrong-token' "$(db_query "SELECT token FROM variant_discovery_candidates
  WHERE run_id=${bad_run_id};")"
assert_eq 'core-token-2' "$(db_query 'SELECT token FROM galleries WHERE gid=900002;')"
assert_eq 'running' "$(db_query "SELECT status FROM variant_discovery_runs WHERE id=${bad_run_id};")"
db_write "DELETE FROM variant_discovery_candidates WHERE run_id=${bad_run_id};
  DELETE FROM variant_discovery_runs WHERE id=${bad_run_id};
  DELETE FROM variant_jobs WHERE id=${bad_job_id};"

# Scoring reads the live gallery row on every evaluation and freezes the
# resulting snapshot only in variant_evaluations. The revision fingerprint is
# included in that immutable snapshot as the stale-commit guard input.
db_write "
  INSERT INTO galleries(
    gid,token,title,title_jpn,file_count,expunged,tags,rating,uploader,posted,
    filesize,thumb,favorite_count,rating_count)
  VALUES(900050,'score-token','Live score before','',20,0,
    '[\"language:chinese\",\"other:tankoubon\"]',4.0,'score',900050,200,
    'thumb-score',1,1);
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active,review_state)
    VALUES(900050,11,1,1,'none');
  INSERT INTO gallery_variants(group_id,gid,membership_state,decision_source,evidence_json)
    VALUES(last_insert_rowid(),900050,'confirmed','automatic',
           json_object('origins',json_array('fixture:uploader_revision'),
                       'kind','uploader_revision'));
"
score_group_id="$(db_query 'SELECT id FROM variant_groups WHERE source_gid=900050;')"
# The consumer portion above stubs the scorer to isolate its resolver checks;
# restore the production implementation for this live-input exercise.
# shellcheck source=lib/variant_scoring.sh
source "${ROOT}/lib/variant_scoring.sh"
# The active policy row in the production snapshot predates the parallel
# policy-revision update; bypass only its hash gate so this fixture exercises
# live gallery reads and the uploader-revision stale guard itself.
variants_policy_load_active() { :; }
variants_evaluate_group "${score_group_id}" >/dev/null
score_evaluation_before="$(db_query "SELECT active_evaluation_id FROM variant_groups WHERE id=${score_group_id};")"
db_write "UPDATE galleries
  SET title='Live score after', favorite_count=99, rating_count=77
  WHERE gid=900050;"
variants_evaluate_group "${score_group_id}" >/dev/null
assert_eq 'Live score after|99|77|object' "$(db_query "
  SELECT json_extract(evaluation.metadata_snapshot_json,'\$[0].title') || '|' ||
         json_extract(evaluation.metadata_snapshot_json,'\$[0].favorite_count') || '|' ||
         json_extract(evaluation.metadata_snapshot_json,'\$[0].rating_count') || '|' ||
         json_type(evaluation.metadata_snapshot_json,'\$[0].uploader_revision_fingerprint')
    FROM variant_evaluations AS evaluation
   WHERE evaluation.id=(SELECT active_evaluation_id FROM variant_groups
                         WHERE id=${score_group_id});")"
assert_eq 'Live score before|fixture:uploader_revision|object|array' "$(db_query "
  SELECT json_extract(evaluation.metadata_snapshot_json,'\$[0].title') || '|' ||
         json_extract(evaluation.metadata_snapshot_json,'\$[0].evidence.origins[0]') || '|' ||
         json_type(evaluation.metadata_snapshot_json,'\$[0].uploader_revision_fingerprint') || '|' ||
         json_type(evaluation.metadata_snapshot_json,'\$[0].origins')
    FROM variant_evaluations AS evaluation WHERE evaluation.id=${score_evaluation_before};")"

  # Schema-26 -> schema-27 -> schema-28 migration is valid for a complete chain
  # and aborts atomically for an invalid graph. Both checks use disposable databases so
# this fixture never touches the playground snapshot.
run_schema27_migration_checks() {
  local saved_db_path="${DB_PATH}" saved_migrations_dir="${MIGRATIONS_DIR}"
  local valid_root="${TEMP_ROOT}/schema27-valid" invalid_root="${TEMP_ROOT}/schema27-invalid"
  local relation_root="${TEMP_ROOT}/schema27-invalid-relation"
  local incomplete_root="${TEMP_ROOT}/schema27-incomplete"
  local valid_db="${valid_root}/data.sqlite3" invalid_db="${invalid_root}/data.sqlite3"
  local relation_db="${relation_root}/data.sqlite3" incomplete_db="${incomplete_root}/data.sqlite3"
  mkdir -p "${valid_root}/migrations" "${invalid_root}/migrations" \
    "${relation_root}/migrations" "${incomplete_root}/migrations"
  cp "${ROOT}"/migrations/*.sql "${valid_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${invalid_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${relation_root}/migrations/"
  cp "${ROOT}"/migrations/*.sql "${incomplete_root}/migrations/"
  # Hold every post-26 migration back so each disposable database can advance
  # deliberately through schema 27 and then schema 28.
  rm -f "${valid_root}/migrations/027_"*.sql \
    "${valid_root}/migrations/028_"*.sql \
    "${valid_root}/migrations/029_"*.sql \
    "${invalid_root}/migrations/027_"*.sql \
    "${invalid_root}/migrations/028_"*.sql \
    "${invalid_root}/migrations/029_"*.sql \
    "${relation_root}/migrations/027_"*.sql \
    "${relation_root}/migrations/028_"*.sql \
    "${relation_root}/migrations/029_"*.sql \
    "${incomplete_root}/migrations/027_"*.sql \
    "${incomplete_root}/migrations/028_"*.sql \
    "${incomplete_root}/migrations/029_"*.sql

  DB_PATH="${valid_db}"
  MIGRATIONS_DIR="${valid_root}/migrations"
  db_init >/dev/null
  db_write "
    INSERT INTO galleries(
      gid,token,title,title_jpn,file_count,expunged,tags,rating,uploader,posted,
      filesize,thumb,first_gid,first_token,parent_gid,parent_token,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (910001,'migration-token-1','Migration parent','',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'migration',910001,100,
       'thumb-m1',910001,'migration-token-1',NULL,NULL,
       910002,'migration-token-2',1,1),
      (910002,'migration-token-2','Migration terminal','',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,'migration',910002,110,
       'thumb-m2',910001,'migration-token-1',910001,'migration-token-1',
       NULL,NULL,2,2);
    INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
      VALUES(910001,11,1,1);
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json)
      VALUES(last_insert_rowid(),910001,'confirmed','automatic','{}',
             json_object('title','Migration parent','filecount',10,
                         'tags',json('[\"language:chinese\",\"other:tankoubon\"]')));
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${valid_root}/migrations/"
  db_init >/dev/null
  assert_eq '27' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  # Historical pre-028 assertion: migration 027 owns the legacy view name.
  assert_eq '910002' "$(db_query \
    'SELECT gid FROM eligible_galleries WHERE component_gid=910001;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  cp "${ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" \
    "${valid_root}/migrations/"
  db_init >/dev/null
  assert_eq '28' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '910002' "$(db_query \
    'SELECT gid FROM scoreable_revision_terminals WHERE component_gid=910001;')"
  assert_eq '910002' "$(db_query \
    "SELECT gid FROM gallery_variants WHERE membership_state='confirmed';")"
  assert_eq '0' "$(db_query \
    "SELECT COUNT(*) FROM pragma_table_info('gallery_variants')
      WHERE name='metadata_snapshot_json';")"

  DB_PATH="${invalid_db}"
  MIGRATIONS_DIR="${invalid_root}/migrations"
  db_init >/dev/null
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (920001,'cycle-token-1','Invalid cycle A',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',1,10,'thumb',
       920002,'cycle-token-2',1,1),
      (920002,'cycle-token-2','Invalid cycle B',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',2,10,'thumb',
       920001,'cycle-token-1',1,1);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${invalid_root}/migrations/"
  if db_init >/dev/null 2>&1; then
    printf 'schema-27 migration accepted an invalid cycle\n' >&2
    DB_PATH="${saved_db_path}"
    MIGRATIONS_DIR="${saved_migrations_dir}"
    return 1
  fi
  assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '920002' "$(db_query \
    'SELECT current_gid FROM galleries WHERE gid=920001;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"

  DB_PATH="${relation_db}"
  MIGRATIONS_DIR="${relation_root}/migrations"
  db_init >/dev/null
  # Schema 26 has no pair guard; migration 27 must diagnose and roll back a
  # fetched half-null relation before creating any replacement views.
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,uploader,posted,filesize,thumb,
      current_gid,current_token,favorite_count,rating_count)
    VALUES
      (930001,'relation-token-1','Invalid relation',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,'invalid',1,10,'thumb',
       930002,NULL,1,1);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${relation_root}/migrations/"
  if db_init >/dev/null 2>&1; then
    printf 'schema-27 migration accepted a half-null relation\n' >&2
    DB_PATH="${saved_db_path}"
    MIGRATIONS_DIR="${saved_migrations_dir}"
    return 1
  fi
  assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
  assert_eq '' "$(db_query \
    "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  assert_eq '930002|' "$(db_query \
    "SELECT current_gid || '|' || COALESCE(current_token,'')
       FROM galleries WHERE gid=930001;")"

  # Every malformed fetched component must abort the migration before the
  # replacement views are committed. These cases exercise graph diagnostics
  # independently of the half-null/token-pair guard above.
  reject_graph_case() {
    local case_name="$1" case_kind="$2"
    local case_root="${TEMP_ROOT}/schema27-${case_name}"
    local case_db="${case_root}/data.sqlite3"
    mkdir -p "${case_root}/migrations"
    cp "${ROOT}"/migrations/*.sql "${case_root}/migrations/"
    # Keep the disposable database at schema 26 until migration 027 is copied.
    rm -f "${case_root}/migrations/027_"*.sql \
      "${case_root}/migrations/028_"*.sql \
      "${case_root}/migrations/029_"*.sql
    DB_PATH="${case_db}"
    MIGRATIONS_DIR="${case_root}/migrations"
    db_init >/dev/null
    case "${case_kind}" in
      branch)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,parent_gid,parent_token,favorite_count,rating_count)
          VALUES
            (950001,'branch-token-1','Branch root',10,0,'[]',4.0,'invalid',
             1,10,'thumb',NULL,NULL,1,1),
            (950002,'branch-token-2','Branch child A',10,0,'[]',4.0,'invalid',
             2,10,'thumb',950001,'branch-token-1',1,1),
            (950003,'branch-token-3','Branch child B',10,0,'[]',4.0,'invalid',
             3,10,'thumb',950001,'branch-token-1',1,1);"
        ;;
      relation-conflict)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,first_gid,first_token,current_gid,current_token,
            favorite_count,rating_count)
          VALUES
            (951001,'conflict-token-1','Conflict source',10,0,'[]',4.0,'invalid',
             1,10,'thumb',951003,'conflict-token-3',951002,'conflict-token-2',1,1),
            (951002,'conflict-token-2','Conflict terminal',10,0,'[]',4.0,'invalid',
             2,10,'thumb',NULL,NULL,NULL,NULL,1,1),
            (951003,'conflict-token-3','Unrelated first',10,0,'[]',4.0,'invalid',
             3,10,'thumb',NULL,NULL,NULL,NULL,1,1);"
        ;;
      multiple-terminals)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,parent_gid,parent_token,current_gid,current_token,
            favorite_count,rating_count)
          VALUES
            (952001,'multi-token-1','Multiple root',10,0,'[]',4.0,'invalid',
             1,10,'thumb',NULL,NULL,952003,'multi-token-3',1,1),
            (952002,'multi-token-2','Multiple parent terminal',10,0,'[]',4.0,'invalid',
             2,10,'thumb',952001,'multi-token-1',NULL,NULL,1,1),
            (952003,'multi-token-3','Multiple current terminal',10,0,'[]',4.0,'invalid',
             3,10,'thumb',NULL,NULL,NULL,NULL,1,1);"
        ;;
      token-mismatch)
        db_write "
          INSERT INTO galleries(
            gid,token,title,file_count,expunged,tags,rating,uploader,posted,
            filesize,thumb,current_gid,current_token,favorite_count,rating_count)
          VALUES
            (953001,'mismatch-token-1','Mismatch source',10,0,'[]',4.0,'invalid',
             1,10,'thumb',953002,'wrong-token',1,1),
            (953002,'mismatch-token-2','Mismatch target',10,0,'[]',4.0,'invalid',
             2,10,'thumb',NULL,NULL,1,1);"
        ;;
      *) return 1 ;;
    esac
    cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" "${case_root}/migrations/"
    if db_init >/dev/null 2>&1; then
      printf 'schema-27 migration accepted invalid %s component\n' "${case_kind}" >&2
      return 1
    fi
    assert_eq '26' "$(db_query 'SELECT MAX(version) FROM _schema_version;')"
    assert_eq '' "$(db_query "SELECT name FROM sqlite_schema WHERE type='view' AND name='scoreable_revision_terminals';")"
  }
  reject_graph_case branch branch
  reject_graph_case relation-conflict relation-conflict
  reject_graph_case multiple-terminals multiple-terminals
  reject_graph_case token-mismatch token-mismatch

  # A blocked replacement is retryable input, not permission to erase the
  # previously effective revision.  Exercise all three incomplete classes in
  # one schema-26 database and keep the old member, canonical/evaluation
  # pointer, pending current action, and exact archive visible after 027.
  DB_PATH="${incomplete_db}"
  MIGRATIONS_DIR="${incomplete_root}/migrations"
  db_init >/dev/null
  printf 'reference predecessor' >"${ARCHIVED_DIR}/incomplete-reference.7z"
  printf 'scope predecessor' >"${ARCHIVED_DIR}/incomplete-scope.7z"
  printf 'scoring predecessor' >"${ARCHIVED_DIR}/incomplete-scoring.7z"
  db_write "
    INSERT INTO galleries(
      gid,token,title,file_count,expunged,tags,rating,file_path,uploader,posted,
      filesize,thumb,current_gid,current_token,favorite_count,rating_count)
    VALUES
      (940001,'incomplete-reference-1','Reference predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-reference.7z','retry',940001,100,'thumb-940001',940002,
       'incomplete-reference-2',1,1),
      (941001,'incomplete-scope-1','Scope predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-scope.7z','retry',941001,100,'thumb-941001',941002,
       'incomplete-scope-2',1,1),
      (941002,'incomplete-scope-2','Scope replacement',11,0,'[]',4.2,NULL,
       'retry',941002,110,'thumb-941002',NULL,NULL,2,2),
      (942001,'incomplete-scoring-1','Scoring predecessor',10,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.0,
       'incomplete-scoring.7z','retry',942001,100,'thumb-942001',942002,
       'incomplete-scoring-2',1,1),
      (942002,'incomplete-scoring-2','Scoring replacement',11,0,
       '[\"language:chinese\",\"other:tankoubon\"]',4.2,NULL,
       'retry',942002,110,'thumb-942002',NULL,NULL,NULL,NULL);
    INSERT INTO variant_groups(
      id,source_gid,desired_rating,is_active,identity_active)
    VALUES
      (9401,940001,11,1,1),
      (9411,941001,11,1,1),
      (9421,942001,11,1,1);
    INSERT INTO gallery_variants(
      group_id,gid,membership_state,decision_source,evidence_json,metadata_snapshot_json,
      variant_state)
    VALUES
      (9401,940001,'confirmed','manual','{\"history\":\"reference\"}','{}','canonical'),
      (9411,941001,'confirmed','manual','{\"history\":\"scope\"}','{}','canonical'),
      (9421,942001,'confirmed','manual','{\"history\":\"scoring\"}','{}','canonical');
    UPDATE variant_groups SET canonical_gid=CASE id
      WHEN 9401 THEN 940001 WHEN 9411 THEN 941001 WHEN 9421 THEN 942001 END
      WHERE id IN (9401,9411,9421);
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94001,9401,id,'completed','[]','[]',940001
      FROM variant_policy_revisions WHERE is_active=1;
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94101,9411,id,'completed','[]','[]',941001
      FROM variant_policy_revisions WHERE is_active=1;
    INSERT INTO variant_evaluations(
      id,group_id,policy_revision_id,state,metadata_snapshot_json,
      member_scores_json,canonical_gid)
    SELECT 94201,9421,id,'completed','[]','[]',942001
      FROM variant_policy_revisions WHERE is_active=1;
    UPDATE variant_groups SET active_evaluation_id=CASE id
      WHEN 9401 THEN 94001 WHEN 9411 THEN 94101 WHEN 9421 THEN 94201 END
      WHERE id IN (9401,9411,9421);
    INSERT INTO variant_actions(
      group_id,evaluation_id,gid,action_type,desired_value,policy_revision_id,status)
    SELECT grouped.id,grouped.active_evaluation_id,grouped.source_gid,
           'rating','10',policy.id,'pending'
      FROM variant_groups AS grouped
      CROSS JOIN variant_policy_revisions AS policy
     WHERE policy.is_active=1 AND grouped.id IN (9401,9411,9421);
  "
  cp "${ROOT}/migrations/027_uploader_revision_chain_projection.sql" \
    "${incomplete_root}/migrations/"
  db_init >/dev/null
  cp "${ROOT}/migrations/028_discovery_revision_archive_vocabulary.sql" \
    "${incomplete_root}/migrations/"
  db_init >/dev/null
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(canonical_gid, '|')
    FROM (SELECT canonical_gid FROM variant_groups
           WHERE id IN (9401,9411,9421) ORDER BY id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(gid, '|')
    FROM (SELECT gid FROM gallery_variants
           WHERE group_id IN (9401,9411,9421)
             AND membership_state='confirmed' ORDER BY group_id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(gid, '|')
    FROM (SELECT gid FROM variant_actions
           WHERE group_id IN (9401,9411,9421) ORDER BY group_id);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(archive_gid, '|')
    FROM (SELECT archive_gid FROM archive_source_galleries
           WHERE gid IN (940001,941001,942001) ORDER BY gid);")"
  assert_eq '940001|941001|942001' "$(db_query "SELECT group_concat(source_gid, '|')
    FROM (SELECT source_gid FROM variant_jobs
           WHERE group_id IN (9401,9411,9421)
             AND job_type='discover' AND status='queued' ORDER BY group_id);")"
  assert_eq 'reference_incomplete|scope_incomplete|scoring_input_incomplete' \
    "$(db_query "SELECT group_concat(blocked_reason, '|')
      FROM current_revision_projection
      WHERE revision_gid IN (940001,941001,942001) ORDER BY revision_gid;")"
  DB_PATH="${saved_db_path}"
  MIGRATIONS_DIR="${saved_migrations_dir}"
}
run_schema27_migration_checks

# The exporter must retain all eight bounded reason samples and agree with the
# durable retryable-run/component projection.  Use distinct component counts
# so a regression that reports one row per run instead of components is caught.
db_write "WITH reasons(reason, ordinal) AS (
    VALUES ('reference_incomplete',1),('scope_incomplete',2),
           ('scoring_input_incomplete',3),('token_mismatch',4),
           ('relation_conflict',5),('cycle',6),('branch',7),
           ('multiple_terminals',8)
  )
  INSERT INTO galleries(gid,token,title,tags)
    SELECT 910100 + ordinal,'blocked-' || reason,'Blocked ' || reason,'[]'
      FROM reasons;
  WITH reasons(reason, ordinal) AS (
    VALUES ('reference_incomplete',1),('scope_incomplete',2),
           ('scoring_input_incomplete',3),('token_mismatch',4),
           ('relation_conflict',5),('cycle',6),('branch',7),
           ('multiple_terminals',8)
  )
  INSERT INTO variant_groups(source_gid,desired_rating,is_active,identity_active)
    SELECT 910100 + ordinal,11,0,0 FROM reasons;
  WITH reasons(reason, ordinal) AS (
    VALUES ('reference_incomplete',1),('scope_incomplete',2),
           ('scoring_input_incomplete',3),('token_mismatch',4),
           ('relation_conflict',5),('cycle',6),('branch',7),
           ('multiple_terminals',8)
  )
  INSERT INTO variant_jobs(job_type,group_id,source_gid,status)
    SELECT 'discover',grouped.id,grouped.source_gid,'queued'
      FROM variant_groups AS grouped WHERE grouped.source_gid BETWEEN 910101 AND 910108;
  WITH reasons(reason, ordinal) AS (
    VALUES ('reference_incomplete',1),('scope_incomplete',2),
           ('scoring_input_incomplete',3),('token_mismatch',4),
           ('relation_conflict',5),('cycle',6),('branch',7),
           ('multiple_terminals',8)
  )
  INSERT INTO variant_discovery_runs(
      group_id,job_id,matching_revision,phase,status,blocked_reason,
      blocked_component_count)
    SELECT grouped.id,job.id,${VARIANTS_MATCHING_REVISION},'publish','retryable',
      reasons.reason,reasons.ordinal
      FROM reasons
      JOIN variant_groups AS grouped ON grouped.source_gid=910100 + reasons.ordinal
      JOIN variant_jobs AS job ON job.group_id=grouped.id;"
metrics_output="$(metrics_emit_payload)"
[[ "$(grep -c '^yomiko_uploader_revision_publication_blocked{' <<<"${metrics_output}")" -eq 8 ]]
for reason in reference_incomplete scope_incomplete scoring_input_incomplete \
  token_mismatch relation_conflict cycle branch multiple_terminals; do
  blocked_line="$(grep "^yomiko_uploader_revision_publication_blocked{reason=\"${reason}\"} " <<<"${metrics_output}")"
  durable_value="$(db_query "SELECT COALESCE(SUM(MAX(blocked_component_count,1)),0)
    FROM variant_discovery_runs
    WHERE status IN ('running','retryable') AND blocked_reason='${reason}';")"
  assert_eq "${durable_value}" "${blocked_line##* }"
done

echo 'variant runtime revision-chain smoke: ok'
