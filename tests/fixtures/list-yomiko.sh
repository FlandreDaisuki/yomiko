#!/usr/bin/env bash

if [[ -n "${MOCK_LIST_ARGS_PATH:-}" ]]; then
  printf '%s\n' "$*" >"${MOCK_LIST_ARGS_PATH}"
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
