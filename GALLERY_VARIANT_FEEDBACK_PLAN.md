# Gallery Variant Feedback — Working Plan

Status: The durable foundation, review interfaces, bounded discovery,
revision-bound scoring sweep, operational remote actions, H@H replacement, and
guarded archive retention milestones are implemented. Matching and operational
rules are code-owned; legacy expanded-policy matching/operations JSON and
hashes remain compatibility and audit evidence only.

## Next Phase Order

All future subagent assignments have a strict five-minute work credit. A new
credit requires an explicit coordinator follow-up; subagents cannot extend
their own assignment window.

1. Complete final native-image and disposable schema-007 upgrade verification
   for the operational milestone, then deploy it without an extra mutation
   enable flag.
2. Discuss replacing Python for Unicode NFKC plus full case folding and local
   score computation. Compare alternatives and prove equivalent behavior with
   Unicode fixtures before changing the runtime dependency.

No product decision remains open for the operational milestone. Unknown remote
behavior must continue to surface as classified evidence rather than adding
undocumented HTML success guesses.

## Discovery Worker/Scheduler — Completed Phase Contract

This section records the completed discovery contract. It did not authorize
remote mutations during that phase; those are covered by the operational
milestone below. The discovery matching/search behavior was confirmed on
2026-08-24.

### A. Ordered schema transition and fixed matching identity

1. Add migration 007 without editing migrations 005 or 006.
2. Define one application constant, `VARIANTS_MATCHING_REVISION`, initially
   `1`. Discovery reads fixed matching behavior from code, not from the active
   scoring policy's legacy `matching_hash` or `matching` JSON section.
3. Persist the revision on the last completed group discovery, every published
   discovery membership/evidence row, and every retained candidate-identity
   review. Existing historical candidate evidence is backfilled as revision
   `1`; winner reviews remain scoring-policy evidence and do not acquire
   matching semantics.
4. Add durable discovery-run and candidate-staging state keyed to the owning
   group/job. Staging holds deduplicated GID/token origins, fetched `gdata`,
   popularity results/errors, and computed match evidence. A partial run is
   resumable but is never the group's completed snapshot.
5. Index revision-stale active groups, unfinished discovery runs, and the next
   bounded staging work. Enforce that only one unfinished discovery run can
   belong to one coalesced group discovery job.
6. A future integer revision increase makes active groups with an older or null
   completed revision immediately eligible for coalesced rediscovery. It does
   not erase manual decisions, reviews, completed runs, or evaluation history.

### B. Pure remote-read adapters

1. Add a search adapter that accepts one already-constructed query, explicit
   normal/expunged mode, and a continuation page. It always disables user
   language, uploader, and tag filters and returns normalized GID/token pairs
   plus an explicit terminal/next-page result.
2. Add a batch `gdata` adapter that rejects more than 25 inputs, validates each
   returned GID/token/error entry, and normalizes successful metadata through
   the existing metadata validator. Per-gallery API errors remain visible and
   do not silently become metadata.
3. Add an authenticated gallery-detail adapter for `favorite_count` and
   `rating_count`. A successful parse stores nonnegative counts and fetch time;
   an unavailable or changed field stores null plus bounded error evidence, as
   already required by the scoring contract.
4. Keep adapters free of SQLite and filesystem writes. Tests use checked-in
   normal, expunged, paginated, `gdata`, popularity-success, and
   popularity-missing fixtures before any live read-only rehearsal.

### C. Deterministic search and matching pipeline

1. Construct a deterministic, deduplicated query plan from the confirmed seed
   galleries selected by the decision in **Open Questions**. Every query
   includes exact `language:chinese$` and `other:tankoubon$` scope terms and is
   issued once in normal mode and once in expunged mode.
2. Creator queries use exact `artist:`/`group:` tags within the documented
   five-inclusion-term and 200-character limits. Distinctive-title queries use
   normalized title terms while preserving volume/part tokens as contradiction
   evidence. Query text and origin are retained with every result.
3. Refresh seed metadata first, then recursively traverse newly observed
   `first_gid`, `parent_gid`, and `current_gid` links until no unseen chain GID
   remains. In-scope chain members are automatic `official_chain` matches;
   out-of-scope chain members are retained as rejected evidence.
4. Independently found in-scope galleries receive an explainable integer
   metadata score from `0` through `100`: title `0`–`40`, creator overlap
   `0`–`30`, content-tag Jaccard `0`–`20`, and page proximity `0`–`10`.
   Category, volume/part conflict, disjoint creators, missing fields, raw
   features, normalized features, component points, and search origins are
   frozen in evidence.
5. Existing manual confirmed/rejected decisions are authoritative and are not
   reopened by rediscovery. A candidate already confirmed in another active
   group remains reviewable so a `same_book` decision can use the implemented
   older-group merge path.

### D. Bounded discovery state machine

1. Use explicit phases: `seed_refresh`, `chain_walk`, `search`, `gdata`,
   `popularity`, `publish`. Store only the next durable cursor and staged data;
   repeating a phase after lease expiry must be idempotent.
2. One worker invocation may advance at most one network discovery group. One
   continuation permits at most eight search requests, four `gdata` batches of
   at most 25 galleries, and the fixed bounded detail-page budget. Enforce at
   least three seconds between search requests.
3. Claim a supported due job in `BEGIN IMMEDIATE` with a unique worker owner
   and 15-minute lease. Requeue expired leases before claiming. Explicit
   feedback priority remains `1000`; matching-revision work precedes annual
   stale work at lower fixed priorities.
4. Classify authentication/configuration and stable invalid-response failures
   separately from transient HTTP/network/rate-limit failures. Transient
   attempts use delays of 5 minutes, 15 minutes, 1 hour, 6 hours, then 24 hours;
   later attempts remain at 24 hours. Every failure keeps its cursor and last
   completed group snapshot.
5. A deactivated or merged-away group cancels unpublished discovery safely.
   Unsupported `reconcile_actions`, `reconcile_retention`, and
   `policy_scoring_sweep` jobs remain queued and cannot starve supported
   `discover`/`evaluate` work.

### E. Atomic completed-snapshot publication

1. Publish only after every planned search page, chain item, `gdata` batch, and
   bounded popularity attempt has reached a terminal state.
2. In one immediate transaction, recheck the active group/job/run/revision;
   upsert normalized remote galleries while preserving local `file_path`,
   feedback, deletion, and H@H fields; publish candidate/confirmed/rejected
   evidence; and retain prior manual labels and historical rows.
3. Create at most one pending pairwise candidate review for each new ambiguous
   group/GID. Store the fixed `matching_revision`, source/candidate snapshot,
   score components, contradictions, and discovery origins in its frozen
   evidence.
4. Only the successful publication updates `last_discovered_at`, the completed
   matching revision, and `next_discovery_at = completed time + 365 days`, then
   marks the discovery job/run completed.
5. If any candidate-identity review is pending, set `candidate_pending` and do
   not enqueue evaluation. Otherwise coalesce an `evaluate` job. Candidate
   resolution continues to enqueue the already implemented local evaluation.

### F. Worker, scheduler, and dry-run behavior

1. Replace the reporting-only worker with a dispatcher for `discover` and
   `evaluate`. Evaluation remains local and calls the existing immutable
   evaluator; this phase does not consume action or policy-sweep jobs.
2. At the start of a mutating run, coalesce discovery for active groups whose
   annual time is due or whose completed matching revision is stale. The
   existing independent five-minute scheduler command, lock, and dedicated log
   remain unchanged.
3. `--max-jobs` bounds supported jobs attempted in one invocation, while the
   one-network-group rule remains stricter. Machine output reports claims,
   continuation/completion, review/evaluation routing, retries, and skipped
   unsupported work without exposing relational group IDs.
4. `--dry-run` takes no lease and performs no database, filesystem, or remote
   mutation. It may perform the same bounded remote reads for the next explicit
   or stale discovery, computes evidence in memory, and reports whether another
   continuation would be needed.

### G. Verification and handoff

1. Cover fresh and schema-006 upgrades, backfill, constraints, revision-stale
   scheduling, staging uniqueness, rollback, integrity, and foreign keys.
2. Cover query construction, normal/expunged isolation, pagination, throttling,
   25-item `gdata`, partial responses, popularity parsing/missing values, chain
   loops, deduplication, every score component, and the confirmed positive and
   negative GID fixtures.
3. Cover claims, expired leases, continuation budgets, retry schedule,
   crash/replay, no partial publication, manual-label preservation, group merge
   cancellation, candidate review creation, evaluation dispatch, annual and
   revision rediscovery, unsupported-job non-starvation, and mutation-free dry
   run.
4. Run `bash -n`, `shellcheck -x`, `git diff --check`, the full native test
   image, and a disposable fixture database migration/integrity rehearsal.
   Do not use or mutate the production database during this phase.
5. Update CLI help, README, architecture, this plan, and the shared progress
   file. Stage only the completed phase after coordinator review; do not commit
   without a separate user instruction.

## Operational Worker — Completed Milestone

Migration 008 binds evaluation and 100-group scoring-sweep jobs to an explicit
scoring revision, adds action leases and error classifications, and retains
superseded winner reviews as resolved history. Worker claims cover discovery,
evaluation, scoring sweeps, action reconciliation, and retention with the
existing 15-minute lease and global lock.

Action reconciliation re-reads current group intent and projects rating,
symbolic favorite routing, H@H, and cleanup actions in fixed order. Each worker
run sends at most 25 actual remote mutations; cleanup is unmetered. Retries use
5 minutes, 15 minutes, 1 hour, 6 hours, then 24 hours. Favorite configuration
errors pause only favorites, and successful equivalent remote state carries
forward across newer evaluations.

Rating `11` maps to remote `10`. A canonical archive or any parseable same-GID
H@H directory suppresses a replacement request. Alternates are deleted only
while the active rating-11 canonical is still a safe regular archive. Missing
or unsafe paths remain visible, and `rated_then_deleted_at` is written only
after an actual deletion. Archive completion queues retention after final
rename; startup self-heal repairs the rename/enqueue crash window.

`variants work --dry-run` remains lock-, lease-, database-, filesystem-, and
remote-mutation-free while reporting prospective jobs, preflight evidence,
remote/local budgets, errors, and continuation. Mutating worker output exposes
gallery GIDs and operational statistics but no internal group/job/action IDs.

## Goal

When a user rates a downloaded gallery `8` through `11`, enqueue independent
background work that discovers other ExHentai/E-Hentai galleries representing
the same Chinese tankoubon, evaluates them, propagates feedback, and routes
favorites. Rating `11`, which exists only in Yomiko, additionally retains the
best available archive.

For a confirmed same-book group, Yomiko should:

- propagate the group's latest local rating to every confirmed variant, mapping
  local `11` to ExHentai rating `10`;
- select one highest-scoring **canonical variant** and classify the remaining
  confirmed galleries as **alternate variants**;
- put the canonical variant in a configured canonical favorite category and
  alternates in a configured alternate category;
- for rating `11`, request the canonical variant through H@H when it is not
  already archived, downloading, or successfully requested;
- retain an existing alternate archive until a replacement canonical archive
  has been committed, then delete lower-scoring local copies and record their
  actual deletion time;
- for ratings `1` through `10`, retain the existing archive-deletion meaning and
  never request a replacement;
- reconsider active groups after one year or when the relevant matching or
  scoring policy changes.

The worker must remain independent from the H@H scan/archive loop. Feedback
persists local intent and enqueues work without waiting for discovery,
evaluation, review, or remote group actions.

## Confirmed Product Decisions

- Variant processing is triggered by ratings `8` through `11`.
- A later rating below `8` on a confirmed group member propagates that rating to
  the group, removes group favorites, deletes local archives under the existing
  rating semantics, and deactivates recurring discovery. Rating a member
  `8` through `11` again reactivates the existing group.
- Discovery is limited to galleries containing both `language:chinese` and
  `other:tankoubon`.
- Different titles, page counts, scan qualities, digital editions, and
  independent uploads can still represent the same book. Official gallery
  chains are useful evidence but are not required.
- The example galleries with GIDs `2008101`, `2795720`, `1150827`, and
  `1819641` are one book despite independent uploaders, title differences, file
  sizes, and page counts from 195 through 205.
- Normal and expunged searches are separate. Store the `expunged` flag, but do
  not penalize or restrict an expunged variant: it can receive normal actions
  and become canonical solely through the same variant score.
- Matching confidence and variant desirability are independent. A high variant
  score cannot compensate for uncertain same-book identity.
- Version one automatically confirms only official-chain matches. Exact-file
  evidence is also considered automatic proof when a future file-search adapter
  supplies it. Independently discovered metadata matches require review.
- File and image-similarity search is deferred from version one. Page-count
  differences therefore do not require local page alignment or pairwise image
  comparisons.
- Candidate and winner review is provided in the existing web feedback page.
  The web/API layer calls JSON-emitting CLI commands; it never accesses SQLite
  directly.
- Normal feedback and variant review use tabs at the same `feedback.html` URL
  and share the existing API token. Every page load defaults to **Feedback**;
  tab selection is never persisted and pending reviews remain visible as a
  badge on the **Variant reviews** tab.
- Review cards omit category because discovery is restricted to Chinese
  tankoubon. They display ExHentai state as **Expunged** or **Not Expunged**
  independently from local **Archived** or **Not Archived** state.
- Pending candidate reviews are visually grouped by feedback/source gallery.
  The source appears once above a candidate grid; each candidate retains its
  own evidence and independent **Same book** / **Different book** resolution.
  Storage and concurrency remain pairwise rather than introducing a batch
  decision.
- The independent variant worker/scheduler revisits reviewed groups. Newly
  discovered remote galleries become persisted `not_archived` candidates and
  require identity review when matching is ambiguous. Confirmed candidates
  retain membership history, then reevaluation may change the canonical
  gallery. Archived and not-archived candidates are reviewed by the same path.
- Review evidence is retained as a labeled corpus. Matching-confidence rules
  are fixed application behavior and change only through explicit software
  revisions; Yomiko does not train or activate matching rules automatically.
  The compact scoring document remains the only operator-editable policy.
  Matching uses an integer `matching_revision`, recorded by completed discovery
  and retained evidence snapshots. A revision increase coalesces rediscovery
  for active groups while preserving manual decisions and labeled evidence.
  Scoring revisions remain independent and do not require remote rediscovery.
- Manual same-book approval adds `+9999` only to match confidence; rejection
  adds `-9999`. These decisions are authoritative and persist with group
  membership.
- A winner review is required whenever the difference between the highest and
  second-highest variant scores is less than `5`. Every variant within less
  than `5` points of the top score is a review choice. Selecting a reviewed
  winner adds `+9999` only to that evaluation's variant score. The override
  expires when new candidates or a new policy revision creates another
  evaluation.
- ExHentai `posted` is the only date used by the initial scoring rules; Yomiko
  does not infer publication dates from titles or tags.
- The editable scoring policy contains only exact tag scores, title-substring
  scores, and the relative `posted` rank step. Initial tag scores are
  `other:full color = +100` and `other:uncensored = +100`; initial title rules
  are empty, and the initial `posted` step is `1`.
- Exact tag matches and title-substring matches add independently. Tag matching
  is exact. Title matching uses Unicode NFKC normalization and case folding
  across both title fields; each configured substring contributes at most once
  per gallery.
- Favorite popularity contributes
  `floor(min(favorite_count / 10, 500))`. Rating confidence contributes
  `floor(min(max((rating - 3) * rating_count / 2, 0), 500))`.
  Missing counts contribute zero, and every component remains visible in the
  persisted score breakdown.
- Favorite categories are two required, distinct environment variables with
  values from `0` through `9`:
  `YOMIKO_CANONICAL_FAVORITE_CATEGORY` and
  `YOMIKO_ALTERNATE_FAVORITE_CATEGORY`.
- Favorite placement is desired state, not append-only history. Reevaluation
  can move canonical and alternate variants, and a group downgrade below `8`
  removes favorites.
- Confirmed variants that were never downloaded are not requested merely to
  delete them.
- An operator scoring-policy change reevaluates stored groups locally. Fixed
  matching or operational behavior changes only with a software/schema
  revision, which must explicitly route any required rediscovery or
  reevaluation.
- Favoriting is important for persistent access, including access to expunged
  galleries, but an explicit group downgrade still removes those favorites.

## Current-System Constraints

- The CLI owns all SQLite access. Web API scripts use CLI commands for
  database-backed reads and writes.
- The scheduler currently runs `yomiko scan` every five minutes. Variant work
  needs a separate command, lock, log, and failure lifecycle.
- `galleries` stores only part of `gdata`. Matching and scoring additionally
  need `category`, `uploader`, `posted`, `filesize`, `thumb`, `first_gid`,
  `parent_gid`, and `current_gid`, plus the associated keys when present.
  Average rating is already supplied by `gdata`; favorite count and rating
  count require authenticated gallery-detail page parsing and new normalized
  fields.
- `yomiko feedback` currently performs rating/favorite requests synchronously,
  updates feedback state, and deletes archives for ratings `1` through `10`.
  Triggered group actions must become durable without changing ungrouped
  rating `1` through `7` behavior unnecessarily.
- `feedbacked_at`, `self_rating`, `rated_then_deleted_at`,
  `hath_requested_at`, and `file_path` have established meanings that must
  remain compatible.
- `rated_then_deleted_at` records completed deletion. It must not be set while
  an archive is merely waiting for its replacement.
- H@H, rating, and favorite calls are not currently represented as durable
  actions. A process failure can leave remote and local state partially
  updated.
- The `gdata` API accepts at most 25 galleries per metadata request. ExHentai
  searches are limited to one every three seconds.
- The current runtime image has no full Unicode normalization utility. Policy
  implementation must add a dependency that provides NFKC normalization and
  Unicode case folding for title-substring validation and comparison.

References:

- [E-Hentai API](https://ehwiki.org/wiki/API)
- [Gallery Searching](https://ehwiki.org/wiki/Gallery_Searching)
- [Favorites](https://ehwiki.org/wiki/Favorites)
- [Making Galleries](https://ehwiki.org/wiki/Making_Galleries)

## Proposed Architecture

### 1. Schema and group identity

Add ordered system migrations for the following concepts while keeping
application schema versions in `_schema_version`:

- `variant_groups`: group ID, originating feedback GID, latest desired rating,
  active/inactive state, canonical GID, last discovery/evaluation timestamps,
  next annual discovery time, active evaluation, and review state.
- `gallery_variants`: group/candidate GID, membership state (`candidate`,
  `confirmed`, or `rejected`), decision source (`automatic` or `manual`), match
  score, evidence JSON, metadata snapshot, variant score/breakdown, and
  canonical/alternate state.
- `variant_policy_revisions`: immutable expanded internal policy JSON, full
  content hash, matching/scoring/operations section hashes, creation time, and
  activation time. Only one revision is active; operators edit only its compact
  scoring projection.
- `variant_evaluations`: immutable completed or review-blocked snapshots tied
  to one policy revision, with member scores, selected canonical GID, or tie
  state.
- `variant_jobs`: job type, group/source GID, priority, status, continuation
  cursor, attempt count, availability time, lease owner/expiry, last error
  classification, and timestamps.
- `variant_actions`: desired-state and audit record for rating, favorite move,
  favorite removal, H@H request, and archive cleanup, including desired value,
  decision revision, attempts, result, and timestamps.
- `variant_reviews`: candidate-identity or tied-winner review, frozen evidence
  and choices, pending/resolved state, decision, and resolver timestamp.

Extend `galleries` through a future migration 006 with the additional normalized
`gdata` fields and `favorite_count`, `rating_count`, and
`popularity_fetched_at` fields sourced from authenticated gallery-detail pages.
Keep historical evidence and evaluations rather than overwriting old scores
when a policy changes.

Group invariants:

- a GID may appear as a candidate in multiple unresolved groups, but it can be
  confirmed in only one active group;
- feedback for a confirmed member reuses its group instead of creating another;
- if two existing groups are later confirmed to represent the same book, merge
  into the older group, preserve both histories, use the most recent feedback
  as desired rating, and enqueue reevaluation;
- at most one unresolved candidate review exists per group/candidate and one
  unresolved winner review per evaluation;
- at most one runnable job of each coalescing job type exists per group;
- action identity is unique for the action type, GID, desired value, and
  decision revision.

Index the next runnable/expired job, stale active groups, group membership,
unresolved reviews, policy sweep cursors, and action reconciliation.

### 2. Database-backed policy lifecycle

Operators edit one compact, complete scoring document:

```json
{
  "format_version": 1,
  "tag_scores": {
    "other:full color": 100,
    "other:uncensored": 100
  },
  "title_substring_scores": {},
  "posted_rank_step": 1
}
```

Tag and title values are signed integers from `-1000` through `1000`.
`posted_rank_step` is a nonnegative integer. Reject unknown keys, malformed
tags, empty title substrings, and title keys that become duplicates after
Unicode normalization. The initial title map is intentionally empty.
Add the required Unicode normalization dependency to both runtime and test
images; ASCII-only lowercasing is not an acceptable substitute for NFKC plus
Unicode case folding.

The CLI validates and expands this compact document with fixed matching,
scoring-formula, and operational behavior. The authoritative runtime policy is
the resulting immutable expanded JSON stored in `variant_policy_revisions`; an
external JSON file is only an import/export and editing format. Workers never
watch or read the file after activation.

Canonicalize compact and expanded documents as recursively key-sorted JSON with
no trailing newline before SHA-256. Preview reports the compact import hash;
database content and section hashes come from the expanded policy. Changes to
whitespace or object-key order therefore retain the same hashes and revision.
The correct legacy migration-005 scoring-section hash is
`70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69`.
Do not edit migration 005 or its seeded immutable revision. Migration 006 and
the policy loader must define the transition from that legacy full policy to
the new expanded representation while preserving revision history.

Policy preview is mutation-free. Activation revalidates the file, reuses or
inserts the immutable expanded revision by content hash, switches the active
revision, and coalesces one scoring sweep in a single transaction. Activating
already-active content is a successful no-op. Process sweeps in cursor batches
of 100 groups from stored snapshots; manual match decisions and labeled
evidence persist. Revision history remains available for audit, but version one
adds no dedicated rollback command. A saved older compact file may be imported
through the normal preview/activation flow.

The hard `language:chinese` and `other:tankoubon` scope, manual match `+9999`/
`-9999`, reviewed-winner `+9999`, exclusive winner-review score gap `5`,
popularity formulas and caps, request budgets,
leases, retries, and scheduling priorities are internal behavior rather than
operator policy fields. An invalid or unavailable active policy fails closed
for variant evaluation/actions but does not disable scanning, archiving, or
unrelated feedback.

Favorite category variables are deployment configuration rather than scoring
policy. Missing, equal, nonnumeric, or out-of-range values leave favorite
actions in a visible retryable configuration-error state; discovery and review
remain available.

#### Policy-boundary resolution

The expanded policy continues to store fixed matching and operations sections
and hashes each section independently for compatibility. Runtime workers do
not read those sections to choose behavior:

- the compact scoring document remains the only operator-editable policy;
- matching and operational invariants are hard-coded application behavior;
- the fixed integer `matching_revision` triggers rediscovery when explicitly
  changed, while scoring jobs bind to an immutable scoring policy revision;
- no operational revision or hash drives action scheduling;
- keep deployment settings, including favorite categories, outside policy
  revision history.

Migration 005 and its seeded immutable revision remain unchanged. Migration
008 adds operational state without rewriting compatibility policy history.

#### Unicode-runtime follow-up

Python currently provides both the reference NFKC-plus-full-case-fold behavior
and the pure local scoring implementation. Treat its removal as a separate
design and compatibility task. A replacement must:

- match the existing Unicode behavior, including multi-character folds such as
  `ß` to `ss`, rather than performing lowercase-only conversion;
- preserve normalized title-key collision validation and deterministic score
  output;
- pass the existing Unicode, formula, tie, and persisted-evaluation fixtures;
- have its runtime size, maintenance cost, and failure behavior compared before
  selection.

A small `utf8proc`-based helper is the leading candidate to investigate, but no
replacement is selected yet. Do not remove Python until the user agrees to the
tradeoff and the compatibility tests pass.

### 3. Feedback and group lifecycle

For rating `8` through `11`, `yomiko feedback` must transactionally:

1. persist the source gallery's rating and `feedbacked_at`;
2. create/reactivate or refresh its group with the latest desired rating;
3. coalesce a high-priority discovery job and the source rating action;
4. return without waiting for remote group actions.

The feedback API response includes `variant_queued`. The affected group is
resolved internally from the gallery GID; its relational ID is not exposed.

For a source rating `8` through `10`, preserve current local deletion behavior:
delete the source archive when present and set `rated_then_deleted_at` only
after actual deletion. Confirmed variants discovered later receive the exact
group rating and the same deletion semantics, but no replacement is requested.

For rating `11`, retain the source archive until evaluation selects and, when
necessary, archives a better canonical variant.

If feedback below `8` targets a confirmed group member, update the group to the
new desired rating, mark it inactive, and enqueue propagation, favorite
removal, and cleanup for all confirmed members. If a below-8 gallery is not a
confirmed member, preserve the existing single-gallery feedback behavior.

Set derived members' `self_rating`, `feedbacked_at`, and `updated_at` when group
intent is applied locally. Track remote completion separately in
`variant_actions`; `feedbacked_at` must not imply that every remote call
succeeded.

### 4. Candidate discovery and match review

Use a bounded metadata-first funnel:

1. Refresh source metadata and follow `first_gid`, `parent_gid`, and
   `current_gid` links. In-scope chain members are direct automatic matches.
2. Require both `language:chinese` and `other:tankoubon` for automated group
   membership. Preserve out-of-scope chain results as rejected evidence.
3. Search normal and expunged galleries separately with user language,
   uploader, and tag filters disabled.
4. Prefer exact artist/group tags plus the required scope tags. Also issue a
   normalized distinctive-title search so missing creator tags do not hide a
   candidate. Narrow overly broad creator results with title terms.
5. Deduplicate GID/token pairs and fetch current metadata in API batches of no
   more than 25.
6. Fetch favorite and rating counts from each authenticated gallery-detail
   page through the bounded continuation/retry lifecycle. Persist null raw
   values and a visible error when a count is unavailable; scoring treats the
   missing count as zero rather than blocking evaluation.
7. Normalize removable creator/language/translator/digital/edition title
   decorations and punctuation, while preserving volume/part numbers as
   potentially contradictory identity evidence.
8. Persist accepted, rejected, and ambiguous candidates and their raw evidence.
   A failed or partial discovery continuation never erases the last completed
   snapshot.

For independently discovered candidates, calculate a review-ordering metadata
score from `0` through `100`:

- normalized title similarity: `0`–`40`, using the better of English/Romaji
  token similarity and Japanese character-bigram similarity;
- exact artist/group overlap: `0`–`30`, with disjoint nonempty creator sets
  recorded as a contradiction;
- Jaccard overlap of parody, character, male, female, and mixed content tags:
  `0`–`20`;
- page-count proximity: `round(10 × min(filecount) / max(filecount))`.

Category mismatch, title volume/part conflicts, missing evidence, and full raw
feature values remain visible beside the score. Metadata score never bypasses
review in version one.

Review decisions:

- `same book`: set membership to confirmed and add `+9999` match evidence;
- `different book`: set membership to rejected and add `-9999` match evidence;
- keep the feature vector, label, policy revision, and evidence snapshot as the
  corpus for later manual policy tuning.

Official-chain matches bypass review. Exact-file matches are reserved as the
second automatic evidence type, but version one does not implement file upload,
hash search, sample retention, or image similarity. Those may be added later
without changing the review/action model.

Any unresolved candidate review blocks a new canonical evaluation because that
candidate could change the winner. Preserve the previous safe archive and
canonical state while review is pending.

### 5. Variant evaluation, ties, and actions

Evaluate only confirmed members using one completed metadata snapshot and one
expanded policy revision. Add these independent components:

- every exact tag present in `tag_scores` contributes its configured points;
- every configured title substring found in `title` or `title_jpn` after
  Unicode NFKC normalization and case folding contributes its configured
  points once, even when a related exact tag also matched;
- relative distinct `posted` ordering contributes `rank * posted_rank_step`,
  where the oldest timestamp has rank `1`, each newer distinct timestamp has
  the next rank, and equal timestamps share a rank;
- favorite popularity contributes
  `floor(min(favorite_count / 10, 500))`;
- rating confidence contributes
  `floor(min(max((rating - 3) * rating_count / 2, 0), 500))`.

Missing favorite or rating counts contribute zero. Persist every raw input,
normalization/match result, formula result, and subtotal in a machine-readable
breakdown. The `expunged` flag is displayed but has no score or eligibility
effect.

If the highest-scoring GID leads the runner-up by at least `5`, it is canonical.
If the score difference is less than `5`, create a winner review containing
every GID within less than `5` points of the top score. Rating propagation may
continue because it does not depend on the winner, but favorite routing, H@H,
and rating-11 archive cleanup wait. The user-selected reviewed winner receives
`+9999` only in that evaluation; the override does not carry into an evaluation
created by a new candidate or policy revision.

For every completed unambiguous evaluation:

- propagate the exact local rating to every confirmed member; submit remote
  `8`, `9`, or `10` unchanged and map local `11` to remote `10`;
- move the canonical GID to
  `YOMIKO_CANONICAL_FAVORITE_CATEGORY` and alternates to
  `YOMIKO_ALTERNATE_FAVORITE_CATEGORY`;
- for desired ratings `8` through `10`, delete any confirmed local archives and
  set `rated_then_deleted_at` after each successful deletion;
- for desired rating `11`, request H@H only when the canonical GID is neither
  archived, present in the H@H download tree, nor covered by an equivalent
  successful request;
- when desired rating is below `8`, submit the downgraded rating, remove each
  favorite with ExHentai's `favcat=favdel` state, delete local archives, and
  leave the group inactive.

For rating `11`, if the canonical archive exists, enqueue alternate cleanup. If
a new canonical download is needed, keep all existing archives and create
retention-reconciliation follow-up work. After `yomiko archive` atomically
commits that canonical archive, it coalesces the group's reconciliation job.
Only then may the worker delete alternate archives.

A failed request, incomplete download, archive failure, pending review, or
unresolved tie must never remove the last retained archive from a rating-11
group. Validate every cleanup path with the same filename-safety rules used by
the archive download endpoint.

### 6. Independent worker and scheduling

Add `yomiko variants work` with a non-overlapping process lock and a dedicated
`logs/yomiko-variants.log`. Schedule it every five minutes independently from
`yomiko scan`; neither command waits for the other.

Each run atomically claims due work with a lease, persists complete evaluation
or review state, records desired actions before remote calls, executes eligible
actions idempotently, and marks the job complete only when immediate work is
terminal or represented by a follow-up job.

Fixed initial operational defaults:

- one network discovery group per worker run;
- eight search requests and four 25-gallery `gdata` batches per continuation;
- bounded authenticated gallery-detail requests for popularity counts;
- unfinished discovery persists its cursor and resumes in a later run without
  applying actions from an incomplete snapshot;
- 15-minute leases;
- transient retry delays of 5 minutes, 15 minutes, 1 hour, 6 hours, and 24
  hours;
- annual rediscovery after 365 days;
- explicit feedback first, policy work second, annual stale discovery last.

Expired leases become runnable without losing evaluation or action records.
Rating and favorite requests set desired remote state and can be retried. Before
an H@H call, record the action as in-flight; after an uncertain process failure,
check the archive, H@H tree, and request record before retrying.

### 7. CLI, API, and web review

CLI surface:

- `yomiko variants enqueue <gid>` — create/refresh a group and coalesce
  discovery work.
- `yomiko variants work [--max-jobs N] [--dry-run]` — process due work; dry-run
  permits remote reads but no database, filesystem, or remote mutations.
- `yomiko variants list [--gid GID] [--status STATUS]` — emit JSON group,
  candidate, evaluation, canonical, job, review, and action state without
  exposing relational group IDs.
- `yomiko variants evaluate <gid>` — resolve the gallery's unique active group
  internally and evaluate its confirmed variants.
- `yomiko variants reviews [--status pending|resolved]` — emit JSON review
  records and frozen evidence.
- `yomiko variants resolve <review-id> --decision <same-book|different-book|winner> [--gid GID]`
  — validate and persist a review decision, then enqueue reevaluation.
- `yomiko variants policy-show [--pretty] [--expanded]` — export the compact
  active policy by default or the complete stored policy for auditing.
- `yomiko variants policy-check <path|->` — validate and preview a compact
  policy, canonical hashes, section changes, and queued-work impact without
  mutation; `-` reads stdin.
- `yomiko variants policy-activate <path|->` — revalidate, import, and
  transactionally activate a compact policy; `-` reads stdin.

Review commands primarily serve the web/API layer but keep stable JSON output.
Reserve stdout for documented payloads and send human progress through existing
API-aware log helpers.

Gallery GIDs and review IDs are the public identity model. Variant-group IDs
remain internal SQLite/worker correlation keys and are omitted from normal CLI,
CGI, and web payloads.

The implemented CGI endpoints call the review CLI commands. The read endpoint
lists pending/resolved review data; the mutation endpoint requires the existing
bearer token and accepts only a review ID, allowlisted decision, and winner GID
when applicable.

`web/feedback.html` includes a pending-review count and two card types:

- candidate card: source/candidate titles, tags, page counts, category,
  expunged state, links, evidence components, contradictions, and **Same book**
  / **Different book** actions;
- winner card: tied or near-tied review choices, archive state, complete
  variant-score breakdown, and an explicit canonical selection action.

The page should reject stale decisions cleanly, refresh after a successful
resolution, and preserve the current token/authentication flow.

## Failure and Concurrency Behavior

- Feedback enqueueing, policy sweeps, and archive-triggered reconciliation are
  repeatable and coalesce by group/job type.
- SQLite transactions atomically claim jobs, activate policies, merge groups,
  persist evaluation snapshots, and record intended actions.
- Candidate discovery may partially gather evidence, but remote mutations use
  only a completed internally consistent snapshot.
- A failed favorite move/removal cannot cause a successful rating or H@H
  request to be forgotten.
- Desired-state idempotency allows a new favorite action when canonical state
  changes without intentionally repeating an already completed identical
  action.
- Existing scan and per-gallery archive locks remain unchanged. The variant
  worker coordinates archive completion through durable jobs rather than
  sharing the scan lock.
- Permanent policy, configuration, review-validation, or remote capability
  errors remain visible and require correction; transient network, rate-limit,
  HTTP, and parsing failures follow the fixed internal backoff schedule.
- JSON CLI output remains clean in API mode, and no API script accesses SQLite
  directly.

## Test Plan

- **Migrations:** fresh install, upgrade from migration 004, new metadata
  columns/tables, future popularity-count fields, constraints, partial
  uniqueness, indexes, expanded seed policy, and atomic rollback. After
  edit/test permission is granted, copy
  `~/docker/yomiko/data/db.sqlite3` into the project's ignored `data/`
  directory as a disposable test database and run the complete migration path
  against that copy. Take the copy while the source is quiescent, or use a
  SQLite-consistent backup, so an active WAL cannot produce an incomplete
  snapshot. Never mutate the source database; verify the resulting schema
  version, `PRAGMA integrity_check`, `PRAGMA foreign_key_check`, and preservation
  of existing gallery/feedback data.
- **Policy:** compact valid/invalid JSON, strict unknown-key rejection, signed
  score bounds, empty initial title map, Unicode-normalized duplicate rejection,
  compact-to-expanded conversion, immutable revisions, key-order/whitespace-
  independent hashes, one active revision, unchanged-policy no-op, scoring
  sweep coalescing, and manual-label retention.
- **Matching:** official chains, all confirmed same-book fixture groups below,
  punctuation/edition decoration, Japanese titles, same-artist different books,
  misleading volume numbers, missing creator tags, page-count differences,
  normal/expunged separation, false positives, and metadata review ordering.
- **Review:** same/different decisions, `±9999` match evidence, persisted corpus,
  stale review rejection, group merge after approval, unresolved-candidate
  evaluation blocking, and direct-chain bypass.
- **Scoring:** exact additive tags, independent Unicode-normalized title
  substrings, signed values, equal-date ranks, configurable rank step, favorite
  and rating-confidence formulas, 500-point caps, flooring for both popularity
  components, missing-count zeroes, explainable breakdowns, expunged neutrality,
  natural winner, exact-tie review, near-tie gaps of `0` through `4`, automatic
  selection at a gap of `5`,
  current-evaluation-only `+9999` winner override, and override expiry.
- **Feedback:** trigger ratings `8`–`11`, exact desired-rating convergence,
  below-8 downgrade/deactivation, later reactivation, API response fields,
  immediate return, and unchanged ungrouped low-rating behavior.
- **Remote actions:** local `11` to remote `10`, exact `1`–`10` propagation,
  canonical/alternate category moves, `favdel` removal, missing configuration,
  partial failures, retries, and desired-state idempotency.
- **Retention:** ratings `1`–`10` delete without replacement; rating `11` avoids
  duplicate H@H requests, retains an old archive during replacement, enqueues
  reconciliation on archive commit, deletes alternates afterward, and never
  loses the last copy during failure/review.
- **Worker:** priority, coalescing, atomic claims, separate locks, expired
  leases, continuation cursors, three-second throttling, 25-entry API batches,
  bounded gallery-detail requests, popularity parse/missing-data behavior,
  request budgets, retry delays, uncertain H@H recovery, annual stale groups,
  and 100-group local policy sweeps.
- **Web/API:** pending count, candidate and tie cards, authentication, input
  validation, evidence rendering, successful resolution refresh, and CLI-only
  database access.
- **End to end:** feedback → normal/expunged discovery → metadata/popularity
  refresh → automatic chain match or review → group evaluation →
  rating/favorite actions → optional H@H replacement → archive commit → safe
  cleanup → downgrade/reactivation → annual or policy reevaluation.
- **Dry run:** remote read-only discovery and explanations occur without
  database, filesystem, or remote mutations.

## Open Questions

### Discovery matching/search behavior — resolved 2026-08-24

以下四項定義 `matching_revision = 1`：

1. **Title similarity 公式**：English/Romaji token similarity 與 Japanese
   character-bigram similarity 都使用 Sørensen–Dice coefficient，再把結果
   四捨五入映射到 `0`–`40`。
2. **Recurring discovery seeds**：以所有 confirmed members 產生並去重
   search queries，不只使用 canonical。
3. **Search traversal 終止條件**：每個 query 的 normal/expunged 結果都以
   durable continuation 讀到 server 表示沒有下一頁；completed discovery
   不設總頁數或 candidate 上限。
4. **低證據 candidate**：只要由本次 search query 找到、通過兩個 scope
   tags、且不是 official chain，就建立人工 review。Metadata score 只排序
   review，不以最低分或最低 evidence 自動 rejected。

### Discovery popularity request budget — resolved 2026-08-24

每次 discovery continuation 最多可讀取多少個 authenticated gallery-detail
pages，以取得 `favorite_count` 與 `rating_count`？已確認固定為 `25` 本；
超過時保存 cursor，留待下一次 worker run。這個值只限制 read-only
remote requests，不改變 candidate membership 或 scoring semantics。

### Creator score and exact query construction — resolved 2026-08-24

1. **Creator component**：source/candidate 只要共享至少一個 exact
   `artist:` 或 `group:` tag 就給 `30` 分，否則 `0` 分；兩邊都有 creator
   tags 但完全不相交時，另記 `disjoint_creator_sets` contradiction。不要依
   creator tag 數量做比例給分。
2. **Creator queries**：所有 confirmed seeds 的每個 unique exact
   `artist:`/`group:` tag 各建立一個 query，再加兩個 required scope tags。
   這可以避免多 creator 合併查詢漏掉只保留部分 tag 的 variant。
3. **Title queries**：每個 confirmed seed 建立一個 query，從 English/
   Romaji 與 Japanese title 的 normalized distinct terms 中選最長三個，長度
   相同時依 Unicode lexical order；沒有空格的 CJK title 當成一個完整
   term。每個 term 都使用 `title:` qualifier。保留 volume/part term，不做
   未定義的 dynamic broad-result threshold。
4. **Minimum title term length**：每個 query 固定以
   `language:chinese$ other:tankoubon$` 開頭。含 CJK 的 title term 至少需要
   `2` 個 Unicode code points，其他 term 至少 `3` 個；更短的 term 不進
   query。如果某個 seed 沒有任何合格 title term，略過該 seed 的 title
   query，但不影響 creator queries。EHWiki 未明列一個跨 script 的 hard
   minimum；此規則是依其 Unicode `2+` 提示與 2026-08-24 無 cookie public
   search 對照（ASCII `2`/`3`、CJK `1`/`2`/`3`）固定為 revision `1` 行為。

### Operational-policy boundary — resolved 2026-08-24

Operational budgets, ordering, retries, leases, retention gates, and remote
response classification are fixed application behavior. Favorite category
numbers remain deployment configuration. No operational revision or runtime
invalidation hash is added; existing expanded-policy matching/operations
sections and hashes remain readable compatibility and audit evidence only.

## Confirmed Matching Fixtures

The user has confirmed that every GID within each row represents the same book:

- `2785385`, `2560104`, `2242204`, `2223627`
- `4058321`, `1483302`
- `2785447`, `2275636`, `1866032`, `1850435`, `1776212`
- `2790696`, `2336603`, `1884563`, `1862304`, `1710983`

GID `3159956` has a similar title to the third group but is a different book;
keep it as a negative matching fixture.

These fixtures supplement the previously confirmed group `2008101`, `2795720`,
`1150827`, and `1819641`. Matching and scoring reports must show their complete
evidence and breakdowns. Decisive evidence should create a meaningful
separation. The fixture reports will validate the agreed initial `+100` tag
scale, fixed `+9999` manual overrides, and exclusive winner-review gap of `5`.
