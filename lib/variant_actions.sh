#!/usr/bin/env bash

# Durable desired-state projection and execution for variant operations.  The
# caller sources path.sh, db.sh, exh.sh, variants.sh, variant_retention.sh, and
# variant_worker.sh before invoking these handlers.

# shellcheck disable=SC2034 # Consumed by variants_work after all libraries load.
VARIANTS_REMOTE_MUTATIONS_PER_RUN=25
VARIANTS_CONFIGURATION_RETRY_SECONDS=86400

# Persist the successful manual H@H command and any matching canonical action
# in one transaction. Ungrouped/manual downloads still update gallery state;
# the action row is added only when the GID is the unambiguous active rating-11
# canonical of a completed evaluation.
variants_actions_record_manual_hath_success() {
  local gid="$1"
  variants_validate_positive_integer "GID" "${gid}" || return 1
  db_query \
    ".parameter set :gid ${gid}" \
    "BEGIN IMMEDIATE;
     UPDATE galleries
        SET hath_requested_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE gid=:gid;
     INSERT INTO variant_actions(
       group_id,evaluation_id,gid,action_type,desired_value,
       decision_revision_id,status,result_json,completed_at)
       SELECT grouped.id,evaluation.id,:gid,'hath_request','request',
              evaluation.policy_revision_id,'succeeded',
              json_object('operation','hath_request','gid',:gid,
                          'desired_value','request','outcome','succeeded',
                          'mutation_sent',json('true'),'manual_command',json('true'),
                          'message','manual H@H request accepted'),
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM variant_groups AS grouped
         JOIN variant_evaluations AS evaluation
           ON evaluation.id=grouped.active_evaluation_id
          AND evaluation.state='completed'
        WHERE grouped.is_active=1 AND grouped.desired_rating=11
          AND grouped.canonical_gid=:gid
     ON CONFLICT(action_type,gid,desired_value,decision_revision_id)
     DO UPDATE SET
       group_id=excluded.group_id,evaluation_id=excluded.evaluation_id,
       status='succeeded',lease_owner=NULL,lease_expires_at=NULL,
       lease_job_id=NULL,last_error_class=NULL,last_error=NULL,
       result_json=excluded.result_json,completed_at=excluded.completed_at,
       updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');
     COMMIT;"
}

variants_actions_project() {
  local group_id="$1"
  variants_validate_positive_integer "group ID" "${group_id}" || return 1

  db_query \
    ".parameter set :group_id ${group_id}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_action_context AS
       SELECT grouped.id AS group_id, grouped.source_gid,
              grouped.desired_rating, grouped.is_active,
              grouped.canonical_gid, grouped.active_evaluation_id,
              COALESCE(evaluation.policy_revision_id, policy.id) AS revision_id,
              CASE WHEN evaluation.state = 'completed' THEN 1 ELSE 0 END AS has_winner
         FROM variant_groups AS grouped
         JOIN variant_policy_revisions AS policy ON policy.is_active = 1
         LEFT JOIN variant_evaluations AS evaluation
           ON evaluation.id = grouped.active_evaluation_id
        WHERE grouped.id = :group_id;
     CREATE TEMP TABLE variant_desired_actions(
       gid INTEGER NOT NULL,
       action_type TEXT NOT NULL,
       desired_value TEXT NOT NULL,
       evaluation_id INTEGER,
       revision_id INTEGER NOT NULL,
       PRIMARY KEY(gid, action_type, desired_value, revision_id)
     );
     INSERT INTO variant_desired_actions
       SELECT member.gid, 'rating',
              CAST(CASE context.desired_rating WHEN 11 THEN 10
                        ELSE context.desired_rating END AS TEXT),
              context.active_evaluation_id, context.revision_id
         FROM variant_action_context AS context
         JOIN gallery_variants AS member ON member.group_id = context.group_id
        WHERE member.membership_state = 'confirmed';
     INSERT INTO variant_desired_actions
       SELECT member.gid, 'archive_cleanup', 'delete',
              context.active_evaluation_id, context.revision_id
         FROM variant_action_context AS context
         JOIN gallery_variants AS member ON member.group_id = context.group_id
        WHERE member.membership_state = 'confirmed'
          AND (
            context.desired_rating BETWEEN 1 AND 10
            OR (context.desired_rating = 11 AND context.is_active = 1
                AND context.has_winner = 1
                AND member.gid <> context.canonical_gid)
          );
     INSERT INTO variant_desired_actions
       SELECT member.gid, 'favorite_remove', 'favdel',
              context.active_evaluation_id, context.revision_id
         FROM variant_action_context AS context
         JOIN gallery_variants AS member ON member.group_id = context.group_id
        WHERE context.desired_rating < 8
          AND member.membership_state = 'confirmed';
     INSERT INTO variant_desired_actions
       SELECT member.gid, 'favorite_move',
              CASE WHEN member.gid = context.canonical_gid
                   THEN 'canonical' ELSE 'alternate' END,
              context.active_evaluation_id, context.revision_id
         FROM variant_action_context AS context
         JOIN gallery_variants AS member ON member.group_id = context.group_id
        WHERE context.is_active = 1 AND context.desired_rating >= 8
          AND context.has_winner = 1 AND context.canonical_gid IS NOT NULL
          AND member.membership_state = 'confirmed';
     INSERT INTO variant_desired_actions
       SELECT context.canonical_gid, 'hath_request', 'request',
              context.active_evaluation_id, context.revision_id
         FROM variant_action_context AS context
        WHERE context.is_active = 1 AND context.desired_rating = 11
          AND context.has_winner = 1 AND context.canonical_gid IS NOT NULL;
     UPDATE galleries
        SET self_rating = (SELECT desired_rating FROM variant_action_context),
            feedbacked_at = COALESCE((SELECT latest_feedback_at
                                        FROM variant_groups WHERE id = :group_id),
                                     feedbacked_at),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE gid IN (SELECT member.gid FROM gallery_variants AS member
                     WHERE member.group_id = :group_id
                       AND member.membership_state = 'confirmed');
     UPDATE variant_actions
        SET status = 'superseded', lease_owner = NULL,
            lease_expires_at = NULL, lease_job_id = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = :group_id
        AND status IN ('pending', 'retryable_error', 'configuration_error',
                       'permanent_error')
        AND NOT EXISTS (
          SELECT 1 FROM variant_desired_actions AS desired
           WHERE desired.gid = variant_actions.gid
             AND desired.action_type = variant_actions.action_type
             AND desired.desired_value = variant_actions.desired_value
             AND desired.revision_id = variant_actions.decision_revision_id
        );
     INSERT INTO variant_actions(
       group_id, evaluation_id, gid, action_type, desired_value,
       decision_revision_id
     )
       SELECT :group_id, desired.evaluation_id, desired.gid,
              desired.action_type, desired.desired_value, desired.revision_id
         FROM variant_desired_actions AS desired
        WHERE 1
     ON CONFLICT(action_type, gid, desired_value, decision_revision_id)
     DO UPDATE SET
       group_id = excluded.group_id,
       evaluation_id = excluded.evaluation_id,
       status = CASE
         WHEN variant_actions.status IN ('superseded', 'permanent_error')
           THEN 'pending' ELSE variant_actions.status END,
       available_at = CASE
         WHEN variant_actions.status IN ('superseded', 'permanent_error')
           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         ELSE variant_actions.available_at END,
       completed_at = CASE
         WHEN variant_actions.status IN ('superseded', 'permanent_error')
           THEN NULL ELSE variant_actions.completed_at END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     SELECT COALESCE(json_group_array(json_object(
       'gid', desired.gid, 'action_type', desired.action_type,
       'desired_value', desired.desired_value
     )), json('[]')) FROM variant_desired_actions AS desired;
     COMMIT;"
}

variants_actions_requeue_expired() {
  db_query \
    "BEGIN IMMEDIATE;
     UPDATE variant_actions
        SET status = 'retryable_error', lease_owner = NULL,
            lease_expires_at = NULL, lease_job_id = NULL,
            last_error_class = 'uncertain',
            last_error = 'action lease expired with an uncertain outcome',
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE status = 'in_flight'
        AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     SELECT changes();
     COMMIT;"
}

variants_actions_schedule_recovery() {
  local categories canonical='' alternate=''
  categories="$(variants_actions_favorite_categories 2>/dev/null)" || true
  if [[ -n "${categories}" ]]; then
    canonical="$(jq -r '.canonical' <<<"${categories}")"
    alternate="$(jq -r '.alternate' <<<"${categories}")"
  fi
  db_query \
    ".parameter set :canonical $(db_parameter_text "${canonical}")" \
    ".parameter set :alternate $(db_parameter_text "${alternate}")" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_action_recovery_groups(
       group_id INTEGER PRIMARY KEY, source_gid INTEGER NOT NULL,
       priority INTEGER NOT NULL, available_at TEXT NOT NULL
     );
     INSERT INTO variant_action_recovery_groups
       SELECT grouped.id, grouped.source_gid, 500,
              MIN(action.available_at)
         FROM variant_groups AS grouped
         JOIN variant_actions AS action ON action.group_id=grouped.id
          AND action.status IN ('pending','retryable_error',
                                'configuration_error','in_flight')
        GROUP BY grouped.id, grouped.source_gid;
     CREATE TEMP TABLE variant_expected_favorites AS
       SELECT grouped.id AS group_id, grouped.source_gid, member.gid,
              CASE WHEN member.gid=grouped.canonical_gid
                   THEN 'canonical' ELSE 'alternate' END AS role,
              CASE WHEN member.gid=grouped.canonical_gid
                   THEN :canonical ELSE :alternate END AS category,
              evaluation.policy_revision_id AS revision_id
         FROM variant_groups AS grouped
         JOIN variant_evaluations AS evaluation
           ON evaluation.id=grouped.active_evaluation_id
          AND evaluation.state='completed'
         JOIN gallery_variants AS member ON member.group_id=grouped.id
          AND member.membership_state='confirmed'
        WHERE :canonical<>'' AND :alternate<>''
          AND grouped.is_active=1 AND grouped.desired_rating>=8
          AND grouped.canonical_gid IS NOT NULL;
     UPDATE variant_actions
        SET status='pending', completed_at=NULL,
            available_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            last_error_class=NULL, last_error=NULL,
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE status IN ('succeeded','configuration_error')
        AND action_type='favorite_move'
        AND EXISTS (
          SELECT 1 FROM variant_expected_favorites AS expected
           WHERE expected.group_id=variant_actions.group_id
             AND expected.gid=variant_actions.gid
             AND expected.role=variant_actions.desired_value
             AND expected.revision_id=variant_actions.decision_revision_id
             AND COALESCE(json_extract(variant_actions.result_json,
                                        '$.resolved_category'),'')
                 <> expected.category
        );
     INSERT OR IGNORE INTO variant_action_recovery_groups
       SELECT expected.group_id, expected.source_gid, 500,
              strftime('%Y-%m-%dT%H:%M:%SZ','now')
         FROM variant_expected_favorites AS expected
        WHERE NOT EXISTS (
          SELECT 1 FROM variant_actions AS action
           WHERE action.group_id=expected.group_id AND action.gid=expected.gid
             AND action.action_type='favorite_move'
             AND action.desired_value=expected.role
             AND action.decision_revision_id=expected.revision_id
             AND action.status='succeeded'
             AND json_extract(action.result_json,'$.resolved_category')
                 = expected.category
        );
     UPDATE variant_action_recovery_groups
        SET available_at=COALESCE((
          SELECT MIN(action.available_at)
            FROM variant_actions AS action
           WHERE action.group_id=variant_action_recovery_groups.group_id
             AND action.status IN ('pending','retryable_error',
                                   'configuration_error','in_flight')
        ), strftime('%Y-%m-%dT%H:%M:%SZ','now'));
     UPDATE variant_jobs
        SET priority=MAX(priority,(SELECT recovery.priority
                                    FROM variant_action_recovery_groups AS recovery
                                   WHERE recovery.group_id=variant_jobs.group_id)),
            available_at=MIN(available_at,(SELECT recovery.available_at
                                    FROM variant_action_recovery_groups AS recovery
                                   WHERE recovery.group_id=variant_jobs.group_id)),
            updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
      WHERE job_type='reconcile_actions' AND status='queued'
        AND group_id IN (SELECT group_id FROM variant_action_recovery_groups);
     INSERT OR IGNORE INTO variant_jobs(
       job_type,group_id,source_gid,priority,status,available_at)
       SELECT 'reconcile_actions',group_id,source_gid,priority,'queued',available_at
         FROM variant_action_recovery_groups;
     SELECT count(*) FROM variant_action_recovery_groups;
     COMMIT;"
}

variants_actions_claim_next() {
  local job_id="$1" owner="$2" allow_remote="${3:-1}"
  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  [[ -n "${owner}" ]] || return 1
  [[ "${allow_remote}" == 0 || "${allow_remote}" == 1 ]] || return 1

  db_query \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :allow_remote ${allow_remote}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_claimed_action(id INTEGER PRIMARY KEY);
     INSERT INTO variant_claimed_action(id)
       SELECT action.id
         FROM variant_actions AS action
         JOIN variant_jobs AS job ON job.group_id = action.group_id
        WHERE job.id = :job_id AND job.job_type = 'reconcile_actions'
          AND job.status = 'leased' AND job.lease_owner = :owner
          AND action.status IN ('pending', 'retryable_error',
                                'configuration_error')
          AND action.available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          AND (:allow_remote = 1 OR action.action_type = 'archive_cleanup')
        ORDER BY CASE action.action_type
          WHEN 'rating' THEN 1 WHEN 'favorite_move' THEN 2
          WHEN 'favorite_remove' THEN 2 WHEN 'hath_request' THEN 3
          ELSE 4 END, action.id
        LIMIT 1;
     UPDATE variant_actions
        SET status = 'in_flight', attempt_count = attempt_count + 1,
            lease_owner = :owner,
            lease_expires_at = (SELECT lease_expires_at FROM variant_jobs
                                  WHERE id = :job_id),
            lease_job_id = :job_id,
            last_attempt_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            last_error_class = NULL, last_error = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT id FROM variant_claimed_action);
     SELECT json_object(
       'id', action.id, 'group_id', action.group_id,
       'evaluation_id', action.evaluation_id, 'gid', action.gid,
       'action_type', action.action_type,
       'desired_value', action.desired_value,
       'attempt_count', action.attempt_count,
       'token', gallery.token, 'file_path', gallery.file_path,
       'hath_requested_at', gallery.hath_requested_at,
       'desired_rating', grouped.desired_rating,
       'is_active', json(CASE grouped.is_active WHEN 1 THEN 'true' ELSE 'false' END),
       'canonical_gid', grouped.canonical_gid,
       'canonical_file_path', canonical.file_path
     )
       FROM variant_actions AS action
       JOIN variant_groups AS grouped ON grouped.id = action.group_id
       JOIN galleries AS gallery ON gallery.gid = action.gid
       LEFT JOIN galleries AS canonical ON canonical.gid = grouped.canonical_gid
      WHERE action.id = (SELECT id FROM variant_claimed_action);
     COMMIT;"
}

variants_actions_finish() {
  local action_id="$1" job_id="$2" owner="$3" status="$4"
  local error_class="$5" error_message="$6" result_json="$7"
  local actual_deleted="${8:-0}" hath_succeeded="${9:-0}"
  variants_validate_positive_integer "action ID" "${action_id}" || return 1
  variants_validate_positive_integer "job ID" "${job_id}" || return 1
  case "${status}" in
  succeeded | retryable_error | permanent_error | configuration_error) ;;
  *) return 1 ;;
  esac
  jq -e 'type == "object"' >/dev/null <<<"${result_json}" || return 1

  db_query \
    ".parameter set :action_id ${action_id}" \
    ".parameter set :job_id ${job_id}" \
    ".parameter set :owner $(db_parameter_text "${owner}")" \
    ".parameter set :status $(db_parameter_text "${status}")" \
    ".parameter set :error_class $(db_parameter_text "${error_class}")" \
    ".parameter set :error_message $(db_parameter_text "${error_message}")" \
    ".parameter set :result $(db_parameter_text "${result_json}")" \
    ".parameter set :actual_deleted ${actual_deleted}" \
    ".parameter set :hath_succeeded ${hath_succeeded}" \
    ".parameter set :configuration_delay ${VARIANTS_CONFIGURATION_RETRY_SECONDS}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_finished_action AS
       SELECT action.id, action.gid, action.action_type, action.attempt_count
         FROM variant_actions AS action
         JOIN variant_jobs AS job ON job.id = :job_id
        WHERE action.id = :action_id AND action.status = 'in_flight'
          AND action.lease_job_id = :job_id AND action.lease_owner = :owner
          AND job.status = 'leased' AND job.lease_owner = :owner;
     UPDATE variant_actions
        SET status = :status, lease_owner = NULL, lease_expires_at = NULL,
            lease_job_id = NULL,
            last_error_class = CASE WHEN :error_class = '' THEN NULL
                                    ELSE :error_class END,
            last_error = CASE WHEN :error_message = '' THEN NULL
                              ELSE :error_message END,
            result_json = json(:result),
            available_at = CASE
              WHEN :status = 'retryable_error' THEN strftime(
                '%Y-%m-%dT%H:%M:%SZ', 'now', '+' || CASE attempt_count
                  WHEN 1 THEN 300 WHEN 2 THEN 900 WHEN 3 THEN 3600
                  WHEN 4 THEN 21600 ELSE 86400 END || ' seconds')
              WHEN :status = 'configuration_error' THEN strftime(
                '%Y-%m-%dT%H:%M:%SZ', 'now',
                '+' || :configuration_delay || ' seconds')
              ELSE available_at END,
            completed_at = CASE WHEN :status IN ('succeeded', 'permanent_error')
                                THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                                ELSE NULL END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id IN (SELECT id FROM variant_finished_action);
     UPDATE galleries
        SET rated_then_deleted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE :actual_deleted = 1
        AND gid = (SELECT gid FROM variant_finished_action);
     UPDATE galleries
        SET hath_requested_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE :hath_succeeded = 1
        AND gid = (SELECT gid FROM variant_finished_action);
     SELECT count(*) FROM variant_finished_action;
     COMMIT;"
}

variants_actions_favorite_categories() {
  local canonical="${YOMIKO_CANONICAL_FAVORITE_CATEGORY:-}"
  local alternate="${YOMIKO_ALTERNATE_FAVORITE_CATEGORY:-}"
  if [[ ! "${canonical}" =~ ^[0-9]$ || ! "${alternate}" =~ ^[0-9]$ ||
    "${canonical}" == "${alternate}" ]]; then
    return 1
  fi
  jq -nc --arg canonical "${canonical}" --arg alternate "${alternate}" \
    '{canonical:$canonical,alternate:$alternate}'
}

variants_actions_latest_remote_matches() {
  local action_json="$1" resolved_value="${2:-}"
  local gid action_type desired current_id
  gid="$(jq -r '.gid' <<<"${action_json}")"
  action_type="$(jq -r '.action_type' <<<"${action_json}")"
  desired="$(jq -r '.desired_value' <<<"${action_json}")"
  current_id="$(jq -r '.id' <<<"${action_json}")"

  db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :current_id ${current_id}" \
    ".parameter set :action_type $(db_parameter_text "${action_type}")" \
    ".parameter set :desired $(db_parameter_text "${desired}")" \
    ".parameter set :resolved $(db_parameter_text "${resolved_value}")" \
    "SELECT CASE WHEN EXISTS (
       SELECT 1 FROM (
         SELECT previous.action_type, previous.desired_value,
                previous.result_json
           FROM variant_actions AS previous
          WHERE previous.gid = :gid AND previous.id <> :current_id
            AND previous.status = 'succeeded'
            AND (previous.action_type = :action_type
                 OR (:action_type IN ('favorite_move','favorite_remove')
                     AND previous.action_type IN ('favorite_move','favorite_remove')))
          ORDER BY previous.completed_at DESC, previous.id DESC LIMIT 1
       ) AS latest
       WHERE latest.action_type = :action_type
         AND latest.desired_value = :desired
         AND (:action_type <> 'favorite_move'
              OR json_extract(latest.result_json, '$.resolved_category') = :resolved)
     ) THEN 1 ELSE 0 END;"
}

variants_actions_local_cleanup() {
  local action_json="$1" gid file_path desired_rating canonical_path result
  gid="$(jq -r '.gid' <<<"${action_json}")"
  file_path="$(jq -r '.file_path // empty' <<<"${action_json}")"
  desired_rating="$(jq -r '.desired_rating' <<<"${action_json}")"
  canonical_path="$(jq -r '.canonical_file_path // empty' <<<"${action_json}")"

  if [[ -z "${file_path}" ]]; then
    jq -nc --argjson gid "${gid}" \
      '{operation:"archive_cleanup",gid:$gid,outcome:"succeeded",actual_deleted:false,message:"no archive path recorded"}'
    return 0
  fi
  if ! archive_filename_is_safe "${file_path}"; then
    jq -nc --argjson gid "${gid}" \
      '{operation:"archive_cleanup",gid:$gid,outcome:"permanent",actual_deleted:false,message:"unsafe archive path"}'
    return 72
  fi
  if [[ ! -e "${ARCHIVED_DIR}/${file_path}" ]]; then
    jq -nc --argjson gid "${gid}" --arg file_path "${file_path}" \
      '{operation:"archive_cleanup",gid:$gid,outcome:"succeeded",actual_deleted:false,missing_file:true,file_path:$file_path,message:"recorded archive is missing"}'
    return 0
  fi
  if [[ "${desired_rating}" == 11 ]]; then
    result=0
    variants_retention_delete_alternate "${canonical_path}" "${file_path}" || result=$?
    if [[ "${result}" -ne 0 ]]; then
      if [[ "${result}" -eq 2 ]]; then
        jq -nc --argjson gid "${gid}" \
          '{operation:"archive_cleanup",gid:$gid,outcome:"permanent",actual_deleted:false,message:"unsafe retention path"}'
        return 72
      fi
      jq -nc --argjson gid "${gid}" \
        '{operation:"archive_cleanup",gid:$gid,outcome:"transient",actual_deleted:false,message:"canonical archive is not available"}'
      return 70
    fi
    if [[ "${VARIANTS_RETENTION_DELETE_RESULT}" == missing ]]; then
      jq -nc --argjson gid "${gid}" --arg file_path "${file_path}" \
        '{operation:"archive_cleanup",gid:$gid,outcome:"succeeded",actual_deleted:false,missing_file:true,file_path:$file_path,message:"recorded archive disappeared before cleanup"}'
      return 0
    fi
  else
    if [[ ! -f "${ARCHIVED_DIR}/${file_path}" || -L "${ARCHIVED_DIR}/${file_path}" ]]; then
      jq -nc --argjson gid "${gid}" \
        '{operation:"archive_cleanup",gid:$gid,outcome:"permanent",actual_deleted:false,message:"archive path is not a regular file"}'
      return 72
    fi
    rm -- "${ARCHIVED_DIR}/${file_path}" || {
      jq -nc --argjson gid "${gid}" \
        '{operation:"archive_cleanup",gid:$gid,outcome:"transient",actual_deleted:false,message:"archive deletion failed"}'
      return 70
    }
  fi
  jq -nc --argjson gid "${gid}" --arg file_path "${file_path}" \
    '{operation:"archive_cleanup",gid:$gid,outcome:"succeeded",actual_deleted:true,file_path:$file_path,message:"archive deleted"}'
}

variants_actions_execute_one() {
  local action_json="$1" job_id="$2" owner="$3"
  local action_id action_type desired gid token result status=0 outcome
  local final_status error_class='' error_message='' actual_deleted=0 hath_succeeded=0
  local categories resolved_category='' lock_fd='' actual_remote=0
  action_id="$(jq -r '.id' <<<"${action_json}")"
  action_type="$(jq -r '.action_type' <<<"${action_json}")"
  desired="$(jq -r '.desired_value' <<<"${action_json}")"
  gid="$(jq -r '.gid' <<<"${action_json}")"
  token="$(jq -r '.token' <<<"${action_json}")"

  case "${action_type}" in
  favorite_move)
    if ! categories="$(variants_actions_favorite_categories)"; then
      result="$(jq -nc --argjson gid "${gid}" --arg role "${desired}" \
        '{operation:"favorite",gid:$gid,desired_value:$role,outcome:"configuration",message:"favorite categories must be distinct values from 0 through 9"}')"
      status=73
    else
      resolved_category="$(jq -r --arg role "${desired}" '.[$role]' <<<"${categories}")"
      if [[ "$(variants_actions_latest_remote_matches "${action_json}" "${resolved_category}")" == 1 ]]; then
        result="$(jq -nc --argjson gid "${gid}" --arg role "${desired}" --arg category "${resolved_category}" \
          '{operation:"favorite",gid:$gid,desired_value:$role,resolved_category:$category,outcome:"succeeded",carried_forward:true,message:"latest remote favorite state already matches"}')"
      else
        result="$(exh_action_favorite "${gid}" "${token}" "${resolved_category}")" || status=$?
        actual_remote="$(jq -r 'if has("mutation_sent") then
          (if .mutation_sent == true then 1 else 0 end) else 1 end' <<<"${result}")"
        result="$(jq -c --arg role "${desired}" --arg category "${resolved_category}" \
          '.desired_value=$role | .resolved_category=$category' <<<"${result}")"
      fi
    fi
    ;;
  favorite_remove)
    if [[ "$(variants_actions_latest_remote_matches "${action_json}")" == 1 ]]; then
      result="$(jq -nc --argjson gid "${gid}" \
        '{operation:"favorite",gid:$gid,desired_value:"favdel",outcome:"succeeded",carried_forward:true,message:"latest remote favorite state already matches"}')"
    else
      result="$(exh_action_favorite "${gid}" "${token}" favdel)" || status=$?
      actual_remote="$(jq -r 'if has("mutation_sent") then
        (if .mutation_sent == true then 1 else 0 end) else 1 end' <<<"${result}")"
    fi
    ;;
  rating)
    if [[ "$(variants_actions_latest_remote_matches "${action_json}")" == 1 ]]; then
      result="$(jq -nc --argjson gid "${gid}" --arg desired "${desired}" \
        '{operation:"rating",gid:$gid,desired_value:$desired,outcome:"succeeded",carried_forward:true,message:"latest remote rating already matches"}')"
    else
      result="$(exh_action_rate "${gid}" "${token}" "${desired}")" || status=$?
      actual_remote="$(jq -r 'if has("mutation_sent") then
        (if .mutation_sent == true then 1 else 0 end) else 1 end' <<<"${result}")"
    fi
    ;;
  hath_request)
    if [[ -n "$(jq -r '.hath_requested_at // empty' <<<"${action_json}")" ]] ||
      variants_retention_archive_is_regular "$(jq -r '.file_path // empty' <<<"${action_json}")" 2>/dev/null ||
      variants_retention_hath_tree_contains_gid "${gid}"; then
      result="$(jq -nc --argjson gid "${gid}" \
        '{operation:"hath_request",gid:$gid,desired_value:"request",outcome:"succeeded",preflight_noop:true,message:"archive, download, or successful request already exists"}')"
    else
      variants_hath_lock_acquire "${gid}" lock_fd || status=$?
      if [[ "${status}" -eq 0 ]]; then
        result="$(exh_action_hath "${gid}" "${token}")" || status=$?
        actual_remote="$(jq -r 'if has("mutation_sent") then
          (if .mutation_sent == true then 1 else 0 end) else 1 end' <<<"${result}")"
        variants_hath_lock_release "${lock_fd}" || true
      elif [[ "${status}" -eq 75 ]]; then
        result="$(jq -nc --argjson gid "${gid}" \
          '{operation:"hath_request",gid:$gid,desired_value:"request",outcome:"transient",message:"another H@H request holds the GID lock"}')"
        status=70
      else
        result="$(jq -nc --argjson gid "${gid}" \
          '{operation:"hath_request",gid:$gid,desired_value:"request",outcome:"configuration",message:"H@H lock could not be acquired"}')"
        status=73
      fi
    fi
    ;;
  archive_cleanup)
    result="$(variants_actions_local_cleanup "${action_json}")" || status=$?
    ;;
  *) return 1 ;;
  esac

  outcome="$(jq -r '.outcome' <<<"${result}")"
  case "${outcome}" in
  succeeded) final_status=succeeded ;;
  transient | uncertain)
    final_status=retryable_error; error_class="${outcome}"
    error_message="$(jq -r '.message' <<<"${result}")"
    ;;
  configuration)
    final_status=configuration_error; error_class=configuration
    error_message="$(jq -r '.message' <<<"${result}")"
    ;;
  permanent)
    final_status=permanent_error; error_class=permanent
    error_message="$(jq -r '.message' <<<"${result}")"
    ;;
  *) return 1 ;;
  esac
  actual_deleted="$(jq -r 'if .actual_deleted == true then 1 else 0 end' <<<"${result}")"
  if [[ "${action_type}" == hath_request && "${outcome}" == succeeded &&
    "$(jq -r '.preflight_noop // false' <<<"${result}")" != true ]]; then
    hath_succeeded=1
  fi
  variants_actions_finish "${action_id}" "${job_id}" "${owner}" \
    "${final_status}" "${error_class}" "${error_message}" "${result}" \
    "${actual_deleted}" "${hath_succeeded}" >/dev/null || return
  jq -nc --argjson gid "${gid}" --arg action_type "${action_type}" \
    --arg status "${final_status}" --argjson remote \
    "$([[ "${actual_remote}" -eq 1 ]] && printf true || printf false)" \
    '{gid:$gid,action_type:$action_type,status:$status,remote_mutation:$remote}'
}

variants_worker_handle_reconcile_actions() {
  local job_json="$1" owner="$2" remote_budget="${3:-0}"
  local job_id group_id source_gid action_json action_type item
  local remote_used=0 local_cleanups=0 results='[]' remaining next_available
  job_id="$(jq -r '.id' <<<"${job_json}")"
  group_id="$(jq -r '.group_id' <<<"${job_json}")"
  source_gid="$(jq -r '.source_gid' <<<"${job_json}")"
  variants_actions_project "${group_id}" >/dev/null || return

  while :; do
    action_json="$(variants_actions_claim_next "${job_id}" "${owner}" \
      "$([[ "${remote_used}" -lt "${remote_budget}" ]] && printf 1 || printf 0)")" || return
    [[ -n "${action_json}" ]] || break
    action_type="$(jq -r '.action_type' <<<"${action_json}")"
    item="$(variants_actions_execute_one "${action_json}" "${job_id}" "${owner}")" || return
    results="$(jq -c --argjson item "${item}" '. + [$item]' <<<"${results}")"
    if [[ "${action_type}" == archive_cleanup ]]; then
      local_cleanups=$((local_cleanups + 1))
    elif [[ "$(jq -r '.remote_mutation' <<<"${item}")" == true ]]; then
      remote_used=$((remote_used + 1))
    fi
  done

  remaining="$(db_query \
    ".parameter set :group_id ${group_id}" \
    "SELECT count(*) FROM variant_actions
      WHERE group_id = :group_id
        AND status IN ('pending','retryable_error','configuration_error','in_flight');")" || return
  if [[ "${remaining}" -gt 0 ]]; then
    next_available="$(db_query \
      ".parameter set :group_id ${group_id}" \
      "SELECT COALESCE(MIN(available_at), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
         FROM variant_actions WHERE group_id=:group_id
          AND status IN ('pending','retryable_error','configuration_error','in_flight');")" || return
    variants_worker_continue_job_at "${job_id}" "${owner}" null "${next_available}" >/dev/null || return
    jq -nc --argjson source_gid "${source_gid}" --argjson remote_used "${remote_used}" \
      --argjson local_cleanups "${local_cleanups}" --argjson results "${results}" \
      '{job_type:"reconcile_actions",source_gid:$source_gid,status:"continued",remote_mutations:$remote_used,local_cleanups:$local_cleanups,results:$results}'
  else
    variants_worker_complete_job "${job_id}" "${owner}" >/dev/null || return
    jq -nc --argjson source_gid "${source_gid}" --argjson remote_used "${remote_used}" \
      --argjson local_cleanups "${local_cleanups}" --argjson results "${results}" \
      '{job_type:"reconcile_actions",source_gid:$source_gid,status:"completed",remote_mutations:$remote_used,local_cleanups:$local_cleanups,results:$results}'
  fi
}

variants_worker_handle_reconcile_retention() {
  local job_json="$1" owner="$2" job_id group_id source_gid canonical_path
  job_id="$(jq -r '.id' <<<"${job_json}")"
  group_id="$(jq -r '.group_id' <<<"${job_json}")"
  source_gid="$(jq -r '.source_gid' <<<"${job_json}")"
  canonical_path="$(db_query \
    ".parameter set :group_id ${group_id}" \
    "SELECT COALESCE(canonical.file_path, '')
       FROM variant_groups AS grouped
       LEFT JOIN galleries AS canonical ON canonical.gid=grouped.canonical_gid
      WHERE grouped.id=:group_id AND grouped.is_active=1
        AND grouped.desired_rating=11 AND grouped.canonical_gid IS NOT NULL;")" || return
  if [[ -n "${canonical_path}" ]] && variants_retention_archive_is_regular "${canonical_path}"; then
    variants_worker_queue_action_reconciliation "${group_id}" "${source_gid}" \
      "${VARIANTS_RETENTION_PRIORITY}" >/dev/null || return
    variants_worker_complete_job "${job_id}" "${owner}" >/dev/null || return
    jq -nc --argjson source_gid "${source_gid}" \
      '{job_type:"reconcile_retention",source_gid:$source_gid,status:"completed",canonical_archive:true}'
  else
    local retry_at
    retry_at="$(db_query "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now','+24 hours');")" || return
    variants_worker_continue_job_at "${job_id}" "${owner}" null \
      "${retry_at}" >/dev/null || return
    jq -nc --argjson source_gid "${source_gid}" \
      '{job_type:"reconcile_retention",source_gid:$source_gid,status:"continued",canonical_archive:false}'
  fi
}
