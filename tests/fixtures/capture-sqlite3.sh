#!/usr/bin/env bash

{
	printf '%s\n' "$@"
	cat
} >"${SQLITE3_ARGS_PATH:?}"
printf '[]\n'
