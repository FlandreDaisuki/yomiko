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
| Uploader revision chain | `uploader_revision_chain` in new internal identifiers | A provider-declared linear revision sequence connected by token-validated `parent` and `current` relations. `first` is supporting consistency/traversal metadata, not a chain ID. Never infer this relationship merely because galleries have the same `uploader` value; one uploader can own several distinct chains. This is distinct from same-book identity between chains. |
| Uploader-revision reference | `<relation>_gid` plus `<relation>_gallery_token` | A nullable provider reference from one gallery revision to its `first`, `parent`, or `current` gallery revision. Both values must be present or both null. |
| First gallery revision | `first_*` | The first gallery referenced by upstream uploader-revision metadata. It is not a durable chain identity and is not necessarily Yomiko's source or canonical gallery. |
| Parent gallery revision | `parent_*` | The immediate predecessor referenced by upstream uploader-revision metadata. |
| Current gallery revision | `current_*` | The replacement referenced by upstream uploader-revision metadata. This is unrelated to a group's current canonical choice. |
| Revision member | `revision_members` | One fetched gallery in a provider uploader-revision component, including both terminal and replaced revisions. It is a current projection of provider facts, not a same-book membership decision. |
| Replaced revision | `is_terminal = 0` in `revision_members` | A nonterminal gallery in a valid uploader-revision chain. It remains gallery and historical evidence but is not a current group/canonical candidate. |
| Scoreable revision terminal | `scoreable_revision_terminals` | The unique terminal of a complete, valid uploader-revision component with the scope and score inputs required by current matching/scoring. This is the current projection used for identity and scoring; it does not promise that this exact GID already has a local archive. |
| Current revision projection | `current_revision_projection` | The authoritative provider-revision result for every fetched component, including incomplete or blocked components. It exposes the terminal, readiness, and bounded blocking reason without manufacturing a chain identity. A blocked component can have `ready = 0` while the last committed confirmed member and archive-source fallback remain authoritative; that row is not a scoreable terminal. |
| Archive source gallery | `archive_source_galleries` | The archive-retention projection normally maps a scoreable revision terminal to the exact GID whose committed local archive is currently safe to present or retain; it may name a replaced predecessor during acquisition. It also emits a fallback row for a confirmed member whose `current_revision_projection.ready = 0`, preserving that member's committed archive while the blocked target remains outside the scoreable-terminal projection. Thus the view's `gid` is either the scoreable terminal or the blocked confirmed member, while `archive_gid` is the exact archive owner; this role is separate from canonical gallery and chain identity. |
| Archive target gallery | `canonical_gid` | The gallery currently intended for archive acquisition. It is selected by canonical identity/scoring policy and is distinct from the provider's scoreable revision terminal and the local archive source; the target can differ from the source until handoff completes. |
| Archive fallback gallery | nullable `archive_gid` in `archive_source_galleries` | A replaced revision whose committed archive remains safe while the archive target is being acquired. A missing mapping is explicit `NULL`; it must not be interpreted as the target having no identity. |
| Stale archive source | archive source no longer equal to the target | A predecessor archive that is retained only for a pending handoff. It is not a canonical gallery and must not be deleted until the target archive is committed. |
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
| Exact-GID acquisition fact | `file_path`, `hath_requested_at`, `hath_last_attempted_at`, `rated_then_deleted_at` | A local archive, H@H watermark, or cleanup timestamp owned by one exact GID. These facts never transfer to a replacement merely because it represents the same uploader revision chain or same-book class. |
| Yomiko API bearer token | `YOMIKO_API_TOKEN` | Credential authorizing mutations against Yomiko's HTTP API. It is never a gallery token or ExHentai API key. |
| ExHentai API key | `apikey` | Credential scraped with `apiuid` for ExHentai API operations. It is never a gallery token or Yomiko bearer token. |

### Variant identity and selection

| Canonical term | Preferred identifier | Meaning |
| --- | --- | --- |
| Same-book identity | `same_book` | A content-identity relationship between two distinct uploader revision chains that represent the same book. Their `uploader` values may be equal or different. This decision never joins revisions inside one chain. |
| Different-book identity | `different_book` | A content-identity decision that two distinct uploader revision chains do not represent the same book. It cannot split one provider-declared chain. |
| Same-book matching | matching policy / `match_score` | Evidence evaluation between scoreable revision terminals of distinct uploader revision chains. It does not validate or establish revision-chain membership. |
| Same-book decision | review decision `same_book` or `different_book` | The human resolution of same-book matching between distinct uploader revision chains. These serialized values are never names for relations inside one chain. |
| Variant group | `variant_group` / `group_id` | Yomiko's same-book class: scoreable revision terminals of distinct uploader revision chains that have been confirmed to represent the same book. |
| Source gallery | `source_gid` | The gallery whose feedback created the group, or the surviving source chosen during a merge/reset. It is not necessarily canonical. A worker job copies this value for diagnostics and routing. |
| Discovery seed | `seed` / `seed_gid` | A confirmed member whose metadata is used to discover more galleries. A group can have several seeds. Do not use “source” for every seed. |
| Identity candidate | membership state `candidate` | The scoreable terminal of a distinct uploader revision chain whose same-book identity still needs a decision. |
| Confirmed member | membership state `confirmed` | An uploader revision chain's scoreable revision terminal accepted as representing the same book in a group. |
| Rejected candidate | membership state `rejected` | A gallery explicitly rejected from same-book membership. Do not call it a group member without the qualifier “rejected candidate.” |
| Canonical gallery | `canonical_gid` | The selected confirmed member used for canonical-dependent actions and retention. It is a same-book selection, not a provider-revision role; it may differ from the scoreable revision terminal and archive source gallery. |
| Non-canonical member | variant state `alternate` | A confirmed member that is not the canonical gallery. It may still be the archive source during a replacement handoff. |
| Candidate identity review | review type `candidate_identity` | Human `same_book` or `different_book` decision between distinct uploader revision chains. Uploader-revision validation never creates this review. |
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

| Discovery run snapshot | `cursor_json` plus staged candidate snapshots | The resumable, immutable-at-the-publication-boundary input collected by one discovery run. A snapshot is not a live graph and does not change current projections until publication succeeds. |
| Discovery candidate | row in `variant_discovery_candidates` | A provider gallery identity staged by a discovery run for validation and publication. It is not yet a current member or a review candidate. |
| Staged discovery candidate | candidate with a nonterminal staging state | A discovery candidate whose metadata, popularity, or evidence is still being collected. It is retryable staging state, not a partial publication. |
| Complete discovery candidate | candidate with `state = 'complete'` | A discovery candidate with all required provider metadata and evidence for the run's publication guard. Complete means publishable input, not that the gallery is a scoreable terminal. |
| Publication | run-level atomic operation | The transaction that applies one complete discovery snapshot to live gallery facts and all affected current projections. Use this term only for that operation; it is not a synonym for a fetched gallery or a view. |

Use **status** for an entity's workflow lifecycle (`queued`, `leased`,
`completed`). Use **state** for a domain classification inside that lifecycle
(`candidate`, `confirmed`, `canonical`, `alternate`). Existing serialized
fields remain only when the migration register explicitly retains them;
migrated vocabulary follows the canonical names above.

The naming gate is normative: before introducing a domain term or verb, confirm
that users can explain its meaning and that it is not ambiguous with an
existing role, state, or operation. In particular, do not introduce **live
graph**, **published gallery**, **accepted discovery member**, **discovery done
gallery**, or **revision last**. Keep **reviewable** for reviews, **confirmed
member** for same-book identity, and **canonical gallery** separate from
**archive source gallery**.

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

The following spellings are historical migration inputs only. The persisted
evidence backfill removes them before the canonical runtime is enabled; they
are not current projection authority or current output:

| Serialized field | Canonical interpretation | Historical disposition |
| --- | --- | --- |
| `eligible` in matching evidence | Historical spelling of `is_revision_terminal` | Removed by the persisted-evidence backfill; current producers emit only `is_revision_terminal`. |
| `uploader_revision.candidate_eligible` | Historical spelling of `uploader_revision.candidate_is_revision_terminal` | Removed by the persisted-evidence backfill; current producers emit only `candidate_is_revision_terminal`. |
| `official_chain_visibility.eligible` | Historical policy predicate | Removed from active policy during migration finalization; retained only in historical migration/policy data, never as a current revision-chain field. |

### Discovery, revision, and archive migration register

| Concept | Previous implementation form | Canonical internal form | Compatibility boundary |
| --- | --- | --- | --- |
| Revision member | `uploader_revision_members` | `revision_members` | Historical migration spelling only; migration 028 removes the old view. |
| Current revision projection | `uploader_revision_representatives` | `current_revision_projection` | Historical migration spelling only; no runtime compatibility view remains. |
| Scoreable revision terminal | `eligible_galleries` | `scoreable_revision_terminals` | Historical migration spelling only; no runtime compatibility view remains. |
| Archive source gallery | `available_galleries` | `archive_source_galleries` | Historical migration spelling only; nullable `archive_gid` means no committed archive source. |
| Identity candidate | “candidate gallery” in current projections | `candidate` membership state / “identity candidate” | Review API compatibility retains `candidate_identity` as the review type. |
| Non-canonical member | “alternate gallery” in prose | `alternate` variant state / “non-canonical member” | `alternate` remains the serialized variant state. |
| Discovery publication | “publish” phase/result used as a gallery state | `publication` run-level operation | The `publish` phase is retained as an internal phase identifier. |

Migration 028 introduces the canonical read-only view names, removes the old
view objects, and does not rewrite historical migrations, immutable evidence,
or external serialized fields. New SQL, shell, JQ, CLI, API, test, and
documentation code uses the canonical terms. The old view spellings remain
only in this historical mapping and migration files.

## Similar-looking concepts that must remain distinct

Do not “unify” the following pairs; use the qualifiers below instead.

| Concepts | Required distinction |
| --- | --- |
| Uploader revision chain / same-book identity | The first is declared by provider `first`/`parent`/`current` metadata; the second is Yomiko's content-identity judgment between distinct chains. Those chains may have the same uploader. Reserve `same_book`, `different_book`, matching, decision, and review terminology for the second. |
| Uploader revision chain / uploader metadata | Chain membership comes only from token-validated provider relations. Equal `galleries.uploader` strings never create a chain. |
| Current gallery revision / canonical gallery | `current` is an upstream uploader-revision relation; `canonical` is Yomiko's selected gallery across a same-book class. |
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
