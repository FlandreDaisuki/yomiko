# ADR-0002: Bounded SQLite writer coordination

- Status: Accepted
- Date: 2026-09-15

## Context

Yomiko uses SQLite in WAL mode and starts independent `sqlite3` processes for
the scheduler, variant worker, scan/archive flow, runtime metrics, HTTP API,
and operator CLI. WAL allows readers to continue while a writer is active, but
SQLite still allows only one writer. The existing scan, worker, and archive
locks protect narrower domain invariants and therefore cannot prevent unrelated
Yomiko writers from reaching SQLite at the same time.

The default SQLite busy timeout is zero, so an ordinary overlap could fail
immediately with `SQLITE_BUSY`. A fix must bound both cooperative Yomiko waits
and SQLite's own wait, preserve transaction and output contracts, and avoid
holding a global database lock across network or filesystem work.

## Decision

Use two explicit database-helper contracts:

- `db_query` and `db_query_json` run with a bounded silent `.timeout`, enable
  foreign keys, and set `PRAGMA query_only=ON`. They never acquire the writer
  gate.
- `db_write` uses the same SQLite timeout, acquires a cooperative `flock`, and
  invokes exactly one SQLite process. It holds the gate only around that
  process, preserves its output and exit status, and never replays an arbitrary
  SQL stream after a failure.

The SQLite timeout defaults to 5,000 ms and is capped at 60,000 ms. The
cooperative gate has an independent 5,000 ms default and the same cap. A gate
timeout returns status 75; a SQLite failure retains SQLite's status. Explicit
multi-statement read-modify-write operations remain responsible for their own
`BEGIN IMMEDIATE` and `COMMIT` transaction boundaries.

The gate inode is per database but lives in the container's private temporary
directory:

```text
/tmp/yomiko-sqlite-writer-<first-16-hex-of-sha256(DB_PATH)>.writer.lock
/tmp/yomiko-sqlite-writer-<first-16-hex-of-sha256(DB_PATH)>.writer.lock.owner
```

The lock inode is opened without truncation and is not removed during normal
operation. The owner marker is short-lived and contains only an allowlisted
component, PID, and UTC start time. Keeping these files under `/tmp` prevents
them from polluting or being persisted beside a bind-mounted database. The
gate coordinates cooperating processes in one container; it is not a
cross-container lock. SQLite's timeout remains the fallback for direct or
separately deployed connections, and one Yomiko container should normally own
a database.

`YOMIKO_DB_COMPONENT` is an internal, allowlisted diagnostic context. It names
the subsystem that is waiting for or using the writer (`startup`, a runtime
component, `variant_worker`, `scan`, `archive`, `cli:<command>`, or
`api:<command>`). It does not select a database, change authorization, alter
lock scope, or become part of SQL. Diagnostics use it to identify a contender
or writer without logging SQL, paths, IDs, tokens, request payloads, or remote
error text.

Domain locks remain separate and narrow. No database gate is held during
network requests, conversion, compression, filesystem deletion, rename, or
sleep, and no command-level lock replaces scan, worker, archive, or H@H
invariants.

## Consequences

Positive consequences:

- Short cooperative writer overlaps wait and complete instead of failing
  immediately.
- Read-only work retains WAL concurrency and cannot accidentally mutate the
  database through the query helper.
- Bind-mounted data directories contain the database and its backups, not
  ephemeral writer-coordination artifacts.
- Stable component diagnostics make bounded failures actionable without
  exposing application data.

Costs and constraints:

- A `/tmp` gate is scoped to a container. Deployments that intentionally share
  one database across containers rely on SQLite's busy timeout and must accept
  that the cooperative gate is not shared.
- The hashed filename means the same database path must be used by cooperating
  processes in the same container. Different database paths intentionally do
  not contend.
- The lock inode may remain in `/tmp` until the container is removed or its
  temporary storage is cleaned. It must not be deleted while the service is
  running because another process could then lock a replacement inode.
- A gate or SQLite timeout still fails the current operation; higher-level
  durable recovery remains responsible for jobs and uncertain remote actions.

## Alternatives considered

- **Lock beside `DB_PATH`:** rejected because a bind-mounted data directory
  would gain internal control files and the files would outlive the container.
- **One fixed `/tmp` lock:** rejected because unrelated databases in one
  container or test process would serialize unnecessarily.
- **Lock the complete command:** rejected because network, filesystem, and
  conversion work would unnecessarily block all database writers and create
  cross-domain deadlock risks.
- **Retry the complete SQL stream:** rejected because autocommitted statements,
  triggers, and `changes()`-based decisions are not generally safe to replay.

## Verification

The regression suite covers direct SQLite contention, cooperative writer
serialization, bounded gate timeout and owner diagnostics, read concurrency,
query-only enforcement, status preservation, and the `/tmp` lock placement.
The full suite and SQLite integrity/foreign-key checks must pass before
release.
