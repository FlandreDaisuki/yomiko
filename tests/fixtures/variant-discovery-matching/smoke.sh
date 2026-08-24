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
v=$(printf '%s' '{"source":{"title":"Book [Vol. 1]","title_jpn":"漫画 Part 1","tags":[]},"candidate":{"gid":9,"title":"Book [Vol. 2]","title_jpn":"漫画 Part 2","tags":[]}}' | variants_matching_evidence_json)
[[ $(jq -r '.contradictions|join(",")' <<<"$v") == *title_volume_part_conflict* ]]
echo ok
