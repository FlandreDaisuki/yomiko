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
status modes and `/api/reviews.sh` route have been removed. ADR-0008 keeps the
full-history HTTP exception and its measurements as historical; they do not
describe active endpoints or budgets. Other route and CLI budgets in this ADR
were unchanged at that time. The retained review outcome metric is also retired;
remove external dashboard and rule references during deployment, while stored
Prometheus samples expire under the configured retention. See [ADR-0010:
Pending-only variant review surface](./0010-pending-only-variant-review-surface.md)
for the accepted decision and verification.

## Subsequent contract (2026-09-30, historical)

At that time, the `metrics` CLI and authenticated `/metrics` response used the
same strict end-to-end budget as other local reads: **less than 1 second**. A
renderer optimization removed per-sample shell subprocesses while preserving
the request-local SQLite snapshot and byte-for-byte exposition. The current
2026-10-07 contract below sets the authenticated `/metrics` limit to less than
500 ms. The metrics CLI remains below 1 second. Measurements from the renderer
change remain in the history below.

## Context

ADR-0007 defines strict external-read limits for local query/read-only CLI and
HTTP API paths. The metrics CLI and authenticated metrics API each have an
explicit latency limit.
ADR-0008 recorded a release-scoped exception for full review-history HTTP
responses. That route has since been removed. The public interface also
contains mutations that wait for remote providers, binary downloads, and local
review decisions. Those modes need explicit scope so future latency checks do
not silently broaden or erase the accepted exceptions.

This ADR records the current budgets by public route and CLI mode. The budgets
are regression criteria for the complete command or response on representative
local workloads. They are not measurements of arbitrary payload sizes, network
conditions, concurrent writer contention, or archive-mount latency.

## Decision

### Subsequent contract (2026-10-07)

Active local HTTP API routes with no accepted exception now have a strict warm
p95 limit of **less than 500 ms**. This includes local reads, feedback,
review decisions, archive metadata lookup, and the authenticated `/metrics`
response. Local query/read-only CLI modes, including the metrics CLI, keep a
strict limit of **less than 1 second**.

These are warm p95 benchmark limits for the complete response. They are not
per-request timeouts. The synchronous provider-wait routes and archive response
body keep their accepted exceptions. This contract supersedes the earlier
HTTP limits below. The CLI limits do not change.

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

- Local query/read-only CLI modes have a strict end-to-end limit of
  **less than 1 second**. Active local HTTP API routes with no accepted
  exception have a strict warm p95 limit of **less than 500 ms**.
- The authenticated `/metrics` response has a strict warm p95 limit of
  **less than 500 ms**. The `metrics` CLI has a strict end-to-end limit of
  **less than 1 second**.
- Local `review_resolve` mutations follow the strict **less than 500 ms** gate
  for representative fresh decisions, including `same_book`, `different_book`,
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
| `GET /health` (`/api/health.sh`) | Direct health response | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: cold `0.007770s`; 20-warm p95 `0.011301s`. |
| `GET /yomiko.user.js` (`/api/install_userscript.sh`) | Render and serve the userscript | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: cold `0.017117s`; 20-warm p95 `0.040838s`. |
| `GET /metrics` (`/api/metrics.sh`) | `yomiko metrics` | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: cold `0.356251s`; 20-warm p95 `0.461498s`; response 24,076 B. |
| `GET /api/galleries.sh` | `yomiko gallery-status <gids...>` | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: one GID, cold `0.166074s`, p95 `0.190920s`; response 419 B. |
| `GET /api/pending_feedback_galleries.sh` | Bounded `yomiko list --format json --pending-feedback --artist-sorting`, followed by one batched `yomiko internal archive-paths <gid...>` lookup | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: cold `0.156562s`; 20-warm p95 `0.222909s`; response 18,567 B. |
| `GET /api/pending_variant_reviews.sh` | `yomiko variants pending-reviews` | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep: cold `0.251844s`; 20-warm p95 `0.316791s`; response 210,513 B. |
| `PUT /api/review_resolve.sh` | `yomiko variants resolve` | Strict `<500ms` for representative local decisions | Latest 2026-10-07 schema-32 sweep, 21 fresh cards per decision: different-book cold/p95 `0.263418s`/`0.357126s`; same-book `0.361092s`/`0.372463s`; winner `0.186270s`/`0.234275s`. |
| `PUT /api/feedback.sh`, ratings 1–11 | Local identity feedback and durable enqueue path; no synchronous remote rating/favorite request | Strict `<500ms` | Latest 2026-10-07 schema-32 sweep, cold/p95: ratings 8 `0.150406s`/`0.229603s`; 9 `0.152284s`/`0.231616s`; 10 `0.088601s`/`0.224558s`; 11 `0.105364s`/`0.225045s`; grouped 3 `0.164326s`/`0.253904s`; fresh ungrouped 3 `0.185430s`/`0.203467s`. |
| `POST /api/update_cookies.sh` | `yomiko login --cookie`; validates against ExHentai | Exempt from strict `<500ms` | Synchronous provider wait and response behavior are retained by user decision. |
| `PUT /api/hath_download.sh` | `yomiko hath`; external H@H request | Exempt from strict `<500ms` | External H@H trigger is exempt by user decision. |
| `GET /api/archive_download.sh` | Run `yomiko internal archive-paths <gid>`, then stream the archive | Metadata lookup: strict `<500ms`; binary body and transfer exempt | Latest 2026-10-07 schema-32 sweep: HTTP 404, 18 B, cold `0.048197s`; 20-warm p95 `0.129099s`. The archive body and transfer are excluded. |

The latest 2026-10-07 full sweep used a schema-32 playground snapshot with
2,379 galleries. It ran with the default strict `<500ms` gate, collected
20 warm samples per route, and used 21 fresh candidate cards and 21 fresh
winner cards. Non-metrics API warm p95 values ranged from 0.011301 to 0.372463
seconds. Authenticated metrics p95 was 0.461498 seconds. Every route passed
its status, payload, and latency checks. The benchmark exited with status 0.

The earlier 2026-10-07 schema-32 sweep measured ordinary route p95s from
0.006019 to 0.360999 seconds and authenticated metrics p95 at 0.404746 seconds.
It used the former metrics `<1s` gate and did not verify the current all-route
`<500ms` contract. Its measurements remain historical.

These results use representative request shapes on one isolated snapshot.
They do not measure every GID, response size, filesystem layout, or load
condition. The strict budgets apply to the listed local mode classes, not only
to the measured identifiers.

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
| `list --format json` read modes, including GID-filtered, default, and pending-feedback listings with representative `--max-count`, `--artist-sorting`, and `--order-by` options | Strict `<1s` for bounded query/read modes | Schema 32, 2,379 galleries: default cold/p95 `0.084s`/`0.090s`; bounded with `--max-count 50 --artist-sorting --order-by gid,desc`: `0.088s`/`0.087s`. |
| `gallery-status <gids...>` | Strict `<1s` | Schema 32: GID 695 cold/p95 `0.150s`/`0.177s`; 25 GIDs `0.153s`/`0.170s`. |
| `variants list` | Strict `<1s` | Schema 32: normal cold/p95 `0.696s`/`0.674s`; `--status pending` `0.384s`/`0.379s`. |
| `variants policy-show` and `variants policy-check <path>` | Strict `<1s` | Schema 32: policy-show cold/p95 `0.203s`/`0.291s`; policy-check of the active compact policy `0.238s`/`0.286s`. |
| `variants pending-reviews` | Strict `<1s` | Schema 32: cold `0.144s`; 20-warm p95 `0.192s`. |
| `help` | Strict `<1s` | Schema 32: cold `0.029s`, 20-warm p95 `0.073s`. |
| `metrics` | Strict `<1s` | Schema 32: cold `0.365s`, 20-warm p95 `0.405s`. |
| `feedback` CLI, including durable rated-feedback enqueue and ratingless timestamp update | No new CLI elapsed-time target | This is a mutation command. The strict feedback budgets in the HTTP registry remain in force for API requests; no corresponding CLI threshold is inferred here. |
| Other mutating, worker, filesystem-heavy, and provider-integration commands | No new elapsed-time target in this ADR | Includes `scan`, `archive`, `rate`, `hath`, `favorite`, `login`, `whoami`, `variants enqueue/work/evaluate/resolve/ungroup/policy-activate`, and `repair-tags`. Individual API budgets and exceptions above continue to apply to their HTTP callers. |

The existing CLI budget applies to local query/read-only modes, not every
command named in `bin/yomiko`. A future budget for mutations or provider waits
requires a separate decision and must state its input-size and dependency
assumptions.

### Regression measurement method

Measure the complete CLI command or HTTP response in an isolated
`yomiko-playground` with a consistent snapshot. Do not run benchmark mutations
against production or enable remote writes. For HTTP, use authenticated
loopback requests when the route requires a token. Keep normal CGI and response
checks in the timer. For CLI, time the public `bin/yomiko` command, not only its
SQL query.

Report the first request separately as cold. Collect at least 20 warm samples
and report nearest-rank p95. For 20 samples, p95 is the 19th sorted sample. A
strict gate passes only when p95 is below its limit. Record the parameters,
fixture size, status, response size, and instrumentation overhead. Before each
review PUT, confirm the review through the authenticated pending-review GET.
Use a fresh review for each successful sample. Use a separate snapshot for each
decision mode.

The current `tests/bench-api-latency.sh` measures every active local HTTP route
in the registry. It covers reads, metrics, feedback, review decisions, and
archive metadata without the archive body. It checks response status, shape,
and size. It creates 21 fresh candidate cards and 21 fresh winner cards. It
checks each review through the authenticated API before the PUT and restores
the fixture snapshot before each mutation sample. It excludes provider waits
and archive transfer. It continues after a budget breach and exits nonzero if
a strict gate fails.

A 2026-09-28 run on a 2,284-gallery snapshot used the former one-second gate.
Its ordinary route p95s ranged from `0.005s` to `0.218s`, except metrics at
`0.990s`. Candidate resolution exceeded that former gate. This run is
historical. The current 2026-10-07 schema-32 results and 500 ms gate appear
above.

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

An earlier 2026-10-07 sweep used a schema-31 snapshot with 2,379 galleries.
Startup applied migration 032. The runner inserted 21 distinct
candidate cards and 21 distinct winner cards. It checked every card through
the authenticated pending-review API before its PUT. It restored the same
fixture snapshot before each mutation sample and collected 20 warm samples for
each decision mode. Candidate `different_book`, `same_book`, and winner p95
were `0.247s`, `0.254s`, and `0.148s`. The previous candidate p95 values on a
2,379-gallery schema-31 snapshot were `1.270s` and `1.328s`. The full sweep
also measured health `0.007s`, userscript `0.023s`, metrics `0.354s`, one-GID
gallery status `0.170s`, pending feedback `0.136s`, pending variant reviews
`0.265s`, and local feedback p95 values from `0.124s` to `0.142s`. Each strict
local route was below the former one-second gate. The candidate responses
were 410 B and
404 B; winner responses were 391 B cold and 393 B warm. The benchmark measured
archive metadata at `0.087s` and 18 B, then exited with a status-contract
failure because BusyBox returned HTTP 200 for the no-archive response.

A run after the fix on 2026-10-07 used an isolated schema-31 snapshot with 2,379
galleries. BusyBox returned HTTP 404 and 18 B for the no-archive response; the
final-worktree 20-sample warm p95 was `0.090s`. The BusyBox loopback regression
also returned HTTP 400 for an invalid GID, 405 for an unsupported method, 500
for a CLI failure, and 200 for an available archive. The test checked response
bodies, CORS and security headers, the OPTIONS 204 response, and origin
rejection before the CLI call.

The 2026-10-07 full sweep also measured target-write scaling with 21 fresh
target cards per case. Each sample restored its saved database and checked the
target card through the pending-review API before the PUT. Each response was
HTTP 200 and 411 B. The table shows the number of confirmed GIDs in each target
class and the number of added pending reviews in a separate class.

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

The route and CLI mode mapping makes the budgets actionable. It preserves
route authentication, response shape, review visibility, and provider behavior.
Candidate identity conflicts and repair follow ADR-0001. The API also accepts
a historical winner GID when the CLI returns its normalized terminal. The
2,284-gallery candidate results exceeded the former one-second gate. The later
schema-32 sweep met the current 500 ms gate. Provider waits remain exempt. The
full-history review exception ended when that route was removed. Refresh the
measurements when the payload, schema, route, or workload changes.
