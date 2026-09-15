---
name: yomiko-playground
description: Create an isolated, runnable Yomiko playground from the current worktree and a consistent snapshot of the production SQLite database. Use for testing current Yomiko code against realistic data without modifying production or repository runtime directories.
---

# Yomiko Playground

Use this skill to verify new migrations, tests, and code changes. Only one
Yomiko playground should be running at a time. Before starting a new one, run
the old playground's `./playground down`; this disconnects its optional network
peer and stops only its containers and network. At the end of every
playground-backed task, including after a failed check, run `./playground down`
as the final step unless the user explicitly asks to observe the running
playground or leave its containers running. Keep the playground directory
unless the user explicitly asks for cleanup.

Create the playground by running the bundled script from anywhere inside the
Yomiko worktree:

```bash
.agents/skills/yomiko-playground/scripts/create_playground.sh --start
```

Pass an unused destination path after `--start` only when the user requests a
specific location. Otherwise keep the generated `/tmp/yomiko-playground.*`
path. Request Docker approval when the environment requires it.

The script copies the current working tree, including uncommitted and untracked
files, but excludes `.git` and runtime `data`, `logs`, `archived`, and `hath`
contents. It uses SQLite's online `.backup` through the running production
container at `~/docker/yomiko`; never replace this with a direct copy of the
live `db.sqlite3` file. It also copies the production ExHentai cookie jar to
`data/cookie-jar.txt` so authenticated read-only discovery sees the same pages
as production. The destination directory remains mode `0700` and the database,
cookie jar, generated metrics token, and generated environment file remain mode
`0600`. Treat the playground as containing production-derived data and
credentials: never print, commit, share, or reuse its cookie jar or tokens
outside the requested read-only Yomiko work. The script copies no production
API token, metrics token, archives, downloads, or logs; both playground tokens
are newly generated and isolated from production.

The generated `playground` helper builds current code and starts a loopback-only
web server with an isolated container, port, API token, and copied database.
Its skill-owned Compose file initializes/migrates the snapshot but intentionally
does not start Yomiko's scheduler. Do not weaken that isolation merely to
reproduce background work; invoke worker or scan commands explicitly inside
the playground when the task requires them.

The generated helper also owns the optional playground Docker network
attachment. The generated `.yomiko-playground.env` leaves
`YOMIKO_NETWORK_PEER_CONTAINER` empty, so normal `./playground up` and test
runs do not connect to production Prometheus or any other peer. The helper
still creates the attachable private network and will connect a peer only when
the variable is explicitly supplied for that command. Use the same override
on `./playground down` so the helper can disconnect the peer before Compose
removes the network. Do not add the playground network to Prometheus's Compose
file: the helper must own any temporary attachment.

Normal playground tests do not need Prometheus access. If a test genuinely
needs to reach production Prometheus, obtain the user's explicit approval
first, then use a command-scoped override on both lifecycle commands:

```bash
YOMIKO_NETWORK_PEER_CONTAINER=prometheus ./playground up
YOMIKO_NETWORK_PEER_CONTAINER=prometheus ./playground down
```

Do not persist that peer in the generated environment file. Connecting a
production Prometheus container is an external observability-side effect and
is separate from ordinary playground startup.

## Optional Prometheus and Grafana observation

Assume the deployment already has the provisioned dashboard **Yomiko
Playground Operations**, UID `yomiko-playground-overview`. Use that dashboard
directly; do not create, copy, transform, or overwrite a dashboard JSON during
a playground task. Its queries are scoped to `job="yomiko-playground"`, so do
not change the production dashboard's `job="yomiko"` queries.

Open the dashboard through the deployment's configured Grafana URL and
navigate by UID `yomiko-playground-overview`; do not hard-code or disclose a
deployment-specific hostname in this skill.

When the user explicitly asks to see the local worktree result in Grafana, use
the bundled helper rather than editing Prometheus files or copying tokens by
hand:

```bash
bash .agents/skills/yomiko-playground/scripts/playground-metrics.sh \
  enable PLAYGROUND_DIR
```

The helper starts or reuses the playground and temporarily overrides the
optional peer so `./playground up` attaches the existing Prometheus container
to the private playground network. It adds the
temporary secret and `yomiko-playground` scrape job, validates the Prometheus
configuration, copies the mounted secret into Prometheus with the correct
container UID/GID, reloads Prometheus, and verifies `up{job="yomiko-playground"}
== 1`. It never prints token contents and never changes the host token to the
Prometheus owner, because the same bind-mounted file must remain readable by
Yomiko in the playground.

Use the other actions as follows:

```bash
bash .agents/skills/yomiko-playground/scripts/playground-metrics.sh \
  status PLAYGROUND_DIR
bash .agents/skills/yomiko-playground/scripts/playground-metrics.sh \
  disable PLAYGROUND_DIR
```

`disable` restores the exact Prometheus files saved before enable, guarded by
checksums, removes the in-container token copy, disconnects the temporary
network peer, and stops the playground. Use `disable PLAYGROUND_DIR
--keep-playground` when the playground should remain running. The script stores
only temporary configuration backups and hashes in
`PLAYGROUND_DIR/.yomiko-playground-metrics`; it refuses to adopt unmarked
manual changes. Set `YOMIKO_PROMETHEUS_DIR`,
`YOMIKO_PROMETHEUS_CONTAINER`, or the file-specific overrides when the
Prometheus deployment is not at its default location.

After enabling, open the existing Grafana dashboard by UID
`yomiko-playground-overview`. This validates the metrics path and dashboard
queries, but does not prove background heartbeat behavior: the playground
Compose file does not start Yomiko's scheduler. Run worker or scan commands
explicitly when testing their runtime metrics. Leave the temporary Prometheus
job and secret in place only when the user explicitly asks to keep observing.

Playgrounds deny remote writes by default through
`YOMIKO_REMOTE_WRITES_ENABLED=false`. Read-only discovery API calls and writes
to the copied playground database remain available, while rating, favorite,
H@H, action-reconciliation, and retention work that could mutate remote state
are not executed. Keep this default unless the user explicitly authorizes
remote writes. To enable them for one playground, change the variable to
`true` in that playground's `.yomiko-playground.env` and run `./playground up`
to recreate the container with the new environment.

After creation, report the playground path, URL, copied schema/gallery summary,
and use these controls as relevant:

```bash
./playground status
./playground logs
./playground shell
./playground test
./playground down
```

Use `./playground up` to apply migrations to the copied database, `./playground
shell` for targeted CLI/API or migration checks, and `./playground test` for
the complete test image. Unless the user explicitly asks to keep observing the
playground, finish the task with `./playground down`; this leaves the copied
directory available for later inspection while removing its running resources.
The generated Compose file is self-contained; the repository does not need a
separate debug Compose file.

Treat the playground as disposable. Mutations inside it are allowed when they
serve the user's task, but production remains read-only. `./playground down`
does not delete the copied directory; delete it only as a separate explicit
cleanup request.
