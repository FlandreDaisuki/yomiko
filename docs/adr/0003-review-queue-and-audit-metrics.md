# ADR-0003: Separate review queue and outcome-audit metrics

- Status: Accepted for audit outcomes; actionable metric suspended on 2026-09-23
- Date: 2026-09-17
- Related: [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md)

## Historical status

This ADR records the design used while
`yomiko_variant_actionable_reviews` was exposed. On 2026-09-23, that metric and
the `review_state_mismatch` invariant member were temporarily removed by user
direction. Earlier testing measured the request-local metrics snapshot with
both signals at about 0.8 seconds; persistent global review projections were
measured above 30 seconds and are unsuitable for bounded request paths. The
audit outcome family remains exposed. The actionable queue examples and
statements below describe the historical contract; review CLI and API behavior
did not change.

## Context

`variant_reviews` stores several kinds of durable rows: pending projection
inputs, manual decisions, superseded rows, and canonical-selection history.
Its raw `status='pending'|'resolved'` is therefore persistence state, not the
product lifecycle shown to users.

In particular, `superseded_at` is independent of raw status. The CLI already
projects every row with a non-null `superseded_at` as
`resolved/superseded`, but the former
`yomiko_variant_reviews{review_type,status}` grouped by raw status. It could
therefore report non-actionable duplicate, implied, hidden, or superseded rows
as pending, while resolved counts omitted their decisive outcome.

ADR-0001 defines the current queue from active identity classes, known
negative edges, visibility, and representative ranking. The existing
`yomiko_variant_actionable_reviews` implements that contract. This ADR defines
how to expose retained review history without confusing it with current work.

## Decision

### Separate current work from retained history

`yomiko_variant_actionable_reviews{review_type}` remains the only metric for
current manual-work counts. Remove:

```text
yomiko_variant_reviews{review_type,status}
```

Add:

```text
yomiko_variant_review_outcome_audit_records{review_type,resolution}
```

The new gauge counts retained audit rows. It does not claim to represent
current relations, current cards, unique decisions, events, or throughput.
There is no compatibility alias: reusing the old name would let dashboards
silently mix old and new semantics during rollout.

### Share one public lifecycle projection

Migration 025 creates the read-only
`variant_review_product_lifecycle(review_id, projected_status, resolution)`
view:

```sql
SELECT review.id,
       CASE WHEN review.superseded_at IS NOT NULL
            THEN 'resolved' ELSE review.status END,
       CASE WHEN review.superseded_at IS NOT NULL
            THEN 'superseded' ELSE review.decision END
  FROM variant_reviews AS review;
```

`superseded` takes precedence over a retained decision. Pending rows with no
resolution do not enter the audit metric; whether they are actionable cannot
be inferred from raw status.

`variants_list_json()`, `variants_reviews_json()`, and the exporter use this
view for lifecycle fields. Each CLI function still owns its row-selection,
visibility, and reconciliation rules; the view does not replace ADR-0001's
class-lifted actionability projection.

Example lifecycle projections:

| Review type | Raw status | Decision | `superseded_at` | Public lifecycle | Counted audit tuple |
| --- | --- | --- | --- | --- | --- |
| candidate_identity | pending | null | null | pending / null | no |
| candidate_identity | resolved | same_book | null | resolved / same_book | candidate_identity / same_book |
| candidate_identity | pending | null | set | resolved / superseded | candidate_identity / superseded |
| winner | resolved | winner | null | resolved / winner | winner / winner |
| winner | resolved | winner | set | resolved / superseded | winner / superseded |

The last row demonstrates precedence: one durable row contributes to exactly
one audit series even though its original decision remains stored.

### Emit only the five valid tuples

The exporter always emits these tuples, including zero values:

```text
candidate_identity / same_book
candidate_identity / different_book
candidate_identity / superseded
winner             / winner
winner             / superseded
```

It does not emit the Cartesian product. A zero-valued invalid tuple would
still falsely advertise that state as part of the public schema. Renderer
validation rejects missing, duplicate, invalid, negative, or fractional rows.

### Keep audit inventory independent of current projection filters

The audit gauge includes every retained terminal row. It does not apply
visibility, active-group, class-lifting, representative ranking, or
`gallery_identity_pairs.current_review_id` filtering. Consequently:

- `same_book` and `different_book` are historical row outcomes, not current
  class relations;
- `superseded` rows are not pending work;
- audit totals are neither current review totals nor additive with the
  actionable queue.

Overlap is intentional. Suppose candidate row 42 was superseded as a duplicate,
then an ungroup changes the classes before reconciliation clears its timestamp.
ADR-0001 may project row 42 as the current actionable representative while this
ADR still projects its durable row as `resolved/superseded`. During that window:

```text
yomiko_variant_actionable_reviews{review_type="candidate_identity"} 1
yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="superseded"} 1
```

The exporter must neither mutate reconciliation state nor force the two
families into an exclusive partition.

### Use a gauge

Review rows can be deleted by ungroup or future retention, reopened by class
changes, or moved from a decision outcome to `superseded`. Snapshot inventory
can therefore decrease or change series and cannot be a counter.

Metrics are a product interface, not a mirror of persistence columns. Internal
fields such as raw `status`, `superseded_at`, or `variant_groups.is_active`
become metric dimensions only after an explicit product universe and lifecycle
are defined.

## Consequences

- Dashboards no longer confuse raw pending rows with the current queue.
- CLI and metrics share superseded precedence without duplicating lifecycle
  CASE expressions.
- The hard rename requires coordinated dashboard, recording-rule, and alert
  updates; old series remain visible until Prometheus retention expires.
- The metric remains row inventory. Current relation counts, event counters,
  latency, and retention-window semantics require separate designs.

## Rejected alternatives

- **Add `resolution` to the old family:** still mixes raw pending state with a
  projected terminal lifecycle and preserves a misleading name.
- **Redefine old pending as actionable:** creates an invisible semantic break
  and combines two different universes.
- **Drop outcome observability:** loses useful retained same/different/winner
  history instead of naming it accurately.
- **Filter or deduplicate by current state:** erases replaced, inactive, and
  later-superseded evidence from audit history.
- **Derive counters from the table:** mutable snapshot rows are not an
  immutable event log.
- **Duplicate the CASE in the exporter:** keeps the lifecycle-drift risk that
  the narrow shared view removes.

## Follow-up

- Update external consumers as part of the metric rename rollout.
- Redesign or remove `yomiko_variant_oldest_pending_review_age_seconds`
  separately; raw `created_at` is not actionable-entry time.
- If retention is introduced, document its window while keeping this metric a
  retained-inventory gauge.
