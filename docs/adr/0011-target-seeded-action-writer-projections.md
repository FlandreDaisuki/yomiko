# ADR-0011: Target-seeded projections for bounded action writes

- Status: Accepted
- Date: 2026-09-28
- Related:
  [ADR-0002: Bounded SQLite writer coordination](./0002-bounded-sqlite-writer-coordination.md),
  [ADR-0006: Discovery revision and archive vocabulary](./0006-discovery-revision-archive-vocabulary.md),
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md)

## Context

The per-group `variants_actions_project` and `variants_actions_claim_next`
write paths joined `archive_source_galleries`, a global recursive projection.
SQLite materialized revision components across the database while those paths
held the shared writer gate. A production action held that gate for 20,198 ms,
long enough to make a review PUT exceed its 5-second gate wait.

## Decision

Bounded action writes seed the existing revision projection helper from the
target group. They derive archive sources and cleanup revision members from
that local projection inside the writer transaction. The archive selection
keeps migration 028's terminal preference, predecessor fallback, and blocked
component fallback. In the transaction, action projection recomputes the
canonical-to-archive GID/path mapping and uses the existing
`canonical_archive_available` preflight result when deriving cleanup actions.
The archive-file regularity check remains outside the transaction; this
decision bounds SQLite revision/archive-source work and adds no filesystem
recheck under the gate. Claiming seeds from the claimed job's group. Global
views remain available to callers that need a database-wide projection.

This extends ADR-0007's target-seeded projection policy to these writer paths;
it does not change the data model or archive authority rules.

## Consequences

On an isolated schema-30 snapshot with 2,284 galleries, `variants_actions_project`
held the writer gate for 46 ms and `variants_actions_claim_next` for 44 ms,
compared with the 20,198 ms project hold and 18,589–18,742 ms claim holds
recorded during the incident.
The 5-second writer wait remains unchanged. Revision components that are
themselves unusually large can still increase action cost, so the existing
slow-writer diagnostics remain useful.

Raising the gate timeout was rejected because it would preserve the long
critical section and extend waits for review and feedback writers. The
regression fixture checks predecessor fallback, blocked-component fallback,
and cleanup behavior using the target-seeded projection.
