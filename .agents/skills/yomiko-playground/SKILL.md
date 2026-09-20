---
name: yomiko-playground
description: Create and operate an isolated Yomiko playground from the current worktree and a consistent production SQLite snapshot. Use for realistic migration, test, CLI, API, and metrics checks without modifying Yomiko production data or repository runtime directories.
---

# Yomiko Playground

Use the repository-owned dispatcher for every playground operation:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko
```

This stable executable path is intentional. Generated playground directories
change on every run, so invoking `/tmp/.../playground`, `bash -lc`, or raw
Docker commands creates narrow, non-reusable approval prefixes. When sandbox
approval is required, request it for the dispatcher executable prefix. Do not
bypass the dispatcher when it supports the operation. The skill itself does
not grant sandbox permission, and a remembered command approval does not grant
semantic permission for production side effects.

## Workflow

Only one playground should run at a time. Stop the prior playground first when
its path is known, then create and start a new one from anywhere in the Yomiko
worktree:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko create --start
```

The command prints the generated `/tmp/yomiko-playground.*` path, copied schema
and gallery summary, and loopback URL. Use a destination argument only when the
user requests a particular unused path.

Pass that path explicitly for all later commands:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR status
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR test
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR test --filter 'TEST NAME'
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR sql 'SELECT 1;'
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR exec bin/yomiko --help
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR logs
```

Use `exec` for noninteractive commands inside the running web container,
`shell` for an interactive Bash session, and `test --trace` only when shell
tracing is useful. Prefer `test --filter` and `sql` over wrapping commands in
`/bin/bash -lc` merely to set `YOMIKO_TEST_FILTER` or run a query.

Unless the user asks to keep observing the playground, always finish with:

```bash
./.agents/skills/yomiko-playground/scripts/yomiko --playground PLAYGROUND_DIR down
```

Run it even after a failed check. `down` removes only that playground's
containers and network; it preserves the copied directory for inspection.
Delete the directory only on a separate explicit cleanup request.

## Isolation and data handling

Creation copies the current worktree, including uncommitted and untracked
files, while excluding `.git` and runtime `data`, `logs`, `archived`, and
`hath` contents. It takes the production database through SQLite's online
`.backup` in the running Yomiko container; never directly copy the live
`db.sqlite3`. It also copies the production ExHentai cookie jar so read-only
discovery behaves realistically.

The destination remains mode `0700`; the database, cookie jar, generated
tokens, and environment file remain mode `0600`. Treat them as
production-derived secrets: never print, commit, share, or reuse them outside
the requested Yomiko work. The playground receives newly generated API and
metrics tokens, not production tokens.

The web server is loopback-only, uses an isolated container and copied
database, and does not start the scheduler. Remote writes are disabled with
`YOMIKO_REMOTE_WRITES_ENABLED=false`; keep that default unless the user
explicitly authorizes remote writes. Mutations to the copied database are
allowed when they serve the task. Invoke workers or scans explicitly when a
check requires them.

Normal tests do not connect to production Prometheus. For an explicit request
to observe playground metrics in Prometheus or Grafana, read
[references/metrics.md](references/metrics.md) before acting. That workflow
temporarily changes production observability configuration and therefore
requires explicit user authorization even if the dispatcher prefix was
previously approved.
