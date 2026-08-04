#!/usr/bin/env bash

# Durable primitives for the `yomiko variants` command family. The caller is
# expected to source common.sh and db.sh first.

VARIANTS_WORK_LOCK_PATH="/tmp/yomiko-variants.lockfile"
VARIANTS_EXPLICIT_FEEDBACK_PRIORITY=1000
# Returned by variants_downgrade_feedback when the GID has no confirmed group.
# Callers must then preserve the existing single-gallery feedback path.
VARIANTS_NOT_GROUPED_STATUS=3

variants_validate_gid() {
  local gid="$1"
  [[ "${gid}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Invalid GID '${gid}'. Must be a positive integer."
    return 1
  }
}

variants_validate_positive_integer() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Invalid ${label} '${value}'. Must be a positive integer."
    return 1
  }
}

# Persist feedback, create or reactivate its group, seed the source as a
# confirmed member, and coalesce discovery plus the source rating action in one
# transaction. The group id is the only stdout emitted by this primitive.
variants_enqueue_feedback() {
  local gid="$1"
  local rating="$2"
  local group_id

  variants_validate_gid "${gid}" || return 1
  if [[ ! "${rating}" =~ ^(8|9|10|11)$ ]]; then
    log_err "Invalid variant feedback rating '${rating}'. Must be 8 through 11."
    return 1
  fi

  # The temporary context table keeps group selection and all dependent writes
  # in one IMMEDIATE transaction and one SQLite connection.
  group_id="$(db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :rating ${rating}" \
    ".parameter set :priority ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_enqueue_context (
       singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
       group_id INTEGER NOT NULL
     );
     INSERT INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, grouped.id
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id = member.group_id
        WHERE member.gid = :gid
          AND member.membership_state = 'confirmed'
        ORDER BY grouped.is_active DESC, grouped.id
        LIMIT 1;
     INSERT OR IGNORE INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, id FROM variant_groups
        WHERE source_gid = :gid
        ORDER BY is_active DESC, id
        LIMIT 1;
     INSERT INTO variant_groups(source_gid, desired_rating)
       SELECT gallery.gid, :rating FROM galleries AS gallery
        WHERE gallery.gid = :gid
          AND NOT EXISTS (SELECT 1 FROM variant_enqueue_context);
     INSERT OR IGNORE INTO variant_enqueue_context(singleton, group_id)
       SELECT 1, id FROM variant_groups
        WHERE source_gid = :gid
        ORDER BY id DESC LIMIT 1;
     UPDATE galleries
        SET self_rating = :rating,
            feedbacked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE gid = :gid
        AND EXISTS (SELECT 1 FROM variant_enqueue_context);
     UPDATE variant_groups
        SET desired_rating = :rating,
            is_active = 1,
            latest_feedback_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT group_id FROM variant_enqueue_context);
     INSERT INTO gallery_variants(
       group_id, gid, membership_state, decision_source, match_score,
       evidence_json, metadata_snapshot_json, decided_at
     )
     SELECT context.group_id, gallery.gid, 'confirmed', 'automatic', 0,
            json_object('kind', 'feedback_source'),
            json_object(
              'gid', gallery.gid, 'token', gallery.token,
              'title', gallery.title, 'title_jpn', gallery.title_jpn,
              'category', gallery.category, 'uploader', gallery.uploader,
              'posted', gallery.posted, 'filecount', gallery.file_count,
              'filesize', gallery.filesize, 'expunged', gallery.expunged,
              'tags', CASE WHEN json_valid(gallery.tags) THEN json(gallery.tags) ELSE json('[]') END,
              'thumb', gallery.thumb, 'first_gid', gallery.first_gid,
              'first_key', gallery.first_key, 'parent_gid', gallery.parent_gid,
              'parent_key', gallery.parent_key, 'current_gid', gallery.current_gid,
              'current_key', gallery.current_key
            ),
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
       FROM galleries AS gallery
       CROSS JOIN variant_enqueue_context AS context
      WHERE gallery.gid = :gid
     ON CONFLICT(group_id, gid) DO UPDATE SET
       membership_state = 'confirmed',
       decision_source = 'automatic',
       evidence_json = excluded.evidence_json,
       metadata_snapshot_json = excluded.metadata_snapshot_json,
       decided_at = excluded.decided_at,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_enqueue_context)
        AND job_type = 'discover' AND status = 'queued';
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     ) SELECT 'discover', group_id, :gid, :priority, 'queued'
         FROM variant_enqueue_context;
     UPDATE variant_actions
        SET status = 'superseded',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_enqueue_context)
        AND gid = :gid AND action_type = 'rating'
        AND desired_value <> CAST(CASE :rating WHEN 11 THEN 10 ELSE :rating END AS TEXT)
        AND status <> 'superseded';
     INSERT INTO variant_actions(
       group_id, gid, action_type, desired_value, decision_revision_id
     )
     SELECT context.group_id, :gid, 'rating',
            CAST(CASE :rating WHEN 11 THEN 10 ELSE :rating END AS TEXT), policy.id
       FROM variant_enqueue_context AS context
       JOIN variant_policy_revisions AS policy ON policy.is_active = 1
     WHERE 1
     ON CONFLICT(action_type, gid, desired_value, decision_revision_id) DO UPDATE SET
       group_id = excluded.group_id,
       status = CASE
         WHEN variant_actions.status = 'superseded' THEN 'pending'
         ELSE variant_actions.status
       END,
       available_at = CASE
         WHEN variant_actions.status = 'superseded'
           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         ELSE variant_actions.available_at
       END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       completed_at = CASE
         WHEN variant_actions.status = 'superseded' THEN NULL
         ELSE variant_actions.completed_at
       END;
     COMMIT;
     SELECT group_id FROM variant_enqueue_context;")" || return

  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Failed to resolve a variant group for GID ${gid}."
    return 1
  }
  printf '%s\n' "${group_id}"
}

# Apply a rating below the variant threshold to an existing confirmed group.
# This stores only desired state: remote actions and archive deletion remain the
# responsibility of the variants worker. The group id is the only stdout on
# success; VARIANTS_NOT_GROUPED_STATUS means no confirmed group and no writes.
variants_downgrade_feedback() {
  local gid="$1"
  local rating="$2"
  local group_id

  variants_validate_gid "${gid}" || return 1
  if [[ ! "${rating}" =~ ^[1-7]$ ]]; then
    log_err "Invalid variant downgrade rating '${rating}'. Must be 1 through 7."
    return 1
  fi

  group_id="$(db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :rating ${rating}" \
    ".parameter set :priority ${VARIANTS_EXPLICIT_FEEDBACK_PRIORITY}" \
    "BEGIN IMMEDIATE;
     CREATE TEMP TABLE variant_downgrade_context (
       singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
       group_id INTEGER NOT NULL,
       policy_revision_id INTEGER NOT NULL
     );
     INSERT INTO variant_downgrade_context(
       singleton, group_id, policy_revision_id
     )
       SELECT 1, grouped.id,
              (SELECT id FROM variant_policy_revisions
                WHERE is_active = 1 LIMIT 1)
         FROM gallery_variants AS member
         JOIN variant_groups AS grouped ON grouped.id = member.group_id
        WHERE member.gid = :gid
          AND member.membership_state = 'confirmed'
        ORDER BY grouped.is_active DESC, grouped.id
        LIMIT 1;
     UPDATE variant_groups
        SET desired_rating = :rating,
            is_active = 0,
            latest_feedback_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE id = (SELECT group_id FROM variant_downgrade_context);
     UPDATE galleries
        SET self_rating = :rating,
            feedbacked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE gid IN (
        SELECT member.gid
          FROM gallery_variants AS member
          JOIN variant_downgrade_context AS context
            ON context.group_id = member.group_id
         WHERE member.membership_state = 'confirmed'
      );
     UPDATE variant_actions
        SET status = 'superseded',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_downgrade_context)
        AND status <> 'superseded'
        AND NOT EXISTS (
          SELECT 1
            FROM gallery_variants AS member
           WHERE member.group_id = variant_actions.group_id
             AND member.gid = variant_actions.gid
             AND member.membership_state = 'confirmed'
             AND variant_actions.decision_revision_id = (
               SELECT policy_revision_id FROM variant_downgrade_context
             )
             AND (
               (variant_actions.action_type = 'rating'
                 AND variant_actions.desired_value = CAST(:rating AS TEXT))
               OR (variant_actions.action_type = 'favorite_remove'
                 AND variant_actions.desired_value = 'favdel')
               OR (variant_actions.action_type = 'archive_cleanup'
                 AND variant_actions.desired_value = 'delete')
             )
        );
     INSERT INTO variant_actions(
       group_id, gid, action_type, desired_value, decision_revision_id
     )
       SELECT context.group_id, member.gid, desired.action_type,
              desired.desired_value, context.policy_revision_id
         FROM variant_downgrade_context AS context
         JOIN gallery_variants AS member
           ON member.group_id = context.group_id
          AND member.membership_state = 'confirmed'
         CROSS JOIN (
           SELECT 'rating' AS action_type, CAST(:rating AS TEXT) AS desired_value
           UNION ALL SELECT 'favorite_remove', 'favdel'
           UNION ALL SELECT 'archive_cleanup', 'delete'
         ) AS desired
        WHERE 1
     ON CONFLICT(action_type, gid, desired_value, decision_revision_id) DO UPDATE SET
       group_id = excluded.group_id,
       status = CASE
         WHEN variant_actions.status = 'superseded' THEN 'pending'
         ELSE variant_actions.status
       END,
       available_at = CASE
         WHEN variant_actions.status = 'superseded'
           THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         ELSE variant_actions.available_at
       END,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       completed_at = CASE
         WHEN variant_actions.status = 'superseded' THEN NULL
         ELSE variant_actions.completed_at
       END;
     UPDATE variant_jobs
        SET priority = MAX(priority, :priority),
            available_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      WHERE group_id = (SELECT group_id FROM variant_downgrade_context)
        AND job_type = 'reconcile_actions' AND status = 'queued';
     INSERT OR IGNORE INTO variant_jobs(
       job_type, group_id, source_gid, priority, status
     ) SELECT 'reconcile_actions', group_id, :gid, :priority, 'queued'
         FROM variant_downgrade_context;
     COMMIT;
     SELECT group_id FROM variant_downgrade_context;")" || return

  if [[ -z "${group_id}" ]]; then
    return "${VARIANTS_NOT_GROUPED_STATUS}"
  fi
  [[ "${group_id}" =~ ^[1-9][0-9]*$ ]] || {
    log_err "Failed to resolve a variant group for GID ${gid}."
    return 1
  }
  printf '%s\n' "${group_id}"
}

# CLI enqueue is intentionally a stored-intent wrapper. Feedback integrations
# should call variants_enqueue_feedback directly so persistence and enqueueing
# cannot be split across transactions.
variants_enqueue_group() {
  local gid="$1"
  local rating

  variants_validate_gid "${gid}" || return 1
  rating="$(db_query \
    ".parameter set :gid ${gid}" \
    "SELECT self_rating FROM galleries WHERE gid = :gid;")" || return
  if [[ -z "${rating}" ]]; then
    log_err "Gallery GID ${gid} was not found."
    return 1
  fi
  if [[ ! "${rating}" =~ ^(8|9|10|11)$ ]]; then
    log_err "Gallery GID ${gid} has stored rating ${rating}; variants require 8 through 11."
    return 1
  fi
  variants_enqueue_feedback "${gid}" "${rating}"
}

variants_status_is_valid() {
  case "$1" in
  active | inactive | none | candidate_pending | winner_pending | queued | leased | completed | failed | cancelled | pending | resolved | in_flight | succeeded | retryable_error | permanent_error | configuration_error | superseded) return 0 ;;
  *) return 1 ;;
  esac
}

# Emit one JSON document. Nested state remains JSON rather than JSON-encoded
# strings by constructing the complete document inside SQLite.
variants_list_json() {
  local gid="${1:-0}"
  local status="${2:-}"

  [[ "${gid}" == "0" ]] || variants_validate_gid "${gid}" || return 1
  if [[ -n "${status}" ]] && ! variants_status_is_valid "${status}"; then
    log_err "Invalid variant status '${status}'."
    return 1
  fi

  db_query \
    ".parameter set :gid ${gid}" \
    ".parameter set :status $(db_parameter_text "${status}")" \
    "SELECT json_object('groups', COALESCE(json_group_array(json(group_json)), json('[]')))
       FROM (
         SELECT json_object(
           'id', grouped.id, 'source_gid', grouped.source_gid,
           'desired_rating', grouped.desired_rating,
           'status', CASE grouped.is_active WHEN 1 THEN 'active' ELSE 'inactive' END,
           'canonical_gid', grouped.canonical_gid,
           'review_state', grouped.review_state,
           'last_discovered_at', grouped.last_discovered_at,
           'last_evaluated_at', grouped.last_evaluated_at,
           'next_discovery_at', grouped.next_discovery_at,
           'active_evaluation_id', grouped.active_evaluation_id,
           'members', json(COALESCE((
             SELECT json_group_array(json_object(
               'gid', member.gid, 'membership_state', member.membership_state,
               'decision_source', member.decision_source,
               'match_score', member.match_score, 'variant_score', member.variant_score,
               'variant_state', member.variant_state,
               'evidence', json(member.evidence_json),
               'metadata_snapshot', json(member.metadata_snapshot_json),
               'variant_score_breakdown', CASE WHEN member.variant_score_json IS NULL THEN NULL ELSE json(member.variant_score_json) END
             )) FROM gallery_variants AS member WHERE member.group_id = grouped.id
           ), '[]')),
           'jobs', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', job.id, 'job_type', job.job_type, 'source_gid', job.source_gid,
               'priority', job.priority, 'status', job.status,
               'attempt_count', job.attempt_count, 'available_at', job.available_at,
               'lease_owner', job.lease_owner, 'lease_expires_at', job.lease_expires_at,
               'last_error_class', job.last_error_class, 'last_error', job.last_error
             )) FROM variant_jobs AS job WHERE job.group_id = grouped.id
           ), '[]')),
           'reviews', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', review.id, 'review_type', review.review_type,
               'candidate_gid', review.candidate_gid, 'evaluation_id', review.evaluation_id,
               'status', review.status, 'decision', review.decision,
               'selected_gid', review.selected_gid, 'evidence', json(review.evidence_json),
               'choices', json(review.choices_json)
             )) FROM variant_reviews AS review WHERE review.group_id = grouped.id
           ), '[]')),
           'actions', json(COALESCE((
             SELECT json_group_array(json_object(
               'id', action.id, 'evaluation_id', action.evaluation_id,
               'gid', action.gid, 'action_type', action.action_type,
               'desired_value', action.desired_value, 'status', action.status,
               'attempt_count', action.attempt_count, 'available_at', action.available_at,
               'last_error', action.last_error
             )) FROM variant_actions AS action WHERE action.group_id = grouped.id
           ), '[]'))
         ) AS group_json
         FROM variant_groups AS grouped
         WHERE (:gid = 0 OR grouped.source_gid = :gid OR EXISTS (
                  SELECT 1 FROM gallery_variants AS member
                   WHERE member.group_id = grouped.id AND member.gid = :gid
                ))
           AND (:status = ''
             OR (:status = 'active' AND grouped.is_active = 1)
             OR (:status = 'inactive' AND grouped.is_active = 0)
             OR grouped.review_state = :status
             OR EXISTS (SELECT 1 FROM variant_jobs AS job
                         WHERE job.group_id = grouped.id AND job.status = :status)
             OR EXISTS (SELECT 1 FROM variant_reviews AS review
                         WHERE review.group_id = grouped.id AND review.status = :status)
             OR EXISTS (SELECT 1 FROM variant_actions AS action
                         WHERE action.group_id = grouped.id AND action.status = :status))
         ORDER BY grouped.id
       );"
}

variants_work() (
  local max_jobs=1
  local dry_run=0
  local lock_fd queued_json queued_count

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --max-jobs=*) max_jobs="${1#*=}"; shift ;;
    --max-jobs)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        log_err "Missing value for --max-jobs."
        return 1
      fi
      max_jobs="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) log_err "Unknown variants work option: $1"; return 1 ;;
    esac
  done
  variants_validate_positive_integer "max jobs" "${max_jobs}" || return 1

  exec {lock_fd}>"${VARIANTS_WORK_LOCK_PATH}"
  if ! flock -n "${lock_fd}"; then
    if yomiko_in_api_mode; then
      printf '{"locked":true,"dry_run":%s,"jobs":[]}\n' "$([[ "${dry_run}" -eq 1 ]] && printf true || printf false)"
    else
      log "Another variants worker is already in progress."
    fi
    return 0
  fi

  # Discovery/evaluation implementations arrive in later phases. Reporting
  # runnable work without leasing it guarantees unsupported jobs are neither
  # consumed nor incorrectly completed.
  queued_json="$(db_query \
    ".parameter set :max_jobs ${max_jobs}" \
    "SELECT COALESCE(json_group_array(json_object(
       'id', id, 'job_type', job_type, 'group_id', group_id,
       'source_gid', source_gid, 'priority', priority, 'status', status,
       'available_at', available_at
     )), json('[]'))
       FROM (SELECT * FROM variant_jobs
              WHERE status = 'queued' AND available_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
              ORDER BY priority DESC, id LIMIT :max_jobs);"
  )" || return

  if yomiko_in_api_mode; then
    printf '{"locked":false,"dry_run":%s,"jobs":%s}\n' \
      "$([[ "${dry_run}" -eq 1 ]] && printf true || printf false)" "${queued_json}"
  else
    queued_count="$(jq 'length' <<<"${queued_json}")"
    log "Variants worker found ${queued_count} queued job(s); processing is not enabled yet."
  fi
)

cmd_variants() {
  local subcommand="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "${subcommand}" in
  enqueue)
    if [[ $# -ne 1 ]]; then
      log_err "Usage: yomiko variants enqueue <gid>"
      return 1
    fi
    local group_id
    group_id="$(variants_enqueue_group "$1")" || return
    if yomiko_in_api_mode; then
      printf '{"variant_queued":true,"variant_group_id":%s}\n' "${group_id}"
    else
      log "Queued variant discovery for GID $1 in group ${group_id}."
    fi
    ;;
  list)
    local gid=0 status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --gid=*) gid="${1#*=}"; shift ;;
      --gid)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --gid."; return 1; }
        gid="$2"; shift 2 ;;
      --status=*) status="${1#*=}"; shift ;;
      --status)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || { log_err "Missing value for --status."; return 1; }
        status="$2"; shift 2 ;;
      *) log_err "Unknown variants list option: $1"; return 1 ;;
      esac
    done
    variants_list_json "${gid}" "${status}"
    ;;
  work) variants_work "$@" ;;
  *)
    log_err "Usage: yomiko variants <enqueue|list|work>"
    return 1
    ;;
  esac
}
