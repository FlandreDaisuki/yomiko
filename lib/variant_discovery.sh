#!/usr/bin/env bash

# Resumable metadata-first discovery for one leased `discover` job. Remote
# adapters are read-only; every durable transition is guarded by the owning
# run/job lease.

VARIANTS_SEARCH_REQUESTS_PER_CONTINUATION=8
VARIANTS_GDATA_BATCH_SIZE=25
VARIANTS_GDATA_BATCHES_PER_CONTINUATION=4
VARIANTS_POPULARITY_REQUESTS_PER_CONTINUATION=25
VARIANTS_ANNUAL_REDISCOVERY_DAYS=365

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
  changed="$(db_query \
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

  counts="$(db_query \
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
    linked_token="$(jq -r --arg relation "${relation}" '.[$relation + "_key"] // empty' <<<"${metadata_json}")"
    [[ "${linked_gid}" =~ ^[1-9][0-9]*$ && -n "${linked_token}" ]] || continue
    [[ "${linked_gid}" != "${source_gid}" ]] || continue
    origin="$(jq -nc --argjson from_gid "${source_gid}" --arg relation "${relation}" \
      '{kind:"official_chain",from_gid:$from_gid,relation:$relation}')"
    variants_discovery_stage_candidate "${run_id}" "${linked_gid}" "${linked_token}" "${origin}" "${owner}" || return
  done
}

variants_discovery_pending_gdata_json() {
  local run_id="$1" origin_kind="$2"
  local origin_filter='1'
  case "${origin_kind}" in
  seed | official_chain)
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
    db_query \
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
    db_query \
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
  changed="$(db_query \
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
  pending="$(variants_discovery_fetch_gdata "${run_id}" official_chain 1 "${owner}")" || return $?
  if [[ "${pending}" -gt 0 ]]; then
    printf '{"phase":"chain_walk","continued":true}\n'
    return 64
  fi
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
  pending="$(variants_discovery_fetch_gdata "${run_id}" all 0 "${owner}")" || return $?
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
    db_query \
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
          'rating', gallery.rating, 'category', gallery.category,
          'uploader', gallery.uploader, 'posted', gallery.posted,
          'filesize', gallery.filesize, 'thumb', gallery.thumb,
          'first_gid', gallery.first_gid, 'first_key', gallery.first_key,
          'parent_gid', gallery.parent_gid, 'parent_key', gallery.parent_key,
          'current_gid', gallery.current_gid, 'current_key', gallery.current_key,
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
          AND json_extract(origin.value, '$.kind') = 'official_chain'
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
    db_query \
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

# Publish a completed discovery snapshot and finish its leased job atomically.
variants_discovery_publish() {
  local run_id="$1" job_id="$2" group_id="$3" owner="$4"

  variants_discovery_build_evidence "${run_id}" "${group_id}" "${owner}" || return $?
  db_query \
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
          AND grouped.is_active = 1;
     CREATE TEMP TABLE variant_publish_guard(
       singleton INTEGER NOT NULL CHECK(singleton = 1)
     );
     INSERT INTO variant_publish_guard(singleton)
       SELECT count(*) FROM variant_publish_context;
     CREATE TEMP TABLE variant_publish_candidates AS
       SELECT candidate.*
         FROM variant_discovery_candidates AS candidate
        WHERE candidate.run_id = :run_id AND candidate.state = 'complete'
          AND candidate.token = (
            SELECT MIN(same_gid.token)
              FROM variant_discovery_candidates AS same_gid
             WHERE same_gid.run_id = candidate.run_id
               AND same_gid.gid = candidate.gid
               AND same_gid.state = 'complete');
     CREATE TEMP TABLE IF NOT EXISTS identity_reconcile_extra_gid(
       gid INTEGER PRIMARY KEY
     );
     INSERT OR IGNORE INTO identity_reconcile_extra_gid(gid)
       SELECT gid FROM variant_publish_candidates;
     $(variants_identity_reconcile_sql)
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
              CASE WHEN source_class.class_gid=candidate_class.class_gid
                   THEN 9999 ELSE -9999 END
                AS adjustment,
              CASE WHEN json_extract(candidate.evidence_json,
                                     '$.automatic_same_book') = 1
                          AND (source_class.class_gid=candidate_class.class_gid
                               OR class_pair.decision IS NULL)
                   THEN 1 ELSE 0 END AS automatic_same_book
         FROM variant_publish_candidates AS candidate
         JOIN variant_groups AS grouped ON grouped.id = :group_id
         JOIN identity_gid_class AS source_class ON source_class.gid=grouped.source_gid
         JOIN identity_gid_class AS candidate_class ON candidate_class.gid=candidate.gid
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
          AND (source_class.class_gid=candidate_class.class_gid
               OR class_pair.decision='different_book'
               OR (json_extract(candidate.evidence_json,
                                '$.automatic_same_book') = 1
                   AND class_pair.decision IS NULL
                   AND NOT EXISTS (
                     SELECT 1
                       FROM gallery_variants AS existing_member
                       JOIN variant_groups AS existing_group
                         ON existing_group.id=existing_member.group_id
                        AND existing_group.is_active=1
                      WHERE existing_member.gid=candidate.gid
                        AND existing_member.membership_state='confirmed'
                        AND existing_member.group_id<>:group_id
                   )));
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
           ON other_group.id = other.group_id AND other_group.is_active = 1
        WHERE identity.decision = 'same_book'
          AND other.membership_state = 'confirmed'
          AND other.group_id <> :group_id;

     INSERT INTO galleries(
       gid, token, title, title_jpn, file_count, expunged, tags, rating,
       category, uploader, posted, filesize, thumb, first_gid, first_key,
       parent_gid, parent_key, current_gid, current_key,
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
              json_extract(candidate.gdata_json, '$.category'),
              json_extract(candidate.gdata_json, '$.uploader'),
              json_extract(candidate.gdata_json, '$.posted'),
              json_extract(candidate.gdata_json, '$.filesize'),
              json_extract(candidate.gdata_json, '$.thumb'),
              json_extract(candidate.gdata_json, '$.first_gid'),
              json_extract(candidate.gdata_json, '$.first_key'),
              json_extract(candidate.gdata_json, '$.parent_gid'),
              json_extract(candidate.gdata_json, '$.parent_key'),
              json_extract(candidate.gdata_json, '$.current_gid'),
              json_extract(candidate.gdata_json, '$.current_key'),
              json_extract(candidate.popularity_json, '$.favorite_count'),
              json_extract(candidate.popularity_json, '$.rating_count'),
              json_extract(candidate.popularity_json, '$.popularity_fetched_at')
         FROM variant_publish_candidates AS candidate
        WHERE EXISTS (SELECT 1 FROM variant_publish_context)
     ON CONFLICT(gid) DO UPDATE SET
       token = excluded.token, title = excluded.title,
       title_jpn = excluded.title_jpn, file_count = excluded.file_count,
       expunged = excluded.expunged, tags = excluded.tags,
       rating = excluded.rating, category = excluded.category,
       uploader = excluded.uploader, posted = excluded.posted,
       filesize = excluded.filesize, thumb = excluded.thumb,
       first_gid = excluded.first_gid, first_key = excluded.first_key,
       parent_gid = excluded.parent_gid, parent_key = excluded.parent_key,
       current_gid = excluded.current_gid, current_key = excluded.current_key,
       favorite_count = excluded.favorite_count,
       rating_count = excluded.rating_count,
       popularity_fetched_at = excluded.popularity_fetched_at,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

     INSERT INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, metadata_snapshot_json, matching_revision, decided_at)
       SELECT :group_id, candidate.gid,
              CASE
                WHEN candidate.gid = (SELECT source_gid FROM variant_groups
                                       WHERE id = :group_id) THEN 'confirmed'
                WHEN identity.decision = 'same_book' THEN 'confirmed'
                WHEN identity.decision = 'different_book' THEN 'rejected'
                WHEN json_extract(candidate.evidence_json, '$.replaced') = 1
                  THEN 'rejected'
                WHEN (json_extract(candidate.evidence_json, '$.category') = 'official_chain'
                   AND json_extract(candidate.evidence_json, '$.automatic_same_book') = 1)
                 AND NOT EXISTS (
                   SELECT 1 FROM gallery_variants AS other
                   JOIN variant_groups AS other_group ON other_group.id = other.group_id
                  WHERE other.gid = candidate.gid
                    AND other.membership_state = 'confirmed'
                    AND other_group.is_active = 1 AND other.group_id <> :group_id)
                  THEN 'confirmed'
                WHEN json_extract(candidate.evidence_json, '$.in_scope') = 1
                  THEN 'candidate'
                ELSE 'rejected' END,
              CASE WHEN identity.automatic_same_book = 1 THEN 'automatic'
                   WHEN identity.decision IS NULL THEN 'automatic' ELSE 'manual' END,
              json_extract(candidate.evidence_json, '$.score')
                + COALESCE(identity.adjustment, 0),
              CASE WHEN identity.decision IS NULL OR identity.automatic_same_book = 1
                   THEN candidate.evidence_json
                   ELSE json_set(candidate.evidence_json,
                     '$.manual_decision', identity.decision,
                     '$.manual_adjustment', identity.adjustment,
                     '$.manual_review_id', identity.current_review_id,
                     '$.manual_decided_at', identity.resolved_at)
                   END,
              json_patch(candidate.gdata_json,
                         COALESCE(candidate.popularity_json, json('{}'))),
              :revision,
              CASE WHEN identity.automatic_same_book = 1
                     THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                   WHEN identity.decision IS NOT NULL THEN identity.resolved_at
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
       metadata_snapshot_json = excluded.metadata_snapshot_json,
       matching_revision = excluded.matching_revision,
       decided_at = CASE
         WHEN excluded.decision_source = 'manual' THEN excluded.decided_at
         WHEN gallery_variants.membership_state = 'confirmed'
           THEN gallery_variants.decided_at
         ELSE COALESCE(excluded.decided_at, gallery_variants.decided_at) END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

     -- A successfully fetched current child becomes the operational source.
     -- The historical member and its evidence remain in the group.
     UPDATE variant_groups
        SET source_gid=(SELECT current_gid FROM galleries
                         WHERE gid=variant_groups.source_gid
                           AND current_gid IS NOT NULL
                           AND current_gid<>gid),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE id=:group_id
        AND EXISTS (
          SELECT 1 FROM galleries AS old_source
           JOIN gallery_variants AS child
             ON child.group_id=:group_id
            AND child.gid=old_source.current_gid
            AND child.membership_state='confirmed'
          WHERE old_source.gid=variant_groups.source_gid
            AND old_source.current_gid IS NOT NULL
            AND old_source.current_gid<>old_source.gid);
     UPDATE variant_jobs
        SET source_gid=(SELECT source_gid FROM variant_groups WHERE id=:group_id),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE group_id=:group_id AND source_gid IS NOT
            (SELECT source_gid FROM variant_groups WHERE id=:group_id);
     UPDATE variant_reviews
        SET superseded_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            evidence_json=json_set(evidence_json,'$.internal_visibility',json_object(
              'reason','replaced_gallery'))
      WHERE group_id=:group_id AND status='pending' AND superseded_at IS NULL
        AND (EXISTS (SELECT 1 FROM galleries AS source
                      JOIN variant_groups AS grouped ON grouped.source_gid=source.gid
                     WHERE grouped.id=:group_id AND source.current_gid IS NOT NULL
                       AND source.current_gid<>source.gid)
          OR EXISTS (SELECT 1 FROM galleries AS historical_source
                      WHERE historical_source.gid=CAST(json_extract(
                        variant_reviews.evidence_json,'$.source_snapshot.gid') AS INTEGER)
                        AND historical_source.current_gid IS NOT NULL
                        AND historical_source.current_gid<>historical_source.gid)
          OR EXISTS (SELECT 1 FROM galleries AS candidate
                      WHERE candidate.gid=variant_reviews.candidate_gid
                        AND candidate.current_gid IS NOT NULL
                        AND candidate.current_gid<>candidate.gid));

     INSERT OR IGNORE INTO variant_reviews(
       review_type, group_id, candidate_gid, policy_revision_id,
       matching_revision, evidence_json, choices_json)
       SELECT 'candidate_identity', :group_id, member.gid,
              context.policy_revision_id, :revision,
              json_set(candidate.evidence_json,
                '$.source_snapshot', json(source_member.metadata_snapshot_json),
                '$.candidate_snapshot', json(member.metadata_snapshot_json)),
              json_array('same_book', 'different_book')
         FROM gallery_variants AS member
         JOIN variant_publish_candidates AS candidate
           ON candidate.gid = member.gid
         JOIN variant_publish_context AS context
         JOIN gallery_variants AS source_member
           ON source_member.group_id = :group_id
          AND source_member.gid = (SELECT source_gid FROM variant_groups
                                   WHERE id = :group_id)
        WHERE member.group_id = :group_id
          AND member.membership_state = 'candidate';

     $(variants_identity_reconcile_sql)

     UPDATE variant_groups
        SET review_state = CASE WHEN EXISTS (
              SELECT 1
                FROM identity_actionable_review AS actionable
                JOIN identity_gid_class AS member_class
                  ON member_class.class_gid IN (
                       actionable.low_class_gid,actionable.high_class_gid)
               WHERE member_class.active_group_id=:group_id)
              THEN 'candidate_pending'
              WHEN EXISTS (SELECT 1 FROM variant_reviews
                            WHERE group_id = :group_id
                              AND review_type = 'winner' AND status = 'pending'
                              AND superseded_at IS NULL)
              THEN 'winner_pending' ELSE 'none' END,
            last_discovered_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            completed_matching_revision = :revision,
            next_discovery_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now',
                                  '+' || :annual_days || ' days'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = :group_id AND EXISTS (SELECT 1 FROM variant_publish_context);
     UPDATE variant_jobs
        SET priority = MAX(priority, 100),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = :group_id AND job_type = 'evaluate' AND status = 'queued'
        AND NOT EXISTS (
          SELECT 1 FROM identity_actionable_review AS actionable
          JOIN identity_gid_class AS member_class
            ON member_class.class_gid IN (
                 actionable.low_class_gid,actionable.high_class_gid)
          WHERE member_class.active_group_id=:group_id);
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status)
       SELECT 'evaluate', grouped.id, grouped.source_gid, 100, 'queued'
         FROM variant_groups AS grouped WHERE grouped.id = :group_id
          AND NOT EXISTS (
            SELECT 1 FROM identity_actionable_review AS actionable
            JOIN identity_gid_class AS member_class
              ON member_class.class_gid IN (
                   actionable.low_class_gid,actionable.high_class_gid)
            WHERE member_class.active_group_id=:group_id);
     UPDATE variant_discovery_runs
        SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = NULL
      WHERE id = :run_id AND EXISTS (SELECT 1 FROM variant_publish_context);
     UPDATE variant_jobs
        SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
            completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = NULL
      WHERE id = :job_id AND EXISTS (SELECT 1 FROM variant_publish_context);
     SELECT json_object(
       'job_type', 'discover',
       'source_gid', (SELECT source_gid FROM variant_groups WHERE id = :group_id),
       'status', 'completed',
       'published', (SELECT count(*) FROM variant_publish_candidates),
       'pending_reviews', (SELECT count(DISTINCT actionable.review_id)
          FROM identity_actionable_review AS actionable
          JOIN identity_gid_class AS member_class
            ON member_class.class_gid IN (
                 actionable.low_class_gid,actionable.high_class_gid)
         WHERE member_class.active_group_id=:group_id),
       'evaluation_queued', json(CASE WHEN EXISTS (
          SELECT 1 FROM variant_jobs WHERE group_id = :group_id
            AND job_type = 'evaluate' AND status = 'queued')
          THEN 'true' ELSE 'false' END));
     COMMIT;"
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
    "SELECT is_active FROM variant_groups WHERE id = :group_id;")" != 1 ]]; then
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
  publish) variants_discovery_publish "${run_id}" "${job_id}" "${group_id}" "${owner}"; return ;;
  *) status=67 ;;
  esac
  if [[ "${status}" -eq 0 || "${status}" -eq 64 ]]; then
    if [[ "$(db_query ".parameter set :group_id ${group_id}" \
      "SELECT is_active FROM variant_groups WHERE id = :group_id;")" != 1 ]]; then
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
