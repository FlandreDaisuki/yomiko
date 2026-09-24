# ADR-0010: Pending-only variant review surface

- Status: Accepted
- Date: 2026-09-24
- Related:
  [ADR-0003: Separate review queue and outcome-audit metrics](./0003-review-queue-and-audit-metrics.md),
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md),
  [ADR-0008: Variant review history latency](./0008-variant-review-history-latency.md),
  [ADR-0009: External interface latency budgets](./0009-external-interface-latency-budgets.md),
  [Architecture](../architecture.md)

## Context

Variant review rows are durable lifecycle records. Stored status and
supersession state do not, by themselves, define which decisions a user can
take now. The former all/resolved CLI and HTTP modes exposed retained history
through a surface understood as a current queue. `variants list` also returned
a `.groups[].reviews` field and could select a group because a raw review row
was resolved, giving the same work two different queue meanings.

The public review surface must identify only currently actionable work while
keeping lifecycle history available to internal transitions and diagnostics.

## Decision

### Publish only the actionable pending queue

The CLI command is `yomiko variants pending-reviews` and accepts no status
argument. The HTTP read is `GET /api/pending_variant_reviews.sh` with no query
string. Any query parameter returns `400`; the former `/api/reviews.sh` route
has been removed and returns `404`. The former `variants reviews` CLI command
is unknown. No alias or redirect preserves the old all/resolved modes.

The queue is a read-only projection. The token-free GET does not run
reconciliation, acquire the writer gate, or persist a read model.
Candidate-identity cards are deduplicated by their current normalized
identity-class pair; superseded or already-implied decisions are omitted.
Source and candidate revision terminals must be scoreable; winner cards must
also belong to an active rating-11 group and have scoreable choice terminals.
The established card fields, field order, and masking, including candidate-tag
redaction, are preserved. Before returning `200`, the API validates JSON shape,
pending status, count equality, and exclusions for private fields.
`actionable_count` equals the returned card count, and every card has
`status: pending`.

### Keep group diagnostics and lifecycle history separate

`variants list` no longer emits `.groups[].reviews`, and a raw resolved review
alone no longer selects a group for `--status resolved`. The remaining
`--status` filter matches group activity (`active` or `inactive`), review
state, job status, or action status; it is not a pending-review queue filter.

`resolve` keeps its current-state, identity, and stale-decision checks.
Reconciliation remains owned by existing mutating transitions. Durable
`variant_reviews` history is preserved, and the read-only
`variant_review_product_lifecycle` view remains available for lifecycle and
reconciliation use. The public pending queue does not expose resolved or
superseded rows.

### Retire the outcome-audit metric family

The exporter no longer emits
`yomiko_variant_review_outcome_audit_records`; it is not renamed or backfilled.
Provisioned dashboard panel 222, “Variant review outcomes — retained audit
records,” has been removed. Any external rule still querying this family must
be retired. Existing Prometheus samples remain untouched and expire under the
configured retention policy.

## Consequences and migration

Clients must replace `variants reviews` with `variants pending-reviews` and
`/api/reviews.sh` with `/api/pending_variant_reviews.sh`. They must remove
status arguments and query strings. Consumers that need historical outcomes
must use internal lifecycle data rather than a public review-list mode.
Dashboards and rules must stop depending on the retired outcome metric.

The pending command and endpoint remain within the strict sub-second read
budget. The measurements below are regression evidence for one snapshot, not a
capacity guarantee for arbitrary queue sizes or concurrent workloads.

## Verification

The isolated playground test suite passed **179 tests, 0 failed**. Direct HTTP
checks confirmed that the old route returns `404`. The new route returned
`200` with no query and zero cards on the copied snapshot; both
`?status=pending` and `?foo=bar` returned `400`. Fixture and queue tests
separately verified positive pending results, count equality, masking, and
private-field rejection. The old CLI command was rejected. Lifecycle tests
still query the database view directly and preserve terminal history.

A three-warm-run benchmark on one copied snapshot with 44 pending cards
measured CLI p95 at **191 ms** and HTTP p95 at **213 ms**, below the 1-second
gate. This small sample is a regression check, not a general performance
claim. The provisioned JSON was updated and validated; an unauthenticated
Grafana API check returned `401`, so runtime reload was not independently
verified. The provider polls files every 30 seconds.
