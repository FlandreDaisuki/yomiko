# ADR-0001: Class-lifted identity review projection

- Status: Accepted
- Date: 2026-09-15
- Related: [ADR-0005: Provider-authoritative uploader-revision chain projection](./0005-provider-authoritative-uploader-revision-chain-projection.md)

## Context

Yomiko stores identity evidence in two related forms. `gallery_identity_pairs`
records an unordered decision between two terminal-normalized GIDs, while confirmed members of
an active `variant_group` represent a same-book equivalence class. Groups can
be merged, leaving historical groups inactive while their reviews and audit
evidence remain owned by those groups.

Treating those rows as direct group-local state creates two failures:

1. A pending review owned by a losing group disappears from the active
   survivor's review state even though its class pair is still unknown.
2. Metrics and read APIs can disagree with the durable queue, or repair state
   by mutating the database.

The following example is the motivating case:

```text
Group A: confirmed {101}, active
Group B: confirmed {102}, owns pending review (102, 103), active

Resolve (101, 102) as same_book.

Group A becomes the active class {101, 102}; Group B becomes inactive.
The unresolved (102, 103) review is still an unknown class pair. It blocks
active Group A, and Group B remains candidate_pending because it owns the
actionable identity-review representative.
```

## Decision

Use one class-lifted identity projection with these rules:

- Every active confirmed group is one equivalence class, identified by its
  smallest scoreable revision terminal GID. An otherwise ungrouped scoreable
  revision terminal GID is a
  singleton class; historical revisions remain exact-GID audit facts.
- Manual identity decisions are unordered. Resolved `different_book` edges are
  lifted from raw GIDs to class pairs; a same-class pair is already resolved.
- Pending candidate rows are classified as `same_book`, known
  `different_book`, or unknown. Unknown class pairs have exactly one
  identity-review representative, preferring an active owner and then the
  lowest review ID.
- Live chain visibility is part of the projection. The migration-028
  `scoreable_revision_terminals` view supplies one complete, token-validated terminal;
  replaced source, candidate, or winner-choice galleries remain audit rows but
  cannot be actionable and cannot suppress a visible identity-review
  representative.
- `candidate_pending` is projected both onto the active classes touched by an
  actionable review and onto the review's durable owner, even when that owner
  is inactive. A pending visible winner review projects `winner_pending` when
  no candidate block has precedence.
- `superseded_at` materializes the projection but does not define it. A class
  change can make a previously superseded pending row the new identity-review
  representative;
  runtime reconciliation may reopen it.

The read-only SQL views created by migration 023 are the authority for:

- class membership, lifted negative edges, pending candidates, visibility, and
  actionable identity-review representatives;
- persisted group review-state repair;
- Prometheus review-state mismatch and actionable-review metrics;
- diagnostics and API projections.

The consuming components are deliberately named here because each must keep
the same projection contract: `variants_identity_reconcile_sql` materializes
the transaction-local version (including discovery staging GIDs),
`variant_discovery_publish` and `variants_evaluate_group` use it while
publishing or evaluating work, `variants_reviews_json` exposes the current
queue, and `metrics_emit_payload` reads the persistent views without mutation.
Uploader-revision normalization is shared with these consumers through
migration 027; no caller may replace it with an ad hoc `current_gid` walk.

Runtime transitions materialize the same projection inside their transaction
before changing durable review rows. A candidate decision queues evaluation
when an active blocker is removed; it does not schedule discovery merely to
rediscover an existing review. Ordinary discovery scheduling remains
independent.

## Consequences

Positive consequences:

- Merging groups cannot strand an unresolved class pair or leave the inactive
  review owner with stale `candidate_pending` state.
- Metrics are genuinely read-only and can be compared directly with the web
  review queue.
- Reclassification is reversible after ungrouping because superseded pending
  evidence is retained.
- The migration repairs historical terminal timestamps and stale review-state
  rows once at startup; no durable repair job is required.

Costs and constraints:

- Projection queries use class and JSON visibility joins and must remain
  bounded. They must not expose gallery IDs, paths, owners, or raw diagnostics
  as metric labels.
- `ungroup` is a structural operation and is not a repair shortcut for stale
  groups; using it would destroy evidence and alter active classes.
- Metrics and read APIs must not call mutating reconciliation commands.
- Terminal jobs and actions must write `status` and `completed_at` in the same
  transaction. Existing completion timestamps are preserved with `COALESCE`
  when an already-terminal action is superseded.

## Verification

Tests cover unknown class pairs, duplicate suppression, visible replacement
handling, an inactive owner whose remaining review becomes superseded, reopen
after ungroup, state-transition evaluation queueing, metric/API agreement,
read-only metrics, and migration backfill of terminal timestamps.
