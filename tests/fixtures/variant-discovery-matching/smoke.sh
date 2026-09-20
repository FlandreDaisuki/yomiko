#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"; source "$root/lib/variant_matching.sh"
q=$(printf '%s' '{"seeds":[{"gid":2,"title":"A long title Vol 2","title_jpn":"漫画","tags":["artist:a","artist:b"]},{"gid":1,"title":"A long title Vol 2","tags":["artist:a"]}]}' | variants_matching_plan_queries)
[[ $(jq '.queries|length' <<<"$q") -eq 3 ]]
[[ $(jq -r '.queries[]|select(.query|contains("artist:a$"))|.origins|length' <<<"$q") -eq 2 ]]
q2=$(printf '%s' '{"seeds":[{"gid":3,"title":"[Artist Name] Book [Vol. 2]","title_jpn":"漫画","tags":["artist:artist name"]}]}' | variants_matching_plan_queries)
[[ $(jq -r '.queries[]|select(.query|contains("artist:artist_name$"))|.query' <<<"$q2") == *'artist:artist_name$'* ]]
[[ $(jq -r '.queries[]|select((.origins|index("title:3")))|.query' <<<"$q2") == *'title:vol_2'* && $(jq -r '.queries[]|select((.origins|index("title:3")))|.query' <<<"$q2") == *'title:漫画'* ]]
e=$(printf '%s' '{"source":{"title":"Book","tags":["artist:a"],"filecount":100},"candidate":{"gid":9,"title":"Other","tags":["artist:a","language:chinese","other:tankoubon"],"filecount":50}}' | variants_matching_evidence_json)
[[ $(jq '.components.creator.points' <<<"$e") -eq 30 ]]
[[ $(jq '.reviewable' <<<"$e") == true ]]
automatic=$(printf '%s' '{"source":{"gid":1,"token":"token-1","title":"Parent","tags":["language:chinese","other:tankoubon"],"first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null},"candidate":{"gid":9,"token":"token-9","title":"Child","tags":["language:chinese","other:tankoubon"],"first_gid":1,"first_token":"token-1","parent_gid":1,"parent_token":"token-1","current_gid":null,"current_token":null}}' | variants_matching_evidence_json)
[[ $(jq '.uploader_revision.linked' <<<"$automatic") == true ]]
[[ $(jq '.reviewable' <<<"$automatic") == false ]]
[[ $(jq '.uploader_revision.child_gid' <<<"$automatic") -eq 9 ]]
[[ $(jq '.uploader_revision.chain_consistent' <<<"$automatic") == true ]]
[[ $(jq '.uploader_revision.contradictions | length' <<<"$automatic") -eq 0 ]]
not_automatic=$(printf '%s' '{"source":{"gid":1,"token":"token-1","title":"Parent","tags":["language:chinese","other:tankoubon"],"first_gid":null,"first_token":null,"parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null},"candidate":{"gid":9,"token":"token-9","title":"Child","tags":["language:chinese","other:tankoubon"],"first_gid":1,"first_token":"wrong-token","parent_gid":1,"parent_token":"token-1","current_gid":null,"current_token":null}}' | variants_matching_evidence_json)
[[ $(jq '.uploader_revision.linked' <<<"$not_automatic") == false ]]
[[ $(jq '.uploader_revision.chain_consistent' <<<"$not_automatic") == false ]]
[[ $(jq -r '.uploader_revision.contradictions | join(",")' <<<"$not_automatic") == chain_token_mismatch ]]
shared_first=$(printf '%s' '{"source":{"gid":1,"token":"token-1","title":"Parent","tags":["language:chinese","other:tankoubon"],"first_gid":50,"first_token":"token-50","parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null},"candidate":{"gid":9,"token":"token-9","title":"Sibling","tags":["language:chinese","other:tankoubon"],"first_gid":50,"first_token":"token-50","parent_gid":null,"parent_token":null,"current_gid":null,"current_token":null}}' | variants_matching_evidence_json)
[[ $(jq '.uploader_revision.linked' <<<"$shared_first") == false ]]
[[ $(jq '.reviewable' <<<"$shared_first") == true ]]
[[ $(jq '.uploader_revision.chain_consistent' <<<"$shared_first") == true ]]
v=$(printf '%s' '{"source":{"title":"Book [Vol. 1]","title_jpn":"漫画 Part 1","tags":[]},"candidate":{"gid":9,"title":"Book [Vol. 2]","title_jpn":"漫画 Part 2","tags":[]}}' | variants_matching_evidence_json)
[[ $(jq -r '.contradictions|join(",")' <<<"$v") == *title_volume_part_conflict* ]]
echo ok
