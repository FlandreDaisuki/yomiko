# Gallery Variant Feedback — Working Plan

Status: The durable foundation and local scoring/evaluation milestone are
implemented. The next work is ordered below. This update is documentation only;
do not start the next implementation phase, copy a database, or run migrations
until the user gives a separate instruction.

## Next Phase Order

1. Add review interfaces: CLI review listing/resolution, CGI read/mutation
   endpoints, and candidate/winner cards in the existing feedback page.
2. Revisit the matching-policy boundary. Matching behavior may be hard-coded
   application behavior without a matching content hash; decide the revision
   and rediscovery mechanism before implementing discovery and matching.
3. Revisit the operational-policy boundary in the same way. Separate fixed
   application behavior from deployment configuration, and retain a revision
   or hash only when it has a concrete runtime or audit purpose.
4. Discuss replacing Python for Unicode NFKC plus full case folding and local
   score computation. Compare alternatives and prove equivalent behavior with
   Unicode fixtures before changing the runtime dependency.

The matching, operations, and Unicode items are open design checkpoints, not
confirmed implementation decisions. After they are settled, update this plan
before implementing discovery, remote actions, or retention reconciliation.

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
- Review evidence is retained as a labeled corpus. Matching-confidence rules
  are fixed application behavior and change only through explicit software
  revisions; Yomiko does not train or activate matching rules automatically.
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

#### Policy-boundary follow-up

The current implemented expanded policy stores fixed matching and operations
sections and hashes each section independently. After the review interfaces,
reconsider that representation. The preferred simplification to evaluate is:

- keep the compact scoring document as the only operator-editable policy;
- hard-code matching and operational invariants in application code;
- replace matching and operations content hashes with explicit software/schema
  revision numbers only where a behavior change must trigger rediscovery,
  reevaluation, or another durable transition;
- keep deployment settings, including favorite categories, outside policy
  revision history.

This follow-up must preserve migration 005 and its seeded immutable revision.
Any schema transition belongs in a later ordered migration after the exact
revision semantics are agreed.

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

Add CGI endpoints that call the review CLI commands. The read endpoint lists
pending/resolved review data; the mutation endpoint requires the existing
bearer token and accepts only a review ID, allowlisted decision, and winner GID
when applicable.

Extend `web/feedback.html` with a pending-review count and two card types:

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

None.

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
