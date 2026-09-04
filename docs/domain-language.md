# Yomiko Domain Language

This document defines the vocabulary used in schema, code, JSON, CLI, API, and
documentation changes. It is normative for new work. Existing names listed in
the migration register remain compatibility constraints until a migration
changes them; their presence does not make them preferred terminology.

At an external boundary, preserve the provider's field name only while parsing
or serializing that provider's contract. Translate it to the canonical Yomiko
name immediately. Historical migration files must remain unchanged; schema
renames belong in a new migration and must update persisted JSON deliberately.

## Naming rules

- Use the full domain term in prose. Acronyms may follow it, for example
  **gallery ID (GID)**.
- Use `snake_case` for schema and JSON identifiers.
- Keep an ExHentai field name in Yomiko when it has the same meaning. Introduce
  a different name only when the Yomiko concept is semantically different.
- Qualify credentials by owner and purpose. Never introduce an unqualified
  `key` or `token` when more than one credential kind is in scope.
- Name timestamps as `<event>_at`. When a numeric external timestamp cannot be
  converted at ingestion, include its unit in the internal name.
- A relationship to a gallery uses the same identity vocabulary as a gallery:
  `<relation>_gid` and `<relation>_gallery_token`.
- Do not use a process result as the entity name. A review may select a
  canonical gallery; the gallery itself is not a "winner gallery."

## Canonical glossary

### Gallery and metadata

| Canonical term | Preferred identifier | Meaning |
| --- | --- | --- |
| Gallery | `gallery` | One ExHentai/E-Hentai gallery record. |
| Gallery ID (GID) | `gid` or `<role>_gid` | The provider's numeric gallery identifier. A GID alone is not a complete remote gallery identity. |
| Gallery token | `gallery_token` or `<relation>_gallery_token` | The provider token paired with a GID in gallery URLs and API requests. The upstream `gtoken`, `token`, and chain `*_key` fields all carry this concept. |
| Gallery identity | `(gid, gallery_token)` | The complete provider identity used to address a gallery. Say “GID” when only the numeric part is meant. |
| Gallery-chain reference | `<relation>_gid` plus `<relation>_gallery_token` | A nullable reference from one gallery to its `first`, `parent`, or `current` gallery. Both values must be present or both null. |
| First gallery | `first_*` | The first gallery referenced by upstream chain metadata. It is not necessarily Yomiko's source or canonical gallery. |
| Parent gallery | `parent_*` | The immediate predecessor referenced by upstream chain metadata. |
| Current gallery | `current_*` | The replacement referenced by upstream chain metadata. This is unrelated to a group's current canonical choice. |
| Terminal gallery | — | A gallery with no distinct valid `current` reference. It is eligible for canonical selection. |
| Replaced gallery | — | A gallery whose valid `current_gid` points to a different GID. It remains historical evidence but is ineligible for a new canonical choice. |
| Display title | `title` | The provider's main title. Do not describe it as necessarily English. |
| Japanese title | `japanese_title` | The optional provider Japanese title. |
| File count | `file_count` | Number of files reported for a gallery. Matching and scoring currently interpret this as page count, but the stored fact is a file count. |
| File size in bytes | `file_size_bytes` | Provider-reported total gallery size. |
| Thumbnail URL | `thumbnail_url` | Provider-reported cover thumbnail URL. |
| Posted time | `posted_at_epoch_seconds` | Provider-reported Unix timestamp for gallery publication. |
| Community rating | `rating` in ExHentai metadata and `galleries.rating` in the retained schema | ExHentai's community aggregate rating in the range 0–5. `rating` and `galleries.rating` mean this community rating. |
| Rating count | `rating_count` | Number of provider ratings. |
| Favorite count | `favorite_count` | Number of provider favorites. |

### Local feedback and archive lifecycle

| Canonical term | Preferred identifier | Meaning |
| --- | --- | --- |
| User rating | `self_rating` in the retained schema | The locally recorded user value in the range 1–11. User ratings are named `self_rating`; they are not the community rating. |
| Desired group rating | `desired_rating` | The latest user rating projected across a variant group. It is intent, not confirmation that a remote write succeeded. |
| Remote rating | action `desired_value` for `rating` | The value sent to ExHentai; local rating 11 maps to remote rating 10. |
| Feedback recorded time | `feedback_recorded_at` | Time local feedback was recorded or projected. |
| Feedback cleanup time | `feedback_cleanup_at` | Time an archive was actually deleted by feedback/retention logic. It is not merely a rating time. |
| H@H attempt time | `hath_last_attempted_at` | Latest authorized H@H request attempt, including uncertain outcomes. |
| H@H accepted-request time | `hath_requested_at` | Latest H@H request known to have been accepted. It is not synonymous with attempt time. |
| Hath download directory | — | A source directory managed by the H@H client. Use **H@H** in prose and retain `hath` in established CLI/config identifiers. |
| Archive | `archive_path` | Yomiko's committed `.7z` artifact. An archive download serves this artifact; it does not request a new H@H download. |
| Yomiko API bearer token | `YOMIKO_API_TOKEN` | Credential authorizing mutations against Yomiko's HTTP API. It is never a gallery token or ExHentai API key. |
| ExHentai API key | `apikey` | Credential scraped with `apiuid` for ExHentai API operations. It is never a gallery token or Yomiko bearer token. |

### Variant identity and selection

| Canonical term | Preferred identifier | Meaning |
| --- | --- | --- |
| Variant group | `variant_group` / `group_id` | Yomiko's set of galleries being treated as possible representations of the same book. |
| Source gallery | `source_gid` | The gallery whose feedback created the group, or the surviving source chosen during a merge/reset. It is not necessarily canonical. A worker job copies this value for diagnostics and routing. |
| Discovery seed | `seed` / `seed_gid` | A confirmed member whose metadata is used to discover more galleries. A group can have several seeds. Do not use “source” for every seed. |
| Candidate gallery | membership state `candidate` | A discovered gallery whose same-book identity still needs a decision. |
| Confirmed member | membership state `confirmed` | A gallery accepted as representing the same book in a group. |
| Rejected candidate | membership state `rejected` | A gallery explicitly rejected from same-book membership. Do not call it a group member without the qualifier “rejected candidate.” |
| Canonical gallery | `canonical_gid` | The selected confirmed member used for canonical-dependent actions and retention. |
| Alternate gallery | variant state `alternate` | A confirmed member that is not canonical. |
| Candidate identity review | review type `candidate_identity` | Human decision between `same_book` and `different_book`. |
| Canonical selection review | current review type `winner` | Human choice of a canonical gallery when automatic scoring cannot decide. “Winner review” is an established serialized value, not the preferred domain term. |
| Identity match score | `match_score` | Evidence score for whether a candidate represents the same book. |
| Canonical score | `canonical_score` | Ranking score among confirmed members for canonical selection. It must not be called a match score. |
| Canonical decision | `variant_canonical_decisions` | Durable manual selection of a canonical gallery. `variant_groups.canonical_gid` is its current projection, not the decision record itself. |
| Evaluation | `variant_evaluation` | Immutable application of one policy revision to one confirmed-member snapshot. |

### Background processing and revisions

| Canonical term | Preferred identifier | Meaning |
| --- | --- | --- |
| Job | `variant_job` | Leased orchestration work such as discover, evaluate, or reconcile. |
| Action | `variant_action` | One durable desired remote or filesystem mutation. An action is not a job. |
| Discovery run | `variant_discovery_run` | Resumable execution state owned by one discover job. |
| Policy revision | `policy_revision_id` | Immutable revision of the combined matching, scoring, and operations policy. |
| Matching revision | `matching_revision` | Code-owned matching-algorithm version. It is not a policy revision ID. |
| Evaluation generation | `evaluation_id` / `expected_evaluation_id` | Concrete evaluation identity used to reject stale work. It is not a revision number. |

Use **status** for an entity's workflow lifecycle (`queued`, `leased`,
`completed`). Use **state** for a domain classification inside that lifecycle
(`candidate`, `confirmed`, `canonical`, `alternate`). Existing serialized
fields are compatibility contracts even where older code does not follow this
rule.

## Same-concept naming migration register

These are verified aliases for the same concept. New code must use the target
name unless it is implementing the named external or compatibility boundary.
Renaming persisted columns or JSON requires a separately tested schema/data
migration; do not edit historical migrations.

| Priority | Canonical concept | Current forms | Target internal form | Allowed boundary |
| --- | --- | --- | --- | --- |
| 2 | File count | upstream/snapshot `filecount`, database/API `file_count`, compatibility `pages`, policy component `page_count` | `file_count` for the fact; `file_count_score` for a score component | Accept upstream `filecount`; remove `pages` after compatibility callers are gone. |
| 2 | Display title | `title`, frontend fallback `title_en` | `title` | Remove `title_en` after compatibility callers are gone. |
| 2 | Japanese title | `title_jpn` | `japanese_title` | Accept upstream `title_jpn`. |
| 2 | File size in bytes | `filesize` | `file_size_bytes` | Accept upstream `filesize`. |
| 2 | Thumbnail URL | `thumb`, UI fallbacks `thumbnail` / `thumbnail_url` | `thumbnail_url` | Accept upstream `thumb`; other aliases are temporary UI compatibility. |
| 2 | Posted time | `posted` | `posted_at_epoch_seconds` | Accept upstream `posted`. |
| 2 | Canonical score | `variant_score` | `canonical_score`; use `<component>_score` for its components | Existing schema/API only. |
| 2 | Canonical selection review | review type and decision `winner`, prose “winner review” | `canonical_selection` / “canonical selection review” | Existing serialized review values only. |
| 3 | Feedback recorded time | `feedbacked_at` | `feedback_recorded_at` | Existing schema/API only. |
| 3 | Feedback cleanup time | `rated_then_deleted_at`, prose “deleted after rating” | `feedback_cleanup_at` | Existing schema/API only. |
| 3 | Archive path | `file_path` | `archive_path` | Existing schema/API only. |
| 3 | Favorite category | `favcat`, “favorite category” | `favorite_category` | `favcat` is allowed in the ExHentai form adapter. |

## Similar-looking concepts that must remain distinct

Do not “unify” the following pairs; use the qualifiers below instead.

| Concepts | Required distinction |
| --- | --- |
| Current gallery / canonical gallery | `current` is an upstream replacement-chain relation; `canonical` is Yomiko's selected representative. |
| Source gallery / discovery seed / canonical gallery | Source records group origin, seeds drive discovery, and canonical drives actions. One gallery may occupy several roles, but the roles are different. |
| Community rating / user rating / desired group rating / remote rating | These have different ranges, ownership, and synchronization guarantees. |
| Identity match score / canonical score | The first answers “same book?”; the second answers “which confirmed member is preferred?” |
| Candidate identity review / canonical selection review | The first changes membership; the second chooses among confirmed members. |
| Policy revision / matching revision / evaluation generation | Policy content, code-owned matching behavior, and a concrete evaluation snapshot invalidate work for different reasons. |
| H@H request attempt / accepted H@H request | An uncertain attempt affects cooldown but is not proof of acceptance. |
| H@H download / archive download | The first asks the external client to acquire a gallery; the second serves an existing local `.7z`. |
| Job / action / discovery run | Orchestration, desired side effect, and resumable discovery state have separate leases and lifecycles. |
| Expunged / replaced / rejected | Provider availability, chain visibility, and Yomiko identity decision are independent facts. |

## Review checklist

For schema, API, or domain-model changes:

1. Name every new field from the canonical glossary.
2. Identify external spellings and translate them in one adapter.
3. Check database rows, frozen JSON, policy JSON, CLI/API projections, and UI
   fallbacks before renaming a persisted concept.
4. Add a new entry to the migration register when an alias must temporarily
   survive.
5. Add a glossary entry when a genuinely new domain concept appears; do not
   overload an existing word.
