#!/usr/bin/env bash

if [[ -n "${METRICS_FIXTURE_FAILURE:-}" ]]; then
	echo 'internal metrics failure' >&2
	exit 42
fi

printf '%s\n' \
	'# HELP fixture_metric A fixture metric.' \
	'# TYPE fixture_metric gauge' \
	'fixture_metric 1'
