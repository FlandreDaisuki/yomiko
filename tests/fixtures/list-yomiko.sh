#!/usr/bin/env bash

case "${1:-}" in
list)
  if [[ -n "${MOCK_LIST_ARGS_PATH:-}" ]]; then
    printf '%s\n' "$*" >"${MOCK_LIST_ARGS_PATH}"
  fi

  if [[ "${MOCK_LIST_EMPTY:-false}" == true ]]; then
    printf '[]\n'
    exit 0
  fi
  if [[ -n "${MOCK_LIST_JSON:-}" ]]; then
    printf '%s\n' "${MOCK_LIST_JSON}"
    exit 0
  fi

  jq -n --arg file_path "${MOCK_LIST_FILE_PATH:-gallery.7z}" '[
    {
      gid: 123456,
      token: "secret-gallery-token",
      title: "Displayed title",
      title_jpn: "Displayed Japanese title",
      file_count: 42,
      tags: "[\"private:metadata\"]",
      file_path: $file_path,
      self_rating: 8,
      created_at: "2026-07-24T00:00:00Z"
    }
  ]'
  ;;
internal)
  [[ "${2:-}" == archive-paths ]] || exit 2
  if [[ -n "${MOCK_ARCHIVE_PATHS_ARGS_PATH:-}" ]]; then
    printf '%s\n' "$*" >"${MOCK_ARCHIVE_PATHS_ARGS_PATH}"
  fi
  if [[ "${MOCK_ARCHIVE_PATHS_FAIL:-false}" == true ]]; then
    printf 'mock archive-path lookup failure\n' >&2
    exit 1
  fi

  shift 2
  if [[ -n "${MOCK_ARCHIVE_PATHS_JSON:-}" ]]; then
    printf '%s\n' "${MOCK_ARCHIVE_PATHS_JSON}"
    exit 0
  fi
  jq -n \
    --arg file_path "${MOCK_LIST_FILE_PATH:-gallery.7z}" \
    --arg null_path "${MOCK_LIST_FILE_PATH_IS_NULL:-false}" \
    --args \
    '[ $ARGS.positional[] | {
      gid: (tonumber),
      archive_path: (if $null_path == "true" then null else $file_path end)
    } ]' "$@"
  ;;
*)
  exit 2
  ;;
esac
