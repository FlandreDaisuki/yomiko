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
| `yomiko_gallery_status` | `state` | Exactly one of `rated_variant`, `different_book`, `pending_rating`, `not_archived`, or `unclassified` for each row in `galleries`. |
| `yomiko_galleries` | none | `SELECT COUNT(*) FROM galleries` from the same read snapshot. |

The status series are an exhaustive, mutually exclusive partition with fixed
precedence:
`rated_variant > different_book > pending_rating > not_archived > unclassified`.
`rated_variant` uses active confirmed variant membership. `different_book` uses
only endpoints of current identity pairs whose current review is resolved as
`different_book`. `pending_rating` uses the complete raw
`yomiko list --pending-feedback` predicate after earlier states are removed;
it is therefore not the actionable queue count when a gallery also matches an
earlier state. `not_archived` means that `file_path` is null or empty, and
`unclassified` is the residual state. No GID, path, review ID, or group ID is
exported.

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

> Exhaustive partition of the galleries table. Precedence: rated_variant > different_book > pending_rating > not_archived > unclassified. Bars are mutually exclusive and sum to yomiko_galleries.

If desired, show `yomiko_galleries{job="yomiko"}` in a neighboring `Gallery
rows` stat. It is the total row count, not a sixth partition category. Keep
the database partition separate from the userscript `gallery-status` UI
states, which may have a null state and are not exhaustive.

The current production snapshot baseline is 1,926 gallery rows:

| State | Expected count |
| --- | ---: |
| `rated_variant` | 564 |
| `different_book` | 553 |
| `pending_rating` | 709 |
| `not_archived` | 100 |
| `unclassified` | 0 |
| `yomiko_galleries` | 1,926 |

These values are a rollout snapshot, not a long-term test fixture. Recalculate
and record ordinary data changes from a consistent database snapshot while
requiring the invariant and status definitions to remain unchanged.

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
sum by (action_type, status, error_class) (yomiko_variant_actions)
(time() - yomiko_runtime_last_success_timestamp_seconds{component="variant_worker"}) / 60
max by (job_type) (yomiko_variant_oldest_runnable_job_age_seconds)
sum by (invariant) (yomiko_variant_invariant_violations)
```

Useful initial alerts are:

| Condition | Expression | Hold |
| --- | --- | --- |
| Target absent | `absent(up{job="yomiko"})` | 5m |
| Scrape failing | `up{job="yomiko"} == 0` | 3m |
| Scheduler missed ticks | `time() - yomiko_runtime_last_started_timestamp_seconds{component="scheduler_tick"} > 180` | 2m |
| Worker missed runs | `time() - yomiko_runtime_last_success_timestamp_seconds{component="variant_worker"} > 240` | 2m |
| Runnable job stuck | `max(yomiko_variant_oldest_runnable_job_age_seconds) > 3600` | 10m |
| Runnable action stuck | `max(yomiko_variant_oldest_runnable_action_age_seconds) > 3600` | 10m |
| Lease expired | `sum(yomiko_variant_expired_leases) > 0` | 2m |
| Invariant violated | `sum(yomiko_variant_invariant_violations) > 0` | 1m |

Use an alerting no-data state for the explicit target/heartbeat absence rules.
Observe a normal baseline before tuning queue-age or attempt thresholds.

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
and publishes `127.0.0.1:62080`. It also sets
`YOMIKO_NETWORK_PEER_CONTAINER=prometheus`; `./playground up` connects that
container to the playground's attachable private Docker network, and
`./playground down` disconnects it before removing the playground network. If
Prometheus is not present, the optional attachment is skipped. That loopback
binding is intentional: Caddy runs in a container and therefore cannot reach
the playground through the host's Docker bridge address. Keep the loopback
binding and use the private network instead of broadening the published
address.

To let the existing Prometheus container read the playground token, replace
`PLAYGROUND_DIR` with the printed directory and `PLAYGROUND_CONTAINER` with the
`YOMIKO_PLAYGROUND_CONTAINER` value in `.yomiko-playground.env`. Then grant
only the required owner and group read access:

```bash
yomiko_uid="$(docker exec PLAYGROUND_CONTAINER id -u)"
prometheus_gid="$(
  docker compose -f "$HOME/docker/prometheus/compose.yaml" \
    exec -T prometheus id -g
)"
sudo chown "${yomiko_uid}:${prometheus_gid}" \
  PLAYGROUND_DIR/data/metrics-token
chmod 0640 PLAYGROUND_DIR/data/metrics-token
```

Temporarily point the Prometheus Compose secret at that file. The playground
helper manages the temporary network attachment, so do not add the playground
network to Prometheus's Compose file:

```yaml
secrets:
  yomiko_playground_metrics_token:
    file: PLAYGROUND_DIR/data/metrics-token

services:
  prometheus:
    secrets:
      - yomiko_playground_metrics_token
```

The generated network remains private to the playground and Prometheus while
the playground is running. The helper reconnects the peer after every
`./playground up` and removes that attachment during `./playground down`.

Add a separate temporary scrape job so production queries and alerts are not
mixed with the test target:

```yaml
  - job_name: "yomiko-playground"
    scrape_interval: 30s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: http
    authorization:
      type: Bearer
      credentials_file: /run/secrets/yomiko_playground_metrics_token
    body_size_limit: 1MB
    sample_limit: 500
    static_configs:
      - targets: ["PLAYGROUND_CONTAINER:80"]
```

This target stays inside the private playground network, so the Caddy route
and private CA are intentionally bypassed for this pre-release test.

Run the same Prometheus validation and recreation commands from step 2, then
query `up{job="yomiko-playground"}` and inspect the `yomiko_*` series in
Grafana. Because the playground intentionally does not run the scheduler,
scheduler/worker timestamps may be absent or stale. This test proves routing,
TLS, authentication, Prometheus parsing, and Grafana queries; it does not prove
production heartbeat behavior.

After testing, remove the temporary job and secret from Prometheus and recreate
it. Then run `./playground down` in the printed playground directory; the
helper also removes Prometheus's temporary network attachment. Keep the
directory until its production-derived database and cookie snapshot are no
longer needed; delete it only as a separate deliberate cleanup.
