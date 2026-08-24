#!/usr/bin/env bash

case "${MOCK_FEEDBACK_RESULT:-high}" in
high) printf '{"variant_queued":true}\n' ;;
low) printf '{"variant_queued":false}\n' ;;
malformed) printf 'successful but not json\n' ;;
*) exit 9 ;;
esac
