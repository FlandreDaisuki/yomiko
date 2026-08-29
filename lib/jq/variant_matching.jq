def variant_volume_pattern:
  "(?:vol(?:ume)?\\.?|v|part|pt)\\s*[-._ ]*\\d+";

def variant_cjk_pattern:
  "[\u3040-\u30ff\u3400-\u9fff]";

def variant_query_title_terms:
  variant_volume_pattern as $volume
  | [ .[]
      | gsub("\\[(?<inside>[^]]+)\\]";
          if (.inside | test($volume)) then .inside else " " end)
      | gsub("\\b(?:creator|language|translator|digital|edition)\\b"; " ")
      | . as $cleaned
      | ($cleaned | scan($volume) | gsub("[-._ ]+"; "_")),
        ($cleaned | gsub($volume; " ") |
         scan("[\u3040-\u30ff\u3400-\u9fff]+|[\\p{L}\\p{N}]+")) ]
  | unique
  | map(select(length >= (if test(variant_cjk_pattern) then 2 else 3 end)))
  | sort_by([(-length), .])
  | .[:3];

def plan_variant_queries($normalized_titles):
  (if type == "array" then . else (.seeds // []) end | sort_by(.gid | tonumber)) as $seeds
  | ([range(0; $seeds | length) as $index |
      $seeds[$index] + {
        normalized_title:$normalized_titles[$index * 2],
        normalized_title_jpn:$normalized_titles[$index * 2 + 1]
      }]) as $normalized_seeds
  | ([
      $normalized_seeds[]
      | . as $seed
      | ($seed.gid | tonumber) as $gid
      | (
          ([($seed.tags // [])[] | select(type == "string") |
            select(startswith("artist:") or startswith("group:"))] | unique | sort
           | .[] as $creator
           | {query:("language:chinese$ other:tankoubon$ " +
                     ($creator | gsub(" "; "_")) + "$"),
              origin:("creator:" + ($gid | tostring) + ":" + $creator)}),
          ([$seed.normalized_title, $seed.normalized_title_jpn]
           | variant_query_title_terms
           | . as $terms
           | until(($terms | length) == 0 or
                   (("language:chinese$ other:tankoubon$ " +
                     ([$terms[] | "title:" + .] | join(" "))) | length) <= 200;
                   $terms[:-1])
           | select(length > 0)
           | {query:("language:chinese$ other:tankoubon$ " +
                     ([.[] | "title:" + .] | join(" "))),
              origin:("title:" + ($gid | tostring))})
        )
    ] | sort_by(.query, .origin) | group_by(.query) |
    map({query:.[0].query, origins:([.[].origin] | unique | sort)})) as $queries
  | {queries:$queries};

def variant_string_set:
  [(. // [])[] | select(type == "string")] | unique | sort;

def variant_title_tokens:
  [scan("[\\p{L}\\p{N}_]+") ] | unique | sort;

def variant_title_bigrams:
  [explode[] | [.] | implode |
   select((test("^\\s$") or test("^\\p{P}$")) | not)] as $characters
  | [range(0; [$characters | length - 1, 0] | max) |
     $characters[.]+$characters[. + 1]] | unique | sort;

def variant_intersection($left; $right):
  [$left[] | select(. as $item | $right | index($item))] | unique | sort;

def variant_union($left; $right):
  ($left + $right) | unique | sort;

def variant_dice($left; $right):
  if $left == $right and ($left | length) > 0 then 1
  elif ($left | length) > 0 and ($right | length) > 0 then
    2 * (variant_intersection($left; $right) | length) /
      (($left | length) + ($right | length))
  else 0 end;

def variant_page_count:
  (.filecount // .file_count // .pages // null) as $value
  | if $value == null then null else (try ($value | tonumber) catch null) end;

def variant_optional_gid:
  if . == null then null
  elif type == "number" and . >= 1 and . == floor then .
  elif type == "string" and test("^[1-9][0-9]*$") then tonumber
  else null end;

def variant_chain_gids:
  [.gid, .first_gid, .parent_gid, .current_gid]
  | map(variant_optional_gid)
  | map(select(. != null))
  | unique;

def variant_timestamp_seconds:
  if type != "string" or length == 0 then null
  else try fromdateiso8601 catch null end;

def variant_equal_known($left; $right):
  $left != null and $right != null
  and ($left | type) == "number"
  and ($right | type) == "number"
  and $left == $right;

def variant_volume_parts:
  [(.normalized_title, .normalized_title_jpn) | scan(variant_volume_pattern)] | unique | sort;

def variant_round_points($ratio; $maximum; $has_evidence):
  if $has_evidence then (($ratio * $maximum + 0.5) | floor) else 0 end;

def variant_matching_evidence($normalizations):
  . as $data
  | $data.source as $source
  | $data.candidate as $candidate
  | ($source + {normalized_title:$normalizations[0], normalized_title_jpn:$normalizations[1],
                normalized_category:$normalizations[2]}) as $a
  | ($candidate + {normalized_title:$normalizations[3], normalized_title_jpn:$normalizations[4],
                   normalized_category:$normalizations[5]}) as $b
  | ($a.gid | variant_optional_gid) as $a_gid
  | ($b.gid | variant_optional_gid) as $b_gid
  | ($a | variant_chain_gids) as $a_chain_gids
  | ($b | variant_chain_gids) as $b_chain_gids
  | (variant_intersection($a_chain_gids; $b_chain_gids) | length) as $shared_chain_gid_count
  | ([ $a.first_gid, $a.parent_gid, $a.current_gid,
       $b.first_gid, $b.parent_gid, $b.current_gid ]
     | map(variant_optional_gid) | map(select(. != null)) | length) as $chain_reference_count
  | (($shared_chain_gid_count > 0) and ($chain_reference_count > 0)) as $same_parent_child_chain
  | (if ($b.parent_gid | variant_optional_gid) == $a_gid or
          ($b.first_gid | variant_optional_gid) == $a_gid then $b_gid
     elif ($a.parent_gid | variant_optional_gid) == $b_gid or
          ($a.first_gid | variant_optional_gid) == $b_gid then $a_gid
     else null end) as $child_gid
  | ($a.popularity_fetched_at | variant_timestamp_seconds) as $a_popularity_fetched_at
  | ($b.popularity_fetched_at | variant_timestamp_seconds) as $b_popularity_fetched_at
  | ($a.normalized_title | variant_title_tokens) as $at
  | ($b.normalized_title | variant_title_tokens) as $bt
  | ($a.normalized_title_jpn | variant_title_bigrams) as $aj
  | ($b.normalized_title_jpn | variant_title_bigrams) as $bj
  | ([variant_dice($at; $bt), variant_dice($aj; $bj)] | max) as $title_ratio
  | variant_round_points($title_ratio; 40;
      (($at | length) > 0 or ($aj | length) > 0) and
      (($bt | length) > 0 or ($bj | length) > 0)) as $title_points
  | ($a.tags | variant_string_set) as $a_tags
  | ($b.tags | variant_string_set) as $b_tags
  | ([$a_tags[] | select(startswith("artist:") or startswith("group:"))]) as $a_creators
  | ([$b_tags[] | select(startswith("artist:") or startswith("group:"))]) as $b_creators
  | variant_intersection($a_creators; $b_creators) as $common_creators
  | (if ($common_creators | length) > 0 then 1 else 0 end) as $creator_overlap
  | (if ($common_creators | length) > 0 then 30 else 0 end) as $creator_points
  | ["parody", "character", "male", "female", "mixed"] as $content_namespaces
  | ([$a_tags[] | split(":")[0] as $namespace |
      select($content_namespaces | index($namespace))]) as $a_content
  | ([$b_tags[] | split(":")[0] as $namespace |
      select($content_namespaces | index($namespace))]) as $b_content
  | variant_intersection($a_content; $b_content) as $content_intersection
  | variant_union($a_content; $b_content) as $content_union
  | (if ($content_union | length) > 0
     then ($content_intersection | length) / ($content_union | length) else 0 end) as $content_jaccard
  | variant_round_points($content_jaccard; 20; ($content_union | length) > 0) as $content_points
  | ($a | variant_page_count) as $a_pages
  | ($b | variant_page_count) as $b_pages
  | (if $a_pages != null and $b_pages != null and (([$a_pages, $b_pages] | max) > 0)
     then ([$a_pages, $b_pages] | min) / ([$a_pages, $b_pages] | max) else 0 end) as $page_proximity
  | variant_round_points($page_proximity; 10; $a_pages != null and $b_pages != null) as $page_points
  | ($a | variant_volume_parts) as $a_parts
  | ($b | variant_volume_parts) as $b_parts
  | ([
      if ($a_creators | length) > 0 and ($b_creators | length) > 0 and
         ($common_creators | length) == 0 then "disjoint_creator_sets" else empty end,
      if $source.category != null and $candidate.category != null and
         $a.normalized_category != $b.normalized_category then "category_mismatch" else empty end,
      if ($a_parts | length) > 0 and ($b_parts | length) > 0 and
         (variant_intersection($a_parts; $b_parts) | length) == 0
      then "title_volume_part_conflict" else empty end,
      if ($source.title | not) or ($candidate.title | not) or
         (($a_creators | length) + ($b_creators | length) == 0)
      then "missing_evidence" else empty end
    ] | unique | sort) as $contradictions
  | ([($data.chain_gids // [])[] | select(tostring | test("^[0-9]+$")) | tonumber] | unique) as $chain_gids
  | ($candidate.gid as $gid | ($gid | tostring | test("^[0-9]+$")) and
     ($chain_gids | index($gid | tonumber)) != null) as $official
  | (["language:chinese", "other:tankoubon"] - $b_tags | length == 0) as $scope
  | {
      uploader_same:(($a.uploader | type) == "string" and
        ($b.uploader | type) == "string" and
        ($a.uploader | length) > 0 and ($b.uploader | length) > 0 and
        $a.uploader == $b.uploader),
      same_parent_child_chain:$same_parent_child_chain,
      rating_count_same:variant_equal_known($a.rating_count; $b.rating_count),
      favorite_count_same:variant_equal_known($a.favorite_count; $b.favorite_count),
      popularity_fetched_at_within_5_minutes:(
        $a_popularity_fetched_at != null and $b_popularity_fetched_at != null and
        (($a_popularity_fetched_at - $b_popularity_fetched_at) | abs) <= 300)
    } as $automatic_same_book_conditions
  | ($automatic_same_book_conditions | [to_entries[].value] | all(. == true)) as $automatic_same_book
  | {
      gid:$candidate.gid,
      category:(if $official and $scope then "official_chain"
                elif $official then "rejected_out_of_scope_chain"
                elif $scope then "independent" else "out_of_scope" end),
      in_scope:$scope,
      official_chain:$official,
      automatic_same_book:$automatic_same_book,
      automatic_same_book_conditions:$automatic_same_book_conditions,
      automatic_same_book_child_gid:(if $automatic_same_book then $child_gid else null end),
      reviewable:($scope and ($official | not) and ($automatic_same_book | not)),
      score:($title_points + $creator_points + $content_points + $page_points),
      raw:{title_similarity:$title_ratio, creator_overlap:$creator_overlap,
           content_tag_jaccard:$content_jaccard, page_proximity:$page_proximity},
      normalized:{title_tokens_source:$at, title_tokens_candidate:$bt,
        japanese_bigrams_shared:(variant_intersection($aj; $bj) | length),
        creators_source:$a_creators, creators_candidate:$b_creators,
        content_tags_source:$a_content, content_tags_candidate:$b_content,
        page_counts:[$a_pages, $b_pages]},
      components:{title:{points:$title_points,max:40}, creator:{points:$creator_points,max:30},
        content_tags:{points:$content_points,max:20}, page_proximity:{points:$page_points,max:10}},
      contradictions:$contradictions,
      origins:($data.origins // [])
    };
