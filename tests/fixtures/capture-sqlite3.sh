#!/usr/bin/env bash

printf '%s\n' "$@" >"${SQLITE3_ARGS_PATH:?}"
printf '[]\n'
