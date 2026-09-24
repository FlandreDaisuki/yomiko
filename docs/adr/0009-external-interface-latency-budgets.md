# ADR-0009: External interface latency budgets

- Status: Accepted
- Date: 2026-09-23
- Related:
  [Architecture](../architecture.md),
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md),
  [ADR-0008: Variant review history latency](./0008-variant-review-history-latency.md),
  [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md)

## Subsequent contract (2026-09-24)

Only the pending review read remains public: `yomiko variants pending-reviews`
and `GET /api/pending_variant_reviews.sh` with no query parameters. It follows
the ordinary strict sub-second read budget. The former `variants reviews`
status modes and `/api/reviews.sh` route have been removed, so the full-history
all/resolved HTTP exception and corresponding table rows below are historical
measurements, not active endpoints or budgets. Other route and CLI budgets in
this ADR are unchanged. The retained review outcome metric is also retired;
remove external dashboard and rule references during deployment, while stored
Prometheus samples expire under the configured retention. See [ADR-0010:
Pending-only variant review surface](./0010-pending-only-variant-review-surface.md)
for the accepted decision and verification.

## Context

ADR-0007 defines strict external-read limits for local query/read-only CLI and
HTTP API paths, plus a separate metrics limit. ADR-0008 grants a release-scoped
exception for full review-history HTTP responses. The public interface also
contains mutations that wait for remote providers, binary downloads, and local
review decisions. Those modes need explicit scope so future latency checks do
not silently broaden or erase the accepted exceptions.

This ADR records the current budgets by public route and CLI mode. The budgets
are regression criteria for the complete command or response on representative
local workloads. They are not measurements of arbitrary payload sizes, network
conditions, concurrent writer contention, or archive-mount latency.

## Decision

### Normative budgets

- Local query/read-only CLI modes and ordinary local HTTP API modes have a
  strict end-to-end limit of **less than 1 second**.
- The `metrics` CLI and authenticated `/metrics` response have a strict
  end-to-end limit of **less than 10 seconds**.
- Full review-history all/resolved HTTP responses retain ADR-0008's accepted
  exception: their sub-second target is deferred, with the existing **1.5
  second** broad regression ceiling. The corresponding CLI modes remain under
  the strict **less than 1 second** limit.
- Local `review_resolve` mutations follow the strict sub-second gate for
  representative fresh decisions, including `same_book`, `different_book`,
  and canonical selection. Synchronous remote-wait routes and the binary
  archive response remain outside that gate as described below. No new
  elapsed-time target is assigned to other CLI mutations, workers,
  filesystem-heavy commands, or provider integrations.

### Public HTTP route registry

The production surface has eleven public `web/api/*.sh` scripts, excluding
the internal `_middleware.sh` helper. The `health.sh`, `metrics.sh`, and
`install_userscript.sh` scripts also have rewrite aliases `/health`,
`/metrics`, and `/yomiko.user.js`. The debug-only echo inspector is not part
of the production surface.

| Public route and mode | CLI path or work performed | Budget / gate | Evidence or exception |
| --- | --- | --- | --- |
| `GET /health` (`/api/health.sh`) | Direct health response | Strict `<1s` | Warm loopback p95 `0.011s`; cold `0.004s`. |
| `GET /yomiko.user.js` (`/api/install_userscript.sh`) | Render and serve the userscript | Strict `<1s` | Warm loopback p95 `0.043s`; cold `0.019s`. |
| `GET /metrics` (`/api/metrics.sh`) | `yomiko metrics` | Strict `<10s` | Authenticated loopback p95 `1.631s`; cold `0.724s`. |
| `GET /api/galleries.sh` | `yomiko gallery-status <gids...>` | Strict `<1s` | One-GID loopback p95 `0.197s`; cold `0.176s`. The earlier 25-GID check was also below one second. |
| `GET /api/pending_feedback_galleries.sh` | Bounded `yomiko list --format json --pending-feedback --group-by artist` | Strict `<1s` | `max_count=50` loopback p95 `0.117s`; cold `0.056s`. |
| `GET /api/reviews.sh?status=pending` | `yomiko variants reviews --status pending` | Strict `<1s` | Loopback p95 `0.214s`; cold `0.235s`. |
| `GET /api/reviews.sh` all or `status=resolved` | `yomiko variants reviews` with the matching status | HTTP exception: p95 `<1s` remains deferred; broad ceiling `<1.5s` | ADR-0008 measured all/resolved p95 `1.067s` / `1.011s`, with a repeat at `1.075s` / `1.026s`. Keep the full review collection and existing response contract. |
| `PUT /api/review_resolve.sh` | `yomiko variants resolve` | Strict `<1s` for representative local decisions | Final-source schema-30 playground samples: 21 fresh candidate reviews per mode, 2,043 galleries; `same_book` cold `0.786s`, warm p95 `0.846s`, 200 / 405 bytes; `different_book` cold `0.763s`, warm p95 `0.844s`, 200 / 411 bytes. Winner selection on a separate 2,001-gallery snapshot: cold `0.131s`, warm p95 `0.193s`, 200 / 393 bytes. Full method and scope: [live review-resolve investigation](../bugs/2026-09-23-review-resolve-live-production-latency.md). Stale repeats retain `409 Conflict`. |
| `PUT /api/feedback.sh`, variant-scoped ratings 8–11 and grouped ratings 1–7 | Local variant feedback and enqueue path | Strict `<1s` | Representative authenticated loopback p95s: rating 11 `0.196s` with the gate observer (`0.131s` uninstrumented); grouped rating 3 `0.305s`; ratings 8/9/10 `0.148s` / `0.156s` / `0.146s`. Final feedback API cold + 20 warm run on 2,001 galleries: cold `0.135s`, warm p95 `0.131s`, 200 / 128 bytes. |
| `PUT /api/feedback.sh`, ungrouped ratings 1–7 | Legacy synchronous remote-rating fallback | Exempt from strict `<1s` | Remote wait and existing synchronous response behavior are retained by user decision. |
| `POST /api/update_cookies.sh` | `yomiko login --cookie`; validates against ExHentai | Exempt from strict `<1s` | Synchronous provider wait and response behavior are retained by user decision. |
| `PUT /api/hath_download.sh` | `yomiko hath`; external H@H request | Exempt from strict `<1s` | External H@H trigger is exempt by user decision. |
| `GET /api/archive_download.sh` | Run a bounded `yomiko list --format json --max-count 1 <gid>` lookup, then stream the archive | Metadata lookup: strict `<1s`; binary body and transfer exempt | The local metadata read remains in the ordinary read budget; no separate route p95 was recorded. Full archive size and transfer time are excluded. |

These timings are observations from schema-30 isolated playground snapshots
recorded on 2026-09-23 and final-source follow-up runs on 2026-09-24. They show
representative requests, not every GID, response size, filesystem layout, or
load condition. Candidate-review samples used newly inserted independent
source/candidate pairs, and winner selection used fresh pending review rows.
The strict budgets apply to the listed local mode classes, not only to the
measured identifiers.

### Public CLI mode registry

| CLI mode | Budget / gate | Coverage and limits |
| --- | --- | --- |
| `list --format json` read modes, including GID-filtered, default, and pending-feedback listings with representative `--max-count`, `--group-by`, and `--order-by` options | Strict `<1s` for bounded query/read modes | Check default and representative bounded options. The API metadata lookup for archive download remains subject to this budget. `list --format table` is advertised but unimplemented and has no latency measurement. |
| `gallery-status <gids...>` | Strict `<1s` | The route sweep measured one-GID and 25-GID CLI requests at `0.152`–`0.191s`; exercise one GID and a representative page-sized batch. |
| `variants list` | Strict `<1s` | The route audit measured representative normal and status-filtered requests below one second; exercise both shapes. |
| `variants policy-show` and `variants policy-check <path>` | Strict `<1s` | `policy-check` uses a representative bounded policy fixture. |
| `variants reviews` pending, all, and resolved | Strict `<1s` | ADR-0008's CLI p95 was `0.204s` / `0.714s` / `0.646s` for pending/all/resolved. The HTTP-only all/resolved exception does not apply to CLI. |
| `help` | Strict `<1s` | Local help output is treated as a public read-only CLI mode. |
| `metrics` | Strict `<10s` | Prior isolated CLI samples were `0.701s`–`0.933s`. |
| `feedback` CLI, including local variant feedback and remote fallback | No new CLI elapsed-time target | This is a mutation command. The strict feedback budgets in the HTTP registry remain in force for API requests; no corresponding CLI threshold is inferred while CLI mutation scope is undecided. |
| Other mutating, worker, filesystem-heavy, and provider-integration commands | No new elapsed-time target in this ADR | Includes `scan`, `archive`, `rate`, `hath`, `favorite`, `login`, `whoami`, `variants enqueue/work/evaluate/resolve/ungroup/policy-activate`, and `repair-tags`. Individual API budgets and exceptions above continue to apply to their HTTP callers. |

The existing CLI budget applies to local query/read-only modes, not every
command named in `bin/yomiko`. A future budget for mutations or provider waits
requires a separate decision and must state its input-size and dependency
assumptions.

### Regression measurement method

For a latency gate, measure the complete CLI command or complete HTTP response
in an isolated `yomiko-playground` using a consistent schema-30 snapshot. Do
not run benchmark mutations against production or enable remote writes. For
HTTP, use authenticated loopback requests when the route requires a token and
retain the route's normal CGI and response validation work in the timer. For
CLI, time the public `bin/yomiko` invocation rather than only its SQL query.

Report the first request separately as cold. Collect at least 20 subsequent
warm samples and report nearest-rank p95 (for 20 samples, the 19th sorted
sample). Strict budgets pass only when the measured p95 is below the stated
limit. Record request parameters, fixture size, status code, response bytes,
and any instrumentation overhead with the result. For mutating review samples,
verify every pending fixture in the authenticated web GET before its PUT and
use a fresh pending review for each successful sample. Measure decision modes
from separate consistent snapshots so earlier mutations cannot change later
samples. For full review all/resolved HTTP modes, continue to check the
ADR-0008 1.5-second ceiling while the sub-second gate is deferred.

The checked-in `tests/bench-review-latency.sh` implements this method for
review modes and keeps canonical response validation in the timed HTTP path.
Other routes need equivalent route-specific coverage before their observed
values are treated as a passing regression gate; measurements in this ADR do
not by themselves establish automated coverage for every route.

## Consequences

The route and CLI mode mapping makes the existing budgets actionable while
preserving route authentication, success response shape, review visibility,
and synchronous provider behavior. Candidate identity conflicts and repair
semantics intentionally follow the monotonic decision rule in ADR-0001; the
API also accepts a historical winner GID when the CLI returns its normalized
terminal. Review resolution now has a measured representative sub-second gate;
remote-wait routes remain exempt, and full review-history HTTP remains the
single measured release exception with a broad ceiling. Measurements are tied
to the recorded fixtures and must be refreshed when payload shape, schema,
route behavior, or workload changes materially.
