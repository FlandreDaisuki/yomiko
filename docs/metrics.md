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

## Current metrics inventory and cleanup decisions

This worktree's exporter has 34 metric families. These groups describe their
purpose and intended consumers.

| Purpose | Metric families | Consumer or operator decision |
| --- | --- | --- |
| Deployment and storage | `yomiko_build_info`, `yomiko_database_schema_version`, `yomiko_database_file_size_bytes` | Version, migration, and local SQLite storage diagnostics. |
| Runtime health | `yomiko_runtime_runs_total`, `yomiko_runtime_last_started_timestamp_seconds`, `yomiko_runtime_last_success_timestamp_seconds`, `yomiko_runtime_success_stale_after_seconds`, `yomiko_runtime_last_failure_timestamp_seconds`, `yomiko_runtime_last_duration_seconds`, `yomiko_runtime_last_exit_code` | Freshness/failure alerts and operator diagnosis. |
| Variant jobs | `yomiko_variant_jobs`, `yomiko_variant_job_errors`, `yomiko_variant_unresolved_job_failures`, `yomiko_variant_job_outcomes_total`, `yomiko_variant_runnable_jobs`, `yomiko_variant_job_max_attempts`, `yomiko_variant_high_attempt_jobs`, `yomiko_variant_jobs_created_recent` | Queue, retry, unresolved failure, and outcome panels/alerts; inspect row detail with `yomiko variants list --gid GID`. |
| Variant actions and leases | `yomiko_variant_actions`, `yomiko_variant_unresolved_action_failures`, `yomiko_variant_runnable_actions`, `yomiko_variant_action_max_attempts`, `yomiko_variant_high_attempt_actions`, `yomiko_variant_expired_leases` | Current unresolved failures, action queue, and retry panels/alerts; inspect durable work with `yomiko variants list --gid GID`. |
| Discovery | `yomiko_variant_discovery_errors`, `yomiko_variant_discovery_due_groups`, `yomiko_uploader_revision_publication_blocked` | Errors, due work, and publication blockers; publication blockers keep their bounded reason labels for a separate operator diagnostic. |
| Reviews, groups, and gallery state | `yomiko_variant_actionable_reviews`, `yomiko_variant_groups`, `yomiko_variant_invariant_violations`, `yomiko_gallery_data_quality_records`, `yomiko_gallery_status`, `yomiko_raw_galleries_rows`, `yomiko_galleries` | Current pending-review queue, current identity-group total, classification/invariant checks, raw row inventory, and the user-visible gallery count. |

`yomiko_variant_discovery_candidates` was removed. It counted staged rows
without their parent run status, so retained rows from a cancelled run could
look like current work. The current provisioned overview has no query for this
family, and no alert or current operator guide depends on it; job/run metrics
remain the pipeline health signals. Candidate rows remain in SQLite for
resumption and diagnosis. `yomiko_uploader_revision_publication_blocked`
stays because it identifies bounded validation reasons that job/run status
does not distinguish.

`yomiko_variant_discovery_runs` was removed. It counted retained run rows by
phase and status, including completed history, so its sum was not a count of
current revision-terminal galleries. Inspect `variant_discovery_runs` through
SQL when debugging a run. `yomiko_variant_discovery_errors` remains:
retryable discovery errors do not appear in
`yomiko_variant_unresolved_job_failures`, which only counts applicable tasks
whose latest terminal job failed.

`yomiko_variant_groups` now has no labels and counts only
`variant_groups.identity_active=1`. The `activity` and `review_state` breakdown
included persistence history and a cached review projection; neither defines a
current identity group type.

Review metrics follow the pending-only contract in
[ADR-0010](./adr/0010-pending-only-variant-review-surface.md). The gallery
universe is all current revision terminals, including incomplete and blocked
terminals; raw rows have a separate inventory gauge. The exporter computes this
from its read snapshot without an API payload cache.

## Gallery status partition

The application exposes three current-count gauges for galleries:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `yomiko_gallery_status` | `state` | Exactly one of `rated_11_variant_canonical`, `rated_11_variant_alternate`, `canonical_selection_unresolved`, `rated_under_11_variant_grouped_galleries`, `candidate_identity_review_pending`, `different_book`, `pending_rating`, `hath_requested`, or `unclassified` for each current revision terminal. |
| `yomiko_raw_galleries_rows` | none | `SELECT COUNT(*) FROM galleries`, including revision predecessors; for inventory and debugging. |
| `yomiko_galleries` | none | One selected current terminal per revision component, including incomplete or blocked terminals; the user-visible gallery count. |

The status series are an exhaustive, mutually exclusive partition with fixed
precedence:
`rated_11_variant_canonical > rated_11_variant_alternate >
canonical_selection_unresolved > rated_under_11_variant_grouped_galleries >
candidate_identity_review_pending > different_book > pending_rating >
hath_requested > unclassified`. The first three states use confirmed
membership in an active rating-11 group joined to its `canonical_gid`:
canonical, alternate when a canonical has been selected, and unresolved
canonical selection when it has not. Unresolved selection does not necessarily
have a pending canonical selection review; use
`yomiko_variant_actionable_reviews{review_type="winner"}` for that queue.
`rated_under_11_variant_grouped_galleries`
counts confirmed members of an identity-active group without current rating-11
winner intent, including ratings 1–10. Their same-book identity remains current
for discovery, review, and userscript matching. `candidate_identity_review_pending`
counts current revision-terminal identity candidate GIDs with a visible,
actionable candidate identity review. Those candidates are not yet confirmed members and
do not inherit the source group's rating or winner role. `different_book` uses
only endpoints of current identity pairs whose
current review is resolved as `different_book`. `pending_rating` applies the
raw `yomiko list --pending-feedback` predicate to current terminals after
earlier states are removed; it is therefore not the actionable queue count when
a gallery also matches an earlier state. `hath_requested` requires an empty `file_path` and a
latest `hath_last_attempted_at` or `hath_requested_at` watermark newer than
`rated_then_deleted_at`. It means that acquisition is awaiting its result, not
that a client is transferring at this moment. An empty path without that
watermark is `unclassified`. A revision component without an identifiable
terminal contributes only to the raw-row gauge. No GID, path, review ID, or
group ID is exported.

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

> Exhaustive partition of current revision-terminal galleries. Canonical roles and unresolved selection apply only to active rating-11 groups; confirmed same-book members without current selection intent are rated_under_11_variant_grouped_galleries; current actionable identity candidates are candidate_identity_review_pending. Unresolved selection need not have a pending review. Precedence: rated_11_variant_canonical > rated_11_variant_alternate > canonical_selection_unresolved > rated_under_11_variant_grouped_galleries > candidate_identity_review_pending > different_book > pending_rating > hath_requested > unclassified. Bars are mutually exclusive and sum to yomiko_galleries.

Show `yomiko_galleries{job="yomiko"}` in a neighboring `Galleries` stat. Use
`yomiko_raw_galleries_rows` only for inventory or debugging; it does not join
the status partition. Keep the database partition separate from the userscript
`gallery-status` UI states, which may have a null state and are not exhaustive.

## Review queue metrics

`yomiko_variant_actionable_reviews{review_type}` reports the current card count
from the same pending-review projection used by the read-only CLI/API. It emits
exactly two series, `candidate_identity` and `winner`, including zero values.
Candidate rows are counted only when they are visible, not implied by an
existing identity relation, and are the representative for their class pair;
winner rows must be pending, unsuperseded, visible, and owned by a current
rating-11 identity group. The renderer reuses the request-local materialized
revision snapshot and review identity projection instead of the recursive global
`variant_identity_actionable_review` view. The `actionable_count` returned by
`yomiko variants pending-reviews` and the pending-review API equals the sum of
the two series.

The `review_state_mismatch` member of
`yomiko_variant_invariant_violations` remains unexposed. Restoring the current
queue count does not restore the retired review-outcome inventory or cached
review-state invariant. Public review reads expose only actionable pending
cards.

## Retired review outcome inventory

The retained review outcome inventory is no longer exported. During rollout,
remove the provisioned Grafana panel `Variant review outcomes — retained audit
records` (panel ID `222`) and any external recording rules, alerts, or dashboard
queries that depend on the retired outcome inventory. Prometheus samples already
stored for that inventory are not rewritten; they expire under the configured
retention policy. Historical dashboard backups remain archival only.

The internal `variant_review_product_lifecycle` view and durable review rows
remain available to reconciliation and database maintenance; their retention
does not imply a public audit-inventory metric. Public review reads expose only
actionable pending cards, whose current counts are exported by
`yomiko_variant_actionable_reviews`.

## Uploader-revision publication blocks

Yomiko exports one fixed gauge for discovery publication that is blocked by an
incomplete or malformed provider revision component:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `yomiko_uploader_revision_publication_blocked` | `reason` | Current running or retryable discovery components that cannot publish a complete scoreable revision terminal projection. |

The family always emits exactly these eight `reason` values, including zeroes:

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

An example exposition is:

```text
# HELP yomiko_uploader_revision_publication_blocked Current discovery components blocked by provider uploader-revision validation.
# TYPE yomiko_uploader_revision_publication_blocked gauge
yomiko_uploader_revision_publication_blocked{reason="reference_incomplete"} 0
yomiko_uploader_revision_publication_blocked{reason="scope_incomplete"} 0
yomiko_uploader_revision_publication_blocked{reason="scoring_input_incomplete"} 0
yomiko_uploader_revision_publication_blocked{reason="token_mismatch"} 0
yomiko_uploader_revision_publication_blocked{reason="relation_conflict"} 0
yomiko_uploader_revision_publication_blocked{reason="cycle"} 0
yomiko_uploader_revision_publication_blocked{reason="branch"} 0
yomiko_uploader_revision_publication_blocked{reason="multiple_terminals"} 0
```

Metric labels are intentionally limited to the fixed reason vocabulary. They
never contain GIDs, tokens, paths, titles, run IDs, or diagnostic text. A
nonzero value means the last completed current/effective-archive projection is
still authoritative; publication does not expose a partial metadata snapshot.
Use the database diagnostic rows to identify the affected work:

```sql
SELECT id AS discovery_run_id, group_id, job_id, phase, status,
       blocked_reason, blocked_component_count, last_error_class, last_error,
       updated_at
  FROM variant_discovery_runs
 WHERE status IN ('running', 'retryable')
   AND blocked_reason IS NOT NULL
 ORDER BY updated_at ASC, id ASC;
```

This query is an operator diagnostic and is not an API or Prometheus label
contract. Correct the provider refresh/readiness problem or wait for bounded
retry; do not manually promote a predecessor or copy its exact-GID archive,
H@H watermark, or cleanup timestamps onto the new terminal.

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

For runtime-health alerts, use freshness debt: zero means healthy and
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

Treat matches from the companion query as `Never succeeded`. A fresh success
resets debt on the next scrape. A future last-success timestamp is clamped to
zero, and a failure or start does not refresh freshness. If the exporter is
down or absent, the runtime query is intentionally no data; the `Yomiko
target` stat and availability alerts own that incident.

Use this runbook mapping when a component has positive debt:

| Component | Meaning | First checks |
| --- | --- | --- |
| `scheduler_tick` | No successful minute tick within 180 seconds. | Container/process status and scheduler logs, then supervision and runtime database-write errors. |
| `variant_worker` | No complete `variants work --max-jobs 5` invocation within 240 seconds. | Latest exit code and failure counter, variant log, then `yomiko variants list --gid GID` for the affected group. |
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

`yomiko_variant_unresolved_job_failures{job_type,error_class}` is the current
terminal-failure gauge. For each `(job_type, group_id)` task (or the singleton
policy sweep), it considers the latest **terminal** job by ID. A failed result
counts once while its group remains applicable; a newer queued/leased job does
not clear it, but a newer completed or cancelled job does. Discovery requires
an identity-active group; evaluation and retention reconciliation additionally
require an operationally active group with desired rating 11. Action
reconciliation requires an operationally active group, and a policy sweep must
target the active policy.
The fixed `error_class` set includes `unknown` for legacy failed rows without
a class. All job-type/class combinations emit zero when absent. This gauge
does not infer that a different job type resolved the same underlying problem;
use the job CLI to inspect that case.

`yomiko_variant_unresolved_action_failures{action_type,error_class}` counts the
latest action for each `(action_type, gid)` in an identity-active group when its
last recorded attempt failed. Retryable, configuration, and permanent errors
remain counted while that action is pending or in flight for a retry because
the durable result retains the last outcome. A later success, supersession, or
newer action row without a failed last attempt for the same task clears it.
Superseded groups and
older failed action rows do not count. The five action types and five bounded
error classes always emit zero-valued series; no GID is exposed.

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
sum by (job_type) (
  yomiko_variant_jobs{job="yomiko",status="queued"}
)
sum by (job_type) (
  yomiko_variant_jobs{job="yomiko",status="leased"}
)
sum by (job_type, status, error_class) (
  yomiko_variant_job_errors{job="yomiko"}
)
sum by (job_type, error_class) (
  yomiko_variant_unresolved_job_failures{job="yomiko"}
)
sum by (action_type, error_class) (
  yomiko_variant_unresolved_action_failures{job="yomiko"}
)
sum by (job_type, outcome) (
  increase(yomiko_variant_job_outcomes_total{job="yomiko"}[1h])
)
sum by (component) (
  increase(yomiko_runtime_runs_total{job="yomiko",result="failure"}[1h])
)
```

The first two queries separately show queued and leased jobs. Queued includes
future retry/backoff work; leased means a worker has claimed the job. The
third query is persisted job error state; the fourth and fifth are current
unresolved job and action failures. The sixth is recent lifecycle activity,
and the seventh is complete invocation failure. The persisted job error-state
query is for ad hoc diagnosis; the dashboard shows current unresolved failures
instead of retained error history.

The `yomiko_variant_runnable_jobs` gauge remains in the overview's `Runnable
jobs` stat to count queued work whose availability time is due.
Use `yomiko variants list --gid GID` for job and action row details; its raw
error text is operator data. No metric label carries an ID, path, owner, or raw
error.

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
sum by (job_type, error_class) (yomiko_variant_unresolved_job_failures)
sum by (job_type, outcome) (increase(yomiko_variant_job_outcomes_total[1h]))
sum by (action_type, status, error_class) (yomiko_variant_actions)
sum by (action_type, error_class) (yomiko_variant_unresolved_action_failures)
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
| Lease expired | `sum(yomiko_variant_expired_leases) > 0` | 2m |
| Invariant violated | `sum(yomiko_variant_invariant_violations) > 0` | 1m |

Keep no-data as OK for runtime debt and never-successful rules; the explicit
`up == 0` and `absent(up{job="yomiko"})` availability rules own exporter
incidents. Observe a normal baseline before tuning attempt thresholds.

## Test an unreleased worktree with a playground

The repository playground builds the current worktree instead of pulling the
published image. It takes an online SQLite backup, copies no production metrics
or API token, denies remote writes, binds the web server to loopback, and does
not run Yomiko's scheduler.

Only one playground may run at a time. Stop the previous one with the stable
dispatcher: `metrics disable` if its temporary scrape is enabled, or `down`
otherwise. Then create a new playground from the repository root:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko create --start
```

The command prints a private directory such as
`/tmp/yomiko-playground.ABC123`. It generates an isolated token at
`data/metrics-token`, sets `YOMIKO_METRICS_TOKEN_FILE` inside the playground,
and publishes `127.0.0.1:62080`. Ordinary tests remain isolated from
production Prometheus. Keep the loopback binding and use the dispatcher for
playground operations.

When the user explicitly wants to see the local worktree result in Grafana,
use the dispatcher to configure and verify the temporary scrape, token copy,
and network attachment:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR metrics enable
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR metrics status
```

Inspect the existing Grafana dashboard by UID
`yomiko-playground-metrics-review`. The dispatcher's `metrics disable` action
restores the Prometheus configuration and disconnects/stops the playground;
use `metrics disable --keep-playground` to restore Prometheus while leaving the
playground web container running.
Because the playground intentionally does not run the scheduler, this proves
the metrics path and dashboard queries but does not prove production heartbeat
behavior. Remove the temporary setup when observation is finished, and delete
the production-derived playground directory only as a deliberate cleanup.
