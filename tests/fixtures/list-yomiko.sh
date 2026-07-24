#!/usr/bin/env bash

jq -n '[
  {
    gid: 123456,
    token: "secret-gallery-token",
    title: "Displayed title",
    title_jpn: "Displayed Japanese title",
    file_count: 42,
    tags: "[\"private:metadata\"]",
    file_path: "gallery.7z",
    self_rating: 8,
    created_at: "2026-07-24T00:00:00Z"
  }
]'
