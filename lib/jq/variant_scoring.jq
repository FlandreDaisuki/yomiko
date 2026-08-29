def decimal_fraction:
  tostring
  | capture("^(?<sign>-?)(?<whole>[0-9]+)(?:\\.(?<frac>[0-9]+))?(?:[eE](?<exp>-?[0-9]+))?$") as $part
  | ($part.frac // "") as $fraction
  | (($part.whole + $fraction) | tonumber) as $digits
  | (($part.exp // "0") | tonumber) as $exponent
  | (($fraction | length) - $exponent) as $scale
  | (if $part.sign == "-" then -1 else 1 end) as $sign
  | if $scale >= 0 then
      [$sign * $digits, pow(10; $scale)]
    else
      [$sign * $digits * pow(10; -$scale), 1]
    end;

def rating_points($rating; $count; $configuration):
  if $count == null then
    ($configuration.missing_count_points | trunc)
  else
    (($rating // 0) | decimal_fraction) as $rating_fraction
    | ($configuration.rating_baseline | decimal_fraction) as $baseline_fraction
    | ($configuration.count_divisor | decimal_fraction) as $divisor_fraction
    | (($rating_fraction[0] * $baseline_fraction[1] -
        $baseline_fraction[0] * $rating_fraction[1]) * $count * $divisor_fraction[1]) as $numerator
    | ($rating_fraction[1] * $baseline_fraction[1] * $divisor_fraction[0]) as $denominator
    | (if $numerator <= 0 then 0 else ($numerator / $denominator | floor) end) as $points
    | [$configuration.minimum, $points] | max
    | [., $configuration.cap] | min
    | trunc
  end;

def scoring_optional_gid:
  if . == null then null
  elif type == "number" and . >= 1 and . == floor then .
  elif type == "string" and test("^[1-9][0-9]*$") then tonumber
  else null end;

# Only the frozen five-condition automatic_same_book evidence can create
# this component; ordinary same_book membership is intentionally ignored.
def automatic_chain_leaf_gid($members; $source_gid):
  ($members | map(select((.gid | tonumber) == $source_gid)) | .[0]) as $source_member
  | ($members | map(select((.evidence.automatic_same_book // false) == true))) as $automatic_members
  | if $source_member == null or ($automatic_members | length) == 0 then null
    else (($automatic_members + [$source_member]) | unique_by(.gid | tonumber)) as $component
    | ([$component[] as $candidate
       | select(
           (any($component[];
             ((.metadata.parent_gid | scoring_optional_gid) ==
              ($candidate.gid | tonumber))) | not)
           and ((
             ($candidate.gid | tonumber) == $source_gid and
             any($component[];
               ((.gid | tonumber) != $source_gid and
                (.metadata.first_gid | scoring_optional_gid) == $source_gid))
           ) | not))
         | ($candidate.gid | tonumber)] | unique) as $leaf_gids
    | if ($leaf_gids | length) == 1 then $leaf_gids[0] else null end
    end;

def score_variant_members($normalizations):
  . as $data
  | $data.policy.scoring as $scoring
  | ($scoring.title_substring_scores | keys) as $title_keys
  | ($data.members | sort_by(.gid | tonumber)) as $members
  | ($data.source_gid // null) as $source_gid
  | (automatic_chain_leaf_gid($members; $source_gid)) as $automatic_chain_leaf_gid
  | (if $automatic_chain_leaf_gid != null
     then ([$members[]
            | select((.gid | tonumber) != $source_gid)
            | select((.evidence.automatic_same_book // false) != true)
            | (.gid | tonumber)] + [$automatic_chain_leaf_gid] | unique)
     else [$members[] | .gid | tonumber]
     end) as $canonical_member_gids
  | ($title_keys | length) as $title_key_count
  | ($normalizations[:$title_key_count]) as $normalized_title_keys
  | ($normalizations[$title_key_count:]) as $normalized_member_titles
  | ([range(0; $title_key_count) as $index |
      {substring:$title_keys[$index], normalized:$normalized_title_keys[$index],
       points:$scoring.title_substring_scores[$title_keys[$index]]}]) as $title_rules
  | ([range(0; $members | length) as $index |
      $members[$index] + {
        normalized_title: $normalized_member_titles[$index * 2],
        normalized_title_jpn: $normalized_member_titles[$index * 2 + 1]
      }]) as $normalized_members
  | ([$members[].metadata.posted | select(. != null)] | unique | sort) as $distinct_posted
  | ([
      $normalized_members[]
      | . as $member
      | ($member.gid | tonumber) as $gid
      | if ($member.metadata | type) != "object" then
          error("member metadata snapshot must be an object")
        else . end
      | ($member.metadata.tags // []) as $tags
      | if ($tags | type) != "array" or any($tags[]; type != "string") then
          error("metadata tags must be a string array or null")
        else . end
      | ([$scoring.tag_scores | to_entries[] |
          select(.key as $tag | $tags | index($tag)) |
          {tag:.key, points:.value}]) as $tag_matches
      | ([$title_rules[] |
          . as $rule
          | ([if ($member.normalized_title | contains($rule.normalized)) then "title" else empty end,
              if ($member.normalized_title_jpn | contains($rule.normalized)) then "title_jpn" else empty end]) as $fields
          | select($fields | length > 0)
          | {substring:$rule.substring, matched_fields:$fields, points:$rule.points}]) as $title_matches
      | ([$tag_matches[].points] | add // 0) as $tag_points
      | ([$title_matches[].points] | add // 0) as $title_points
      | $member.metadata.posted as $raw_posted
      | (if $raw_posted == null then null
         else (($distinct_posted | index($raw_posted)) + ($scoring.posted_rank.oldest_rank | trunc)) end) as $rank
      | (if $rank == null then 0 else $rank * ($scoring.posted_rank.step | trunc) end) as $posted_points
      | ($member.metadata.filecount // null) as $filecount
      | ($scoring.page_count // null) as $page_count_configuration
      | (if $page_count_configuration == null then 0
         elif $filecount == null then ($page_count_configuration.missing_count_points | trunc)
         else [($filecount - $page_count_configuration.offset),
               $page_count_configuration.cap] | min | trunc end) as $page_count_points
      | $member.metadata.favorite_count as $favorite_count
      | (if $favorite_count == null then ($scoring.favorite_popularity.missing_count_points | trunc)
         else [($favorite_count / $scoring.favorite_popularity.divisor | floor),
               ($scoring.favorite_popularity.cap | trunc)] | min end) as $favorite_points
      | $member.metadata.rating as $rating
      | $member.metadata.rating_count as $rating_count
      | rating_points($rating; $rating_count; $scoring.rating_confidence) as $rating_points
      | {
          gid:$gid,
          components:{
            exact_tags:{matches:$tag_matches, subtotal:$tag_points},
            title_substrings:{matches:$title_matches, subtotal:$title_points},
            posted_rank:{rank:$rank, points:$posted_points},
            page_count:{points:$page_count_points},
            favorite_popularity:{points:$favorite_points},
            rating_confidence:{points:$rating_points},
            expunged:{points:($scoring.expunged_adjustment | trunc)}
          },
          score:($tag_points + $title_points + $posted_points + $page_count_points + $favorite_points +
                 $rating_points + ($scoring.expunged_adjustment | trunc))
        }
    ]) as $scores
  | if ($scores | length) == 0 then error("variant group has no confirmed members") else . end
  | ($scores | map(select(.gid as $gid |
      $canonical_member_gids | index($gid) != null))) as $canonical_scores
  | if ($canonical_scores | length) == 0 then error("variant group has no canonical candidates") else . end
  | ([$canonical_scores[].score] | max) as $top
  | ($canonical_scores | sort_by([(-.score), .gid])) as $ranked
  | (if ($ranked | length) > 1 then $ranked[1].score else null end) as $runner_up_score
  | (if $runner_up_score == null then null else $top - $runner_up_score end) as $score_gap
  | ($scoring.winner_review_score_gap_exclusive | trunc) as $review_gap
  | ([$ranked[] | select($top - .score < $review_gap) | .gid]) as $review_gids
  | (if ($review_gids | length) > 1
     then (if $score_gap == 0 then "exact_tie" else "near_tie" end)
     else null end) as $review_reason
  | (if ($automatic_chain_leaf_gid != null and ($canonical_member_gids | length) == 1)
     then [$automatic_chain_leaf_gid] else $review_gids end) as $canonical_gids
  | {
      scoring_snapshot:[$members[] | {gid:(.gid | tonumber),
        title:.metadata.title, title_jpn:.metadata.title_jpn,
        tags:.metadata.tags, filecount:.metadata.filecount,
        posted:.metadata.posted, favorite_count:.metadata.favorite_count,
        rating:.metadata.rating, rating_count:.metadata.rating_count,
        first_gid:.metadata.first_gid,
        parent_gid:.metadata.parent_gid,
        automatic_same_book:(.evidence.automatic_same_book // false),
        expunged:.metadata.expunged}],
      member_scores:$scores,
      top_score:$top,
      tied_gids:$canonical_gids,
      selected_canonical_gid:(if ($canonical_gids | length) == 1 then $canonical_gids[0] else null end),
      automatic_canonical_gid:(if ($automatic_chain_leaf_gid != null and
                                    ($canonical_member_gids | length) == 1)
                               then $automatic_chain_leaf_gid else null end),
      winner_review:{runner_up_score:$runner_up_score,
                     score_gap:$score_gap, reason:$review_reason, choices:$review_gids}
    };
