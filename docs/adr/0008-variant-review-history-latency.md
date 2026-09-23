# ADR-0008: Variant review history latency

- Status: Accepted
- Date: 2026-09-23
- Related:
  [ADR-0005: Provider-authoritative uploader-revision-chain projection](./0005-provider-authoritative-uploader-revision-chain-projection.md),
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md),
  [Review-history latency plan](../plans/2026-09-23-fix-review-history-latency.md)

## Context

The full `variants reviews` CLI and `GET /api/reviews.sh` response were slow on
a schema-30 snapshot with 2,000 galleries and 2,192 stored reviews. The API
returned the same review collection as the CLI, but repeated revision CTE work
and two full JSON parse/format passes made the all/resolved paths take over six
seconds and expanded the response from about 7.4 MB to about 11 MB.

The endpoint must keep returning the complete visible review collection,
including its evidence and ordering. It must preserve the pending queue and
visibility rules, remain read-only, and reject malformed or private data before
sending a successful response.

ADR-0007 sets a strict external-read limit below one second. The review
all/resolved paths remain just above that limit after this change. The user
approved their measured release performance and deferred the subsecond target
for future work.

## Decision

### Keep the full review contract and read-only boundary

`variants_reviews_json` continues to use a query-only database connection and
does not acquire the writer gate or persist a read model. The API writes the
CLI response to a temporary file, validates it in SQLite memory, and sends no
200 headers until validation succeeds. The temporary directory is removed on
exit. The API response contains exactly `success`, `actionable_count`, and
`reviews`; it streams the validated compact CLI JSON after adding the public
`success: true` field.

Validation checks the exact top-level key set and uniqueness, compact
one-line framing, the review row shape, numeric counts, and recursively
forbidden internal keys. Malformed, legacy, extra-key, duplicate-key,
non-compact, or private-key payloads return 502 before a 200 response. The
validator first applies `json_valid(raw)`, since SQLite’s JSONB parser also
accepts JSON5 and the raw bytes are streamed unchanged. SQLite JSONB and
`readfile()` are available in the supported Alpine 3.23.2 image; the validator
uses the installed SQLite runtime and adds no package dependency.

### Share the revision projection work and index the review cache

The shared evaluation/review/retention SQL materializes the repeatedly used
component-member, relation-edge, valid-edge, component-classification, and
classified-member CTEs. Ordered edge provenance is aggregated once per
component and joined to its members. Review output is canonical-equal to the
committed HEAD projection on the snapshot and to the existing malformed-chain
fixtures, including edge order.

Review cache lookups use a temporary `(kind, key_id)` index. The resolved
identity projection reuses the shared visibility CTE and skips pending/actionable
class calculations that resolved rows do not consume. All and pending retain
their existing identity projection.

### Record a release-scoped latency exception

This ADR supersedes ADR-0007’s subsecond limit only for full `variants reviews`
all/resolved HTTP requests in this release. The user accepted the current
release performance. The final gated strict-JSON 20-run benchmark measured
HTTP p95 of 1.067 seconds for all and 1.011 seconds for resolved. A second
strict-JSON run measured 1.075 and 1.026 seconds. All/pending/resolved CLI and
pending HTTP remain gated below one second. Other external reads retain
ADR-0007's limit; this exception does not claim that the all/resolved HTTP
target has been met, and the subsecond target remains future performance work.

The runnable benchmark performs 20 or more warmed samples for all, pending,
and resolved; checks the full canonical API envelope and review payload;
records revision-stage, CLI, validator, CGI, loopback HTTP, bytes, process CPU,
and first-run timings; and enforces subsecond p95 for all three CLI modes and
pending HTTP. It applies a 1.5-second broad regression ceiling to every mode.
All/resolved HTTP subsecond p95 is explicitly deferred; one second is not its
passing gate.

## Measurements

Measurements below use a consistent isolated schema-30 snapshot, the same
2,000-gallery database, and 20 warm samples. HTTP time is loopback client
elapsed time; its CPU column is the curl client process. CLI, validator, and
CGI CPU values are process CPU.

| Review mode | Visible reviews | CLI bytes | API bytes | CLI p95 / avg CPU | Validator p95 / avg CPU | CGI p95 / avg CPU | HTTP p95 / client CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| all | 1,941 | 7,391,651 | 7,391,666 | 0.714 s / 0.674 s | 0.363 s / 0.353 s | 1.045 s / 1.022 s | 1.067 s / 0.008 s |
| pending | 4 | 12,190 | 12,205 | 0.204 s / 0.195 s | 0.012 s / 0.011 s | 0.241 s / 0.220 s | 0.230 s / 0.003 s |
| resolved | 1,937 | 7,379,496 | 7,379,511 | 0.646 s / 0.625 s | 0.359 s / 0.348 s | 0.986 s / 0.965 s | 1.011 s / 0.008 s |

The final gated run’s first measured all/pending/resolved HTTP requests took
1.020 / 0.186 / 0.945 seconds. These are first requests after the playground
service started, not container startup timings. Canonical comparisons confirmed
that API responses preserve the complete CLI review set and add only the public
success envelope. The broad 1.5-second ceiling and subsecond CLI/pending HTTP
gates passed.

A five-sample HEAD/current comparison on the same database found:

| Shared projection mode | HEAD median | Current median | Canonical rows |
| --- | ---: | ---: | --- |
| evaluation | 0.111 s | 0.061 s | equal, including ordered edge provenance |
| retention | 0.091 s | 0.052 s | equal, including ordered edge provenance |
| status | 0.013 s | 0.017 s | equal |
| list | 0.017 s | 0.010 s | equal |

Status and list projection SQL and query plans were identical to HEAD. Full
read-only CLI medians were 0.172 / 0.165 seconds for gallery status and 0.106 /
0.121 seconds for variants list, with canonical output equal. The evaluation
and retention plans contain the five intended materialized component CTEs;
their projection times improved on this snapshot.

## Consequences

The complete review history is preserved and the API streams compact CLI JSON
after validating it, avoiding jq’s full response reformatting. The response
size is nearly the CLI size. Review all/resolved still exceed the general
one-second read limit by about 11–67 ms in the final gated strict-JSON run,
with small run-to-run variation. Future work must reduce the remaining CLI or
validation cost without changing visibility, evidence, ordering, or response
completeness. This snapshot does not include a large archive tree and does
not measure contention from concurrent writers.
