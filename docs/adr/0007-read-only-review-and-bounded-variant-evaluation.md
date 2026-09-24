# ADR-0007: Read-only review projection and bounded variant evaluation

- Status: Accepted
- Date: 2026-09-21
- Related:
  [Domain language](../domain-language.md),
  [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md),
  [ADR-0002: Bounded SQLite writer coordination](./0002-bounded-sqlite-writer-coordination.md),
  [ADR-0005: Provider-authoritative uploader-revision-chain projection](./0005-provider-authoritative-uploader-revision-chain-projection.md),
  [ADR-0006: Discovery, revision, and archive vocabulary](./0006-discovery-revision-archive-vocabulary.md)

## Subsequent public review contract (2026-09-24)

Review reads remain query-only and do not run or persist reconciliation. The
public queue is now pending-only: use `yomiko variants pending-reviews` or
`GET /api/pending_variant_reviews.sh` without a query string. The prior
`variants reviews` CLI mode and `/api/reviews.sh` route were removed, and no
resolved-history read mode is exposed. The read-only and writer-gate boundaries
in this ADR remain in force; the review API inventory and all/resolved examples
below describe the superseded contract. See [ADR-0010: Pending-only variant
review surface](./0010-pending-only-variant-review-surface.md) for the accepted
decision and verification.

## Context

The variant worker consumed excessive CPU and held the SQLite writer gate for
long periods because small evaluations repeatedly rebuilt global identity and
uploader-revision projections. Four entry points amplified the problem:

1. The review GET path opened a write transaction before serializing a
   response, ran global identity reconciliation, and repaired durable review,
   group, and job state.
2. `variants_evaluate_group` ran global identity reconciliation and expanded
   `current_revision_projection` inside `BEGIN IMMEDIATE`, even when the
   target group had only a few confirmed members.
3. The evaluation input query expanded the same global uploader-revision
   projection before entering the guarded transaction.
4. The public `variants evaluate <gid>` command called
   `variants_current_gid` before locating a group. A normal source GID
   therefore paid for a global uploader-revision traversal before evaluation
   began.

Coupling this work to the writer gate delayed otherwise unrelated API,
scheduler, telemetry, and worker writes. It also violated ADR-0002's helper
boundary: a read API must not acquire the writer gate or repair durable state
as a side effect of serialization.

This decision preserves ADR-0001's class-lifted identity semantics,
ADR-0005's provider-authoritative uploader revision chains, and ADR-0006's
vocabulary. It supersedes any earlier runtime interpretation in which review
serialization owns or triggers mutating reconciliation. The class,
inactive-owner, representative-selection, and review-lifecycle rules in
ADR-0001 remain authoritative.

## Decision

### Bound work on externally exposed read paths

Externally exposed local query/read-only CLI and HTTP API paths have a strict
latency limit of less than 1 second. The metrics CLI and authenticated metrics
API have a separate strict limit of less than 10 seconds. The limit applies to
the complete command or response.

Schema-28 `revision_members` is a global projection: its recursive seed is
every row in `galleries`, and a keyed read of `current_revision_projection` or
`archive_source_galleries` still evaluates that global walk before applying the
outer GID filter. Do not use these projections on bounded external request
paths. Instead, seed recursion from the requested GIDs or selected records,
follow indexed `parent_gid`/`current_gid` relations, and materialize the exact
request-local revision, archive, or grouped result once. Full-table traversal
is appropriate when the endpoint's contract covers the full table, such as an
exhaustive metric. Read paths remain free of request-time durable mutation and
remote lookup.

The gallery-status API and `variants list` now use bounded request-local
projections and meet the measured limit. At the time of this ADR,
`variants reviews` all/resolved exceeded 1 second in both CLI and HTTP
measurements. ADR-0008 later accepted an HTTP-only release exception; the CLI
all/resolved modes now meet the subsecond p95 gate. ADR-0009 records the
current budgets and deferrals. Pagination remains deferred for full-history
HTTP responses, so that route's subsecond target remains incomplete.

### Keep review GETs free of durable mutation

`variants_reviews_json` uses the `db_query` contract. A review GET must not:

- call `variants_identity_reconcile_sql` or another durable reconciliation
  path;
- mutate `variant_reviews`, `variant_groups`, `variant_jobs`, actions, or
  evaluations;
- enqueue evaluation or action-reconciliation work while serializing a
  response; or
- acquire the SQLite writer gate to project the review queue.

The GET projects the currently derivable queue. It does not repair durable
state when that projection differs from persisted review or group state.

Durable reconciliation remains owned by explicit mutation boundaries:

- discovery publication applies a complete provider snapshot, updates affected
  current same-book identity and current revision projections, and coalesces
  follow-up work;
- review resolution commits a `same_book`, `different_book`, or
  canonical-selection decision and reconciles the affected durable evidence
  in the same transaction;
  and
- `ungroup` intentionally changes same-book identity, preserves historical
  evidence, and rebuilds affected current projections.

A stale review-resolution attempt may still perform reconciliation inside its
explicit mutation transaction even when the requested review decision is no
longer applicable. This does not make a read API a mutation owner.

Evaluation owns only its guarded target-group commit: it validates the scored
snapshot, records an immutable evaluation, and updates the target group's
members, canonical gallery, and canonical-selection review. Worker queue
claiming, startup recovery, and idle scheduling retain their existing
boundaries and do not become global reconciliation owners.

### Share one exact, bounded uploader-revision projection

`variants_revision_projection_sql` in `lib/common.sh` is the shared SQL
emitter for evaluation, review, retention, status, and list projections. Each
mode preserves the authoritative uploader-revision-chain rules from ADR-0005
and the canonical projection names from ADR-0006. Status and list modes receive
an explicit GID seed set; the metrics request uses status mode with the complete
gallery set because its output is an exhaustive gallery partition.

The evaluator builds its seed set in two bounded phases:

1. Preliminary seeds contain the target group's source GID, confirmed members,
   and any pending canonical-selection review's source and integer choice
   GIDs.
2. After traversing those uploader revision chains, the final seed set adds
   relevant pending `candidate_identity` review owner and candidate endpoints,
   canonical-selection review evidence, endpoints of related
   `gallery_identity_pairs`, and confirmed members of active same-book classes
   that touch the preliminary result.

Review owners are not filtered by `identity_active`. Pending evidence owned by
an inactive group can still block an active same-book class. Unrelated review
backlogs do not become traversal roots.

Recursive expansion reads the `galleries` base table directly:

- forward `parent` and `current` traversal uses the gallery primary key;
- reverse traversal uses equality on `parent_gid` or `current_gid`;
- `first`, `parent`, and `current` pairs retain completeness, referenced
  row, and token validation;
- `first` is consistency evidence but does not establish an uploader
  revision chain by itself;
- valid `parent` and `current` edges form local components and preserve
  cycle, branch, and multiple-terminal detection; and
- the projection preserves the blocking precedence for relation conflicts,
  missing references, token mismatches, cycles, branches, multiple terminals,
  incomplete scope, and incomplete scoring inputs.

Each projected row retains `component_gids` and ordered `edge_provenance`.
Those values remain part of evaluation's input and uploader-revision
fingerprints. The projection is therefore not a direct-`current_gid`
shortcut: it retains complete component validation and stale-input detection
while limiting recursive work to components reachable from the bounded seeds.

Evaluation constructs the input snapshot before taking the writer gate and
rebuilds the same bounded projection inside `BEGIN IMMEDIATE` for commit-time
validation. The guarded transaction preserves ADR-0001's identity rules:

- confirmed members project through scoreable revision terminals;
- pending `candidate_identity` reviews project through their source and
  candidate terminals;
- implied `same_book` pairs and known `different_book` pairs do not create
  new actionable reviews;
- an unknown class pair has one representative, preferring an active owner and
  then the lowest review ID;
- pending evidence owned by an inactive group can still block an active class;
  and
- a successful commit mutates only the target evaluation, group, members, and
  canonical-selection review.

`variant_evaluation_guard` exists only when the policy, source GID, desired
rating, activity flags, expected evaluation, membership, gallery metadata,
scoring inputs, and uploader-revision fingerprints still match the snapshot
that was scored. Every durable evaluation, canonical, member, group, review,
manual-decision, and job write is gated by that row. A blocked or stale
evaluation is therefore a complete durable no-op.

### Index reverse uploader-revision traversal

Schema 30 adds:

```sql
CREATE INDEX idx_galleries_parent_gid
ON galleries(parent_gid)
WHERE parent_gid IS NOT NULL;

CREATE INDEX idx_galleries_current_gid
ON galleries(current_gid)
WHERE current_gid IS NOT NULL;
```

The recursive SQL keeps reverse branches in the indexable
`source.parent_gid = walk.gid` and `source.current_gid = walk.gid` forms.
Forward branches use the `galleries.gid` primary key. The partial predicates
retain malformed rows with a non-null relation GID so that pair and token
validation can classify them instead of hiding them.

### Prefer direct group lookup for public GID evaluation

`variants_evaluate_gid` first resolves a unique active, identity-active,
rating-11 group using the raw input GID as either:

- `variant_groups.source_gid`; or
- a confirmed `gallery_variants.gid`.

A normal source or confirmed-member GID therefore does not invoke
`variants_current_gid` or expand the global current revision projection.
When the direct lookup has no unique result, the existing
`variants_current_gid` fallback remains available for a historical revision
GID that is no longer a current source or member. Existing ambiguity, error,
and exit-status behavior is preserved.

The variant worker calls `variants_evaluate_group` with a group ID and does
not use this public lookup. There is one canonical
`variants_evaluate_gid` definition in `lib/variants.sh`; the scoring layer
does not override it.

### Bound retention recovery by target group

Retention recovery has the same bounded-work requirement as evaluation. The
old worker path expanded the schema-28 `archive_source_galleries` recursive
projection globally once per eligible group. With a large eligible set, that
repeated global traversal consumed the worker's CPU budget before it could
durably claim queued work, causing lease starvation.

The retention helpers therefore take the eligible group IDs as an explicit
target set. A single pre-lock snapshot seeds the shared `retention` revision
projection only from those groups and derives the archive-source rows in the
same connection. Its semantic invariants remain those of the old projection:

- a committed archive on the current terminal wins;
- a safe committed predecessor may remain the `archive_gid` while the
  terminal is being acquired;
- a blocked revision component preserves its confirmed-member archive fallback
  rather than being treated as an absent target; and
- `archive_gid` and `file_path` remain exact-GID facts, with nullable archive
  output when no safe source exists.

The worker uses this bounded snapshot for startup self-heal and scheduled
recovery. Recovery treats the first snapshot only as a lock target. After
acquiring the per-GID archive lock, it performs a second bounded snapshot and
rechecks active identity, evaluation, canonical GID, archive source, path
safety, and filesystem regularity before clearing a stale path or queuing
H@H work. This post-lock recheck closes the SQLite-update/final-rename race
without holding a global lock or trusting stale pre-lock intent.

Future retention changes must preserve this boundary: do not restore a global
`archive_source_galleries` projection inside a per-group loop. A durable
materialized projection would require a separate migration, invalidation, and
repair decision; until then, every recovery query must be target-seeded and
bounded, while retaining the archive-source and blocked-component semantics
above.

### Materialize review projection only in connection-local TEMP state

Review mode seeds the exact shared projection from the selected review
universe: owner source GIDs, `candidate_identity` review candidate GIDs, and
integer GIDs from canonical-selection review `choices_json`. It then adds only
related active confirmed members and identity-pair endpoints. It does not use
every gallery or every identity pair as a traversal root.

`variants_reviews_json` uses one short-lived `db_query` connection:

1. Materialize the exact uploader-revision projection once in a
   connection-local TEMP cache.
2. Derive scoreable revision terminals and the non-recursive
   class-lifted identity, visibility, pending-review, and actionable-review
   caches from that projection.
3. Enable `PRAGMA query_only=ON` for the final JSON SELECT.
4. Close the connection, which discards all TEMP state.

This sequence performs no main-database transaction or durable write and does
not acquire the writer gate. `all`, `pending`, and `resolved` select
different review universes or output filters without changing the response
schema or ordering.

## Consequences

Positive consequences:

- Review GETs cannot mutate durable rows or block another Yomiko writer.
- Evaluation work scales with the target and related uploader revision chains,
  not every gallery, review, and group.
- Normal source/member CLI evaluation avoids global revision normalization.
- Cycle, branch, missing-reference, token-mismatch, component fingerprint,
  class-lifted cross-group blocker, and inactive-owner behavior remain
  consistent across evaluation and review projection.
- Reverse uploader-revision traversal uses index seeks instead of repeatedly
  scanning `galleries`.

Costs and constraints:

- The local projection SQL is substantial. The input snapshot and guarded
  revalidation each build a bounded projection intentionally so that stale
  scoring results cannot commit.
- Review GETs build one exact recursive TEMP projection and one non-recursive
  identity cache. Serializing a large `all` response can still dominate
  latency even though it does not hold the writer gate.
- A large or malformed uploader revision chain still requires visiting every
  reachable endpoint; correctness forbids replacing that work with a
  direct-`current_gid` approximation.
- The two indexes add storage and gallery-relation write amplification.
- Historical GID fallback may still pay for global current revision
  projection. Normal active source/member inputs must not enter that fallback.
- Durable state is repaired only at explicit mutation boundaries. Callers must
  not reintroduce read-time or evaluation-time global reconciliation to obtain
  immediate repair.

## Rejected alternatives

### Follow only direct `current_gid`

This loses bidirectional uploader-revision-chain traversal, token validation,
cycle, branch, multiple-terminal, and `first`-relation conflict detection. It
also weakens uploader-revision fingerprints. A malformed component could then
appear scoreable and produce an incorrect canonical gallery or review
projection.

### Inspect only current target rows

This misses endpoints connected through class-lifted reviews, pending evidence
owned by an inactive group, and related `different_book` decisions. An
evaluation could commit while an actionable cross-group identity review still
blocks the target class.

### Rebuild global projections in every read or evaluation

This preserves the previous consistency shortcut at the cost of placing
unrelated groups, reviews, and uploader revision chains in every operation.
The measured result was excessive CPU, writer gate saturation, scheduler
retries, and telemetry timeouts. Global durable reconciliation belongs only to
explicit mutation owners.

### Introduce a durable materialized revision projection now

Discovery publication, review resolution, and `ungroup` could eventually
maintain a durable revision projection so reads and evaluations use only keyed
lookups. That design requires a backfill, a version transition, write
amplification for every relation mutation, rollback semantics, invalidation,
and a repair path. The bounded SQL projection and schema-30 indexes solve the
current failure without introducing that additional durable state. A
materialized projection remains a separate future decision if scale requires
it.

## Verification

Validation used a consistent schema-30 production snapshot with approximately
2,000 galleries and 274 variant groups:

- The original global evaluation path did not complete within 45 seconds.
- Direct group evaluation completed in approximately 0.25 seconds.
- Public source-GID evaluation completed in approximately 0.47 seconds after
  removing the normal-path global normalization. A prior 4.68-second run spent
  approximately 4.41 seconds in `current_revision_projection`.
- Pending review GET completed in approximately 0.26 seconds.
- An `all` review GET containing 1,937 rows completed in approximately
  6.26 seconds. The remaining cost is dominated by producing the complete JSON
  response, not writer gate contention.
- A concurrent connection acquired `BEGIN IMMEDIATE` promptly while the
  review GET built and read its TEMP projection.
- `EXPLAIN QUERY PLAN` used
  `idx_galleries_parent_gid` and `idx_galleries_current_gid` for reverse
  traversal and did not materialize the global current revision projection on
  the normal evaluation path.
- Repeated review GETs produced stable output and left durable review, group,
  job, and gallery state unchanged.
- Regression coverage includes direct source/member lookup, historical GID
  fallback, unique and tied canonical selection, durable manual canonical
  decisions, unrelated-review isolation, cross-group evaluation,
  `candidate_identity`, canonical-selection, and stale complete no-op paths,
  malformed uploader revision chains, inactive-owner precedence, review
  projection, and schema-30 migration/index behavior.
- The complete fresh-playground suite passed: 168 tests passed, 0 failed.

Retention recovery was also accepted on an isolated production SQLite
snapshot configured so the production eligibility query selected exactly 126
groups and the worker had queued local work available. One worker invocation
produced these bounded-work results:

- the maximum relevant SQLite invocation was `214,836` microseconds
  (`retention_recovery`), below the 10-second threshold;
- the first durable lease was recorded `34.335` seconds after worker start,
  below the 60-second threshold; and
- the lease trigger recorded job `16074` as `evaluate`, attempt `1`, with a
  concrete lease owner and expiry during the `queued` to `leased` transition.

The disposable evaluate handler subsequently persisted a transient retry for
its fixture-local scoring inputs. That does not weaken the acceptance result:
the check targets pre-claim boundedness and durable lease acquisition, not
provider access or successful scoring of synthetic fixture data.

Operational monitoring should continue to track writer gate hold time,
evaluation latency, queued work, review GET durable-state differences, and the
frequency of historical GID fallback. An unexpected fallback rate indicates a
variant-group ownership or current-membership problem; it does not justify
restoring global projection to ordinary review or evaluation paths.
