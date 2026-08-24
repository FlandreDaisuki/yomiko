#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/lib/exh.sh"
FIXTURE="${ROOT}/tests/fixtures/variant-discovery-remote"

page0=$(exh_parse_search_response "$(<"${FIXTURE}/search-page-0.html")" normal 0)
jq -e '.mode == "normal" and (.results | length) == 2 and .terminal == false and .next_page == 1' <<<"${page0}" >/dev/null
terminal=$(exh_parse_search_response "$(<"${FIXTURE}/search-terminal.html")" expunged 1)
jq -e '.mode == "expunged" and (.results[0].gid == 102) and .terminal == true and .next_page == null' <<<"${terminal}" >/dev/null
empty=$(exh_parse_search_response '<html><body>No results found</body></html>' normal 0)
jq -e '.mode == "normal" and .results == [] and .terminal == true and .next_page == null' <<<"${empty}" >/dev/null

gdata=$(exh_normalize_gallery_data_batch '[[100,"aaa"],[101,"bbb"],[103,"missing"]]' "$(<"${FIXTURE}/gdata-response.json")")
jq -e '.entries[0].status == "ok" and .entries[1].status == "error" and .entries[2].error == "missing or invalid gdata entry"' <<<"${gdata}" >/dev/null
if exh_normalize_gallery_data_batch '[[100,"aaa"],[100,"aaa"]]' '{"gmetadata":[]}' >/dev/null 2>&1; then exit 1; fi

pop=$(exh_parse_gallery_popularity "$(<"${FIXTURE}/popularity-success.html")" 2026-08-24T00:00:00Z)
jq -e '.favorite_count == 1234 and .rating_count == 56 and .error == null' <<<"${pop}" >/dev/null
missing=$(exh_parse_gallery_popularity "$(<"${FIXTURE}/popularity-missing.html")")
jq -e '.favorite_count == null and .rating_count == null and (.error | length) > 0' <<<"${missing}" >/dev/null
echo 'variant discovery remote smoke: ok'
