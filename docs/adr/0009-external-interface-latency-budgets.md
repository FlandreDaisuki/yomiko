# ADR-0009: External interface latency budgets

- Status: Accepted
- Date: 2026-09-23
- Related:
  [Architecture](../architecture.md),
  [ADR-0007: Read-only review projection and bounded variant evaluation](./0007-read-only-review-and-bounded-variant-evaluation.md),
  [ADR-0008: Variant review history latency](./0008-variant-review-history-latency.md),
  [ADR-0001: Class-lifted identity review projection](./0001-class-lifted-identity-review-projection.md),
  [ADR-0011: Target-seeded action writer projections](./0011-target-seeded-action-writer-projections.md)

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

## Subsequent contract (2026-09-30)

The `metrics` CLI and authenticated `/metrics` response now use the same strict
end-to-end budget as other local reads: **less than 1 second**. A renderer
optimization removed per-sample shell subprocesses while preserving the
request-local SQLite snapshot and byte-for-byte exposition. The latest
same-snapshot measurements are recorded below; prior observations remain in
the measurement history.

## Context

ADR-0007 defines strict external-read limits for local query/read-only CLI and
HTTP API paths. The metrics modes now share the strict sub-second limit below.
ADR-0008 grants a release-scoped exception for full review-history HTTP
responses. The public interface also contains mutations that wait for remote
providers, binary downloads, and local review decisions. Those modes need
explicit scope so future latency checks do not silently broaden or erase the
accepted exceptions.

This ADR records the current budgets by public route and CLI mode. The budgets
are regression criteria for the complete command or response on representative
local workloads. They are not measurements of arbitrary payload sizes, network
conditions, concurrent writer contention, or archive-mount latency.

## Decision

### Subsequent contract (2026-10-02)

[ADR-0015](./0015-rating-driven-favorite-and-feedback-reconciliation.md)
moves every rated feedback request, including previously ungrouped ratings
`1` through `7`, onto local identity persistence and durable action enqueueing.
The former synchronous remote-rating exception has ended: ExHentai rating and
favorite changes are worker-owned, and the API returns after enqueueing under
the strict `<1s` budget. Low-rated archive cleanup is also worker-owned.
Ratings `8` through `10` retain synchronous deletion of the submitted source
archive after enqueue; rating `11` retains it pending canonical reconciliation.
The 2026-09-28 grouped feedback observations remain historical; the post-change
fresh-ungrouped measurement is added below after verification.

### Normative budgets

- Local query/read-only CLI modes and ordinary local HTTP API modes have a
  strict end-to-end limit of **less than 1 second**.
- The `metrics` CLI and authenticated `/metrics` response have a strict
  end-to-end limit of **less than 1 second**.
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
| `GET /metrics` (`/api/metrics.sh`) | `yomiko metrics` | Strict `<1s` | 2026-09-30 same schema-30 2,356-gallery snapshot: after change warm p95 `0.407s`, max `0.408s`, cold `0.391s`, 24,072 B; paired old-renderer p95 `1.908s` and earlier run `1.821s`. Exposition bytes matched exactly. |
| `GET /api/galleries.sh` | `yomiko gallery-status <gids...>` | Strict `<1s` | One-GID loopback p95 `0.197s`; cold `0.176s`. The earlier 25-GID check was also below one second. |
| `GET /api/pending_feedback_galleries.sh` | Bounded `yomiko list --format json --pending-feedback --artist-sorting`, followed by one batched `yomiko internal archive-paths <gid...>` lookup | Strict `<1s` | 2026-10-02 flag update: `max_count=50`, HTTP 200, 18,309 B, cold `0.100s`, warm p95 `0.138s` (20 samples). The 2026-10-01 DTO/batched baseline used the former `--sort-by artist` spelling: 18,313 B, cold `0.139s`, warm p95 `0.192s` (20 samples). The 2026-09-28 inline-path p95 `0.117s` remains historical. |
| `GET /api/reviews.sh?status=pending` | `yomiko variants reviews --status pending` | Strict `<1s` | Loopback p95 `0.214s`; cold `0.235s`. |
| `GET /api/reviews.sh` all or `status=resolved` | `yomiko variants reviews` with the matching status | HTTP exception: p95 `<1s` remains deferred; broad ceiling `<1.5s` | ADR-0008 measured all/resolved p95 `1.067s` / `1.011s`, with a repeat at `1.075s` / `1.026s`. Keep the full review collection and existing response contract. |
| `PUT /api/review_resolve.sh` | `yomiko variants resolve` | Strict `<1s` for representative local decisions | Prior final-source schema-30 samples passed: 21 fresh candidate reviews per mode, 2,043 galleries; `same_book` p95 `0.846s`, `different_book` p95 `0.844s`. Winner selection on a separate 2,001-gallery snapshot: 21 fresh rows, p95 `0.193s`, 200 / 393 bytes. A later 2,284-gallery isolated sweep measured candidate `different_book` / `same_book` p95 `1.216s` / `1.189s`, exceeding this gate. The checked-in sweep had one winner fixture in that snapshot, so its `0.163s` winner result is a spot check rather than p95 evidence. The 2026-10-07 schema-32 sweep measured `different_book` / `same_book` / winner p95 `0.247s` / `0.254s` / `0.148s` with 21 fresh cards per mode. Stale repeats retain `409 Conflict`. |
| `PUT /api/feedback.sh`, ratings 1–11 | Local identity feedback and durable enqueue path; no synchronous remote rating/favorite request | Strict `<1s` | The 2026-09-28 grouped samples remain historical. ADR-0015 adds fresh ungrouped low ratings to this route class; post-change measurements are recorded below. Ratings 8–10 still delete the submitted source archive on the request path. |
| `POST /api/update_cookies.sh` | `yomiko login --cookie`; validates against ExHentai | Exempt from strict `<1s` | Synchronous provider wait and response behavior are retained by user decision. |
| `PUT /api/hath_download.sh` | `yomiko hath`; external H@H request | Exempt from strict `<1s` | External H@H trigger is exempt by user decision. |
| `GET /api/archive_download.sh` | Run `yomiko internal archive-paths <gid>`, then stream the archive | Metadata lookup: strict `<1s`; binary body and transfer exempt | 2026-10-01 exact-path loopback check for no-archive GID 695: HTTP 404, 18 B, cold `0.050s`, warm p95 `0.121s` and max `0.126s` (20 samples). The 2026-10-07 sweep measured p95 `0.087s` and 18 B, but BusyBox returned transport HTTP 200 with a `Status: 404 Not Found` header and the `Archive not found` body. The benchmark reports this status mismatch as a failure. The 2026-09-28 inline-path p95 `0.085s` remains the previous implementation's historical baseline. Full archive size and transfer time are excluded. |

These timings are observations from schema-30 isolated playground snapshots
recorded on 2026-09-23, final-source follow-up runs on 2026-09-24, and later
follow-ups noted below. They show
representative requests, not every GID, response size, filesystem layout, or
load condition. Candidate-review samples used newly inserted independent
source/candidate pairs, and winner selection used fresh pending review rows.
The strict budgets apply to the listed local mode classes, not only to the
measured identifiers.

Earlier metrics observations remain historical: the 2026-09-23 exception run
measured authenticated HTTP p95 `1.631s` and cold `0.724s`; a 2026-09-28
2,284-gallery sweep measured p95 `0.990s`.

The 2026-09-30 metrics comparison used one unchanged schema-30 playground
database with 2,356 gallery rows. The authenticated HTTP response was 24,072 B
before and after; rendering with the old and new formatters against that frozen
database produced byte-identical exposition. The old formatter had a paired
20-warm p95 of `1.908s`; a separate 20-warm run on the same snapshot measured
`1.821s`. The optimized formatter measured cold `0.391s`, warm p95 `0.407s`,
and warm max `0.408s`. The CLI measured warm p95 `0.428s` and max `0.436s`.
SQLite projection and metrics aggregation took about `0.145s` and `0.077s`,
respectively, so shell rendering accounted for most of the prior latency.

### Public CLI mode registry

| CLI mode | Budget / gate | Coverage and limits |
| --- | --- | --- |
| `list --format json` read modes, including GID-filtered, default, and pending-feedback listings with representative `--max-count`, `--artist-sorting`, and `--order-by` options | Strict `<1s` for bounded query/read modes | Check default and representative bounded options. The API metadata lookup for archive download remains subject to this budget. `list --format table` is advertised but unimplemented and has no latency measurement. |
| `gallery-status <gids...>` | Strict `<1s` | The route sweep measured one-GID and 25-GID CLI requests at `0.152`–`0.191s`; exercise one GID and a representative page-sized batch. |
| `variants list` | Strict `<1s` | The route audit measured representative normal and status-filtered requests below one second; exercise both shapes. |
| `variants policy-show` and `variants policy-check <path>` | Strict `<1s` | `policy-check` uses a representative bounded policy fixture. |
| `variants reviews` pending, all, and resolved | Strict `<1s` | ADR-0008's CLI p95 was `0.204s` / `0.714s` / `0.646s` for pending/all/resolved. The HTTP-only all/resolved exception does not apply to CLI. |
| `help` | Strict `<1s` | Local help output is treated as a public read-only CLI mode. |
| `metrics` | Strict `<1s` | 2026-09-30 same-snapshot optimized run: 20-warm CLI p95 `0.428s`, max `0.436s`. Earlier isolated CLI samples were `0.701s`–`0.933s`. |
| `feedback` CLI, including durable rated-feedback enqueue and ratingless timestamp update | No new CLI elapsed-time target | This is a mutation command. The strict feedback budgets in the HTTP registry remain in force for API requests; no corresponding CLI threshold is inferred here. |
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

The checked-in `tests/bench-api-latency.sh` measures all active strict local
HTTP route modes in the registry: ordinary reads, metrics, local feedback,
candidate review resolution, and archive metadata without an archive body. It
checks HTTP status and response shape and records body bytes. It restores the
isolated baseline before each candidate PUT and verifies that review through
the authenticated pending-review GET immediately before timing the PUT. The
2026-09-28 source snapshot had only one pending winner review; the script
therefore reports winner selection as a one-fixture spot check, while the prior
21-fresh-winner p95 remains the available p95 evidence. The sweep excludes the
provider-wait routes and archive body covered by explicit exemptions above.
It continues after a measured budget breach so the remaining routes still get
observations, then exits nonzero if any strict gate fails. On the 2,284-gallery
snapshot, 20-warm HTTP p95s were `0.005s` for health, `0.022s` for the
userscript, `0.990s` for metrics, `0.198s` for one-GID gallery status,
`0.071s` for pending feedback, and `0.218s` for pending reviews. Local feedback
p95s were `0.134–0.181s` across the measured rating modes, and the archive
metadata-only response was HTTP 404, 18 bytes, p95 `0.085s`. All measured
routes returned their expected statuses. The candidate review results above
were the only strict-budget failures; this run exited 1.

On 2026-10-01, the current DTO-plus-batched-path sweep measured pending
feedback at HTTP 200, 18,313 bytes, cold `0.139s`, and warm p95 `0.192s`
across 20 samples. It then exited before mutation and archive routes because
the snapshot had fewer than 21 candidate reviews visible through the
authenticated pending-review API. The archive metadata route was measured
separately against the same isolated loopback service and no-archive GID 695:
one cold request followed by 20 warm requests using `curl -sS --max-time 60
-o /dev/null -w '%{http_code}\t%{time_total}\t%{size_download}\n'
'http://127.0.0.1/api/archive_download.sh?gid=695'`. All returned HTTP 404 and
18 bytes; cold was `0.050s`, warm p95 `0.121s`, and warm max `0.126s`. The two
updated routes remain below the strict one-second gate. The incomplete sweep
does not provide current measurements for its mutation routes.

On 2026-10-02, the ADR-0015 current-worktree sweep measured 20 warm samples per
route on the recreated isolated playground. Fresh ungrouped feedback rating
`3` returned HTTP 200 with warm p95 `0.187s`; grouped rating `3` measured
`0.207s`. Ratings `8`, `9`, `10`, and `11` measured `0.244s`, `0.267s`,
`0.233s`, and `0.267s`. The other measured local routes also remained under
one second. The sweep stopped before decision-resolution samples because the
snapshot had fewer than 21 authenticated pending candidate reviews. This
fixture limitation does not affect the recorded feedback samples, which ran
before that gate.

On 2026-10-07, the full sweep used a fresh schema-31 snapshot with 2,379
galleries. Startup applied migration 032. The runner inserted 21 distinct
candidate cards and 21 distinct winner cards. It checked every card through
the authenticated pending-review API before its PUT. It restored the same
fixture snapshot before each mutation sample and collected 20 warm samples for
each decision mode. Candidate `different_book`, `same_book`, and winner p95
were `0.247s`, `0.254s`, and `0.148s`. The previous candidate p95 values on a
2,379-gallery schema-31 snapshot were `1.270s` and `1.328s`. The full sweep
also measured health `0.007s`, userscript `0.023s`, metrics `0.354s`, one-GID
gallery status `0.170s`, pending feedback `0.136s`, pending variant reviews
`0.265s`, and local feedback p95 values from `0.124s` to `0.142s`. Each strict
local route was below one second. The candidate responses were 410 B and
404 B; winner responses were 391 B cold and 393 B warm. The benchmark measured
archive metadata at `0.087s` and 18 B, then exited with a status-contract
failure because BusyBox returned HTTP 200 for the no-archive response.

The same playground measured target-write scaling with 21 fresh target cards
per case. Each sample restored its saved database and checked the target card
through the pending-review API before the PUT. The response was HTTP 200 and
411 B in each case. The table shows the number of confirmed GIDs in each
target class and the number of added pending reviews in a separate class.

| Confirmed GIDs in target class | Added unrelated pending reviews | Warm PUT p95 |
| ---: | ---: | ---: |
| 1 | 0 | `0.218s` |
| 1 | 500 | `0.218s` |
| 1 | 2,000 | `0.209s` |
| 21 | 500 | `0.230s` |
| 101 | 500 | `0.259s` |

The measurement shows no increase as unrelated pending history grows from 0 to
2,000 rows. A target class with 101 confirmed GIDs added `0.041s` to p95 over
the one-GID class with 500 unrelated reviews. The writer-gate diagnostic
threshold was set to zero in the isolated container to record short holds.
With 2,000 unrelated reviews, the write held the gate for `59ms` for a
one-GID class and `100ms` for a 101-GID class. Both had `wait_ms=0` and
`status=0`. No wait or hold reached the normal 1,000 ms log threshold.

The debug playground image installs this runner at
`/home/yomiko/bench-api-latency.sh`; invoke it through the playground
dispatcher with `YOMIKO_BENCH_ISOLATED_PLAYGROUND=1`.

## Consequences

The route and CLI mode mapping makes the existing budgets actionable while
preserving route authentication, success response shape, review visibility,
and synchronous provider behavior. Candidate identity conflicts and repair
semantics intentionally follow the monotonic decision rule in ADR-0001; the
API also accepts a historical winner GID when the CLI returns its normalized
terminal. Review resolution retains the representative sub-second gate, which
the later 2,284-gallery candidate samples exceed. Remote-wait routes remain
exempt; the former full review-history HTTP exception retired with its route.
Measurements are tied to the recorded fixtures and must be refreshed when
payload shape, schema, route behavior, or workload changes materially.
