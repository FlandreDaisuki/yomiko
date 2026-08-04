# Gallery Variant Feedback — Finalized Plan

Status: Product and implementation decisions are complete; implementation has
not started.

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
- Review evidence is retained as a labeled corpus. Global confidence rules are
  tuned only through explicit manual policy revisions; Yomiko does not train or
  activate policies automatically.
- Manual same-book approval adds `+9999` only to match confidence; rejection
  adds `-9999`. These decisions are authoritative and persist with group
  membership.
- Equal top variant scores require review. Selecting a tied winner adds `+9999`
  only to that evaluation's variant score. The override expires when new
  candidates or a new policy revision creates another evaluation.
- ExHentai `posted` is the only date used by the initial scoring rules; Yomiko
  does not infer publication dates from titles or tags.
- Initial variant scoring is `other:full color = +100`,
  `other:uncensored = +100`, plus a relative upload-date bonus from newest
  `+N` to oldest `+1` within the completed evaluation snapshot. Galleries with
  equal `posted` times receive equal date bonuses.
- Favorite categories are two required, distinct environment variables with
  values from `0` through `9`:
  `YOMIKO_CANONICAL_FAVORITE_CATEGORY` and
  `YOMIKO_ALTERNATE_FAVORITE_CATEGORY`.
- Favorite placement is desired state, not append-only history. Reevaluation
  can move canonical and alternate variants, and a group downgrade below `8`
  removes favorites.
- Confirmed variants that were never downloaded are not requested merely to
  delete them.
- A scoring-policy change reevaluates stored groups locally. A matching-policy
  change schedules rediscovery. Operational policy changes do not stale match
  or score results.
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
- `variant_policy_revisions`: immutable full policy JSON, full content hash,
  matching/scoring/operations section hashes, creation time, and activation
  time. Only one revision is active.
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

Extend `galleries` with the additional normalized `gdata` fields. Keep
historical evidence and evaluations rather than overwriting old scores when a
policy changes.

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

The authoritative policy is the full validated JSON stored in
`variant_policy_revisions`; it is separate from system schema migration
tracking. A JSON file is only an import format for user customization.

The document contains three independently hashed sections:

- `matching`: required scope tags, metadata evidence weights, direct automatic
  evidence kinds, and review behavior;
- `scoring`: variant tag weights, relative `posted` scoring, and manual winner
  override behavior;
- `operations`: discovery cadence, request budgets, lease, and retry delays.

Policy activation is transactional: validate the entire document, reuse or
insert its immutable revision by content hash, activate it, and enqueue only the
work implied by changed section hashes:

- matching hash changed: rediscover all active groups;
- scoring hash changed: reevaluate all active confirmed groups from their
  latest metadata snapshots without remote discovery;
- operations hash changed: use new limits for future work without invalidating
  evaluations.

Process scoring-only policy sweeps in cursor-based batches of 100 groups so an
installation with 2,000+ galleries can be reevaluated quickly without 2,000
network jobs. Manual match decisions and labeled feature snapshots persist
across all policy revisions.

Seed the initial policy as part of installing the schema. Invalid policy fails
closed for variant evaluation/actions but does not disable scanning, archiving,
or unrelated feedback.

Favorite category variables are deployment configuration rather than scoring
policy. Missing, equal, nonnumeric, or out-of-range values leave favorite
actions in a visible retryable configuration-error state; discovery and review
remain available.

### 3. Feedback and group lifecycle

For rating `8` through `11`, `yomiko feedback` must transactionally:

1. persist the source gallery's rating and `feedbacked_at`;
2. create/reactivate or refresh its group with the latest desired rating;
3. coalesce a high-priority discovery job and the source rating action;
4. return without waiting for remote group actions.

The feedback API response includes `variant_queued` and the affected
`variant_group_id`.

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
6. Normalize removable creator/language/translator/digital/edition title
   decorations and punctuation, while preserving volume/part numbers as
   potentially contradictory identity evidence.
7. Persist accepted, rejected, and ambiguous candidates and their raw evidence.
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
policy revision. Initial additive variant score:

- `other:full color`: `+100`;
- `other:uncensored`: `+100`;
- relative distinct `posted` ordering: newest `+N` through oldest `+1`; equal
  timestamps receive the same rank.

Persist a machine-readable breakdown. The `expunged` flag is displayed but has
no initial score or eligibility effect.

If exactly one GID has the highest score, it is canonical. If multiple GIDs tie
at the top, create a winner review. Rating propagation may continue because it
does not depend on the winner, but favorite routing, H@H, and rating-11 archive
cleanup wait. The user-selected tied winner receives `+9999` only in that
evaluation; the override does not carry into an evaluation created by a new
candidate or policy revision.

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

Initial operational policy defaults:

- one network discovery group per worker run;
- eight search requests and four 25-gallery `gdata` batches per continuation;
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
  candidate, evaluation, canonical, job, review, and action state.
- `yomiko variants reviews [--status pending|resolved]` — emit JSON review
  records and frozen evidence.
- `yomiko variants resolve <review-id> --decision <same-book|different-book|winner> [--gid GID]`
  — validate and persist a review decision, then enqueue reevaluation.
- `yomiko variants policy-check <path>` — validate a policy without mutation.
- `yomiko variants policy-activate <path>` — import and activate a valid
  database policy revision.

Review commands primarily serve the web/API layer but keep stable JSON output.
Reserve stdout for documented payloads and send human progress through existing
API-aware log helpers.

Add CGI endpoints that call the review CLI commands. The read endpoint lists
pending/resolved review data; the mutation endpoint requires the existing
bearer token and accepts only a review ID, allowlisted decision, and winner GID
when applicable.

Extend `web/feedback.html` with a pending-review count and two card types:

- candidate card: source/candidate titles, tags, page counts, category,
  expunged state, links, evidence components, contradictions, and **Same book**
  / **Different book** actions;
- winner card: tied variants, archive state, complete variant-score breakdown,
  and an explicit canonical selection action.

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
  HTTP, and parsing failures follow the policy backoff schedule.
- JSON CLI output remains clean in API mode, and no API script accesses SQLite
  directly.

## Test Plan

- **Migrations:** fresh install, upgrade from migration 004, new metadata
  columns/tables, constraints, partial uniqueness, indexes, seed policy, and
  atomic rollback.
- **Policy:** valid/invalid JSON, immutable revisions, stable section hashes,
  one active revision, unchanged-policy no-op, matching rediscovery, scoring
  batch reevaluation, operations-only activation, and manual-label retention.
- **Matching:** official chains, the four supplied independent examples,
  punctuation/edition decoration, Japanese titles, same-artist different books,
  misleading volume numbers, missing creator tags, page-count differences,
  normal/expunged separation, false positives, and metadata review ordering.
- **Review:** same/different decisions, `±9999` match evidence, persisted corpus,
  stale review rejection, group merge after approval, unresolved-candidate
  evaluation blocking, and direct-chain bypass.
- **Scoring:** initial tag/date rules, equal-date ranks, explainable breakdowns,
  expunged neutrality, natural winner, tied review, current-evaluation-only
  `+9999` winner override, and override expiry.
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
  request budgets, retry delays, uncertain H@H recovery, annual stale groups,
  and 100-group local policy sweeps.
- **Web/API:** pending count, candidate and tie cards, authentication, input
  validation, evidence rendering, successful resolution refresh, and CLI-only
  database access.
- **End to end:** feedback → normal/expunged discovery → automatic chain match
  or review → group evaluation → rating/favorite actions → optional H@H
  replacement → archive commit → safe cleanup → downgrade/reactivation →
  annual or policy reevaluation.
- **Dry run:** remote read-only discovery and explanations occur without
  database, filesystem, or remote mutations.
