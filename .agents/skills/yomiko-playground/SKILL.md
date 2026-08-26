---
name: yomiko-playground
description: Create an isolated, runnable Yomiko playground from the current worktree and a consistent snapshot of the production SQLite database. Use for testing current Yomiko code against realistic data without modifying production or repository runtime directories.
---

# Yomiko Playground

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
cookie jar, and generated environment file remain mode `0600`. Treat the
playground as containing a production session credential: never print, commit,
share, or reuse its cookie jar outside the requested read-only Yomiko work. The
script copies no production API token, archives, downloads, or logs.

The generated `playground` helper builds current code and starts a loopback-only
debug server with an isolated container, port, API token, and copied database.
Its Compose override initializes/migrates the snapshot but intentionally does
not start Yomiko's scheduler. Do not weaken that isolation merely to reproduce
background work; invoke worker or scan commands explicitly inside the
playground when the task requires them.

Playgrounds deny remote writes by default through
`YOMIKO_REMOTE_WRITES_ENABLED=false`. Read-only discovery API calls and writes
to the copied playground database remain available, while rating, favorite,
H@H, action-reconciliation, and retention work that could mutate remote state
are not executed. Keep this default unless the user explicitly authorizes
remote writes. To enable them for one playground, change the variable to
`true` in that playground's `.yomiko-playground.env` and run `./playground up`
to recreate the container with the new environment.

After creation, report the playground path, URL, copied schema/gallery summary,
and these controls as relevant:

```bash
./playground status
./playground logs
./playground shell
./playground test
./playground down
```

Treat the playground as disposable. Mutations inside it are allowed when they
serve the user's task, but production remains read-only. Do not remove the
playground automatically; leave cleanup or deletion to an explicit user
request.
