# ADR-0017: Bounded scheduler container logs

- Status: Accepted
- Date: 2026-10-07
- Related:
  [Architecture](../architecture.md),
  [Gallery variants](../gallery-variants.md)

## Context

The scheduler duplicated scan and variant-worker output to files that grew
without a limit. It also sent the same output to the container log stream.
The container stream can interleave both jobs. Many inner worker and archive
messages have no reliable source label, so an operator could not identify
their source from a mixed stream.
The optional `HOST_LOG_DIR` mount could preserve those files across container
recreation, but it did not provide rotation.

## Decision

The scheduler combines stdout and stderr from scan and variant-worker commands
in the container log stream. It prefixes each line with `[scan]` or
`[variants]` so the source stays clear when the streams interleave. It does not
append these streams to `yomiko-scan.log` or `yomiko-variants.log`.

The `yomiko` Compose service uses Docker's `local` logging driver with
`max-size: "10m"` and `max-file: "5"`. All service stdout and stderr share an
approximate 50 MB size-based retention limit per container. Use
`docker compose logs` to read them. Docker does not retain a time-based window.
Docker keeps each log set only for its container's lifecycle. Container
recreation starts a new log history.

`HOST_LOG_DIR` is deprecated for scheduler output. Existing scan and variant
log files in a mounted directory remain in place and are not updated or
deleted. The optional mount can still expose the writer gate diagnostic
`yomiko-writer.log`. This decision does not set its file retention. Its
best-effort writes must not add diagnostics to CLI or CGI output.

## Consequences

Scheduled scan and worker output has a size ceiling and remains available
through Docker's log interface. A container recreation discards access to the
previous container's log history. Deployments that mounted `HOST_LOG_DIR` may
keep old scheduler log files; operators can remove them after checking their
contents. The writer diagnostic keeps its existing file behavior and separate
retention requirements.

## Verification

The focused playground test `scheduler labels interleaved scan and worker
output` passed. It checks labels on stdout and stderr, output from both jobs
while they overlap, and the absence of the old scheduler files. The complete
playground suite passed 214 tests with no failures. The effective Compose
configuration reports the `local` driver with `10m` and `5` options.
Shellcheck passed for the scheduler and path library.
The test suite has existing `SC2034` and `SC2317` findings; it passes
shellcheck with those findings excluded.

The playground container used the same logging options. It wrote 60,000 filler
records, more than 60 MB, to container stdout. `docker compose logs` returned
the two latest markers and no oldest marker. After container recreation, the
old marker stayed absent and a new marker appeared in the log stream.
