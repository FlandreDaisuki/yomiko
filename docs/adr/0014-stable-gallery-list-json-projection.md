# ADR-0014: Stable gallery list JSON projection

- Status: Accepted
- Date: 2026-10-01
- Related:
  [Architecture](../architecture.md),
  [ADR-0009: External interface latency budgets](./0009-external-interface-latency-budgets.md),
  [Yomiko Domain Language](../domain-language.md)

## Context

`yomiko list --format json` used `SELECT * FROM galleries` for ordinary reads
and `SELECT galleries.*` for artist-sorted reads. As the schema grew, those
queries automatically added gallery tokens, revision-chain facts, local archive
paths, feedback and H@H state, timestamps, and other internal fields to the
CLI JSON contract. The public pending-feedback and archive-download API
scripts were the only runtime callers of `yomiko list`; both needed the local
archive path, while the feedback page also uses the list's display metadata.

The pending-feedback HTTP response already includes `file_path`. That is an
existing compatibility exposure and removing it requires a separate HTTP API
contract change. The internal CLI naming convention also cannot serve as an
authorization boundary because any local user who can execute `yomiko` can
invoke its commands.

## Decision

Make both `yomiko list` SQL branches select a fixed gallery metadata DTO:
`gid`, `title`, `title_jpn`, `file_count`, `expunged`, `tags`, `rating`,
`uploader`, `posted`, `filesize`, `thumb`, `favorite_count`, and `rating_count`.
Retain the existing top-level JSON array, SQLite JSON value types, null fields,
and compatible metadata names. Keep the current filtering and sorting
predicates even when they use fields outside this output projection. Do not add
a token-bearing compatibility mode or serialize unlisted schema fields.

Add the hidden read-only command `yomiko internal archive-paths <gid...>` for
API adapters. It validates every GID with the CLI allowlist, binds each GID as
a SQLite parameter, and returns one `{gid, archive_path}` row per requested
GID. The query is seeded only by those exact GIDs; unknown GIDs and rows with
no archive return `archive_path: null`. The command selects no gallery token
or unrelated row data. `internal` denotes the narrow API-oriented interface;
it is not access control.

The pending-feedback API keeps calling `list` for its sorted metadata and
performs one batched `internal archive-paths` call when results are present.
It joins by GID and retains its existing `{success, galleries}` response and
the `gid`, `title`, `title_jpn`, `file_count`, and `file_path` gallery fields.
The existing HTTP `file_path` exposure remains for compatibility. The archive
download API uses the exact-GID path command directly and retains its filename,
regular-file, non-symlink, status, and content-disposition checks.

## Consequences

The CLI list JSON contract is stable as galleries gain schema columns, and its
general output no longer contains tokens, archive paths, revision relations,
feedback state, H@H timestamps, or database timestamps. External CLI scripts
that relied on those removed fields must move to the documented metadata DTO
or an appropriate narrow command.

The separate archive-path lookup adds one CLI startup and database read to a
nonempty pending-feedback HTTP request; batching keeps this fixed at one extra
call instead of one call per gallery. The archive download lookup remains
bounded to one requested GID. ADR-0009 defines the current budgets for these
HTTP reads.

The narrow command reduces accidental data exposure in general list output;
it does not prevent local CLI users from reading archive paths. The pending
feedback endpoint continues to expose `file_path` as an existing HTTP
compatibility field. Removing that field requires a future API contract
decision.

Future metadata additions must be deliberately added to the fixed DTO and its
tests. Fields used only for filtering or sorting may remain in SQL predicates
without entering the serialized row.

## Verification

Focused playground regressions passed: 16 tests across the list DTO, exact
parameterized archive-path lookup, pending API, artist sorting, and archive
download checks. The complete playground suite passed: 201 tests, 0 failures.
The real playground CLI was also checked against GID 90186: `list --format
json` emitted the 13 DTO keys with neither `token` nor `file_path`, and
`internal archive-paths` emitted only `gid` and `archive_path` (the path value
was not printed). The focused tests additionally verified a real non-null
path, unknown-GID nulls, exact binding, and no token serialization.

`bash -n` passed for the changed shell entrypoints, fixture, and test runner;
`git diff --check` passed. ShellCheck ran and exited 1 on existing warnings in
unchanged lines; it reported no warnings on the changed lines.

In the isolated schema-30 playground snapshot (2,356 gallery rows),
`YOMIKO_BENCH_ISOLATED_PLAYGROUND=1 /home/yomiko/bench-api-latency.sh` measured
the pending-feedback route at HTTP 200, 18,313 bytes, cold `0.139s`, and warm
p95 `0.192s` across 20 samples. The sweep then stopped before mutation and
archive routes because fewer than 21 candidate reviews were visible through
the authenticated pending-review API. The archive metadata CGI route was
measured separately with one cold and 20 warm loopback requests for no-archive
GID 695 using `curl -sS --max-time 60 -o /dev/null -w
'%{http_code}\t%{time_total}\t%{size_download}\n'
'http://127.0.0.1/api/archive_download.sh?gid=695'`. It returned HTTP 404 and
18 bytes; cold was `0.050s`, warm p95 `0.121s`, and warm max `0.126s`. Both
changed routes remain below the strict one-second budget. The incomplete sweep
does not establish new latency evidence for its mutation routes; see
[ADR-0009](./0009-external-interface-latency-budgets.md).
