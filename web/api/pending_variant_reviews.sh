#!/usr/bin/env bash

# usage:
# curl 'http://localhost:62080/api/pending_variant_reviews.sh'

API_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOMIKO_BIN="${YOMIKO_BIN:-${HOME}/bin/yomiko}"
# shellcheck disable=SC1091
source "${API_DIR}/_middleware.sh"
middleware_cli_in_api_mode
middleware_cors

json_error() {
  local status="$1"
  local error="$2"

  echo "Status: ${status}"
  echo "Content-Type: application/json"
  echo ""
  jq -n --arg error "${error}" '{success: false, error: $error}'
}

if [[ "${REQUEST_METHOD:-GET}" != "GET" ]]; then
  echo "Status: 405 Method Not Allowed"
  echo "Allow: GET"
  echo "Content-Type: application/json"
  echo ""
  jq -n '{success: false, error: "Method not allowed"}'
  exit 0
fi

if [[ -n "${QUERY_STRING:-}" ]]; then
  json_error "400 Bad Request" "Query parameters are not supported"
  exit 0
fi

cli_args=(variants pending-reviews)

api_tmp_dir="$(mktemp -d /tmp/yomiko-reviews.XXXXXX)" || {
  json_error "502 Bad Gateway" "Failed to list variant reviews"
  exit 0
}
trap 'rm -rf -- "${api_tmp_dir}"' EXIT
cli_output_path="${api_tmp_dir}/cli.json"
cli_error_path="${api_tmp_dir}/cli.stderr"
validation_path="${api_tmp_dir}/valid"

if "${YOMIKO_BIN}" "${cli_args[@]}" >"${cli_output_path}" 2>"${cli_error_path}"; then
  :
else
  api_log_command_failure "${cli_args[*]}" "$(<"${cli_error_path}")"
  # A read failure is an upstream/CLI failure. Never return its diagnostics.
  json_error "502 Bad Gateway" "Failed to list variant reviews"
  exit 0
fi

if sqlite3 -bail :memory: <<SQL >"${validation_path}" 2>/dev/null
WITH payload(raw) AS MATERIALIZED (
  SELECT CAST(readfile('${cli_output_path}') AS TEXT)
), valid_payload(raw,value) AS MATERIALIZED (
  SELECT raw,jsonb(raw) FROM payload WHERE json_valid(raw)
), checked(raw) AS (
  SELECT raw FROM valid_payload
   WHERE json_type(value)='object'
     AND json_type(value,'$.reviews')='array'
     AND json_type(value,'$.actionable_count') IN ('integer','real')
     AND json_extract(value,'$.actionable_count')>=0
     AND json_extract(value,'$.actionable_count')=json_array_length(value,'$.reviews')
     AND CAST(json_extract(value,'$.actionable_count') AS INTEGER)=json_extract(value,'$.actionable_count')
     AND substr(raw,1,20)='{"actionable_count":'
     AND substr(CAST(raw AS BLOB),-2,2)=x'7d0a'
     AND instr(CAST(raw AS BLOB),x'0a')=length(CAST(raw AS BLOB))
     AND (SELECT COUNT(*) FROM json_each(valid_payload.value))=2
     AND (SELECT COUNT(*) FROM json_each(valid_payload.value)
           WHERE key='actionable_count')=1
     AND (SELECT COUNT(*) FROM json_each(valid_payload.value)
           WHERE key='reviews')=1
     AND NOT EXISTS (
       SELECT 1 FROM json_each(valid_payload.value)
        WHERE key NOT IN ('actionable_count','reviews')
     )
     AND NOT EXISTS (
       SELECT 1 FROM json_tree(valid_payload.value) AS node
        WHERE node.key IN (
          'group_id','selected_gid','selected_canonical_gid','first_key',
          'parent_key','current_key','chain_key_mismatch'
        )
     )
     AND NOT EXISTS (
       SELECT 1 FROM json_each(valid_payload.value,'$.reviews') AS review
        WHERE review.type<>'object'
           OR json_type(review.value,'$.id') IS NULL
           OR json_type(review.value,'$.id') NOT IN ('integer','real')
           OR json_type(review.value,'$.review_type') IS NOT 'text'
           OR json_extract(review.value,'$.review_type') NOT IN ('candidate_identity','winner')
           OR json_type(review.value,'$.source_gid') IS NULL
           OR json_type(review.value,'$.source_gid') NOT IN ('integer','real')
           OR json_type(review.value,'$.status') IS NOT 'text'
           OR json_extract(review.value,'$.status')<>'pending'
           OR json_type(review.value,'$.evidence') IS NOT 'object'
           OR json_type(review.value,'$.source') IS NOT 'object'
           OR json_type(review.value,'$.choices') IS NOT 'array'
           OR json_type(review.value,'$.canonical_gid') IS NULL
           OR json_type(review.value,'$.canonical_gid') NOT IN ('null','integer','real')
           OR (json_extract(review.value,'$.review_type')='candidate_identity' AND (
                 json_type(review.value,'$.candidate') IS NOT 'object'
              OR json_type(review.value,'$.candidate_gid') IS NULL
              OR json_type(review.value,'$.candidate_gid') NOT IN ('integer','real')
              OR (json_type(review.value,'$.covered_review_count') IS NOT NULL
                  AND json_type(review.value,'$.covered_review_count') NOT IN ('null','integer','real'))
              OR (json_type(review.value,'$.covered_review_count') IN ('integer','real') AND (
                     json_extract(review.value,'$.covered_review_count')<1
                  OR CAST(json_extract(review.value,'$.covered_review_count') AS INTEGER)
                     !=json_extract(review.value,'$.covered_review_count')))
              OR (json_type(review.value,'$.source_class_size') IS NOT NULL
                  AND json_type(review.value,'$.source_class_size') NOT IN ('null','integer','real'))
              OR (json_type(review.value,'$.source_class_size') IN ('integer','real') AND (
                     json_extract(review.value,'$.source_class_size')<1
                  OR CAST(json_extract(review.value,'$.source_class_size') AS INTEGER)
                     !=json_extract(review.value,'$.source_class_size')))
              OR (json_type(review.value,'$.candidate_class_size') IS NOT NULL
                  AND json_type(review.value,'$.candidate_class_size') NOT IN ('null','integer','real'))
              OR (json_type(review.value,'$.candidate_class_size') IN ('integer','real') AND (
                     json_extract(review.value,'$.candidate_class_size')<1
                  OR CAST(json_extract(review.value,'$.candidate_class_size') AS INTEGER)
                     !=json_extract(review.value,'$.candidate_class_size')))
           ))
           OR (json_extract(review.value,'$.review_type')='winner' AND (
                 (json_type(review.value,'$.candidate') IS NOT NULL
                  AND json_type(review.value,'$.candidate') IS NOT 'null')
              OR (json_type(review.value,'$.candidate_gid') IS NOT NULL
                  AND json_type(review.value,'$.candidate_gid') IS NOT 'null')
           ))
     )
)
SELECT 1 FROM checked;
SQL
  [[ "$(<"${validation_path}")" == 1 ]]
then
  :
else
  api_log_command_failure "${cli_args[*]}" "Invalid CLI result: JSON schema or privacy validation failed"
  json_error "502 Bad Gateway" "Failed to list variant reviews"
  exit 0
fi

echo "Status: 200 OK"
echo "Content-Type: application/json"
echo ""
# The CLI emits one compact JSON object. Preserve its complete bytes after the
# SQLite shape/privacy validation, adding only the public success envelope.
sed '1s/^[[:space:]]*{/{"success":true,/' "${cli_output_path}"
