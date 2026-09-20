# Playground metrics observation

Read this reference only when the user explicitly asks to expose a playground
to the production Prometheus/Grafana stack. Ordinary playground tests do not
need this connection.

The deployment is expected to have a provisioned **Yomiko Playground
Operations** dashboard with UID `yomiko-playground-overview`. Use that dashboard
directly. Do not create, copy, transform, or overwrite dashboard JSON, change
the production dashboard's `job="yomiko"` queries, or disclose a
deployment-specific Grafana hostname.

## Commands

Use the stable dispatcher for the entire workflow:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko \
  --playground PLAYGROUND_DIR metrics enable
./.agents/skills/yomiko-playground/scripts/yomiko \
  --playground PLAYGROUND_DIR metrics status
./.agents/skills/yomiko-playground/scripts/yomiko \
  --playground PLAYGROUND_DIR metrics disable
```

`enable` starts or reuses the playground and temporarily attaches the existing
Prometheus container to its private network. It adds a temporary secret and
`yomiko-playground` scrape job, validates the Prometheus configuration, copies
the token into Prometheus with the correct container ownership, reloads
Prometheus, and verifies `up{job="yomiko-playground"} == 1`. It never prints
the token.

After enabling, open the existing Grafana dashboard by UID. A healthy scrape
validates the metrics path and dashboard queries, but does not prove background
heartbeat behavior because the playground does not run Yomiko's scheduler.
Invoke the relevant worker or scan explicitly when the task requires its
runtime metrics.

`disable` restores the exact Prometheus files saved before `enable`, guarded by
checksums, removes the in-container token copy, disconnects Prometheus, and
stops the playground. To restore Prometheus while leaving the playground
running, use:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko \
  --playground PLAYGROUND_DIR metrics disable --keep-playground
```

Leave the temporary scrape configuration in place only when the user
explicitly asks to keep observing it.

## Safety invariants

- The helper stores its backups, checksums, and state in
  `PLAYGROUND_DIR/.yomiko-playground-metrics` and refuses to adopt unmarked
  manual configuration.
- It refuses to disable if the managed Prometheus files changed after enable;
  inspect that conflict instead of overwriting unrelated edits.
- Do not persist a production network peer in `.yomiko-playground.env` or add
  the playground network to Prometheus Compose. The helper owns the temporary
  attachment.
- Do not change the host token's owner. Yomiko must continue to read the same
  bind-mounted file.
- The helper supports `YOMIKO_PROMETHEUS_DIR`,
  `YOMIKO_PROMETHEUS_CONTAINER`, `YOMIKO_PROMETHEUS_COMPOSE_FILE`, and
  `YOMIKO_PROMETHEUS_CONFIG_FILE` for non-default deployments. Avoid shell
  prefixes solely for these overrides when the defaults are correct, because
  doing so defeats the stable approval prefix.
