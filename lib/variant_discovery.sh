#!/usr/bin/env bash

# Resumable metadata-first discovery for one leased `discover` job. Remote
# adapters are read-only; every durable transition is guarded by the owning
# run/job lease.

VARIANTS_SEARCH_REQUESTS_PER_CONTINUATION=8
VARIANTS_GDATA_BATCH_SIZE=25
VARIANTS_GDATA_BATCHES_PER_CONTINUATION=4
VARIANTS_POPULARITY_REQUESTS_PER_CONTINUATION=25
VARIANTS_ANNUAL_REDISCOVERY_DAYS=365
VARIANTS_DISCOVERY_BLOCKED_STATUS=76

variants_discovery_validate_id() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

variants_discovery_assert_lease() {
  local run_id="$1" owner="$2"
  [[ "$(db_query \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "SELECT count(*) FROM variant_discovery_runs
      WHERE id = :run_id AND status = 'running' AND lease_owner = :owner
        AND lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now');")" == 1 ]]
}

variants_discovery_stage_candidate() {
  local run_id="$1" gid="$2" token="$3" origin_json="$4" owner="$5"
  local changed

  variants_discovery_validate_id "${run_id}" || return 1
  variants_validate_gid "${gid}" || return 1
  [[ -n "${token}" ]] || return 1
  jq -e 'type == "object"' >/dev/null <<<"${origin_json}" || return 1
  changed="$(db_write \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :gid ${gid}" \
    ".parameter set :token $(db_parameter_text "${token}")" \
    ".parameter set :origin $(db_parameter_text "${origin_json}")" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "INSERT INTO variant_discovery_candidates(
       run_id, gid, token, matching_revision, origin_json, state
     )
       SELECT :run_id, :gid, :token, run.matching_revision,
              json_array(json(:origin)), 'gdata_pending'
         FROM variant_discovery_runs AS run WHERE run.id = :run_id
          AND run.status = 'running' AND run.lease_owner = :owner
          AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
     ON CONFLICT(run_id, gid, token) DO UPDATE SET
       origin_json = CASE WHEN EXISTS (
         SELECT 1 FROM json_each(variant_discovery_candidates.origin_json)
          WHERE json(value) = json(:origin)
       ) THEN variant_discovery_candidates.origin_json
       ELSE json_insert(variant_discovery_candidates.origin_json, '\$[#]',
                        json(:origin)) END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     SELECT changes();")" || return
  [[ "${changed}" == 1 ]]
}

variants_discovery_stage_seeds() {
  local run_id="$1" group_id="$2" owner="$3"
  local counts

  variants_discovery_assert_lease "${run_id}" "${owner}" || return 1

  counts="$(db_write \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :group_id ${group_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "BEGIN IMMEDIATE;
     INSERT OR IGNORE INTO variant_discovery_candidates(
       run_id, gid, token, matching_revision, origin_json, state
     )
       SELECT :run_id, member.gid, gallery.token, run.matching_revision,
              json_array(json_object('kind', 'seed', 'gid', member.gid)),
              'gdata_pending'
         FROM gallery_variants AS member
         JOIN galleries AS gallery ON gallery.gid = member.gid
         JOIN variant_discovery_runs AS run ON run.id = :run_id
        WHERE member.group_id = :group_id
          AND member.membership_state = 'confirmed'
          AND run.status = 'running' AND run.lease_owner = :owner
          AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          AND length(COALESCE(gallery.token, '')) > 0;
     -- A provider-level error is not a valid empty snapshot. Requeue every
     -- errored candidate at the next seed refresh so a transient response
     -- cannot fall through to query planning (or a permanent code 66).
     UPDATE variant_discovery_candidates
        SET state='gdata_pending', last_error_class=NULL, last_error=NULL,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE run_id=:run_id AND state='error'
        AND EXISTS (SELECT 1 FROM variant_discovery_runs AS run
                     WHERE run.id=:run_id AND run.status='running'
                       AND run.lease_owner=:owner
                       AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ','now'));
     SELECT (SELECT count(*) FROM gallery_variants
              WHERE group_id = :group_id AND membership_state = 'confirmed')
            || '|' ||
            (SELECT count(*) FROM variant_discovery_candidates AS candidate
              WHERE candidate.run_id = :run_id AND EXISTS (
                SELECT 1 FROM json_each(candidate.origin_json)
                 WHERE json_extract(value, '$.kind') = 'seed'));
     COMMIT;")" || return
  [[ "${counts%%|*}" == "${counts#*|}" && "${counts%%|*}" != 0 ]]
}

variants_discovery_stage_chain_links() {
  local run_id="$1" source_gid="$2" metadata_json="$3" owner="$4"
  local relation linked_gid linked_token origin

  for relation in first parent current; do
    linked_gid="$(jq -r --arg relation "${relation}" '.[$relation + "_gid"] // empty' <<<"${metadata_json}")"
    linked_token="$(jq -r --arg relation "${relation}" '.[$relation + "_token"] // empty' <<<"${metadata_json}")"
    [[ "${linked_gid}" =~ ^[1-9][0-9]*$ && -n "${linked_token}" ]] || continue
    [[ "${linked_gid}" != "${source_gid}" ]] || continue
    origin="$(jq -nc --argjson from_gid "${source_gid}" --arg relation "${relation}" \
      '{kind:"uploader_revision",from_gid:$from_gid,relation:$relation}')"
    variants_discovery_stage_candidate "${run_id}" "${linked_gid}" "${linked_token}" "${origin}" "${owner}" || return
  done
}

variants_discovery_pending_gdata_json() {
  local run_id="$1" origin_kind="$2"
  local origin_filter='1'
  case "${origin_kind}" in
  seed | uploader_revision)
    origin_filter="EXISTS (SELECT 1 FROM json_each(candidate.origin_json)
      WHERE json_extract(value, '$.kind') = '${origin_kind}')"
    ;;
  all) ;;
  *) return 1 ;;
  esac
  db_query \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :batch_size ${VARIANTS_GDATA_BATCH_SIZE}" \
    "SELECT COALESCE(json_group_array(json_array(gid, token)), json('[]'))
       FROM (SELECT candidate.gid, candidate.token
               FROM variant_discovery_candidates AS candidate
              WHERE candidate.run_id = :run_id
                AND candidate.state IN ('discovered', 'gdata_pending')
                AND ${origin_filter}
              ORDER BY candidate.gid, candidate.token
              LIMIT :batch_size);"
}

variants_discovery_store_gdata_entry() {
  local run_id="$1" entry_json="$2" follow_chain="$3" owner="$4"
  local gid token status metadata error
  gid="$(jq -r '.gid' <<<"${entry_json}")"
  token="$(jq -r '.token' <<<"${entry_json}")"
  status="$(jq -r '.status' <<<"${entry_json}")"
  if [[ "${status}" == ok ]]; then
    metadata="$(jq -c '.metadata' <<<"${entry_json}")"
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    db_write \
      ".parameter set :run_id ${run_id}" \
      ".parameter set :gid ${gid}" \
      ".parameter set :token $(db_parameter_text "${token}")" \
      ".parameter set :metadata $(db_parameter_text "${metadata}")" \
      ".parameter set :owner $(db_parameter_text "${owner}")" \
      "UPDATE variant_discovery_candidates
          SET gdata_json = json(:metadata),
              expunged = CASE json_extract(:metadata, '$.expunged')
                           WHEN 1 THEN 1 ELSE 0 END,
              state = 'gdata_complete', last_error_class = NULL,
              last_error = NULL,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE run_id = :run_id AND gid = :gid AND token = :token
          AND EXISTS (SELECT 1 FROM variant_discovery_runs AS run
                       WHERE run.id = :run_id AND run.status = 'running'
                         AND run.lease_owner = :owner
                         AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));" || return
    if [[ "${follow_chain}" -eq 1 ]]; then
      variants_discovery_stage_chain_links "${run_id}" "${gid}" "${metadata}" "${owner}" || return
    fi
  else
    error="$(jq -r '.error // "gdata unavailable"' <<<"${entry_json}")"
    db_write \
      ".parameter set :run_id ${run_id}" \
      ".parameter set :gid ${gid}" \
      ".parameter set :token $(db_parameter_text "${token}")" \
      ".parameter set :error $(db_parameter_text "${error}")" \
      ".parameter set :owner $(db_parameter_text "${owner}")" \
      "UPDATE variant_discovery_candidates
          SET state = 'error', last_error_class = 'permanent',
              last_error = :error,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE run_id = :run_id AND gid = :gid AND token = :token
          AND EXISTS (SELECT 1 FROM variant_discovery_runs AS run
                       WHERE run.id = :run_id AND run.status = 'running'
                         AND run.lease_owner = :owner
                         AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));" || return
  fi
}

# Fetch at most the fixed gdata continuation budget. Prints the number still
# pending for the selected origin kind.
variants_discovery_fetch_gdata() {
  local run_id="$1" origin_kind="$2" follow_chain="$3" owner="$4"
  local batches=0 requested response entry
  while ((batches < VARIANTS_GDATA_BATCHES_PER_CONTINUATION)); do
    requested="$(variants_discovery_pending_gdata_json "${run_id}" "${origin_kind}")" || return
    [[ "$(jq 'length' <<<"${requested}")" -gt 0 ]] || break
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    response="$(exh_api_get_gallery_data_batch "${requested}")" || return 75
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    jq -e --argjson requested "${requested}" '
      . as $response
      | type == "object" and (.entries | type == "array")
      and (.entries | length) == ($requested | length)
      and all(.entries[];
        (.gid | type == "number") and (.token | type == "string")
        and (.status == "ok" or .status == "error"))
      and all($requested[];
        . as $pair
        | any($response.entries[]; .gid == $pair[0] and .token == $pair[1]))
    ' >/dev/null 2>&1 <<<"${response}" || return 75
    while IFS= read -r entry; do
      variants_discovery_store_gdata_entry "${run_id}" "${entry}" "${follow_chain}" "${owner}" || return
    done < <(jq -c '.entries[]' <<<"${response}")
    batches=$((batches + 1))
  done
  requested="$(variants_discovery_pending_gdata_json "${run_id}" "${origin_kind}")" || return
  jq 'length' <<<"${requested}"
}

variants_discovery_set_phase() {
  local run_id="$1" owner="$2" phase="$3" cursor_json="${4:-null}"
  jq -e 'type == "object" or type == "null"' >/dev/null <<<"${cursor_json}" || return 1
  local changed
  changed="$(db_write \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :phase $(db_parameter_text "${phase}")" \
    ".parameter set :cursor $(db_parameter_text "${cursor_json}")" \
    "UPDATE variant_discovery_runs
        SET phase = :phase,
            cursor_json = CASE WHEN :cursor = 'null' THEN NULL ELSE json(:cursor) END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = :run_id AND status = 'running' AND lease_owner = :owner
        AND lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     SELECT changes();")" || return
  [[ "${changed}" == 1 ]]
}

variants_discovery_seed_phase() {
  local run_id="$1" group_id="$2" owner="$3"
  local pending seeds_json query_plan cursor
  variants_discovery_stage_seeds "${run_id}" "${group_id}" "${owner}" || return 65
  pending="$(variants_discovery_fetch_gdata "${run_id}" seed 1 "${owner}")" || return $?
  if [[ "${pending}" -gt 0 ]]; then
    printf '{"phase":"seed_refresh","continued":true}\n'
    return 64
  fi
  [[ "$(db_query ".parameter set :run_id ${run_id}" \
    "SELECT count(*) FROM variant_discovery_candidates
      WHERE run_id=:run_id AND state='error';")" == 0 ]] || return 75
  seeds_json="$(db_query \
    ".parameter set :run_id ${run_id}" \
    "SELECT json_object('seeds', COALESCE(json_group_array(json(gdata_json)), json('[]')))
       FROM variant_discovery_candidates AS candidate
      WHERE candidate.run_id = :run_id AND candidate.gdata_json IS NOT NULL
        AND EXISTS (SELECT 1 FROM json_each(candidate.origin_json)
                     WHERE json_extract(value, '$.kind') = 'seed');")" || return
  [[ "$(jq '.seeds | length' <<<"${seeds_json}")" -gt 0 ]] || return 66
  query_plan="$(printf '%s' "${seeds_json}" | variants_matching_plan_queries)" || return
  cursor="$(jq -c '. + {query_index:0,mode:"normal",page:0}' <<<"${query_plan}")" || return
  variants_discovery_set_phase "${run_id}" "${owner}" chain_walk "${cursor}" || return
  printf '{"phase":"chain_walk","continued":false}\n'
}

variants_discovery_chain_phase() {
  local run_id="$1" owner="$2" cursor="$3" pending
  pending="$(variants_discovery_fetch_gdata "${run_id}" uploader_revision 1 "${owner}")" || return $?
  if [[ "${pending}" -gt 0 ]]; then
    printf '{"phase":"chain_walk","continued":true}\n'
    return 64
  fi
  [[ "$(db_query ".parameter set :run_id ${run_id}" \
    "SELECT count(*) FROM variant_discovery_candidates
      WHERE run_id=:run_id AND state='error';")" == 0 ]] || return 75
  variants_discovery_set_phase "${run_id}" "${owner}" search "${cursor}" || return
  printf '{"phase":"search","continued":false}\n'
}

variants_discovery_search_throttle() {
  sleep 3
}

variants_discovery_search_phase() {
  local run_id="$1" owner="$2" cursor="$3"
  local request_count=0 query_index mode page query_entry query response terminal next_page origin result gid token query_count
  query_count="$(jq '.queries | length' <<<"${cursor}")"
  query_index="$(jq -r '.query_index' <<<"${cursor}")"
  mode="$(jq -r '.mode' <<<"${cursor}")"
  page="$(jq -r '.page' <<<"${cursor}")"
  while ((query_index < query_count && request_count < VARIANTS_SEARCH_REQUESTS_PER_CONTINUATION)); do
    query_entry="$(jq -c --argjson index "${query_index}" '.queries[$index]' <<<"${cursor}")"
    query="$(jq -r '.query' <<<"${query_entry}")"
    ((request_count == 0)) || variants_discovery_search_throttle
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    response="$(exh_search_gallery "${query}" "${mode}" "${page}")" || return 75
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    while IFS= read -r result; do
      gid="$(jq -r '.gid' <<<"${result}")"
      token="$(jq -r '.token' <<<"${result}")"
      origin="$(jq -nc --arg query "${query}" --arg mode "${mode}" \
        --argjson page "${page}" --argjson seeds "$(jq -c '.origins' <<<"${query_entry}")" \
        '{kind:"search",query:$query,mode:$mode,page:$page,query_origins:$seeds}')"
      variants_discovery_stage_candidate "${run_id}" "${gid}" "${token}" "${origin}" "${owner}" || return
    done < <(jq -c '.results[]' <<<"${response}")
    terminal="$(jq -r '.terminal' <<<"${response}")"
    if [[ "${terminal}" == true ]]; then
      if [[ "${mode}" == normal ]]; then
        mode=expunged
        page=0
      else
        query_index=$((query_index + 1))
        mode=normal
        page=0
      fi
    else
      next_page="$(jq -r '.next_page' <<<"${response}")"
      [[ "${next_page}" =~ ^[0-9]+$ && "${next_page}" -gt "${page}" ]] || return 67
      page="${next_page}"
    fi
    request_count=$((request_count + 1))
  done
  cursor="$(jq -c --argjson query_index "${query_index}" --arg mode "${mode}" \
    --argjson page "${page}" '.query_index=$query_index | .mode=$mode | .page=$page' <<<"${cursor}")"
  if ((query_index >= query_count)); then
    variants_discovery_set_phase "${run_id}" "${owner}" gdata "${cursor}" || return
    printf '{"phase":"gdata","continued":false,"search_requests":%s}\n' "${request_count}"
  else
    variants_discovery_set_phase "${run_id}" "${owner}" search "${cursor}" || return
    jq -nc --argjson requests "${request_count}" '{phase:"search",continued:true,search_requests:$requests}'
    return 64
  fi
}

variants_discovery_gdata_phase() {
  local run_id="$1" owner="$2" cursor="$3" pending
  pending="$(variants_discovery_fetch_gdata "${run_id}" all 1 "${owner}")" || return $?
  if [[ "${pending}" -gt 0 ]]; then
    printf '{"phase":"gdata","continued":true}\n'
    return 64
  fi
  variants_discovery_set_phase "${run_id}" "${owner}" popularity "${cursor}" || return
  printf '{"phase":"popularity","continued":false}\n'
}

variants_discovery_popularity_phase() {
  local run_id="$1" owner="$2" cursor="$3"
  local count=0 candidate gid token popularity fetched_at remaining
  while ((count < VARIANTS_POPULARITY_REQUESTS_PER_CONTINUATION)); do
    candidate="$(db_query \
      ".parameter set :run_id ${run_id}" \
      "SELECT json_object('gid', gid, 'token', token)
         FROM variant_discovery_candidates
        WHERE run_id = :run_id AND state = 'gdata_complete'
        ORDER BY gid, token LIMIT 1;")" || return
    [[ -n "${candidate}" ]] || break
    gid="$(jq -r '.gid' <<<"${candidate}")"
    token="$(jq -r '.token' <<<"${candidate}")"
    fetched_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    popularity="$(exh_get_gallery_popularity "${gid}" "${token}" "${fetched_at}")" || return 75
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    db_write \
      ".parameter set :run_id ${run_id}" \
      ".parameter set :gid ${gid}" \
      ".parameter set :token $(db_parameter_text "${token}")" \
      ".parameter set :popularity $(db_parameter_text "${popularity}")" \
      ".parameter set :owner $(db_parameter_text "${owner}")" \
      "UPDATE variant_discovery_candidates
          SET popularity_json = json(:popularity), state = 'complete',
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE run_id = :run_id AND gid = :gid AND token = :token
          AND state = 'gdata_complete'
          AND EXISTS (SELECT 1 FROM variant_discovery_runs AS run
                       WHERE run.id = :run_id AND run.status = 'running'
                         AND run.lease_owner = :owner
                         AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));" || return
    count=$((count + 1))
  done
  remaining="$(db_query ".parameter set :run_id ${run_id}" \
    "SELECT count(*) FROM variant_discovery_candidates
      WHERE run_id = :run_id AND state = 'gdata_complete';")" || return
  if [[ "${remaining}" -gt 0 ]]; then
    jq -nc --argjson requests "${count}" '{phase:"popularity",continued:true,popularity_requests:$requests}'
    return 64
  fi
  variants_discovery_set_phase "${run_id}" "${owner}" publish "${cursor}" || return
  jq -nc --argjson requests "${count}" '{phase:"publish",continued:false,popularity_requests:$requests}'
}

# Freeze matching evidence before publication. The feedback source remains the
# comparison anchor while all confirmed members contribute search queries.
variants_discovery_build_evidence() {
  local run_id="$1" group_id="$2" owner="$3"
  local source_json chain_json candidate_json payload evidence gid token

  variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
  source_json="$(db_query \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :group_id ${group_id}" \
    "SELECT COALESCE(
       (SELECT json_patch(candidate.gdata_json,
                 COALESCE(candidate.popularity_json, json('{}')))
          FROM variant_discovery_candidates AS candidate
          JOIN variant_groups AS grouped ON grouped.source_gid = candidate.gid
         WHERE candidate.run_id = :run_id AND grouped.id = :group_id
           AND candidate.state = 'complete'
         ORDER BY candidate.token LIMIT 1),
       (SELECT json_object(
          'gid', gallery.gid, 'token', gallery.token,
          'title', gallery.title, 'title_jpn', gallery.title_jpn,
          'filecount', gallery.file_count, 'expunged', gallery.expunged,
          'tags', CASE WHEN json_valid(gallery.tags) THEN json(gallery.tags)
                       ELSE json('[]') END,
          'rating', gallery.rating,
          'uploader', gallery.uploader, 'posted', gallery.posted,
          'filesize', gallery.filesize, 'thumb', gallery.thumb,
          'first_gid', gallery.first_gid, 'first_token', gallery.first_token,
          'parent_gid', gallery.parent_gid, 'parent_token', gallery.parent_token,
          'current_gid', gallery.current_gid, 'current_token', gallery.current_token,
          'favorite_count', gallery.favorite_count,
          'rating_count', gallery.rating_count,
          'popularity_fetched_at', gallery.popularity_fetched_at)
          FROM galleries AS gallery JOIN variant_groups AS grouped
            ON grouped.source_gid = gallery.gid WHERE grouped.id = :group_id)
     );")" || return
  [[ -n "${source_json}" ]] || return 66

  chain_json="$(db_query \
    ".parameter set :run_id ${run_id}" \
    "SELECT COALESCE(json_group_array(gid), json('[]')) FROM (
       SELECT DISTINCT candidate.gid
         FROM variant_discovery_candidates AS candidate,
              json_each(candidate.origin_json) AS origin
        WHERE candidate.run_id = :run_id
          AND json_extract(origin.value, '$.kind') = 'uploader_revision'
        ORDER BY candidate.gid
     );")" || return

  while IFS= read -r candidate_json; do
    gid="$(jq -r '.gid' <<<"${candidate_json}")"
    token="$(jq -r '.token' <<<"${candidate_json}")"
    payload="$(jq -nc \
      --argjson source "${source_json}" \
      --argjson candidate "$(jq -c '.snapshot' <<<"${candidate_json}")" \
      --argjson chain_gids "${chain_json}" \
      --argjson origins "$(jq -c '.origins' <<<"${candidate_json}")" \
      '{source:$source,candidate:$candidate,chain_gids:$chain_gids,origins:$origins}')" || return
    evidence="$(printf '%s' "${payload}" | variants_matching_evidence_json)" || return
    variants_discovery_assert_lease "${run_id}" "${owner}" || return 1
    db_write \
      ".parameter set :run_id ${run_id}" \
      ".parameter set :gid ${gid}" \
      ".parameter set :token $(db_parameter_text "${token}")" \
      ".parameter set :evidence $(db_parameter_text "${evidence}")" \
      ".parameter set :owner $(db_parameter_text "${owner}")" \
      "UPDATE variant_discovery_candidates
          SET evidence_json = json(:evidence),
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE run_id = :run_id AND gid = :gid AND token = :token
          AND state = 'complete'
          AND EXISTS (SELECT 1 FROM variant_discovery_runs AS run
                       WHERE run.id = :run_id AND run.status = 'running'
                         AND run.lease_owner = :owner
                         AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));" || return
  done < <(db_query \
    ".parameter set :run_id ${run_id}" \
    "SELECT json_object(
       'gid', gid, 'token', token, 'origins', json(origin_json),
       'snapshot', json(json_patch(gdata_json,
                     COALESCE(popularity_json, json('{}')))))
       FROM variant_discovery_candidates
      WHERE run_id = :run_id AND state = 'complete'
      ORDER BY gid, token;")
}

# Return the first bounded reason for a staged publication that cannot be
# committed.  This runs after the publication transaction has rolled back, so
# it only inspects the durable provider snapshot and never mutates live rows.
variants_discovery_publish_block_reason() {
  local run_id="$1"
  local output_mode="${2:-reason}"
  db_query \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :mode $(db_parameter_text "${output_mode}")" \
    "WITH candidates AS (
       SELECT candidate.* FROM variant_discovery_candidates AS candidate
        WHERE candidate.run_id=:run_id AND candidate.state='complete'
     ), rows AS (
       SELECT candidate.gid, candidate.token,
              json_extract(candidate.gdata_json,'$.first_gid') AS first_gid,
              json_extract(candidate.gdata_json,'$.first_token') AS first_token,
              json_extract(candidate.gdata_json,'$.parent_gid') AS parent_gid,
              json_extract(candidate.gdata_json,'$.parent_token') AS parent_token,
              json_extract(candidate.gdata_json,'$.current_gid') AS current_gid,
              json_extract(candidate.gdata_json,'$.current_token') AS current_token,
              json_extract(candidate.gdata_json,'$.filecount') AS file_count,
              json_extract(candidate.gdata_json,'$.tags') AS tags,
              json_extract(candidate.popularity_json,'$.favorite_count') AS favorite_count,
              json_extract(candidate.popularity_json,'$.rating_count') AS rating_count
         FROM candidates AS candidate
       UNION ALL
       SELECT gallery.gid, gallery.token, gallery.first_gid, gallery.first_token,
              gallery.parent_gid, gallery.parent_token, gallery.current_gid,
              gallery.current_token, gallery.file_count, gallery.tags,
              gallery.favorite_count, gallery.rating_count
         FROM galleries AS gallery
        WHERE NOT EXISTS (SELECT 1 FROM candidates AS candidate
                           WHERE candidate.gid=gallery.gid)
     ), relation_pairs AS (
       SELECT gid AS source_gid, 'first' AS relation, first_gid AS target_gid,
              first_token AS target_token FROM rows
       UNION ALL SELECT gid, 'parent', parent_gid, parent_token FROM rows
       UNION ALL SELECT gid, 'current', current_gid, current_token FROM rows
     ), relation_facts AS (
       SELECT pair.*,
              CASE WHEN (pair.target_gid IS NULL) = (pair.target_token IS NULL)
                   THEN 1 ELSE 0 END AS pair_complete,
              CASE WHEN pair.target_gid IS NULL THEN 1
                   WHEN EXISTS (SELECT 1 FROM rows AS target
                                 WHERE target.gid=pair.target_gid) THEN 1 ELSE 0 END
                AS target_fetched,
              CASE WHEN pair.target_gid IS NULL THEN 1
                   WHEN EXISTS (SELECT 1 FROM rows AS target
                                 WHERE target.gid=pair.target_gid
                                   AND target.token IS pair.target_token) THEN 1 ELSE 0 END
                AS token_matched
         FROM relation_pairs AS pair
     ), valid_edges AS (
       SELECT CASE WHEN relation='parent' THEN target_gid ELSE source_gid END AS from_gid,
              CASE WHEN relation='parent' THEN source_gid ELSE target_gid END AS to_gid,
              relation
         FROM relation_facts
        WHERE relation IN ('parent','current') AND pair_complete=1
          AND (target_gid IS NULL OR (target_fetched=1 AND token_matched=1))
          AND target_gid IS NOT NULL
     ), undirected(from_gid,to_gid) AS (
       SELECT from_gid,to_gid FROM valid_edges
       UNION
       SELECT to_gid,from_gid FROM valid_edges
     ), walk(root_gid,gid) AS (
       SELECT gid,gid FROM rows
       UNION
       SELECT walk.root_gid,edge.to_gid
         FROM walk JOIN undirected AS edge ON edge.from_gid=walk.gid
     ), component_map AS (
       SELECT gid,MIN(root_gid) AS component_gid FROM walk GROUP BY gid
     ), component_members AS (
       SELECT gid,component_gid FROM component_map
     ), candidate_components AS (
       SELECT DISTINCT map.component_gid
         FROM candidates AS candidate
         JOIN component_map AS map ON map.gid=candidate.gid
     ), cycle_reach(start_gid,gid) AS (
       SELECT from_gid,to_gid FROM valid_edges
       UNION
       SELECT reach.start_gid,edge.to_gid
         FROM cycle_reach AS reach JOIN valid_edges AS edge
           ON edge.from_gid=reach.gid
     ), component_stats AS (
       SELECT member.component_gid,
              COUNT(*) AS component_size,
              SUM(CASE WHEN NOT EXISTS (
                    SELECT 1 FROM valid_edges AS edge
                     WHERE edge.from_gid=member.gid) THEN 1 ELSE 0 END)
                AS terminal_count,
              MAX(CASE WHEN EXISTS (
                    SELECT 1 FROM relation_facts AS fact
                     JOIN component_members AS source
                       ON source.gid=fact.source_gid
                      AND source.component_gid=member.component_gid
                    WHERE fact.pair_complete=0
                       OR (fact.target_gid IS NOT NULL
                           AND (fact.target_fetched=0 OR fact.token_matched=0)))
                       THEN 1 ELSE 0 END) AS has_broken_relation,
              MAX(CASE WHEN EXISTS (
                    SELECT 1 FROM cycle_reach AS reach
                     JOIN component_members AS cycle_member
                       ON cycle_member.component_gid=member.component_gid
                      AND cycle_member.gid=reach.start_gid
                    WHERE reach.start_gid=reach.gid)
                       THEN 1 ELSE 0 END) AS has_cycle,
              MAX(CASE WHEN (SELECT COUNT(*) FROM valid_edges AS edge
                              WHERE edge.relation='parent'
                                AND edge.from_gid=member.gid)>1
                       THEN 1 ELSE 0 END) AS has_parent_branch,
              MAX(CASE WHEN (SELECT COUNT(*) FROM valid_edges AS edge
                              WHERE edge.relation='current'
                                AND edge.from_gid=member.gid)>1
                       THEN 1 ELSE 0 END) AS has_current_branch
         FROM component_members AS member
        GROUP BY member.component_gid
     ), component_current_inputs AS (
       SELECT DISTINCT map.component_gid
         FROM candidates AS candidate
         JOIN component_map AS map ON map.gid=candidate.gid
        WHERE EXISTS (SELECT 1 FROM json_each(candidate.origin_json)
                       WHERE json_extract(value,'$.kind') IN
                             ('seed','uploader_revision'))
     ), terminal_rows AS (
       SELECT rows.*, map.component_gid
         FROM rows
         JOIN component_map AS map ON map.gid=rows.gid
        WHERE NOT EXISTS (SELECT 1 FROM valid_edges AS edge
                           WHERE edge.from_gid=rows.gid)
     ), reasons(reason, priority) AS (
       SELECT 'reference_incomplete', 5 WHERE EXISTS (
         SELECT 1 FROM variant_discovery_candidates
          WHERE run_id=:run_id AND state='error')
       UNION ALL SELECT 'token_mismatch', 10 WHERE EXISTS (
         SELECT 1 FROM candidates GROUP BY gid HAVING COUNT(DISTINCT token)>1)
       UNION ALL SELECT 'relation_conflict', 20 WHERE EXISTS (
         SELECT 1 FROM candidates
          WHERE (json_extract(gdata_json,'$.first_gid') IS NULL) IS NOT
                    (json_extract(gdata_json,'$.first_token') IS NULL)
             OR (json_extract(gdata_json,'$.parent_gid') IS NULL) IS NOT
                    (json_extract(gdata_json,'$.parent_token') IS NULL)
             OR (json_extract(gdata_json,'$.current_gid') IS NULL) IS NOT
                    (json_extract(gdata_json,'$.current_token') IS NULL))
       UNION ALL SELECT 'token_mismatch', 30 WHERE EXISTS (
         SELECT 1 FROM candidates AS candidate
          JOIN galleries AS target
            ON target.gid IN (json_extract(candidate.gdata_json,'$.first_gid'),
                              json_extract(candidate.gdata_json,'$.parent_gid'),
                              json_extract(candidate.gdata_json,'$.current_gid'))
          WHERE (target.gid=json_extract(candidate.gdata_json,'$.first_gid')
                 AND target.token IS NOT json_extract(candidate.gdata_json,'$.first_token'))
             OR (target.gid=json_extract(candidate.gdata_json,'$.parent_gid')
                 AND target.token IS NOT json_extract(candidate.gdata_json,'$.parent_token'))
             OR (target.gid=json_extract(candidate.gdata_json,'$.current_gid')
                 AND target.token IS NOT json_extract(candidate.gdata_json,'$.current_token')))
       UNION ALL SELECT 'token_mismatch', 31 WHERE EXISTS (
         SELECT 1 FROM candidates AS candidate
          JOIN galleries AS existing ON existing.gid = candidate.gid
         WHERE existing.token IS NOT candidate.token
            OR existing.token IS NOT json_extract(candidate.gdata_json,'$.token'))
       UNION ALL SELECT 'reference_incomplete', 40 WHERE EXISTS (
         SELECT 1 FROM candidates AS candidate
          JOIN json_each(json_array(
            json_object('gid',json_extract(candidate.gdata_json,'$.first_gid'),
                        'token',json_extract(candidate.gdata_json,'$.first_token')),
            json_object('gid',json_extract(candidate.gdata_json,'$.parent_gid'),
                        'token',json_extract(candidate.gdata_json,'$.parent_token')),
            json_object('gid',json_extract(candidate.gdata_json,'$.current_gid'),
                        'token',json_extract(candidate.gdata_json,'$.current_token')))) AS relation
         WHERE json_extract(relation.value,'$.gid') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM candidates AS staged
                            WHERE staged.gid=json_extract(relation.value,'$.gid'))
           AND NOT EXISTS (SELECT 1 FROM galleries AS fetched
                            WHERE fetched.gid=json_extract(relation.value,'$.gid')))
       UNION ALL SELECT 'cycle', 41 WHERE EXISTS (
         SELECT 1 FROM component_stats AS stats
          WHERE stats.has_cycle=1
            AND stats.component_gid IN (SELECT component_gid FROM candidate_components))
       UNION ALL SELECT 'branch', 42 WHERE EXISTS (
         SELECT 1 FROM component_stats AS stats
          WHERE (stats.has_parent_branch=1 OR stats.has_current_branch=1)
            AND stats.component_gid IN (SELECT component_gid FROM candidate_components))
       UNION ALL SELECT 'multiple_terminals', 43 WHERE EXISTS (
         SELECT 1 FROM component_stats AS stats
          WHERE stats.terminal_count<>1
            AND stats.component_gid IN (SELECT component_gid FROM candidate_components))
       UNION ALL SELECT 'relation_conflict', 44 WHERE EXISTS (
         SELECT 1
           FROM relation_facts AS first_fact
           JOIN component_map AS source ON source.gid=first_fact.source_gid
           JOIN component_map AS target ON target.gid=first_fact.target_gid
           JOIN component_stats AS stats ON stats.component_gid=source.component_gid
          WHERE first_fact.relation='first'
            AND first_fact.pair_complete=1
            AND stats.component_size > 1
            AND source.component_gid IN (SELECT component_gid FROM candidate_components)
            AND source.component_gid<>target.component_gid)
       UNION ALL SELECT 'scoring_input_incomplete', 50 WHERE EXISTS (
         SELECT 1 FROM terminal_rows AS terminal
          WHERE terminal.component_gid IN
                  (SELECT component_gid FROM component_current_inputs)
            AND (terminal.file_count IS NULL
              OR terminal.favorite_count IS NULL
              OR terminal.rating_count IS NULL))
       UNION ALL SELECT 'scope_incomplete', 60 WHERE EXISTS (
         SELECT 1 FROM terminal_rows AS terminal
          WHERE terminal.component_gid IN
                  (SELECT component_gid FROM component_current_inputs)
            AND NOT (EXISTS (SELECT 1 FROM json_each(terminal.tags)
                              WHERE value='language:chinese')
                 AND EXISTS (SELECT 1 FROM json_each(terminal.tags)
                              WHERE value='other:tankoubon')))
     ), reason_counts(reason, blocked_count) AS (
       SELECT 'reference_incomplete', COUNT(*)
         FROM variant_discovery_candidates
        WHERE run_id=:run_id AND state='error'
       UNION ALL
       SELECT 'token_mismatch', COUNT(*)
         FROM (
           SELECT map.component_gid
             FROM relation_facts AS fact
             JOIN component_map AS map ON map.gid=fact.source_gid
            WHERE map.component_gid IN (SELECT component_gid FROM candidate_components)
              AND fact.token_matched=0
           UNION
           SELECT map.component_gid
             FROM candidates AS candidate
             JOIN component_map AS map ON map.gid=candidate.gid
             JOIN galleries AS existing ON existing.gid=candidate.gid
            WHERE map.component_gid IN (SELECT component_gid FROM candidate_components)
              AND (existing.token IS NOT candidate.token
                OR existing.token IS NOT json_extract(candidate.gdata_json,'$.token'))
         ) AS token_conflicts
       UNION ALL
       SELECT 'reference_incomplete', COUNT(DISTINCT map.component_gid)
         FROM relation_facts AS fact
         JOIN component_map AS map ON map.gid=fact.source_gid
        WHERE map.component_gid IN (SELECT component_gid FROM candidate_components)
          AND fact.target_gid IS NOT NULL AND fact.target_fetched=0
       UNION ALL
       SELECT 'relation_conflict', COUNT(*)
         FROM component_stats AS stats
        WHERE stats.component_gid IN (SELECT component_gid FROM candidate_components)
          AND stats.has_broken_relation=1
       UNION ALL
       SELECT 'cycle', COUNT(*)
         FROM component_stats AS stats
        WHERE stats.component_gid IN (SELECT component_gid FROM candidate_components)
          AND stats.has_cycle=1
       UNION ALL
       SELECT 'branch', COUNT(*)
         FROM component_stats AS stats
        WHERE stats.component_gid IN (SELECT component_gid FROM candidate_components)
          AND (stats.has_parent_branch=1 OR stats.has_current_branch=1)
       UNION ALL
       SELECT 'multiple_terminals', COUNT(*)
         FROM component_stats AS stats
        WHERE stats.component_gid IN (SELECT component_gid FROM candidate_components)
          AND stats.terminal_count<>1
       UNION ALL
       SELECT 'scoring_input_incomplete', COUNT(DISTINCT terminal.component_gid)
         FROM terminal_rows AS terminal
        WHERE terminal.component_gid IN
                (SELECT component_gid FROM component_current_inputs)
          AND (terminal.file_count IS NULL
            OR terminal.favorite_count IS NULL
            OR terminal.rating_count IS NULL)
       UNION ALL
       SELECT 'scope_incomplete', COUNT(DISTINCT terminal.component_gid)
         FROM terminal_rows AS terminal
        WHERE terminal.component_gid IN
                (SELECT component_gid FROM component_current_inputs)
          AND NOT (EXISTS (SELECT 1 FROM json_each(terminal.tags)
                            WHERE value='language:chinese')
               AND EXISTS (SELECT 1 FROM json_each(terminal.tags)
                            WHERE value='other:tankoubon'))
     ), selected AS (
       SELECT reason FROM reasons ORDER BY priority LIMIT 1
     )
       SELECT CASE WHEN :mode='count' THEN CAST(MAX(1, COALESCE((
                SELECT blocked_count FROM reason_counts
                 WHERE reason=selected.reason), 1)) AS TEXT)
                 ELSE selected.reason END
       FROM selected;"
}

variants_discovery_reset_blocked_run() {
  local run_id="$1" job_id="$2" reason="$3" owner="$4"
  local blocked_count
  blocked_count="$(variants_discovery_publish_block_reason "${run_id}" count)" || return
  [[ "${blocked_count}" =~ ^[1-9][0-9]*$ ]] || blocked_count=1
  db_write \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :reason $(db_parameter_text "${reason}")" \
    ".parameter set :blocked_count ${blocked_count}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "BEGIN IMMEDIATE;
     DELETE FROM variant_discovery_candidates WHERE run_id=:run_id;
     UPDATE variant_discovery_runs
        SET status='retryable', phase='seed_refresh', cursor_json=NULL,
            blocked_reason=:reason, blocked_component_count=:blocked_count,
            lease_owner=NULL, lease_expires_at=NULL,
            last_error_class='transient', last_error=:reason,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:run_id AND status='running' AND lease_owner=:owner;
     UPDATE variant_jobs
        SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','+300 seconds'),
            last_error_class='transient', last_error=:reason,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:job_id AND status='leased' AND lease_owner=:owner;
     COMMIT;" \
    >/dev/null
}

# Return the bidirectional identity/revision closure seeded by staged candidates.
# Publish calls this inside BEGIN IMMEDIATE so group and relation membership are
# fresh for the same atomic transaction that consumes the projection.
variants_discovery_publish_scope_sql() {
  cat <<'SQL'
     -- Seed from publication candidates and close over alternating identity
     -- and revision edges. This includes identities attached to a terminal
     -- reached through a predecessor/current revision chain.
     CREATE TEMP TABLE variant_publish_scope_gid(gid INTEGER PRIMARY KEY);
     WITH RECURSIVE identity_link(source_gid,target_gid) AS MATERIALIZED (
       SELECT grouped.source_gid,member.gid
         FROM variant_groups AS grouped
         JOIN gallery_variants AS member ON member.group_id=grouped.id
        WHERE grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND grouped.source_gid IS NOT NULL
       UNION
       SELECT member.gid,grouped.source_gid
         FROM variant_groups AS grouped
         JOIN gallery_variants AS member ON member.group_id=grouped.id
        WHERE grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND grouped.source_gid IS NOT NULL
       UNION
       SELECT low_gid,high_gid FROM gallery_identity_pairs
       UNION
       SELECT high_gid,low_gid FROM gallery_identity_pairs
       UNION
       SELECT grouped.source_gid,review.candidate_gid
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
        WHERE review.review_type='candidate_identity'
          AND grouped.source_gid IS NOT NULL AND review.candidate_gid IS NOT NULL
       UNION
       SELECT review.candidate_gid,grouped.source_gid
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
        WHERE review.review_type='candidate_identity'
          AND grouped.source_gid IS NOT NULL AND review.candidate_gid IS NOT NULL
       UNION
       SELECT grouped.source_gid,CAST(choice.value AS INTEGER)
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
         JOIN json_each(review.choices_json) AS choice
        WHERE review.review_type='winner'
          AND grouped.source_gid IS NOT NULL
          AND json_type(choice.value)='integer'
       UNION
       SELECT CAST(choice.value AS INTEGER),grouped.source_gid
         FROM variant_reviews AS review
         JOIN variant_groups AS grouped ON grouped.id=review.group_id
         JOIN json_each(review.choices_json) AS choice
        WHERE review.review_type='winner'
          AND grouped.source_gid IS NOT NULL
          AND json_type(choice.value)='integer'
       UNION
       SELECT source.gid,target.gid
         FROM galleries AS source
         JOIN galleries AS target
           ON target.gid=source.parent_gid AND target.token IS source.parent_token
        WHERE source.parent_gid IS NOT NULL AND source.parent_token IS NOT NULL
       UNION
       SELECT target.gid,source.gid
         FROM galleries AS source
         JOIN galleries AS target
           ON target.gid=source.parent_gid AND target.token IS source.parent_token
        WHERE source.parent_gid IS NOT NULL AND source.parent_token IS NOT NULL
       UNION
       SELECT source.gid,target.gid
         FROM galleries AS source
         JOIN galleries AS target
           ON target.gid=source.current_gid AND target.token IS source.current_token
        WHERE source.current_gid IS NOT NULL AND source.current_token IS NOT NULL
       UNION
       SELECT target.gid,source.gid
         FROM galleries AS source
         JOIN galleries AS target
           ON target.gid=source.current_gid AND target.token IS source.current_token
        WHERE source.current_gid IS NOT NULL AND source.current_token IS NOT NULL
     ), identity_walk(gid) AS (
       SELECT gid FROM variant_publish_candidates
       UNION
       SELECT grouped.source_gid FROM variant_groups AS grouped
        WHERE grouped.id=:group_id AND grouped.source_gid IS NOT NULL
       UNION
       SELECT identity_link.target_gid
         FROM identity_walk
         JOIN identity_link ON identity_link.source_gid=identity_walk.gid
     )
     INSERT OR IGNORE INTO variant_publish_scope_gid(gid)
       SELECT gid FROM identity_walk WHERE gid IS NOT NULL;
SQL
}

# Publish a completed discovery snapshot and finish its leased job atomically.
variants_discovery_publish() {
  local run_id="$1" job_id="$2" group_id="$3" owner="$4"
  local preflight_reason

  variants_discovery_build_evidence "${run_id}" "${group_id}" "${owner}" || return $?
  preflight_reason="$(variants_discovery_publish_block_reason "${run_id}")" || return 1
  if [[ -n "${preflight_reason}" ]]; then
    return "${VARIANTS_DISCOVERY_BLOCKED_STATUS}"
  fi
  db_write \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :group_id ${group_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :revision ${VARIANTS_MATCHING_REVISION}" \
    ".parameter set :annual_days ${VARIANTS_ANNUAL_REDISCOVERY_DAYS}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_publish_context(
       run_id INTEGER PRIMARY KEY, policy_revision_id INTEGER NOT NULL
     );
     INSERT INTO variant_publish_context(run_id, policy_revision_id)
       SELECT run.id, policy.id
         FROM variant_discovery_runs AS run
         JOIN variant_jobs AS job ON job.id = run.job_id
         JOIN variant_groups AS grouped ON grouped.id = run.group_id
         JOIN variant_policy_revisions AS policy ON policy.is_active = 1
        WHERE run.id = :run_id AND run.job_id = :job_id
          AND run.group_id = :group_id AND run.phase = 'publish'
          AND run.status = 'running' AND run.lease_owner = :owner
          AND run.lease_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          AND run.matching_revision = :revision
          AND job.status = 'leased' AND job.lease_owner = :owner
          AND grouped.identity_active = 1;
     CREATE TEMP TABLE variant_publish_guard(
       singleton INTEGER NOT NULL CHECK(singleton = 1)
     );
     INSERT INTO variant_publish_guard(singleton)
       SELECT count(*) FROM variant_publish_context;
     CREATE TEMP TABLE variant_publish_candidates AS
       SELECT candidate.*
         FROM variant_discovery_candidates AS candidate
        WHERE candidate.run_id = :run_id AND candidate.state = 'complete';
     -- The preflight runs before BEGIN IMMEDIATE. Recheck the frozen seed
     -- membership under the writer lock so a group edit cannot publish a
     -- snapshot built from a stale member set.
     CREATE TEMP TABLE variant_publish_member_guard(
       conflict_count INTEGER NOT NULL CHECK (conflict_count = 0)
     );
     INSERT INTO variant_publish_member_guard(conflict_count)
       SELECT CASE WHEN
         COALESCE((SELECT json_group_array(gid) FROM (
           SELECT member.gid
             FROM gallery_variants AS member
            WHERE member.group_id = :group_id
              AND member.membership_state = 'confirmed'
            ORDER BY member.gid)), '[]') IS NOT
         COALESCE((SELECT json_group_array(gid) FROM (
           SELECT DISTINCT candidate.gid
             FROM variant_publish_candidates AS candidate
            WHERE EXISTS (SELECT 1 FROM json_each(candidate.origin_json)
                           WHERE json_extract(value,'$.kind') = 'seed')
            ORDER BY candidate.gid)), '[]')
         THEN 1 ELSE 0 END
        FROM variant_publish_context;
     -- A GID is identified by its token.  Choosing MIN(token) here would
     -- silently publish a mixed provider snapshot; reject the complete run
     -- instead and let the worker refresh it from the provider.
     CREATE TEMP TABLE variant_publish_token_guard(
       conflict_count INTEGER NOT NULL CHECK (conflict_count = 0)
     );
     INSERT INTO variant_publish_token_guard(conflict_count)
       SELECT count(*)
         FROM (
           SELECT gid
             FROM variant_publish_candidates
            GROUP BY gid
            HAVING COUNT(DISTINCT token) > 1
           UNION ALL
           SELECT candidate.gid
             FROM variant_publish_candidates AS candidate
             JOIN galleries AS existing ON existing.gid = candidate.gid
            WHERE existing.token IS NOT candidate.token
               OR existing.token IS NOT
                    json_extract(candidate.gdata_json, '$.token')
         );
     INSERT INTO galleries(
       gid, token, title, title_jpn, file_count, expunged, tags, rating,
       uploader, posted, filesize, thumb, first_gid, first_token,
       parent_gid, parent_token, current_gid, current_token,
       favorite_count, rating_count, popularity_fetched_at)
       SELECT candidate.gid,
              json_extract(candidate.gdata_json, '$.token'),
              json_extract(candidate.gdata_json, '$.title'),
              json_extract(candidate.gdata_json, '$.title_jpn'),
              json_extract(candidate.gdata_json, '$.filecount'),
              CASE json_extract(candidate.gdata_json, '$.expunged')
                WHEN 1 THEN 1 ELSE 0 END,
              json(json_extract(candidate.gdata_json, '$.tags')),
              json_extract(candidate.gdata_json, '$.rating'),
              json_extract(candidate.gdata_json, '$.uploader'),
              json_extract(candidate.gdata_json, '$.posted'),
              json_extract(candidate.gdata_json, '$.filesize'),
              json_extract(candidate.gdata_json, '$.thumb'),
              json_extract(candidate.gdata_json, '$.first_gid'),
              json_extract(candidate.gdata_json, '$.first_token'),
              json_extract(candidate.gdata_json, '$.parent_gid'),
              json_extract(candidate.gdata_json, '$.parent_token'),
              json_extract(candidate.gdata_json, '$.current_gid'),
              json_extract(candidate.gdata_json, '$.current_token'),
              json_extract(candidate.popularity_json, '$.favorite_count'),
              json_extract(candidate.popularity_json, '$.rating_count'),
              json_extract(candidate.popularity_json, '$.popularity_fetched_at')
         FROM variant_publish_candidates AS candidate
        WHERE EXISTS (SELECT 1 FROM variant_publish_context)
     ON CONFLICT(gid) DO UPDATE SET
       token = excluded.token, title = excluded.title,
       title_jpn = excluded.title_jpn, file_count = excluded.file_count,
       expunged = excluded.expunged, tags = excluded.tags,
       rating = excluded.rating,
       uploader = excluded.uploader, posted = excluded.posted,
       filesize = excluded.filesize, thumb = excluded.thumb,
       first_gid = excluded.first_gid, first_token = excluded.first_token,
       parent_gid = excluded.parent_gid, parent_token = excluded.parent_token,
       current_gid = excluded.current_gid, current_token = excluded.current_token,
       favorite_count = excluded.favorite_count,
       rating_count = excluded.rating_count,
       popularity_fetched_at = excluded.popularity_fetched_at,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

     $(variants_discovery_publish_scope_sql)
     CREATE TEMP TABLE variant_publish_revision_projection AS
     $(variants_revision_projection_sql status_publish)
     SELECT revision_gid,terminal_gid,component_gid,component_size,ready,
            is_terminal,blocked_reason,component_gids
       FROM revision_projection;

     -- The same bounded graph projection validates the staged snapshot and the live
     -- database.  No current projection is changed until this guard passes.
     CREATE TEMP TABLE variant_publish_projection_guard(
       conflict_count INTEGER NOT NULL CHECK (conflict_count = 0)
     );
     INSERT INTO variant_publish_projection_guard(conflict_count)
       SELECT
         (SELECT COUNT(*) FROM variant_publish_candidates AS candidate
           WHERE json_extract(candidate.gdata_json, '$.token') IS NOT candidate.token)
         + (SELECT COUNT(*) FROM variant_publish_candidates AS candidate
           WHERE (json_extract(candidate.gdata_json, '$.title') IS NULL
               OR json_extract(candidate.gdata_json, '$.filecount') IS NULL
               OR json_extract(candidate.gdata_json, '$.tags') IS NULL)
             AND EXISTS (SELECT 1 FROM json_each(candidate.origin_json)
                          WHERE json_extract(value,'$.kind') IN ('seed','uploader_revision')))
         + (SELECT COUNT(*) FROM variant_publish_revision_projection AS revision_projection
             JOIN variant_publish_candidates AS candidate
               ON candidate.gid = revision_projection.revision_gid
            WHERE revision_projection.ready = 0);

     CREATE TEMP TABLE IF NOT EXISTS identity_reconcile_extra_gid(
       gid INTEGER PRIMARY KEY
     );
     INSERT OR IGNORE INTO identity_reconcile_extra_gid(gid)
       SELECT gid FROM variant_publish_candidates;
     -- The first reconcile runs before publish components have owners.  Keep
     -- an empty table available for its shared publish-scoped state builder;
     -- the final reconcile below runs after this table is populated.
     CREATE TEMP TABLE variant_publish_component_owner(
       component_gid INTEGER PRIMARY KEY,
       owner_group_id INTEGER NOT NULL
     );
     $(variants_identity_reconcile_sql publish)
     CREATE TEMP TABLE variant_publish_identity AS
       SELECT candidate.gid,
              CASE WHEN source_class.class_gid=candidate_class.class_gid THEN (
                SELECT MIN(pair.current_review_id)
                  FROM gallery_identity_pairs AS pair
                  JOIN variant_reviews AS support ON support.id=pair.current_review_id
                  JOIN identity_gid_class AS support_low ON support_low.gid=pair.low_gid
                  JOIN identity_gid_class AS support_high ON support_high.gid=pair.high_gid
                 WHERE support.decision='same_book'
                   AND support_low.class_gid=source_class.class_gid
                   AND support_high.class_gid=source_class.class_gid
              ) ELSE class_pair.supporting_review_id END AS current_review_id,
              CASE WHEN source_class.class_gid=candidate_class.class_gid
                   THEN 'same_book' ELSE class_pair.decision END AS decision,
              review.resolved_at,
              0 AS uploader_revision_link
         FROM variant_publish_candidates AS candidate
         JOIN variant_groups AS grouped ON grouped.id = :group_id
         JOIN identity_gid_class AS source_class ON source_class.gid=grouped.source_gid
         JOIN identity_gid_class AS candidate_class ON candidate_class.gid=candidate.gid
         LEFT JOIN identity_revision_projection AS source_revision
           ON source_revision.revision_gid=grouped.source_gid
         LEFT JOIN identity_revision_projection AS candidate_revision
           ON candidate_revision.revision_gid=candidate.gid
         LEFT JOIN identity_class_pair AS class_pair
           ON class_pair.low_class_gid=MIN(source_class.class_gid,candidate_class.class_gid)
          AND class_pair.high_class_gid=MAX(source_class.class_gid,candidate_class.class_gid)
         LEFT JOIN variant_reviews AS review ON review.id=CASE
           WHEN source_class.class_gid=candidate_class.class_gid THEN (
             SELECT MIN(pair.current_review_id)
               FROM gallery_identity_pairs AS pair
               JOIN variant_reviews AS support ON support.id=pair.current_review_id
               JOIN identity_gid_class AS support_low ON support_low.gid=pair.low_gid
               JOIN identity_gid_class AS support_high ON support_high.gid=pair.high_gid
              WHERE support.decision='same_book'
                AND support_low.class_gid=source_class.class_gid
                AND support_high.class_gid=source_class.class_gid
           ) ELSE class_pair.supporting_review_id END
        WHERE candidate.gid <> grouped.source_gid
          -- A provider-declared uploader-revision component is one identity
          -- unit, not a manual same-book decision. Cross-component identity
          -- decisions remain represented by the class-pair projection.
          AND NOT (source_revision.component_gid IS NOT NULL
                   AND source_revision.component_gid=candidate_revision.component_gid)
          AND (source_class.class_gid=candidate_class.class_gid
               OR class_pair.decision='different_book');
     -- A stored same-book decision must already have merged active groups.
     -- Treat any violation as corruption and roll back the complete snapshot.
     CREATE TEMP TABLE variant_publish_identity_guard(
       conflict_count INTEGER NOT NULL CHECK (conflict_count = 0)
     );
     INSERT INTO variant_publish_identity_guard(conflict_count)
       SELECT count(*)
         FROM variant_publish_identity AS identity
         JOIN gallery_variants AS other ON other.gid = identity.gid
         JOIN variant_groups AS other_group
           ON other_group.id = other.group_id AND other_group.identity_active = 1
        WHERE identity.decision = 'same_book'
          AND other.membership_state = 'confirmed'
          AND other.group_id <> :group_id
          -- A shared ready provider component can legitimately still be
          -- present in a second legacy group; the owner normalization below
          -- merges that group atomically. Only an unrelated cross-chain
          -- confirmed member is a publication invariant violation.
          AND NOT EXISTS (
            SELECT 1
              FROM variant_publish_revision_projection AS candidate_revision
              JOIN variant_publish_revision_projection AS other_revision
                ON other_revision.component_gid = candidate_revision.component_gid
             WHERE candidate_revision.revision_gid = identity.gid
               AND other_revision.revision_gid = other.gid);

     INSERT INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, matching_revision, decided_at)
       SELECT :group_id, candidate.gid,
              CASE
                WHEN candidate.gid = (SELECT source_gid FROM variant_groups
                                       WHERE id = :group_id) THEN 'confirmed'
                WHEN identity.decision = 'same_book' THEN 'confirmed'
                WHEN EXISTS (
                  SELECT 1
                    FROM variant_publish_revision_projection AS source_revision
                    JOIN variant_publish_revision_projection AS candidate_revision
                      ON candidate_revision.component_gid=source_revision.component_gid
                   WHERE source_revision.revision_gid=(SELECT source_gid
                                                    FROM variant_groups
                                                   WHERE id=:group_id)
                     AND candidate_revision.revision_gid=candidate.gid
                     AND candidate_revision.ready=1
                     AND candidate_revision.is_terminal=1)
                  THEN 'confirmed'
                WHEN identity.decision = 'different_book' THEN 'rejected'
                WHEN EXISTS (
                  SELECT 1 FROM variant_publish_revision_projection AS revision_projection
                   WHERE revision_projection.revision_gid = candidate.gid
                     AND revision_projection.ready = 1
                     AND revision_projection.is_terminal = 0)
                  THEN 'rejected'
                WHEN json_extract(candidate.evidence_json, '$.in_scope') = 1
                  THEN 'candidate'
                ELSE 'rejected' END,
              CASE WHEN identity.decision IS NULL THEN 'automatic' ELSE 'manual' END,
              json_extract(candidate.evidence_json, '$.score'),
              CASE WHEN identity.decision IS NULL
                   THEN candidate.evidence_json
                   ELSE json_set(candidate.evidence_json,
                     '$.manual_decision', identity.decision,
                     '$.manual_review_id', identity.current_review_id,
                     '$.manual_decided_at', identity.resolved_at)
                   END,
              :revision,
              CASE WHEN identity.decision IS NOT NULL THEN identity.resolved_at
                   WHEN json_extract(candidate.evidence_json, '$.category') = 'independent'
                     THEN NULL
                   ELSE strftime('%Y-%m-%dT%H:%M:%SZ', 'now') END
         FROM variant_publish_candidates AS candidate
         LEFT JOIN variant_publish_identity AS identity ON identity.gid = candidate.gid
       WHERE candidate.evidence_json IS NOT NULL
          AND EXISTS (SELECT 1 FROM variant_publish_context)
     ON CONFLICT(group_id, gid) DO UPDATE SET
       membership_state = CASE
         WHEN excluded.decision_source = 'manual' THEN excluded.membership_state
         WHEN gallery_variants.decision_source = 'automatic'
           AND gallery_variants.membership_state = 'confirmed'
           AND gallery_variants.gid <> (SELECT source_gid FROM variant_groups
                                         WHERE id = :group_id)
           AND NOT EXISTS (
             SELECT 1 FROM variant_publish_revision_projection AS revision_projection
              WHERE revision_projection.revision_gid = gallery_variants.gid
                AND revision_projection.ready = 1)
           AND excluded.membership_state <> 'confirmed'
           THEN excluded.membership_state
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN gallery_variants.membership_state
         ELSE excluded.membership_state END,
       decision_source = CASE
         WHEN excluded.decision_source = 'manual' THEN 'manual'
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN gallery_variants.decision_source
         ELSE excluded.decision_source END,
       match_score = CASE
         WHEN excluded.decision_source = 'manual' THEN excluded.match_score
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN gallery_variants.match_score
         ELSE excluded.match_score END,
       evidence_json = CASE
         WHEN excluded.decision_source = 'manual' THEN excluded.evidence_json
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN json_set(gallery_variants.evidence_json, '$.latest_discovery',
                         json(excluded.evidence_json))
         ELSE excluded.evidence_json END,
       matching_revision = excluded.matching_revision,
       decided_at = CASE
         WHEN excluded.decision_source = 'manual' THEN excluded.decided_at
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN gallery_variants.decided_at
         ELSE COALESCE(excluded.decided_at, gallery_variants.decided_at) END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

     -- Normalize every active group touched by a refreshed uploader-revision
     -- component.  The provider component is the identity unit: a terminal
     -- is promoted once, while predecessor rows remain exact-GID history.
     CREATE TEMP TABLE variant_publish_components(
       component_gid INTEGER PRIMARY KEY,
       terminal_gid INTEGER NOT NULL
     );
     INSERT INTO variant_publish_components(component_gid, terminal_gid)
       SELECT revision_projection.component_gid,
              MIN(revision_projection.terminal_gid)
         FROM variant_publish_revision_projection AS revision_projection
         JOIN variant_publish_candidates AS candidate
           ON candidate.gid = revision_projection.revision_gid
        WHERE revision_projection.ready = 1
        GROUP BY revision_projection.component_gid;
     CREATE TEMP TABLE variant_publish_affected_groups(
       group_id INTEGER PRIMARY KEY
     );
     INSERT INTO variant_publish_affected_groups(group_id)
       SELECT DISTINCT member.group_id
         FROM gallery_variants AS member
         JOIN variant_publish_revision_projection AS revision_projection
           ON revision_projection.revision_gid = member.gid
         JOIN variant_publish_components AS component
           ON component.component_gid = revision_projection.component_gid
        WHERE member.membership_state = 'confirmed';
     INSERT OR IGNORE INTO variant_publish_affected_groups(group_id)
       SELECT :group_id;
     DELETE FROM variant_publish_component_owner;
     INSERT INTO variant_publish_component_owner(component_gid, owner_group_id)
       SELECT component_gid, owner_group_id
         FROM (
           SELECT component.component_gid,
                  grouped.id AS owner_group_id,
                  ROW_NUMBER() OVER (
                    PARTITION BY component.component_gid
                    ORDER BY grouped.identity_active DESC, grouped.id) AS rank
             FROM variant_publish_components AS component
             JOIN variant_publish_revision_projection AS revision_projection
               ON revision_projection.component_gid = component.component_gid
             JOIN gallery_variants AS member
               ON member.gid = revision_projection.revision_gid
             JOIN variant_groups AS grouped ON grouped.id = member.group_id
            WHERE member.membership_state = 'confirmed'
         ) AS ranked
        WHERE rank = 1;
     CREATE TEMP TABLE variant_publish_group_owner(
       group_id INTEGER PRIMARY KEY,
       owner_group_id INTEGER NOT NULL
     );
     -- A group can contain several provider components.  If two groups share
     -- one component, all of their components belong to the same identity
     -- owner; reducing each component independently would leave the second
     -- group's other members behind in an active group.  Compute connected
     -- group sets first, then map every component and group to one survivor.
     WITH RECURSIVE group_components(group_id, component_gid) AS (
       SELECT DISTINCT affected.group_id, revision_projection.component_gid
         FROM variant_publish_affected_groups AS affected
         JOIN gallery_variants AS member
           ON member.group_id = affected.group_id
         JOIN variant_publish_revision_projection AS revision_projection
           ON revision_projection.revision_gid = member.gid
         JOIN variant_publish_components AS component
           ON component.component_gid = revision_projection.component_gid
        WHERE member.membership_state = 'confirmed'
     ), group_links(group_id, other_group_id) AS (
       SELECT left_group.group_id, right_group.group_id
         FROM group_components AS left_group
         JOIN group_components AS right_group
           ON right_group.component_gid = left_group.component_gid
          AND right_group.group_id <> left_group.group_id
       UNION
       SELECT right_group.group_id, left_group.group_id
         FROM group_components AS left_group
         JOIN group_components AS right_group
           ON right_group.component_gid = left_group.component_gid
          AND right_group.group_id <> left_group.group_id
     ), reachable(root_group, group_id) AS (
       SELECT group_id, group_id FROM variant_publish_affected_groups
       UNION
       SELECT reachable.root_group, links.other_group_id
         FROM reachable
         JOIN group_links AS links ON links.group_id = reachable.group_id
     ), group_sets(group_id, root_group) AS (
       SELECT group_id, MIN(root_group)
         FROM reachable
        GROUP BY group_id
     ), owners(root_group, owner_group_id) AS (
       SELECT sets.root_group,
              COALESCE(MIN(CASE WHEN grouped.identity_active = 1
                                THEN sets.group_id END), MIN(sets.group_id))
         FROM group_sets AS sets
         JOIN variant_groups AS grouped ON grouped.id = sets.group_id
        GROUP BY sets.root_group
     )
     INSERT INTO variant_publish_group_owner(group_id, owner_group_id)
       SELECT sets.group_id, owners.owner_group_id
         FROM group_sets AS sets
         JOIN owners ON owners.root_group = sets.root_group;
     UPDATE variant_publish_component_owner AS component_owner
        SET owner_group_id = (
              SELECT MIN(group_owner.owner_group_id)
                FROM gallery_variants AS member
                JOIN variant_publish_revision_projection AS revision_projection
                  ON revision_projection.revision_gid = member.gid
                JOIN variant_publish_group_owner AS group_owner
                  ON group_owner.group_id = member.group_id
               WHERE member.membership_state = 'confirmed'
                 AND revision_projection.component_gid = component_owner.component_gid);
     -- Components can form a path through a group that also owns a second
     -- component (A={X,Y}, B={Y,Z}).  Close that bipartite projection once
     -- more: the first pass discovers the shared Y owner, this pass carries
     -- that survivor across B to Z.  The recursive group-set calculation is
     -- still authoritative; this is a defensive materialization of its
     -- transitive result before membership copying begins.
     UPDATE variant_publish_group_owner AS group_owner
        SET owner_group_id = (
              SELECT MIN(component_owner.owner_group_id)
                FROM variant_publish_component_owner AS component_owner
                JOIN variant_publish_revision_projection AS revision_projection
                  ON revision_projection.component_gid = component_owner.component_gid
                JOIN gallery_variants AS member
                  ON member.gid = revision_projection.revision_gid
               WHERE member.group_id = group_owner.group_id
                 AND member.membership_state = 'confirmed')
      WHERE EXISTS (
              SELECT 1 FROM variant_publish_component_owner AS component_owner
               JOIN variant_publish_revision_projection AS revision_projection
                 ON revision_projection.component_gid = component_owner.component_gid
               JOIN gallery_variants AS member
                 ON member.gid = revision_projection.revision_gid
              WHERE member.group_id = group_owner.group_id
                AND member.membership_state = 'confirmed');
     UPDATE variant_publish_component_owner AS component_owner
        SET owner_group_id = (
              SELECT MIN(group_owner.owner_group_id)
                FROM gallery_variants AS member
                JOIN variant_publish_revision_projection AS revision_projection
                  ON revision_projection.revision_gid = member.gid
                JOIN variant_publish_group_owner AS group_owner
                  ON group_owner.group_id = member.group_id
               WHERE member.membership_state = 'confirmed'
                 AND revision_projection.component_gid = component_owner.component_gid);
     INSERT OR IGNORE INTO variant_publish_group_owner(group_id, owner_group_id)
       SELECT :group_id, :group_id;
     CREATE TEMP TABLE variant_publish_feedback_owner(
       owner_group_id INTEGER PRIMARY KEY,
       desired_rating INTEGER NOT NULL,
       latest_feedback_at TEXT
     );
     INSERT INTO variant_publish_feedback_owner(
       owner_group_id, desired_rating, latest_feedback_at)
       SELECT owner_group_id, desired_rating, latest_feedback_at
         FROM (
           SELECT map.owner_group_id, grouped.desired_rating,
                  grouped.latest_feedback_at,
                  ROW_NUMBER() OVER (
                    PARTITION BY map.owner_group_id
                    ORDER BY COALESCE(grouped.latest_feedback_at, '') DESC,
                             grouped.id DESC) AS rank
             FROM variant_publish_group_owner AS map
             JOIN variant_groups AS grouped ON grouped.id = map.group_id
         ) AS ranked
        WHERE rank = 1;
     UPDATE variant_groups AS grouped
        SET desired_rating = feedback.desired_rating,
            latest_feedback_at = feedback.latest_feedback_at,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
       FROM variant_publish_feedback_owner AS feedback
      WHERE grouped.id = feedback.owner_group_id;

     -- Retain a deterministic identity owner when a provider component joins
     -- two previously separate groups.  Inactive groups remain audit history.
     UPDATE variant_groups
        SET identity_active = 0,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE identity_active = 1
        AND id IN (SELECT group_id FROM variant_publish_affected_groups)
        AND id NOT IN (SELECT owner_group_id FROM variant_publish_component_owner);
     -- Copy the other active group's confirmed cross-chain members to the
     -- deterministic owner before the old group is left as history.
     INSERT OR IGNORE INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, variant_score, variant_state, decided_at,
       matching_revision)
       SELECT owner.owner_group_id, member.gid, member.membership_state,
              member.decision_source, member.match_score, member.evidence_json,
              member.variant_score, member.variant_state, member.decided_at,
              member.matching_revision
         FROM gallery_variants AS member
         JOIN variant_publish_revision_projection AS revision_projection
           ON revision_projection.revision_gid = member.gid
         JOIN variant_publish_component_owner AS owner
           ON owner.component_gid = revision_projection.component_gid
         WHERE member.membership_state = 'confirmed'
          AND member.group_id <> owner.owner_group_id
       ON CONFLICT(group_id, gid) DO UPDATE SET
         membership_state = CASE
           WHEN gallery_variants.membership_state = 'confirmed'
             OR excluded.membership_state = 'confirmed' THEN 'confirmed'
           ELSE gallery_variants.membership_state END,
         decision_source = CASE
           WHEN gallery_variants.decision_source = 'manual'
             OR excluded.decision_source = 'manual' THEN 'manual'
           ELSE gallery_variants.decision_source END,
         match_score = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.match_score
           WHEN excluded.decision_source = 'manual' THEN excluded.match_score
           ELSE COALESCE(excluded.match_score, gallery_variants.match_score) END,
         evidence_json = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.evidence_json
           WHEN excluded.decision_source = 'manual' THEN excluded.evidence_json
           ELSE COALESCE(excluded.evidence_json, gallery_variants.evidence_json) END,
         variant_score = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.variant_score
           WHEN excluded.decision_source = 'manual' THEN excluded.variant_score
           ELSE COALESCE(excluded.variant_score, gallery_variants.variant_score) END,
         variant_state = COALESCE(gallery_variants.variant_state, excluded.variant_state),
         decided_at = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.decided_at
           WHEN excluded.decision_source = 'manual' THEN excluded.decided_at
           ELSE COALESCE(excluded.decided_at, gallery_variants.decided_at) END,
         matching_revision = excluded.matching_revision,
         updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now');
     -- A losing group may own components that were not staged in this
     -- discovery (for example B={Y,Z} while the run refreshed Y).  Copy the
     -- complete confirmed losing-group membership through the connected
     -- group owner, otherwise deactivating B would orphan Z's active truth.
     INSERT OR IGNORE INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, variant_score, variant_state, decided_at,
       matching_revision)
       SELECT group_owner.owner_group_id, member.gid, member.membership_state,
              member.decision_source, member.match_score, member.evidence_json,
              member.variant_score, member.variant_state, member.decided_at,
              member.matching_revision
         FROM gallery_variants AS member
         JOIN variant_publish_group_owner AS group_owner
           ON group_owner.group_id = member.group_id
         WHERE member.membership_state = 'confirmed'
          AND member.group_id <> group_owner.owner_group_id
       ON CONFLICT(group_id, gid) DO UPDATE SET
         membership_state = CASE
           WHEN gallery_variants.membership_state = 'confirmed'
             OR excluded.membership_state = 'confirmed' THEN 'confirmed'
           ELSE gallery_variants.membership_state END,
         decision_source = CASE
           WHEN gallery_variants.decision_source = 'manual'
             OR excluded.decision_source = 'manual' THEN 'manual'
           ELSE gallery_variants.decision_source END,
         match_score = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.match_score
           WHEN excluded.decision_source = 'manual' THEN excluded.match_score
           ELSE COALESCE(excluded.match_score, gallery_variants.match_score) END,
         evidence_json = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.evidence_json
           WHEN excluded.decision_source = 'manual' THEN excluded.evidence_json
           ELSE COALESCE(excluded.evidence_json, gallery_variants.evidence_json) END,
         variant_score = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.variant_score
           WHEN excluded.decision_source = 'manual' THEN excluded.variant_score
           ELSE COALESCE(excluded.variant_score, gallery_variants.variant_score) END,
         variant_state = COALESCE(gallery_variants.variant_state, excluded.variant_state),
         decided_at = CASE
           WHEN gallery_variants.decision_source = 'manual' THEN gallery_variants.decided_at
           WHEN excluded.decision_source = 'manual' THEN excluded.decided_at
           ELSE COALESCE(excluded.decided_at, gallery_variants.decided_at) END,
         matching_revision = excluded.matching_revision,
         updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now');
     UPDATE variant_groups
        SET canonical_gid = NULL,
            active_evaluation_id = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT owner_group_id FROM variant_publish_component_owner)
        AND EXISTS (
          SELECT 1 FROM gallery_variants AS member
           JOIN variant_publish_revision_projection AS revision_projection
             ON revision_projection.revision_gid = member.gid
           JOIN variant_publish_components AS component
             ON component.component_gid = revision_projection.component_gid
          WHERE member.group_id = variant_groups.id
            AND member.membership_state = 'confirmed'
            AND revision_projection.revision_gid <> revision_projection.terminal_gid
        );
     INSERT OR IGNORE INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, matching_revision, decided_at)
       SELECT owner.owner_group_id, component.terminal_gid, 'confirmed',
              'automatic', 0,
              json_object('kind','uploader_revision_terminal'),
              :revision, strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM variant_publish_component_owner AS owner
         JOIN variant_publish_components AS component
           ON component.component_gid = owner.component_gid;
     UPDATE gallery_variants AS member
        SET membership_state = CASE
              WHEN member.gid = revision_projection.terminal_gid THEN 'confirmed'
              ELSE 'rejected' END,
            decision_source = CASE WHEN member.gid = revision_projection.terminal_gid
                                   THEN member.decision_source ELSE 'automatic' END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
       FROM variant_publish_revision_projection AS revision_projection
       JOIN variant_publish_components AS component
         ON component.component_gid = revision_projection.component_gid
       JOIN variant_publish_component_owner AS owner
         ON owner.component_gid = component.component_gid
      WHERE member.group_id = owner.owner_group_id
        AND member.gid = revision_projection.revision_gid
        AND member.membership_state <> CASE
              WHEN member.gid = revision_projection.terminal_gid THEN 'confirmed'
              ELSE 'rejected' END;

     -- Only pairs touching a refreshed revision component need projection.
     -- Untouched pairs remain in place; the temporary relation still folds
     -- aliases in touched components and keeps the newest colliding review.
     CREATE TEMP TABLE variant_publish_pair_source AS
       SELECT pair.low_gid,pair.high_gid,pair.current_review_id
         FROM gallery_identity_pairs AS pair
        WHERE EXISTS (
          SELECT 1 FROM variant_publish_revision_projection AS revision_projection
           JOIN variant_publish_components AS component
             ON component.component_gid=revision_projection.component_gid
          WHERE revision_projection.revision_gid=pair.low_gid)
           OR EXISTS (
          SELECT 1 FROM variant_publish_revision_projection AS revision_projection
           JOIN variant_publish_components AS component
             ON component.component_gid=revision_projection.component_gid
          WHERE revision_projection.revision_gid=pair.high_gid);
     CREATE TEMP TABLE variant_publish_pairs(
       low_gid INTEGER NOT NULL,
       high_gid INTEGER NOT NULL,
       current_review_id INTEGER NOT NULL,
       PRIMARY KEY(low_gid, high_gid)
     );
     WITH normalized AS (
       SELECT MIN(COALESCE(low_revision.terminal_gid, pair.low_gid),
                  COALESCE(high_revision.terminal_gid, pair.high_gid)) AS low_gid,
              MAX(COALESCE(low_revision.terminal_gid, pair.low_gid),
                  COALESCE(high_revision.terminal_gid, pair.high_gid)) AS high_gid,
              pair.current_review_id,
              ROW_NUMBER() OVER (
                PARTITION BY
                  MIN(COALESCE(low_revision.terminal_gid, pair.low_gid),
                      COALESCE(high_revision.terminal_gid, pair.high_gid)),
                  MAX(COALESCE(low_revision.terminal_gid, pair.low_gid),
                      COALESCE(high_revision.terminal_gid, pair.high_gid))
                ORDER BY pair.current_review_id DESC) AS rank
         FROM variant_publish_pair_source AS pair
         LEFT JOIN variant_publish_revision_projection AS low_revision
           ON low_revision.revision_gid = pair.low_gid AND low_revision.ready = 1
         LEFT JOIN variant_publish_revision_projection AS high_revision
           ON high_revision.revision_gid = pair.high_gid AND high_revision.ready = 1
        WHERE COALESCE(low_revision.terminal_gid, pair.low_gid) <
              COALESCE(high_revision.terminal_gid, pair.high_gid)
     )
     INSERT INTO variant_publish_pairs(low_gid, high_gid, current_review_id)
       SELECT low_gid, high_gid, current_review_id
         FROM normalized WHERE rank = 1;
     DELETE FROM gallery_identity_pairs
      WHERE EXISTS (
        SELECT 1 FROM variant_publish_pair_source AS affected
         WHERE affected.low_gid=gallery_identity_pairs.low_gid
           AND affected.high_gid=gallery_identity_pairs.high_gid);
     INSERT INTO gallery_identity_pairs(low_gid, high_gid, current_review_id)
       SELECT low_gid, high_gid, current_review_id
         FROM variant_publish_pairs
        WHERE 1
       ON CONFLICT(low_gid,high_gid) DO UPDATE SET
         current_review_id=MAX(gallery_identity_pairs.current_review_id,
                               excluded.current_review_id);
     UPDATE variant_groups
        SET source_gid = COALESCE((
              SELECT revision_projection.terminal_gid
                FROM variant_publish_revision_projection AS revision_projection
               WHERE revision_projection.revision_gid = variant_groups.source_gid
                 AND revision_projection.ready = 1), source_gid),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id IN (SELECT owner_group_id FROM variant_publish_component_owner);
     UPDATE variant_canonical_decisions AS decision
        SET canonical_gid = COALESCE((
              SELECT revision_projection.terminal_gid
                FROM variant_publish_revision_projection AS revision_projection
               WHERE revision_projection.revision_gid = decision.canonical_gid
                 AND revision_projection.ready = 1), decision.canonical_gid)
      WHERE decision.status = 'active'
        AND decision.group_id IN (SELECT owner_group_id
                                    FROM variant_publish_component_owner);
     -- A manual canonical decision follows the current uploader-revision
     -- projection. Refresh its member fingerprint after terminal
     -- normalization so the evaluator does not mistake this intentional
     -- replacement for an unrelated member-set edit.
     UPDATE variant_canonical_decisions AS decision
        SET member_fingerprint = (
              SELECT json_group_array(member.gid)
                FROM gallery_variants AS member
               WHERE member.group_id = decision.group_id
                 AND member.membership_state = 'confirmed'
               ORDER BY member.gid)
      WHERE decision.status = 'active'
        AND decision.group_id IN (SELECT owner_group_id
                                    FROM variant_publish_component_owner);
     UPDATE variant_groups
        SET canonical_gid = (
              SELECT decision.canonical_gid
                FROM variant_canonical_decisions AS decision
               WHERE decision.group_id = variant_groups.id
                 AND decision.status = 'active'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id IN (SELECT owner_group_id FROM variant_publish_component_owner);
     UPDATE gallery_variants AS member
        SET variant_state = CASE
              WHEN member.gid = grouped.canonical_gid THEN 'canonical'
              ELSE 'alternate' END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
       FROM variant_groups AS grouped
      WHERE grouped.id IN (SELECT owner_group_id
                             FROM variant_publish_component_owner)
        AND member.group_id = grouped.id
        AND member.membership_state = 'confirmed'
        AND grouped.canonical_gid IS NOT NULL;
     UPDATE gallery_variants AS member
        SET variant_state = 'undetermined',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE member.group_id IN (SELECT owner_group_id
                                  FROM variant_publish_component_owner)
        AND member.membership_state <> 'confirmed';
     UPDATE galleries
        SET self_rating = (
              SELECT grouped.desired_rating
                FROM variant_groups AS grouped
                JOIN gallery_variants AS member ON member.group_id = grouped.id
               WHERE member.gid = galleries.gid
                 AND member.membership_state = 'confirmed'
                 AND grouped.id IN (SELECT owner_group_id
                                      FROM variant_publish_component_owner)),
            feedbacked_at = (
              SELECT grouped.latest_feedback_at
                FROM variant_groups AS grouped
                JOIN gallery_variants AS member ON member.group_id = grouped.id
               WHERE member.gid = galleries.gid
                 AND member.membership_state = 'confirmed'
                 AND grouped.id IN (SELECT owner_group_id
                                      FROM variant_publish_component_owner)),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE gid IN (
        SELECT member.gid FROM gallery_variants AS member
         WHERE member.membership_state='confirmed'
           AND member.group_id IN (SELECT owner_group_id
                                     FROM variant_publish_component_owner));

     -- Coalesce every current job for an affected group before changing its
     -- group owner.  Releasing duplicate leases first makes the survivor's
     -- group/source update safe against the partial unique job index; a stale
     -- worker can only finish a cancelled row, which is deliberately a no-op.
     CREATE TEMP TABLE variant_publish_job_rank(
       job_id INTEGER PRIMARY KEY,
       owner_group_id INTEGER NOT NULL,
       rank INTEGER NOT NULL
     );
     INSERT INTO variant_publish_job_rank(job_id, owner_group_id, rank)
       SELECT job.id, owner.owner_group_id,
              ROW_NUMBER() OVER (
                PARTITION BY job.job_type, owner.owner_group_id
                ORDER BY CASE job.status WHEN 'leased' THEN 0 ELSE 1 END,
                         job.id DESC)
         FROM variant_jobs AS job
         JOIN variant_publish_group_owner AS owner
           ON owner.group_id = job.group_id
        WHERE job.status IN ('queued', 'leased');
     UPDATE variant_discovery_runs AS run
        SET status = 'cancelled', lease_owner = NULL,
            lease_expires_at = NULL, completed_at = NULL,
            last_error_class = NULL,
            last_error = 'uploader revision publication coalesced duplicate job',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE run.job_id IN (
        SELECT job_id FROM variant_publish_job_rank WHERE rank > 1)
        AND run.status IN ('running', 'retryable');
     DELETE FROM variant_discovery_candidates
      WHERE run_id IN (
        SELECT run.id FROM variant_discovery_runs AS run
         JOIN variant_publish_job_rank AS ranked ON ranked.job_id = run.job_id
        WHERE ranked.rank > 1);
     UPDATE variant_jobs AS job
        SET status = 'cancelled', lease_owner = NULL,
            lease_expires_at = NULL,
            completed_at = COALESCE(job.completed_at,
                                    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_error_class = NULL,
            last_error = 'uploader revision publication coalesced duplicate job',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE job.id IN (
        SELECT job_id FROM variant_publish_job_rank WHERE rank > 1);
     UPDATE variant_jobs AS job
        SET group_id = ranked.owner_group_id,
            source_gid = (SELECT grouped.source_gid FROM variant_groups AS grouped
                           WHERE grouped.id = ranked.owner_group_id),
            expected_evaluation_id = CASE WHEN job.job_type = 'evaluate'
                                          THEN NULL ELSE job.expected_evaluation_id END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
       FROM variant_publish_job_rank AS ranked
      WHERE ranked.job_id = job.id AND ranked.rank = 1;
     UPDATE variant_discovery_runs AS run
        SET group_id = (SELECT ranked.owner_group_id
                          FROM variant_publish_job_rank AS ranked
                         WHERE ranked.job_id = run.job_id AND ranked.rank = 1),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE EXISTS (SELECT 1 FROM variant_publish_job_rank AS ranked
                     WHERE ranked.job_id = run.job_id AND ranked.rank = 1);

     -- Current rating/favourite work follows the terminal, but an in-flight
     -- request is first fenced off as superseded.  Its old lease can no
     -- longer finish after this transaction; a fresh terminal action is then
     -- inserted with the same desired state.  H@H and archive cleanup remain
     -- exact-GID history and are intentionally excluded.
     CREATE TEMP TABLE variant_publish_action_retarget(
       action_id INTEGER PRIMARY KEY,
       terminal_gid INTEGER NOT NULL,
       owner_group_id INTEGER NOT NULL,
       evaluation_id INTEGER,
       action_type TEXT NOT NULL,
       desired_value TEXT NOT NULL,
       policy_revision_id INTEGER NOT NULL
     );
     INSERT INTO variant_publish_action_retarget(
       action_id, terminal_gid, owner_group_id, evaluation_id,
       action_type, desired_value, policy_revision_id)
       SELECT action.id, revision_projection.terminal_gid, owner.owner_group_id,
              action.evaluation_id, action.action_type, action.desired_value,
              action.policy_revision_id
         FROM variant_actions AS action
         JOIN variant_publish_revision_projection AS revision_projection
           ON revision_projection.revision_gid = action.gid
          AND revision_projection.ready = 1
          AND revision_projection.revision_gid <> revision_projection.terminal_gid
         JOIN gallery_variants AS terminal_member
           ON terminal_member.gid = revision_projection.terminal_gid
          AND terminal_member.membership_state = 'confirmed'
         JOIN variant_publish_group_owner AS owner
           ON owner.group_id = terminal_member.group_id
        WHERE action.action_type IN ('rating', 'favorite_move', 'favorite_remove')
          AND action.status IN ('pending', 'retryable_error',
                               'configuration_error', 'in_flight');
     UPDATE variant_actions AS action
        SET status = 'superseded', lease_owner = NULL,
            lease_expires_at = NULL, lease_job_id = NULL,
            completed_at = COALESCE(action.completed_at,
                                    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE action.id IN (SELECT action_id FROM variant_publish_action_retarget);
     INSERT INTO variant_actions(
       group_id, evaluation_id, gid, action_type, desired_value,
       policy_revision_id, status)
       SELECT retarget.owner_group_id, retarget.evaluation_id,
              retarget.terminal_gid, retarget.action_type,
              retarget.desired_value, retarget.policy_revision_id, 'pending'
         FROM variant_publish_action_retarget AS retarget
        WHERE 1
      ON CONFLICT(action_type, gid, desired_value, policy_revision_id)
      DO UPDATE SET
        group_id = excluded.group_id,
        evaluation_id = excluded.evaluation_id,
        status = CASE WHEN variant_actions.status IN ('superseded', 'permanent_error')
                      THEN 'pending' ELSE variant_actions.status END,
        completed_at = CASE WHEN variant_actions.status IN ('superseded', 'permanent_error')
                           THEN NULL ELSE variant_actions.completed_at END,
        available_at = CASE WHEN variant_actions.status IN ('superseded', 'permanent_error')
                           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                           ELSE variant_actions.available_at END,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

     -- Feedback precedes discovery, so newly confirmed members inherit the
     -- current class rating in the same transaction that publishes identity.
     CREATE TEMP TABLE variant_publish_rating_projection AS
       SELECT member.gid, grouped.desired_rating,
              grouped.latest_feedback_at
        FROM variant_groups AS grouped
         JOIN gallery_variants AS member ON member.group_id=grouped.id
        WHERE grouped.id IN (SELECT owner_group_id
                               FROM variant_publish_group_owner)
          AND grouped.identity_active=1
          AND member.membership_state='confirmed'
          AND EXISTS (SELECT 1 FROM variant_publish_context);
     UPDATE galleries
        SET self_rating=(SELECT projection.desired_rating
                           FROM variant_publish_rating_projection AS projection
                          WHERE projection.gid=galleries.gid),
            feedbacked_at=(SELECT projection.latest_feedback_at
                             FROM variant_publish_rating_projection AS projection
                            WHERE projection.gid=galleries.gid),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE gid IN (SELECT gid FROM variant_publish_rating_projection)
        AND EXISTS (
          SELECT 1 FROM variant_publish_rating_projection AS projection
           WHERE projection.gid=galleries.gid
             AND (galleries.self_rating IS NOT projection.desired_rating
                  OR galleries.feedbacked_at IS NOT projection.latest_feedback_at));

     UPDATE variant_jobs
        SET source_gid=(SELECT source_gid FROM variant_groups
                         WHERE id=variant_jobs.group_id),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id IN (SELECT group_id FROM variant_publish_affected_groups)
        AND source_gid IS NOT (SELECT source_gid FROM variant_groups
                                WHERE id=variant_jobs.group_id);
     UPDATE variant_reviews
        SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            evidence_json=json_set(evidence_json,'$.internal_visibility',json_object(
              'reason','replaced_gallery'))
      WHERE group_id IN (SELECT group_id FROM variant_publish_affected_groups)
        AND status='pending' AND superseded_at IS NULL
        AND (EXISTS (
               SELECT 1 FROM variant_groups AS grouped
                JOIN variant_publish_revision_projection AS revision_projection
                  ON revision_projection.revision_gid=grouped.source_gid
                 AND revision_projection.ready=1
                 AND revision_projection.is_terminal=0
               WHERE grouped.id=variant_reviews.group_id)
          OR EXISTS (
               SELECT 1 FROM variant_publish_revision_projection AS revision_projection
                WHERE revision_projection.revision_gid=CAST(json_extract(
                         variant_reviews.evidence_json,'$.source_snapshot.gid') AS INTEGER)
                  AND revision_projection.ready=1
                  AND revision_projection.is_terminal=0)
          OR EXISTS (
               SELECT 1 FROM variant_publish_revision_projection AS revision_projection
                WHERE revision_projection.revision_gid=variant_reviews.candidate_gid
                  AND revision_projection.ready=1
                  AND revision_projection.is_terminal=0)
          OR (variant_reviews.candidate_gid IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM scoreable_revision_terminals AS scoreable_terminal
                WHERE scoreable_terminal.gid=variant_reviews.candidate_gid)));
     -- A source promotion can turn a historical candidate row into a
     -- self-review (the frozen candidate is now the group's terminal). Keep
     -- that immutable review for audit, but supersede it before rebuilding the
     -- identity projection so it cannot violate the self-review invariant.
     UPDATE variant_reviews AS review
        SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            evidence_json=json_set(review.evidence_json,'$.internal_visibility',
              json_object('reason','provider_revision_component'))
      WHERE review.review_type='candidate_identity'
        AND review.status='pending'
        AND review.superseded_at IS NULL
        AND review.candidate_gid IS NOT NULL
        AND review.group_id IN (SELECT group_id FROM variant_publish_affected_groups)
        AND review.candidate_gid = (SELECT grouped.source_gid
                                      FROM variant_groups AS grouped
                                     WHERE grouped.id=review.group_id);

     INSERT OR IGNORE INTO variant_reviews(
       review_type, group_id, candidate_gid, policy_revision_id,
       matching_revision, evidence_json, choices_json)
       SELECT 'candidate_identity', :group_id, member.gid,
              context.policy_revision_id, :revision,
              json_set(candidate.evidence_json,
                '$.source_snapshot', json_object(
                  'gid', source_member.gid,
                  'title', source_gallery.title,
                  'title_jpn', source_gallery.title_jpn,
                  'filecount', source_gallery.file_count,
                  'tags', CASE WHEN json_valid(source_gallery.tags)
                               THEN json(source_gallery.tags) ELSE json('[]') END),
                '$.candidate_snapshot', json_object(
                  'gid', member.gid,
                  'title', candidate_gallery.title,
                  'title_jpn', candidate_gallery.title_jpn,
                  'filecount', candidate_gallery.file_count,
                  'tags', CASE WHEN json_valid(candidate_gallery.tags)
                               THEN json(candidate_gallery.tags) ELSE json('[]') END)),
              json_array('same_book', 'different_book')
         FROM gallery_variants AS member
         JOIN variant_publish_candidates AS candidate
           ON candidate.gid = member.gid
         JOIN variant_publish_context AS context
         JOIN gallery_variants AS source_member
           ON source_member.group_id = :group_id
          AND source_member.gid = (SELECT source_gid FROM variant_groups
                                   WHERE id = :group_id)
         JOIN galleries AS source_gallery ON source_gallery.gid = source_member.gid
         JOIN galleries AS candidate_gallery ON candidate_gallery.gid = member.gid
        WHERE member.group_id = :group_id
          AND member.membership_state = 'candidate'
          -- A provider revision component is one identity unit.  Once the
          -- owner source has been promoted to its terminal, do not create a
          -- self-review for another member of that same component.
          AND NOT EXISTS (
            SELECT 1
              FROM variant_publish_revision_projection AS source_revision
              JOIN variant_publish_revision_projection AS candidate_revision
                ON candidate_revision.component_gid = source_revision.component_gid
             WHERE source_revision.revision_gid = (SELECT source_gid
                                                FROM variant_groups
                                               WHERE id = :group_id)
               AND candidate_revision.revision_gid = member.gid);

     $(variants_identity_reconcile_sql publish)

     CREATE TEMP TABLE variant_publish_counts(
       published INTEGER NOT NULL, pending_reviews INTEGER NOT NULL
     );
     INSERT INTO variant_publish_counts(published, pending_reviews)
       SELECT (SELECT count(*) FROM variant_publish_candidates),
              (SELECT count(DISTINCT actionable.review_id)
                 FROM identity_actionable_review AS actionable
                 JOIN identity_gid_class AS member_class
                   ON member_class.class_gid IN (
                        actionable.low_class_gid, actionable.high_class_gid)
                WHERE member_class.active_group_id=:group_id);

     UPDATE variant_groups
        SET review_state = (
              SELECT projected.review_state
                FROM identity_group_review_state AS projected
               WHERE projected.group_id=variant_groups.id),
            last_discovered_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            completed_matching_revision = :revision,
            next_discovery_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now',
                                  '+' || :annual_days || ' days'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT owner_group_id FROM variant_publish_component_owner)
        AND EXISTS (SELECT 1 FROM variant_publish_context);
     UPDATE variant_jobs
        SET priority = MAX(priority, 100),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id IN (SELECT owner_group_id FROM variant_publish_component_owner)
        AND job_type = 'evaluate' AND status = 'queued'
        AND EXISTS (SELECT 1 FROM variant_groups AS grouped
                     WHERE grouped.id = variant_jobs.group_id AND grouped.desired_rating = 11)
        AND NOT EXISTS (
          SELECT 1 FROM identity_actionable_review AS actionable
          JOIN identity_gid_class AS member_class
            ON member_class.class_gid IN (
                 actionable.low_class_gid,actionable.high_class_gid)
          WHERE member_class.active_group_id=variant_jobs.group_id);
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status)
       SELECT 'evaluate', grouped.id, grouped.source_gid, 100, 'queued'
         FROM variant_groups AS grouped
        WHERE grouped.id IN (SELECT owner_group_id FROM variant_publish_component_owner)
          AND grouped.desired_rating = 11
          AND NOT EXISTS (
            SELECT 1 FROM identity_actionable_review AS actionable
            JOIN identity_gid_class AS member_class
              ON member_class.class_gid IN (
                   actionable.low_class_gid,actionable.high_class_gid)
            WHERE member_class.active_group_id=grouped.id);
     -- Lower ratings do not create winner work, but a terminal replacement
     -- must still reconcile the exact-GID remote rating/favorite actions.
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status)
       SELECT 'reconcile_actions', grouped.id, grouped.source_gid, 100, 'queued'
         FROM variant_groups AS grouped
        WHERE grouped.id IN (SELECT owner_group_id FROM variant_publish_component_owner)
          AND grouped.desired_rating BETWEEN 1 AND 10;
     -- Candidate staging is disposable only after publication has completed.
     -- Keeping this deletion in the same transaction makes rollback preserve
     -- both the frozen candidates and the resumable cursor.
     DELETE FROM variant_discovery_candidates WHERE run_id = :run_id;
     UPDATE variant_discovery_runs SET cursor_json = NULL
      WHERE id = :run_id AND EXISTS (SELECT 1 FROM variant_publish_context)
        AND EXISTS (SELECT 1 FROM variant_publish_job_rank AS ranked
                     WHERE ranked.job_id = :job_id AND ranked.rank = 1);
     UPDATE variant_discovery_runs
        SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = NULL,
            blocked_reason = NULL, blocked_component_count = 0
      WHERE id = :run_id AND EXISTS (SELECT 1 FROM variant_publish_context)
        AND EXISTS (SELECT 1 FROM variant_publish_job_rank AS ranked
                     WHERE ranked.job_id = :job_id AND ranked.rank = 1);
     UPDATE variant_jobs
        SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = NULL
      WHERE id = :job_id AND EXISTS (SELECT 1 FROM variant_publish_context)
        AND EXISTS (SELECT 1 FROM variant_publish_job_rank AS ranked
                     WHERE ranked.job_id = :job_id AND ranked.rank = 1);
     SELECT json_object(
       'job_type', 'discover',
       'source_gid', (SELECT source_gid FROM variant_groups WHERE id = :group_id),
       'status', 'completed',
       'published', (SELECT published FROM variant_publish_counts),
       'pending_reviews', (SELECT pending_reviews FROM variant_publish_counts),
       'evaluation_queued', json(CASE WHEN EXISTS (
          SELECT 1 FROM variant_jobs WHERE group_id = :group_id
            AND job_type = 'evaluate' AND status = 'queued')
          THEN 'true' ELSE 'false' END));
     COMMIT;" || return "${VARIANTS_DISCOVERY_BLOCKED_STATUS}"
}

# Advance exactly one durable phase for one leased discovery job.
variants_worker_handle_discover() {
  local job_json="$1" owner="$2"
  local job_id group_id run_id phase cursor output status=0 current_cursor
  job_id="$(jq -r '.id' <<<"${job_json}")"
  group_id="$(jq -r '.group_id' <<<"${job_json}")"
  run_id="$(jq -r '.run_id' <<<"${job_json}")"
  IFS='|' read -r phase cursor < <(db_query \
    ".parameter set :run_id ${run_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    "SELECT phase, COALESCE(cursor_json, 'null')
       FROM variant_discovery_runs
      WHERE id = :run_id AND status = 'running' AND lease_owner = :owner;" \
    )
  [[ -n "${phase:-}" ]] || return 1
  if [[ "$(db_query ".parameter set :group_id ${group_id}" \
    "SELECT identity_active FROM variant_groups WHERE id = :group_id;")" != 1 ]]; then
    variants_worker_cancel_discovery_job "${job_id}" "${owner}" || return
    jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
      '{job_type:"discover",source_gid:$source_gid,status:"cancelled"}'
    return 0
  fi
  case "${phase}" in
  seed_refresh) output="$(variants_discovery_seed_phase "${run_id}" "${group_id}" "${owner}")" || status=$? ;;
  chain_walk) output="$(variants_discovery_chain_phase "${run_id}" "${owner}" "${cursor}")" || status=$? ;;
  search) output="$(variants_discovery_search_phase "${run_id}" "${owner}" "${cursor}")" || status=$? ;;
  gdata) output="$(variants_discovery_gdata_phase "${run_id}" "${owner}" "${cursor}")" || status=$? ;;
  popularity) output="$(variants_discovery_popularity_phase "${run_id}" "${owner}" "${cursor}")" || status=$? ;;
  publish)
    variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}" || status=$?
    if [[ "${status}" -eq 0 ]]; then
      return 0
    fi
    if [[ "${status}" -eq "${VARIANTS_DISCOVERY_BLOCKED_STATUS}" ]]; then
      local blocked_reason blocked_delay
      blocked_reason="$(variants_discovery_publish_block_reason "${run_id}")"
      [[ "${blocked_reason}" =~ ^(reference_incomplete|scope_incomplete|scoring_input_incomplete|token_mismatch|relation_conflict|cycle|branch|multiple_terminals)$ ]] || blocked_reason='relation_conflict'
      variants_discovery_reset_blocked_run "${run_id}" "${job_id}" "${blocked_reason}" "${owner}" || return
      blocked_delay=300
      jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
        --arg reason "${blocked_reason}" --argjson delay "${blocked_delay}" \
        '{job_type:"discover",source_gid:$source_gid,status:"retryable_blocked",blocked_reason:$reason,retry_in_seconds:$delay}'
      return 0
    fi
    ;;
  *) status=67 ;;
  esac
  if [[ "${status}" -eq 0 || "${status}" -eq 64 ]]; then
    if [[ "$(db_query ".parameter set :group_id ${group_id}" \
      "SELECT identity_active FROM variant_groups WHERE id = :group_id;")" != 1 ]]; then
      variants_worker_cancel_discovery_job "${job_id}" "${owner}" || return
      jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
        '{job_type:"discover",source_gid:$source_gid,status:"cancelled"}'
      return 0
    fi
    current_cursor="$(db_query ".parameter set :run_id ${run_id}" \
      "SELECT COALESCE(cursor_json, 'null') FROM variant_discovery_runs WHERE id = :run_id;")" || return
    variants_worker_continue_job "${job_id}" "${owner}" "${current_cursor}" >/dev/null || return
    jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
      --argjson detail "${output:-null}" \
      '{job_type:"discover",source_gid:$source_gid,status:"continued",detail:$detail}'
    return 0
  fi
  if [[ "${status}" -eq 75 ]]; then
    local delay
    delay="$(variants_worker_retry_job "${job_id}" "${owner}" transient \
      "discovery remote read failed during ${phase}")" || return
    jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
      --argjson delay "${delay}" \
      '{job_type:"discover",source_gid:$source_gid,status:"retryable_error",retry_in_seconds:$delay}'
    return 0
  fi
  variants_worker_fail_job "${job_id}" "${owner}" permanent \
    "discovery failed during ${phase} with status ${status}" >/dev/null || return
  jq -nc --argjson source_gid "$(jq '.source_gid' <<<"${job_json}")" \
    --argjson code "${status}" \
    '{job_type:"discover",source_gid:$source_gid,status:"permanent_error",error_status:$code}'
}
