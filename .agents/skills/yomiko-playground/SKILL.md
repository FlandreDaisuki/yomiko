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

The generated helper also owns the playground Docker network interface. On
`./playground up`, it connects the configured
`YOMIKO_NETWORK_PEER_CONTAINER` (default: `prometheus`) to the playground's
attachable private network; on `./playground down`, it disconnects that peer
before Compose removes the playground containers and network. If the peer is
not present, the helper skips that optional attachment. Override the variable
in `.yomiko-playground.env` when another container needs access, or leave it
empty to disable the attachment.

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
