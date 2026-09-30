# ADR-0012: Parallel playground test execution

- Status: Accepted
- Date: 2026-10-01
- Related:
  [ADR-0002: Bounded SQLite writer coordination](./0002-bounded-sqlite-writer-coordination.md)

## Context

`tests/run.sh` originally invoked its 191 registered tests sequentially. A
controlled run of the original `HEAD` harness and its original revision-chain
and publication-fault fixtures passed 191/191 in 516.85 seconds. An earlier
in-session estimate of about 222 seconds was a rough tool-wait estimate and
was not timed; the controlled run is the baseline used here.

The requested limits were a strict 30-second full-suite ceiling and a current
run target below 22 seconds. The final harness has 195 registrations: three
new harness checks and one split revision-chain test. The measured counts
therefore differ, and timings describe this test workflow on one host rather
than a guarantee for other machines.

## Decision

Use a bounded Bash worker pool, defaulting to 16 jobs and accepting
`YOMIKO_TEST_JOBS` values from 1 through 64. Each test worker gets its own
temporary root and SQLite writer-lock directory. The parent records each
worker's status and output separately, then flushes results in registration
order and returns failure if any test or required seed preparation fails.
Tests contending on fixed `/tmp` archive/scan locks use a serial lane; unrelated
workers continue concurrently.

Prepare one fully migrated current-schema database seed in the background with
`db_init` and SQLite `.backup`. Runtime and publication-fault fixtures copy that
immutable seed to distinct database paths. Tests for migrations retain their
older-schema setup and execute the actual migrations. The schema-27/28
revision-chain checks are a separate registered fixture so the runtime smoke
can overlap them while preserving upgrade and rollback assertions.

Register the measured long revision-chain, action-budget, schema-27/28,
publication-fault, and handoff fixtures near the beginning of the list. Use
linear payload generation for the 263,000-byte database-streaming test. Keep
26 members in the remote-action budget fixture; 24 of its 26 cleanup actions
are pre-marked succeeded to represent resumed work, leaving two local cleanups
to run alongside the 25-call remote limit and its one-action continuation.

The dispatcher forwards `YOMIKO_TEST_JOBS` and its substring `--filter` to the
test container. The default remains 16 because the measured 24-worker runs did
not improve the full-suite time.

## Experiments and measurements

All timings below use the isolated playground workflow and `/usr/bin/time -p`
around the dispatcher unless stated otherwise.

| Change or experiment | Measurement and decision |
| --- | --- |
| Initial 16-worker pool | 97.75 seconds; parallelism alone did not meet either limit. |
| Full-pool drain before fixed archive/scan lock tests | The runner-internal phase profile found about 4.84 seconds of avoidable pool wait, separate from `/usr/bin/time -p` dispatcher wall time, in addition to about 3 seconds of serialized lock tests. A serial-only lane replaced the global drain. |
| 16 versus 24 workers | Before later fixture improvements, 194/194 took 24.32 seconds at 16 jobs and 24.23 seconds at 24. More workers did not help, so the default stayed 16. |
| Broadly defer seed consumers | A 26.56-second run had a test failure and a worse critical path. This queue/classifier was removed; only actual seed consumers wait for readiness. |
| Current-schema and schema-26 seed reuse | The publication-fault focused test fell from 65.29 seconds to 16.28 seconds (an intermediate run measured 17.24 seconds). The revision-chain smoke, initially about 28.78 seconds, now uses separate runtime and migration tests; the measured focused runs were 18.40 and 13.52 seconds. The migration checks still perform their real schema-27/28 attempts. |
| Large payload substitution | Replacing Bash's repeated string substitution, which took 30.96 seconds for 263,000 bytes, with `printf` piped to `tr` preserves the exact payload and avoids the quadratic construction. |
| Remote budget fixture | The 26-member, resumed-cleanup fixture retains the 25-plus-1 remote boundary, multi-cleanup state, and final 52 succeeded actions while doing less redundant work. |
| `grep` to `rg` | On the real 306-line metrics payload, 500 searches took 940 ms with `grep` and 1,333 ms with `rg`. Pattern escaping and no-match count output also differ, so no replacement was made. |
| `find` to `fd` | On the small Hath-tree fixture, 200 scans took 180 ms with `find` and 1,377 ms with `fd` plus root and path normalization. On a synthetic 1,008-directory tree, 100 scans took 1,250 ms and 864 ms respectively. `fd` defaults also omit hidden/ignored paths and the root. The real fixture favors `find`, which remains in use. |
| Critical-path registration order | Profiling showed the handoff fixture ending at +21.943 seconds after starting at +10.030. Moving it into the early block produced two clean 195/195 full runs at 19.90 and 20.69 seconds. |

The original 191/191 baseline took 516.85 seconds. The final 195/195 runs took
19.90 and 20.69 seconds, about a 25-fold elapsed-time reduction using the
slower current run. Both current runs meet the strict 30-second ceiling and
the run-specific 22-second target on the measured host; those are measured-host
acceptance results, not portable limits for every machine.

## Consequences and maintenance

The pool preserves deterministic output order and isolates common database and
temporary-file state, but fixture authors must keep other shared paths local or
add tests with fixed locks to the appropriate serial lane. Shared-seed consumers
must wait for the atomic completion status, while migration tests must continue
creating their intended old schema rather than reusing the current-schema seed.
The serial lane is intentionally narrow; expanding it reduces concurrency.

The timings were collected on one host with a warm playground Docker test image.
CPU availability, container contention, filesystem and Docker caches, and test
registration count affect wall time. Do not treat 22 seconds as a portable
service-level promise; rerun the complete suite in the target environment when
its performance matters.
