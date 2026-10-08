def exh_metadata_invalid($message):
  error("invalid gallery metadata: " + $message);

def exh_metadata_required($name):
  if has($name) and .[$name] != null then .[$name]
  else exh_metadata_invalid("missing required field " + $name)
  end;

def exh_metadata_unsigned_integer($name; $maximum):
  (if type == "number" then .
   elif type == "string" and test("^(0|[1-9][0-9]*)$") then tonumber
   else exh_metadata_invalid($name + " must be an unsigned integer")
   end)
  | if . >= 0 and . <= $maximum and . == floor then .
    else exh_metadata_invalid($name + " must be an unsigned integer")
    end;

def exh_metadata_decimal($name; $minimum; $maximum):
  (if type == "number" then .
   elif type == "string" and test("^(0|[1-9][0-9]*)([.][0-9]+)?$") then tonumber
   else exh_metadata_invalid($name + " must be numeric")
   end)
  | if . >= $minimum and . <= $maximum then .
    else exh_metadata_invalid($name + " is outside the allowed range")
    end;

def exh_metadata_optional_unsigned_integer($name; $maximum):
  if . == null then null else exh_metadata_unsigned_integer($name; $maximum) end;

def exh_metadata_optional_nonempty_string($name):
  if . == null then null
  elif type == "string" and length > 0 then .
  else exh_metadata_invalid($name + " must be a non-empty string or null")
  end;

def normalize_gallery_metadata($expected_gid):
  if type != "object" then exh_metadata_invalid("root must be an object") else . end
  | if has("first_token") then . else . + {first_token: .first_key} end
  | if has("parent_token") then . else . + {parent_token: .parent_key} end
  | if has("current_token") then . else . + {current_token: .current_key} end
  | del(.first_key, .parent_key, .current_key)
  | . as $metadata
  | ($metadata | exh_metadata_required("gid") | exh_metadata_unsigned_integer("gid"; 2147483647)) as $gid
  | if ($gid | tostring) != ($expected_gid | tonumber | tostring)
    then exh_metadata_invalid("gid does not match the requested gallery")
    else .
    end
  | ($metadata | exh_metadata_required("token")) as $token
  | ($metadata | exh_metadata_required("title")) as $title
  | ($metadata | exh_metadata_required("filecount") | exh_metadata_unsigned_integer("filecount"; 2147483647)) as $filecount
  | ($metadata | exh_metadata_required("expunged")) as $expunged
  | ($metadata | exh_metadata_required("tags")) as $tags
  | ($metadata | exh_metadata_required("rating") | exh_metadata_decimal("rating"; 0; 5)) as $rating
  | ($metadata | exh_metadata_required("category")) as $category
  | ($metadata | exh_metadata_required("uploader")) as $uploader
  | ($metadata | exh_metadata_required("posted") | exh_metadata_unsigned_integer("posted"; 9007199254740991)) as $posted
  | ($metadata | exh_metadata_required("filesize") | exh_metadata_unsigned_integer("filesize"; 9007199254740991)) as $filesize
  | ($metadata | exh_metadata_required("thumb")) as $thumb
  | (($metadata.first_gid? // null) | exh_metadata_optional_unsigned_integer("first_gid"; 2147483647)) as $first_gid
  | (($metadata.parent_gid? // null) | exh_metadata_optional_unsigned_integer("parent_gid"; 2147483647)) as $parent_gid
  | (($metadata.current_gid? // null) | exh_metadata_optional_unsigned_integer("current_gid"; 2147483647)) as $current_gid
  | (($metadata.first_token? // null) | exh_metadata_optional_nonempty_string("first_token")) as $first_token
  | (($metadata.parent_token? // null) | exh_metadata_optional_nonempty_string("parent_token")) as $parent_token
  | (($metadata.current_token? // null) | exh_metadata_optional_nonempty_string("current_token")) as $current_token
  | if ($token | type) != "string" or ($token | length) == 0
    then exh_metadata_invalid("token must be a non-empty string") else . end
  | if ($title | type) != "string" or ($title | length) == 0
    then exh_metadata_invalid("title must be a non-empty string") else . end
  | if ($category | type) != "string" or $category != "Manga"
    then exh_metadata_invalid("category must be exactly Manga") else . end
  | if ($uploader | type) != "string" or ($uploader | length) == 0
    then exh_metadata_invalid("uploader must be a non-empty string") else . end
  | if ($thumb | type) != "string" or ($thumb | length) == 0
    then exh_metadata_invalid("thumb must be a non-empty string") else . end
  | if (($metadata.title_jpn? // null) | type) != "null"
      and (($metadata.title_jpn? // null) | type) != "string"
    then exh_metadata_invalid("title_jpn must be a string or null") else . end
  | if ($expunged | type) != "boolean"
    then exh_metadata_invalid("expunged must be boolean") else . end
  | if ($tags | type) != "array" or any($tags[]; type != "string")
    then exh_metadata_invalid("tags must be an array of strings") else . end
  | {
      gid: $gid,
      token: $token,
      title: $title,
      title_jpn: ($metadata.title_jpn? // null),
      filecount: $filecount,
      expunged: $expunged,
      tags: $tags,
      rating: $rating,
      uploader: $uploader,
      posted: $posted,
      filesize: $filesize,
      thumb: $thumb,
      first_gid: $first_gid,
      first_token: $first_token,
      parent_gid: $parent_gid,
      parent_token: $parent_token,
      current_gid: $current_gid,
      current_token: $current_token
    };
