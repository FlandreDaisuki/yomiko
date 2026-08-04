#!/usr/bin/env bash

case "${MOCK_FEEDBACK_RESULT:-high}" in
high) printf '{"variant_queued":true,"variant_group_id":42}\n' ;;
low) printf '{"variant_queued":false,"variant_group_id":null}\n' ;;
malformed) printf 'successful but not json\n' ;;
*) exit 9 ;;
esac
