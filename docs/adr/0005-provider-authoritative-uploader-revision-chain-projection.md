# ADR-0005: Provider-authoritative uploader-revision-chain projection

- Status: Accepted
- Date: 2026-09-19
- Related:
  [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md),
  [ADR-0004: Userscript local-state H@H de-duplication](./0004-userscript-local-state-hath-deduplication.md),
  [ExHentai provider behavior](../exhentai.md)

## Context

ExHentai reports a single uploader's gallery-revision relations through the
token-bearing `first`, `parent`, and `current` fields. This ADR calls that
provider-declared relation an **uploader revision chain**. Chain membership is
never inferred merely from equal `galleries.uploader` values, and one uploader
may own several distinct chains.

This is distinct from **same-book identity**: Yomiko's content-identity
matching, decision, and review between distinct uploader revision chains. The
chains may have the same or different `uploader` value. In the identity domain,
candidate decisions `same_book` and `different_book`, same-book matching, and
same-book review mean that second relationship. Uploader-revision validation
does not produce such a decision or review. This terminology does not change
ADR-0004's userscript `local_state_relation` presentation.

Yomiko already stores uploader-revision relation pairs on `galleries`, but
currently turns them into matching evidence such as
`evidence.official_chain`, keeps replaced GIDs in current variant membership,
and collapses part of a chain only while scoring. That reverses the authority
boundary. A valid uploader revision chain is not a similarity hypothesis and
cannot be overridden by a canonical choice, cross-chain same-book decision, or
later `ungroup` operation. It mirrors provider state. The current design
also scores the mutable metadata snapshot copied into `gallery_variants`, so a
successful discovery can refresh a live gallery's popularity without
refreshing the score input used by its owning group.

For example, given:

```text
100 -> 101 -> 102
201 -> 203 -> 206
309 -> 322
```

where each arrow is a validated parent-to-child replacement, the current
projection must contain only `102`, `206`, and `322`. The earlier GIDs remain
gallery and audit history. If a later `103` validly replaces `102`, `103`
becomes the current uploader-revision representative, inherits the current
group intent, is rescored from current inputs, and may receive its own H@H
request.

There are two different notions of “current” during that last transition. A
fully described `103` may be ready for identity, scoring, and acquisition work
while the only committed local archive still belongs to `102`. Treating either
state as the only projection would make it impossible either to request the
replacement or to preserve a safe local copy until that request completes.

## Decision

### Gallery relations are the uploader-revision authority

Keep `first_gid/first_token`, `parent_gid/parent_token`, and
`current_gid/current_token` on `galleries` as the mutable provider facts. A
relation is usable only when both identity fields are present, its referenced
row has been fetched, and the token matches. An absent target remains a staged
reference to fetch; it is not represented by a fabricated skeletal gallery
row.

Use validated `parent` and `current` paths to establish an uploader revision
chain and its unique terminal. `parent` can express an immediate predecessor
while an older gallery's `current` may jump directly to the terminal; the two
fields need not be reciprocal at every hop.

`first` is retained, fetched, token-validated, and used as consistency evidence
when present. It is not a durable chain identifier and does not establish an
uploader revision chain by itself. Singleton galleries need not have `first`,
and no chain table, synthetic chain key, persisted `is_terminal`, or persisted
eligibility flag is introduced.

A publishable uploader-revision component must have one unambiguous terminal
and no token mismatch, cycle, branch, conflicting replacement relation, or
multiple terminal. The component is one indivisible revision-identity unit.
It takes precedence over a conflicting legacy `different_book`, canonical, or
grouping projection, but it is not itself a `same_book` decision.

### Keep only the eligible terminal in current projections

Derive one shared **eligible gallery** projection from validated live gallery
relations and required metadata. A gallery is eligible when it is the unique
terminal of a complete component and has the metadata required by current
matching/scoring, including `file_count`, `favorite_count`, `rating_count`, and
the required `language:chinese` and `other:tankoubon` scope tags.

After a successful discovery publication, only that terminal participates in
current `gallery_variants` membership, class-lifted identity, canonical
selection, scoring, desired actions, and current read projections. Replaced
members remain in `galleries` and in immutable historical evaluations,
reviews, completed actions, and acquisition facts; they are not current group
members.

Current mutable identity references follow the representative. This includes
the group source, active manual canonical decisions, current identity-pair
endpoints, pending work, and other current projections. The source review or
evaluation behind a manual choice remains frozen evidence of the original
decision. Selecting `102` therefore means selecting its uploader revision
chain; the active choice follows a later eligible `103` without adding a
separate selected-chain field.

An automatically scored canonical is different: new terminal metadata can
change which uploader-revision representative wins. When its member/input
fingerprint changes, invalidate the old current evaluation/canonical projection
and let the one coalesced evaluation select the winner again. Retarget
`canonical_gid` directly only when an active manual decision already fixes that
uploader revision chain.

`ungroup` first resolves its input to the eligible uploader-revision
representative and detaches that whole chain from a cross-chain same-book
class. It cannot split the uploader revision chain.

When an uploader-revision relation connects two independently rated groups,
merge them using the existing intent rule: the group with the newest
`latest_feedback_at`, with the existing deterministic tie-breaker, supplies
`desired_rating`. The surviving group ID is chosen independently by the
existing deterministic ownership rule. An unrated child simply inherits its
group's current rating intent; no explicit-versus-inherited flag is added.

### Separate eligible work from effective local availability

Derive a second shared **available gallery** projection for local archive
presentation and destructive-retention safety. Eligible means the GID is the
current terminal used for scoring and desired work. Available means an exact
GID still owns the committed local copy that must be kept until a safe handoff.
These projections may temporarily name different GIDs.

The `102 -> 103` rating-11 handoff is normative:

1. Until `103` has a complete, valid uploader-revision component, scope,
   metadata, and scoring inputs, publication does not occur and `102` remains
   the completed projection.
2. A successful publication promotes eligible `103`, retargets current
   membership and decisions, and scores it. If selected, `103` receives a new
   exact-GID H@H action under the normal guards.
3. A committed archive on `102` remains the effective available copy while
   `103` is being acquired. No cleanup or destructive supersession may remove
   that fallback.
4. Committing the `103` archive atomically makes it the effective available
   copy and coalesces action/cleanup reconciliation for the old archive.

The new representative never inherits the predecessor's H@H attempt/request
watermarks, `file_path`, cleanup timestamp, or completed actions. Those are
exact-GID facts under ADR-0004. For ratings `1` through `10`, no replacement
archive acquisition is required: complete remote readiness is sufficient for
eligible promotion, and ordinary rating/retention actions reconcile afterward.

### Publish live inputs and all affected current projections atomically

Discovery retains its staged run. A successful publish transaction must:

1. upsert the latest metadata, popularity, and provider relations for every
   discovered GID, including existing rows;
2. validate all uploader-revision components touched by those rows;
3. find every current identity group containing any touched GID, rather than
   only the group whose discovery job performed the fetch;
4. merge connected groups and normalize each uploader-revision component to
   its one eligible terminal;
5. mutate all affected current identity references, invalidate stale automatic
   evaluation/canonical state, and supersede or rebuild pending work whose
   concrete-GID projection changed; and
6. coalesce one follow-up job of each required kind per affected group.

Rating-11 groups receive exactly one due score evaluation. Ratings `1` through
`10` receive action reconciliation when their member or intent projection
changed, without creating winner work. Existing uniqueness/coalescing
constraints remain the idempotency boundary.

Live `galleries` rows become the scoring authority. Remove the mutable
`gallery_variants.metadata_snapshot_json` duplicate. Freeze the exact member,
metadata, score-input, policy, and uploader-revision-edge/origin snapshot only
when an immutable evaluation or review is created. Existing historical
snapshots are not rewritten.

Evaluation reads current live inputs, rejects a stale membership/input
fingerprint at commit, and writes a new immutable evaluation. It may schedule
the normal downstream action projection, but it must not enqueue discovery or
enqueue itself. Gallery metadata writes must not use recursive scheduling
triggers. The successful discovery-publish boundary is the only source of
score-refresh scheduling.

### Incomplete or malformed discovery never partially publishes

Missing referenced rows or tokens, required score inputs, or required scope
tags means **not ready**. A token mismatch, cycle, branch, relation conflict,
or multiple terminal means **invalid**. Neither condition creates a manual
identity review, promotes a terminal, or partially publishes otherwise fresh
metadata/popularity.

The attempted publication rolls back in full and preserves the last completed
live/current/effective projection. The discovery run records a bounded
diagnostic, waits under bounded retry/backoff policy, then restarts at provider
refresh so it cannot repeatedly retry a frozen invalid staging snapshot.

Expose the always-present, bounded-cardinality metric family
`yomiko_uploader_revision_publication_blocked{reason}` for blocked publication,
partitioned by this fixed reason set:

```text
reference_incomplete
scope_incomplete
scoring_input_incomplete
token_mismatch
relation_conflict
cycle
branch
multiple_terminals
```

Metrics count current blocked runs/components and never label by GID, token,
path, title, or diagnostic text. Runtime diagnostics may retain sanitized
detail for operators.

## Consequences

Positive consequences:

- Uploader-revision identity is represented once as provider data instead of
  duplicated as matching-policy evidence.
- Current groups contain one representative per uploader-revision component, so
  grouping, scoring, reviews, actions, metrics, and reads share the same unit.
- Every successful discovery refreshes the live inputs used by scoring and
  schedules all affected groups, including a gallery refreshed through another
  group's discovery.
- Current decisions can follow provider replacement without rewriting the
  historical evidence that justified them.
- The eligible/available split can request `103` without risking the only
  committed archive on `102`.
- The design adds views and validation rather than cached uploader-revision
  state fields, minimizing invalidation paths.

Costs and constraints:

- Discovery publication becomes a wider transaction that must find and lock
  every affected current group under the existing SQLite writer discipline.
- Every current-GID consumer must use the shared projection; raw
  `current_gid` predicates or ad hoc uploader-revision walks can recreate
  disagreement.
- Strict rollback means a malformed or incomplete uploader-revision component
  also withholds otherwise newer metadata/popularity until a complete snapshot
  is available. Metrics and bounded retry are therefore mandatory.
- Removing the mutable member snapshot requires coordinated scoring, review,
  CLI/API, migration, and fixture updates.
- Historical evaluations and reviews can name GIDs that are no longer current
  members. Readers must distinguish frozen audit evidence from current
  projections.

## Rejected alternatives

- **Keep `evidence.official_chain` as authority and collapse during scoring:**
  leaves replaced GIDs in current membership and lets grouping/review/action
  consumers disagree with scoring.
- **Use `first` as a chain primary key:** the provider does not document the
  necessary singleton/presence/stability contract, and real rows can have
  useful parent/current relations without it.
- **Persist a chain table, `chain_id`, `is_terminal`, or readiness columns:**
  duplicates facts already derivable at publication and creates additional
  invalidation paths without representing an independent business fact.
- **Record every provider edge as an immutable event:** current gallery rows
  plus frozen review/evaluation snapshots preserve the required audit boundary;
  an event log would add storage and reconciliation complexity not required by
  the workflow.
- **Replace `102` only after `103` has a committed archive:** prevents `103`
  from entering scoring and desired actions, so it cannot naturally obtain the
  archive needed to complete the handoff.
- **Delete or supersede `102` as soon as `103` is eligible:** can destroy the
  only known-good local copy before replacement acquisition succeeds.
- **Publish metadata while withholding only an invalid uploader-revision
  projection:** exposes a live fact set that current membership and scoring
  deliberately do not accept. The selected strict contract keeps one atomic
  completed snapshot.
- **Turn malformed uploader-revision data into same-book review:** revision
  validity is an ingestion/readiness problem, not a cross-chain content
  identity decision.

## Verification contract

Acceptance coverage must include:

- terminal-only projection for `100 -> 101 -> 102`, `201 -> 203 -> 206`, and
  `309 -> 322`;
- the full `102 -> 103` eligible/effective archive handoff;
- an unrated child inheriting group intent and independently rated groups using
  newest-feedback intent;
- manual canonical, cross-chain `same_book`/`different_book`, and `ungroup`
  interactions with an indivisible uploader-revision component;
- token mismatch, unfetched reference, absent scope, null scoring input, cycle,
  branch, relation conflict, and multiple-terminal rollback/retry/metrics;
- popularity refresh of an existing GID and exactly one evaluation for every
  affected rating-11 group, including a group other than the publisher;
- no discovery/evaluation recursion and correct transaction rollback after a
  failure between metadata upsert and projection rewrite;
- immutable historical review/evaluation/action evidence after current GIDs
  move; and
- no transfer of exact-GID H@H, archive, deletion, or cleanup facts.
