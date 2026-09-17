# Metrics deployment

Yomiko exposes a bearer-authenticated Prometheus endpoint at `GET /metrics`.
This guide connects it to the existing host observability services; it does not
install or manage those services for the operator.

## Host infrastructure assumed by this guide

The following services are deployment prerequisites, not components bundled
with Yomiko. The examples use this verified compatibility baseline:

| Service | Verified version | Assumption used here |
| --- | --- | --- |
| Docker Compose | 5.5.1 | Runs Yomiko and each observability service from separate Compose projects. |
| Caddy | 2.11.4 | Terminates private TLS and proxies `*.home.arpa` names to published host ports. |
| Grafana Alloy | 1.19.2 | Already collects host and Docker logs into Loki; it is not in the Yomiko metrics path below. |
| Prometheus | 3.14.0 | Owns scraping and durable PromQL storage. It resolves private host DNS and trusts a mounted private CA, represented below as `/etc/prometheus/certs/local-ca.pem`. |
| Grafana | 13.0.2 | Has the local Prometheus service, represented as `https://prometheus.home.arpa`, provisioned as its default data source. |

`home.arpa` is the local-network example domain throughout this guide. Replace
these names with the corresponding names from the deployment's private DNS and
TLS configuration. Likewise, replace the example private-CA path with the
read-only container path used by that Prometheus deployment.

The version numbers above, rather than mutable image tags such as `latest`, are
the compatibility baseline for this document. Revalidate the configuration
after changing those images. Older versions and an observability deployment
with different DNS, TLS, or data-source conventions are outside this guide.

The resulting data path is:

```text
Yomiko /metrics -> Caddy/private TLS -> Prometheus -> Grafana
Yomiko container logs -------------> Alloy -> Loki
```

Prometheus should be the only metrics scraper in this layout. Alloy remains an
assumed host service because it owns the existing log pipeline, but configuring
it to scrape the same endpoint would either duplicate samples or require a
separate Prometheus-compatible remote-write backend.

## Gallery status partition

The application exposes two current-count gauges for the database gallery
universe:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `yomiko_gallery_status` | `state` | Exactly one of `rated_variant_canonical`, `rated_variant_alternate`, `rated_variant_pending_selection`, `different_book`, `pending_rating`, `hath_requested`, or `unclassified` for each row in `galleries`. |
| `yomiko_galleries` | none | `SELECT COUNT(*) FROM galleries` from the same read snapshot; this is a gallery-row total, not a logical-book total. |

The status series are an exhaustive, mutually exclusive partition with fixed
precedence:
`rated_variant_canonical > rated_variant_alternate >
rated_variant_pending_selection > different_book > pending_rating >
hath_requested > unclassified`. The first three states use active confirmed
membership joined to the current active group's `canonical_gid`: canonical,
alternate when a canonical has been selected, and pending selection when it has
not. `different_book` uses only endpoints of current identity pairs whose
current review is resolved as `different_book`. `pending_rating` uses the
complete raw `yomiko list --pending-feedback` predicate after earlier states
are removed; it is therefore not the actionable queue count when a gallery also
matches an earlier state. `hath_requested` requires an empty `file_path` and a
latest `hath_last_attempted_at` or `hath_requested_at` watermark newer than
`rated_then_deleted_at`. It means that acquisition is awaiting its result, not
that a client is transferring at this moment. An empty path without that
watermark is `unclassified`. No GID, path, review ID, or group ID is exported.

The partition invariant is:

```promql
sum without (state) (yomiko_gallery_status) - yomiko_galleries
```

This must be zero for each matching external-label set. Apply the same
instance/job selector to both sides when more than one Yomiko database is
present; do not combine status from multiple instances with one total.

For a current-count Grafana panel, use an instant query with no `rate()`,
`increase()`, time-range sum, or stacking:

```promql
sum by (state) (yomiko_gallery_status{job="yomiko"})
```

Use a horizontal bar gauge or one-row-per-state table, unit `short`, decimals
`0`, minimum `0`, and preserve the query's precedence order so zero-valued
states remain visible. Title the panel `Gallery status — exclusive
precedence` and use this description:

> Exhaustive partition of gallery rows. Precedence: rated_variant_canonical > rated_variant_alternate > rated_variant_pending_selection > different_book > pending_rating > hath_requested > unclassified. Bars are mutually exclusive and sum to yomiko_galleries; the total is not a logical-book count.

If desired, show `yomiko_galleries{job="yomiko"}` in a neighboring `Gallery
rows` stat. It is the total row count, not a sixth partition category. Keep
the database partition separate from the userscript `gallery-status` UI
states, which may have a null state and are not exhaustive.

The 2026-09-17 production snapshot baseline is 1,950 gallery rows:

| State | Expected count |
| --- | ---: |
| `rated_variant_canonical` | 212 |
| `rated_variant_alternate` | 332 |
| `rated_variant_pending_selection` | 48 |
| `different_book` | 560 |
| `pending_rating` | 697 |
| `hath_requested` | 101 |
| `unclassified` | 0 |
| `yomiko_galleries` | 1,950 |

These values are a rollout snapshot, not a long-term test fixture. Recalculate
and record ordinary data changes from a consistent database snapshot while
requiring the invariant and status definitions to remain unchanged.

## Actionable variant review queue

Yomiko exports the current manual-review work in one fixed, two-series gauge:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `yomiko_variant_actionable_reviews` | `review_type` | Current cards in the pending web variant-review queue. |

The only `review_type` values are `candidate_identity` and `winner`:

```text
# HELP yomiko_variant_actionable_reviews Current reviews actionable in the web queue by review type.
# TYPE yomiko_variant_actionable_reviews gauge
yomiko_variant_actionable_reviews{review_type="candidate_identity"} 0
yomiko_variant_actionable_reviews{review_type="winner"} 0
```

`candidate_identity` is one visible representative per unknown unordered pair
of active same-book classes. Same-class pairs, current resolved
`different_book` pairs, replaced source/candidate galleries, and duplicate raw
pending rows are excluded; visible rows take precedence over inactive owners,
then the lowest review ID is selected. A later merge or ungroup can change the
classes and reopen a formerly materialized review. `winner` counts visible
pending, non-superseded canonical-selection reviews. A winner is hidden when
its source or any choice is replaced. The migration-023 read-only views are
the authority for this projection; see [ADR-0001](./adr/0001-class-lifted-identity-review-projection.md)
for its full identity-class design.

These are actionable queue cards, not audit-row counts. The former raw review
lifecycle family and `yomiko_variant_oldest_pending_review_age_seconds` are no
longer exported: raw pending rows can be duplicate, implied, hidden, or
superseded projection inputs and must not be presented as current work. A
review row's `created_at` is durable evidence age, not the timestamp at which
the current actionable episode began, so it cannot provide a reliable queue
waiting-time contract. If Yomiko later exposes review age or an SLO, it must
first persist an authoritative false-to-true actionable transition for each
queue episode. The metrics command reads the persistent views in its existing
single SQLite read transaction and never invokes `yomiko variants reviews`; the
web command may reconcile and materialize durable visibility as part of
listing.

For output from the same database state, the parity invariant is:

```text
metric(candidate_identity) == count(web reviews with review_type=candidate_identity)
metric(winner) == count(web reviews with review_type=winner)
metric(candidate_identity) + metric(winner) == web actionable_count
```

Use an instant/current-value query for a dashboard panel:

```promql
sum by (review_type) (
  yomiko_variant_actionable_reviews{job="yomiko"}
)
```

Use a horizontal bar gauge or a two-row table with unit `short`, zero
decimals, minimum `0`, and both zero-valued series visible in this order:
`Identity decision (same / different)`, then `Canonical selection`. The
provisioned panel is titled `Variant reviews — actionable queue` and describes
the deliberate exclusion of raw pending audit rows. This is current manual
work, not throughput, so do not apply `rate()`, `increase()`, range sums,
stacking, or an alert. A nonzero review queue is an operator decision, not a
service incident.

On the consistent 2026-09-15 rollout snapshot, raw pending rows were 50
`candidate_identity` and 47 `winner`; the actionable metric and pending web
queue were 9 and 0 respectively. These numbers are an observation only, not a
CI fixture or a health threshold.

## Retained variant review outcomes

Yomiko separately exports the terminal outcomes of retained review rows. This
is a gauge because retention, ungroup/reopen behavior, and later projection
changes can remove rows or move a row between resolution series; it is not a
monotonic event counter.

| Metric | Labels | Meaning |
| --- | --- | --- |
| `yomiko_variant_review_outcome_audit_records` | `review_type`, `resolution` | Durable review rows whose shared product-lifecycle projection has a terminal outcome. |

The family always emits exactly these five bounded series, including zeros:

```text
# HELP yomiko_variant_review_outcome_audit_records Retained variant review audit records by review type and projected terminal resolution.
# TYPE yomiko_variant_review_outcome_audit_records gauge
yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="same_book"} 0
yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="different_book"} 0
yomiko_variant_review_outcome_audit_records{review_type="candidate_identity",resolution="superseded"} 0
yomiko_variant_review_outcome_audit_records{review_type="winner",resolution="winner"} 0
yomiko_variant_review_outcome_audit_records{review_type="winner",resolution="superseded"} 0
```

The lifecycle and audit contract is defined by
[ADR-0003](./adr/0003-review-queue-and-audit-metrics.md).
`variant_review_product_lifecycle` is the read-only authority shared by CLI
JSON presentation and this metric. A non-null `superseded_at` always projects
to `status=resolved` and `resolution=superseded`, even if the raw row retains
a resolved decision. Otherwise, resolved candidate rows project their
`same_book` or `different_book` decision and resolved winner rows project
`winner`. Non-superseded pending rows have no terminal outcome and are not
counted.

This is retained audit-row inventory, not the current queue, current identity
relation, review throughput, or a cumulative counter. It intentionally does
not apply gallery visibility, active-group filtering, class lifting, current
class-pair deduplication, or `gallery_identity_pairs.current_review_id`
deduplication. Its total therefore equals the number of rows in the lifecycle
view with `projected_status='resolved'` and a non-null `resolution`, while it
must not be added to the actionable queue.

For a historical inventory panel, use an instant, non-stacked bar gauge or
table:

```promql
sum by (review_type, resolution) (
  yomiko_variant_review_outcome_audit_records{job="yomiko"}
)
```

Do not apply `rate()`, `increase()`, or range sums, and do not use this
inventory as a throughput alert. If a dashboard covers more than one Yomiko
database, preserve the existing instance selector or group by instance before
interpreting totals. The provisioned panel is titled
`Variant review outcomes — retained audit records` and explicitly describes
the inventory boundary above.

## Runtime freshness health

Runtime freshness measures successful completion, not starts, failures, queue
activity, or individual variant-job outcomes. Yomiko exports one fixed,
low-cardinality gauge for each supported component:

| Component | Nominal cadence | Stale after |
| --- | ---: | ---: |
| `scheduler_tick` | 60s | 180s |
| `variant_worker` | 60s | 240s |
| `scan` | 300s | 900s |

```text
# HELP yomiko_runtime_success_stale_after_seconds Maximum supported age of the latest successful component run before it is stale.
# TYPE yomiko_runtime_success_stale_after_seconds gauge
yomiko_runtime_success_stale_after_seconds{component="scheduler_tick"} 180
yomiko_runtime_success_stale_after_seconds{component="variant_worker"} 240
yomiko_runtime_success_stale_after_seconds{component="scan"} 900
```

These values are scheduling policy and are exported from the same fixed
component definition as the runtime state series. They are not stored in
`runtime_component_state`. A schedule change must update the scheduler,
startup log, exported value, tests, architecture text, dashboard description,
and alert expectations together.

The dashboard's primary health query is freshness debt: zero means healthy and
a positive value is the number of seconds overdue. Keep all calculations in
seconds and do not add `or vector(0)`:

```promql
(
  clamp_min(
    time() - yomiko_runtime_last_success_timestamp_seconds{job="yomiko"}
    - on (job, instance, component)
      yomiko_runtime_success_stale_after_seconds{job="yomiko"},
    0
  )
)
and on (job, instance, component)
  (yomiko_runtime_last_success_timestamp_seconds{job="yomiko"} > 0)
```

The timestamp filter keeps a component with no prior success out of the
decades-wide Unix-epoch calculation. Show that state separately in red with:

```promql
yomiko_runtime_last_success_timestamp_seconds{job="yomiko"} == 0
```

Render matches from the companion query as `Never succeeded`. A fresh success
resets debt on the next scrape. A future last-success timestamp is clamped to
zero, and a failure or start does not refresh freshness. If the exporter is
down or absent, the runtime query is intentionally no data; the `Yomiko
target` stat and availability alerts own that incident.

Use this runbook mapping when a component has positive debt:

| Component | Meaning | First checks |
| --- | --- | --- |
| `scheduler_tick` | No successful minute tick within 180 seconds. | Container/process status and scheduler logs, then supervision and runtime database-write errors. |
| `variant_worker` | No complete `variants work --max-jobs 5` invocation within 240 seconds. | Latest exit code and failure counter, variant log, then `yomiko variants jobs` queue detail. |
| `scan` | No complete scan/archive pass within 900 seconds. | Scan logs, scan-lock contention, H@H input, archive/network failures, and last-started versus last-duration. |

### Raw age diagnostic

Raw age is useful after freshness debt identifies an incident, but it is not a
universal health threshold and must not be stacked:

```promql
clamp_min(
  time() - yomiko_runtime_last_success_timestamp_seconds{job="yomiko"},
  0
)
and on (job, instance, component)
  (yomiko_runtime_last_success_timestamp_seconds{job="yomiko"} > 0)
```

## Runtime invocations versus variant-job outcomes

These are two independent observability layers. The `variant_worker` runtime
family records one result for each complete `yomiko variants work --max-jobs 5`
invocation, derived only from its final exit status. Scheduling, lease
recovery, claiming, handler dispatch, durable state transitions, output
validation, and budget accounting are part of that invocation. A correctly
persisted retryable, permanent, or configuration job result returns zero and
therefore increments runtime success; a database/orchestration/handler failure
that prevents the command from completing increments runtime failure. Empty
queues and lock-busy API invocations are successful no-ops.

Do not add runtime invocations to job events. One invocation can process up to
five jobs, one job can continue or retry across several invocations, and
cancellation can be caused by feedback, review, ungrouping, or startup policy
reconciliation outside the worker.

`yomiko_variant_jobs{job_type,status}` remains a scrape-time snapshot. The
`queued` and `leased` values describe current work; `completed`, `failed`, and
`cancelled` are retained terminal history and are gauges. They must not be
used with `rate()` or `increase()`, and a retained failed row alone is not an
always-firing incident. `yomiko_variant_job_errors` adds the bounded `status`
label so a queued retry/backoff row and a retained failed row remain distinct:

```text
yomiko_variant_job_errors{job_type="evaluate",status="queued",error_class="transient"} 1
yomiko_variant_job_errors{job_type="evaluate",status="failed",error_class="configuration"} 1
```

Migration 024 adds the persistent, fixed-cardinality counter
`yomiko_variant_job_outcomes_total{job_type,outcome}`. It begins at zero when
the migration is applied; historical rows are not backfilled. Its six bounded
outcomes are:

| Outcome | Durable transition | Meaning |
| --- | --- | --- |
| `completed` | `leased -> completed` | Successful terminal work. |
| `continued` | `leased -> queued` with no error class | Normal bounded continuation. |
| `retryable_error` | `leased -> queued` with `transient` or `uncertain` | Durable retry or lease recovery. |
| `permanent_error` | `leased -> failed` with `permanent` | Terminal persisted-input/state failure. |
| `configuration_error` | `leased -> failed` with `configuration` | Terminal policy/configuration/dependency failure. |
| `cancelled` | `queued` or `leased -> cancelled` | Work became inapplicable. |

Claims, same-status updates, dry runs, action outcomes inside a reconciliation
job, and handler crashes that leave a row leased are not job outcomes. The
counter update is an `AFTER UPDATE` trigger in the same SQLite transaction as
the lifecycle change, so rollback removes both state and event. The counter
table contains no job IDs, group IDs, owners, messages, or other unbounded
labels.

Use current gauges for current state and the counter for event rates:

```promql
sum by (job_type, status) (
  yomiko_variant_jobs{job="yomiko",status=~"queued|leased"}
)
sum by (job_type, status, error_class) (
  yomiko_variant_job_errors{job="yomiko"}
)
sum by (job_type, outcome) (
  increase(yomiko_variant_job_outcomes_total{job="yomiko"}[1h])
)
sum by (component) (
  increase(yomiko_runtime_runs_total{job="yomiko",result="failure"}[1h])
)
```

The first query is active queue/lease state, the second is persisted error
state, the third is recent lifecycle activity, and the fourth is complete
invocation failure. Keep them in separate panels and alerts. Action-level
failures remain owned by `yomiko_variant_actions` and its age/attempt metrics.
Use `yomiko variants jobs` for exact row identity and sanitized diagnostic
details; no metric label carries an ID, path, owner, or raw error.

## 1. Configure Yomiko's metrics secret

The deployed Yomiko image must contain the `/metrics` endpoint before applying
these production steps. Until that image is published, use the
[playground procedure](#test-an-unreleased-worktree-with-a-playground).

Create a dedicated token without printing it. Do not reuse
`YOMIKO_API_TOKEN`, put the token in a URL, or commit it:

```bash
cd "$HOME/docker/yomiko"
umask 077
openssl rand -hex 32 > data/metrics-token
yomiko_uid="$(docker compose exec -T yomiko id -u)"
prometheus_gid="$(
  docker compose -f "$HOME/docker/prometheus/compose.yaml" \
    exec -T prometheus id -g
)"
sudo chown "${yomiko_uid}:${prometheus_gid}" data/metrics-token
chmod 0640 data/metrics-token
```

The ownership lookup uses the service identities from the deployed images
instead of assuming host-specific UID/GID values. Mode `0640` lets Yomiko read
as the file owner and Prometheus read through its primary group without making
the secret world-readable. Recheck ownership after either image changes; do
not work around an ownership error with mode `0644`.

Add the secret to `$HOME/docker/yomiko/compose.yaml`:

```yaml
services:
  yomiko:
    environment:
      YOMIKO_METRICS_TOKEN_FILE: /run/secrets/yomiko_metrics_token
    secrets:
      - yomiko_metrics_token

secrets:
  yomiko_metrics_token:
    file: ./data/metrics-token
```

Validate and recreate Yomiko:

```bash
cd "$HOME/docker/yomiko"
docker compose config --quiet
docker compose up -d
docker compose exec -T yomiko test -r /run/secrets/yomiko_metrics_token
```

With the token absent or unreadable, `/metrics` deliberately returns `503`.
With a missing or incorrect bearer credential, it returns `401` without a
metrics payload.

## 2. Add the Prometheus scrape

Mount the same token in `$HOME/docker/prometheus/compose.yaml`:

```yaml
services:
  prometheus:
    secrets:
      - yomiko_metrics_token
    volumes:
      - "${LOCAL_CA_FILE:?Set LOCAL_CA_FILE}:/etc/prometheus/certs/local-ca.pem:ro"

secrets:
  yomiko_metrics_token:
    file: ../yomiko/data/metrics-token
```

Add one job under `scrape_configs` in
`$HOME/docker/prometheus/prometheus.yml`:

```yaml
  - job_name: "yomiko"
    scrape_interval: 30s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: https
    authorization:
      type: Bearer
      credentials_file: /run/secrets/yomiko_metrics_token
    tls_config:
      ca_file: /etc/prometheus/certs/local-ca.pem
    body_size_limit: 1MB
    sample_limit: 500
    static_configs:
      - targets: ["yomiko.home.arpa"]
```

The private DNS entry resolves to the deployment host, Caddy proxies
`yomiko.home.arpa` to the Yomiko host port, and the existing CA mount validates
that private certificate.

Validate the complete configuration before recreating Prometheus:

```bash
cd "$HOME/docker/prometheus"
docker compose config --quiet
docker compose run --rm --no-deps --entrypoint promtool prometheus \
  check config /etc/prometheus/prometheus.yml
docker compose up -d
docker compose exec -T prometheus \
  test -r /run/secrets/yomiko_metrics_token
```

A later `prometheus.yml`-only change can use the lifecycle reload endpoint,
when enabled, instead of recreating the container:

```bash
curl --fail --silent --show-error --request POST \
  https://prometheus.home.arpa/-/reload
```

## 3. Verify Prometheus and Grafana

Query Prometheus without sending the Yomiko token from the shell:

```bash
curl --fail --silent --show-error --get \
  --data-urlencode 'query=up{job="yomiko"}' \
  https://prometheus.home.arpa/api/v1/query
```

The sample value must become `1`. If it remains `0`, inspect the Prometheus
target error first; the usual causes are an unreadable secret, a private DNS or
CA mismatch, a Caddy route pointing at the wrong host port, or an older Yomiko
image that returns `404`.

Grafana needs no additional data source: the assumed host already provisions
Prometheus as the default. Start in Explore with:

```promql
up{job="yomiko"}
yomiko_build_info
yomiko_database_schema_version
sum by (job_type, status) (yomiko_variant_jobs)
sum by (job_type, status, error_class) (yomiko_variant_job_errors)
sum by (job_type, outcome) (increase(yomiko_variant_job_outcomes_total[1h]))
sum by (action_type, status, error_class) (yomiko_variant_actions)
(
  clamp_min(
    time() - yomiko_runtime_last_success_timestamp_seconds{job="yomiko"}
    - on (job, instance, component)
      yomiko_runtime_success_stale_after_seconds{job="yomiko"},
    0
  )
)
and on (job, instance, component)
  (yomiko_runtime_last_success_timestamp_seconds{job="yomiko"} > 0)
yomiko_runtime_last_success_timestamp_seconds{job="yomiko"} == 0
max by (job_type) (yomiko_variant_oldest_runnable_job_age_seconds)
sum by (invariant) (yomiko_variant_invariant_violations)
```

Useful initial alerts are:

| Condition | Expression | Hold |
| --- | --- | --- |
| Target absent | `absent(up{job="yomiko"})` | 5m |
| Scrape failing | `up{job="yomiko"} == 0` | 3m |
| Runtime overdue | Freshness-debt query above, filtered to `> 0` and gated by `up{job="yomiko"} == 1` | 2m |
| Scheduler never succeeded | `yomiko_runtime_last_success_timestamp_seconds{job="yomiko",component="scheduler_tick"} == 0` and `up{job="yomiko"} == 1` | 3m |
| Worker never succeeded | `yomiko_runtime_last_success_timestamp_seconds{job="yomiko",component="variant_worker"} == 0` and `up{job="yomiko"} == 1` | 4m |
| Scan never succeeded | `yomiko_runtime_last_success_timestamp_seconds{job="yomiko",component="scan"} == 0` and `up{job="yomiko"} == 1` | 15m |
| Runtime invocation failure burst | `sum by (component) (increase(yomiko_runtime_runs_total{job="yomiko",component="variant_worker",result="failure"}[15m])) >= 3` | 1m |
| New terminal/configuration job outcome | `sum by (job_type, outcome) (increase(yomiko_variant_job_outcomes_total{job="yomiko",outcome=~"permanent_error|configuration_error"}[15m])) > 0` | 1m |
| Retry storm | `sum by (job_type) (increase(yomiko_variant_job_outcomes_total{job="yomiko",outcome="retryable_error"}[15m])) >= 3` | 2m |
| Runnable job stuck | `max(yomiko_variant_oldest_runnable_job_age_seconds) > 3600` | 10m |
| Runnable action stuck | `max(yomiko_variant_oldest_runnable_action_age_seconds) > 3600` | 10m |
| Lease expired | `sum(yomiko_variant_expired_leases) > 0` | 2m |
| Invariant violated | `sum(yomiko_variant_invariant_violations) > 0` | 1m |

Keep no-data as OK for runtime debt and never-successful rules; the explicit
`up == 0` and `absent(up{job="yomiko"})` availability rules own exporter
incidents. Observe a normal baseline before tuning queue-age or attempt
thresholds.

## Test an unreleased worktree with a playground

The repository playground builds the current worktree instead of pulling the
published image. It takes an online SQLite backup, copies no production metrics
or API token, denies remote writes, binds the web server to loopback, and does
not run Yomiko's scheduler.

Only one playground may run at a time. Stop an older one with its own
`./playground down`, then create the new one from the repository root:

```bash
.agents/skills/yomiko-playground/scripts/create_playground.sh --start
```

The command prints a private directory such as
`/tmp/yomiko-playground.ABC123`. It generates an isolated token at
`data/metrics-token`, sets `YOMIKO_METRICS_TOKEN_FILE` inside the playground,
and publishes `127.0.0.1:62080`. It leaves
`YOMIKO_NETWORK_PEER_CONTAINER` empty, so ordinary `./playground up` and
tests stay isolated from production Prometheus. That loopback binding is
intentional: Caddy runs in a container and therefore cannot reach the
playground through the host's Docker bridge address. Keep the loopback binding
and use the private network instead of broadening the published address.

If a test genuinely needs access to production Prometheus, obtain explicit
user approval first. Use a command-scoped peer override on both lifecycle
commands; do not persist it in `.yomiko-playground.env`:

```bash
YOMIKO_NETWORK_PEER_CONTAINER=prometheus ./playground up
YOMIKO_NETWORK_PEER_CONTAINER=prometheus ./playground down
```

When the user explicitly wants to see the local worktree result in Grafana,
use the repository skill helper to configure and verify the temporary scrape,
token copy, and network attachment instead of editing deployment files by hand:

```bash
bash .agents/skills/yomiko-playground/scripts/playground-metrics.sh \
  enable PLAYGROUND_DIR
```

Inspect the existing Grafana dashboard by UID
`yomiko-playground-overview`. The helper's `disable` action restores the
Prometheus configuration and disconnects/stops the playground; use
`disable PLAYGROUND_DIR --keep-playground` when observation should continue.
Because the playground intentionally does not run the scheduler, this proves
the metrics path and dashboard queries but does not prove production heartbeat
behavior. Remove the temporary setup when observation is finished, and delete
the production-derived playground directory only as a deliberate cleanup.
