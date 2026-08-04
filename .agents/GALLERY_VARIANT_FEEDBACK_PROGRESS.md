# Gallery Variant Feedback — Shared Progress

This file coordinates implementation of `GALLERY_VARIANT_FEEDBACK_PLAN.md`.
Every agent must read it before starting, update only its assigned section, and
record concrete findings, changed files, verification, blockers, and handoff
notes before its 10-minute work window ends.

## Coordination rules

- Coordinator: `/root`.
- Agent work window: at most 10 minutes per assigned task.
- Do not overwrite or revert another agent's edits.
- Do not guess about external behavior; record unknowns and verify against
  repository code or authoritative sources.
- Stop and mark `FATAL DECISION` if implementation depends on a product choice
  not settled by the finalized plan.
- Keep changes in small, independently verifiable slices.

## Current phase

Foundation milestone complete. The next major phase is the policy lifecycle and
executable-policy foundation: parse and validate policy JSON, activate immutable
database revisions, route work according to section changes, and make the
active policy available to later worker handlers without hard-coded duplicates.

## Coordinator status

- 2026-08-04: Read the finalized plan, project instructions, and architecture;
  coordinated all bounded implementation slices recorded below.
- 2026-08-05: Created branch
  `feat/gallery-variant-feedback-foundation`, integrated grouped downgrade
  routing, centralized archive-filename safety checks, and completed native
  Alpine verification.
- 2026-08-05: Reframed the next milestone around the missing policy control
  plane and runtime-consumption boundary. Discovery/evaluation work should not
  grow more hard-coded policy constants before this boundary exists.
- Next milestone: complete the policy lifecycle and execution foundation
  described below. Discovery continuations, evaluation/review, remote actions,
  retention reconciliation, and web review cards follow it.

## Next major phase: policy lifecycle and execution foundation

- Status: ready to implement.
- Goal: turn the policy seeded by migration 005 from inert database data into a
  validated, operator-manageable, revisioned input that later worker handlers
  can consume deterministically.
- Source-of-truth rule: the active row in `variant_policy_revisions` is
  authoritative. A JSON file is only an import/export and editing format; the
  worker must never watch a mutable file or treat it as live configuration.

### Required operator flow

1. Export or copy the current example policy to a host-side JSON file.
2. Edit that file.
3. Run `yomiko variants policy-check <path|->` to validate and display the
   canonical full/section hashes without changing the database.
4. Run `yomiko variants policy-activate <path|->` to transactionally reuse or
   insert an immutable revision, activate it, and enqueue only the work implied
   by the changed sections.
5. Inspect the returned revision ID, hashes, section-change flags, and queued
   work. `-` should read JSON from stdin so Docker operators do not need an
   extra bind mount or `docker compose cp` step.

Recommended Docker workflow:

```bash
docker compose exec -T yomiko \
  yomiko variants policy-show --pretty > variant-policy.json

docker compose exec -T yomiko \
  yomiko variants policy-check - < variant-policy.json

docker compose exec -T yomiko \
  yomiko variants policy-activate - < variant-policy.json
```

`policy-show` is the read-only export surface needed to make the edit/check/
activate loop self-contained. It should emit only the active policy document;
`--pretty` changes formatting only.

### Parsing, validation, and hashing contract

- Add a formatted example policy whose canonical form exactly matches the
  migration-005 seed and its four committed hashes.
- Parse with `jq`, reject malformed JSON, and validate the complete supported
  shape with allowlisted keys and values. Unknown fields must fail closed so a
  typo cannot silently become an ignored policy setting.
- Validate types, integer ranges, nonempty/unique arrays, supported enum values,
  the E-Hentai `gdata` batch cap of 25, and cross-field invariants.
- `matching.metadata_score.total_max` must equal the sum of the title, creator,
  content-tag, and page-count component maxima.
- Canonicalize as compact recursively key-sorted JSON before hashing. Hash the
  exact canonical bytes without a trailing newline using SHA-256.
- Compute independent hashes for the full document and the `matching`,
  `scoring`, and `operations` sections. The example must reproduce:
  - full: `95cfec1154b96ff2dbd8ac5569e7e841e78645d71470b763d2cf4735c23f1e3b`
  - matching: `a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e`
  - scoring: `70119b24d58ec197f22b5fa079fc5b8760b66976f4d324664a0173d58ca88`
  - operations: `7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d`
- Keep favorite categories out of policy JSON. They remain deployment
  configuration through `YOMIKO_CANONICAL_FAVORITE_CATEGORY` and
  `YOMIKO_ALTERNATE_FAVORITE_CATEGORY`.

### Activation and work-routing contract

- Perform revision lookup/insertion, active-revision switching, change
  classification, and job coalescing in one `BEGIN IMMEDIATE` transaction.
- Reuse a prior immutable revision when its full content hash already exists.
  Reactivating it must not duplicate revision content.
- Activating the already-active content is a successful no-op and creates no
  jobs.
- A matching-section change queues/coalesces immediate `discover` work for all
  active groups. Rediscovery will also produce evaluation under the new policy,
  so it takes precedence over a separate scoring-only sweep.
- A scoring-only change queues/coalesces one global
  `policy_scoring_sweep` job. The handler later processes active groups in
  cursor batches using `operations.policy_sweep_batch_size` and stored metadata
  snapshots, without remote discovery.
- An operations-only change invalidates no discovery or evaluation data and
  creates no policy job; future work uses the newly active limits.
- Preserve the priority order finalized in the policy: explicit feedback,
  policy work, then annual stale discovery.
- Structured CLI output must include the activated revision ID, all hashes,
  `changed`, per-section change booleans, and counts/booleans for work routed.
  Human diagnostics must use API-aware logging and never corrupt JSON stdout.

### Runtime policy execution boundary

- Provide one loader that reads and validates the single active revision and
  returns its revision ID plus typed `matching`, `scoring`, and `operations`
  values. Discovery, evaluation, and action handlers must use this loader
  instead of copying seed constants into shell code.
- A job/evaluation must retain the policy revision that made its decision.
  Matching and scoring must never combine values from different active
  revisions during one unit of work.
- Operational values control discovery groups per run, search and gdata
  continuation budgets, throttling, leases, retry delays, annual rediscovery,
  and scoring-sweep batch size.
- Invalid or unavailable active policy fails closed for variant evaluation and
  action execution, with visible configuration errors. It must not disable
  scanning, archiving, unrelated feedback, or read-only policy inspection.
- The reporting-only `variants work` behavior remains honest until individual
  discovery/evaluation/action handlers are implemented; policy activation may
  queue their durable jobs but must not mark unsupported work complete.

### Implementation slices

1. Example JSON plus strict validator/canonicalizer/hash helpers.
2. `policy-show` and mutation-free `policy-check`, including stdin support and
   stable JSON output.
3. Transactional `policy-activate` with immutable revision reuse and exact
   section-change job routing.
4. Active-policy loader and typed access helpers for future worker handlers.
5. Focused tests, Docker packaging of the example, README operator workflow,
   and architecture updates that distinguish implemented behavior from queued
   worker phases.

### Acceptance gate

- The seed/example canonical hashes match migration 005 exactly.
- Invalid JSON, unknown fields, unsupported enums, bad numeric limits, and an
  incorrect `metadata_score.total_max` are rejected before database mutation.
- Check/show paths make no database writes; activation is atomic.
- Unchanged, operations-only, scoring-only, and matching-change activations
  each produce the exact revision/job behavior above, including idempotent job
  coalescing and reactivation of an older revision.
- Policy contents remain immutable, exactly one revision is active, foreign-key
  and integrity checks pass, and machine-readable stdout is valid JSON.
- `bash -n`, `shellcheck`, `git diff --check`, focused policy tests, and the full
  native project test image pass before advancing to discovery execution.

## Agent assignments

### schema_foundation

- Status: completed
- Scope: implement migration 005 with the plan's normalized gallery metadata,
  variant tables, constraints/indexes, and seeded initial policy. Own only
  `migrations/005_*.sql` plus this section. Work window: 10 minutes.
- Findings: E-Hentai chain metadata uses the normalized `first_key`,
  `parent_key`, and `current_key` names alongside their GIDs. Cross-table active
  membership uniqueness cannot be expressed as a partial index, so migration
  triggers reject confirming or reactivating a GID in a second active group.
  The initial policy JSON is canonicalized and includes all finalized matching,
  scoring, and operational defaults; full and section SHA-256 hashes were
  independently verified.
- Changed files: `migrations/005_gallery_variants.sql`; this section of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification: Applied migrations 001 through 005 to an in-memory SQLite
  database via Python's SQLite 3 binding with foreign keys enabled; verified
  policy full/section hashes, policy immutability, active-membership conflict,
  runnable-job coalescing, `PRAGMA foreign_key_check`, and
  `PRAGMA integrity_check`. `git diff --check` passed. The repository's
  `sqlite3` executable is a Docker-backed wrapper and could not access its
  daemon, so direct CLI validation was unavailable.
- Blockers / handoff: No fatal decision or schema blocker. Consumers should use
  the exact job types/check values and column names declared by migration 005;
  immutable tied evaluations are superseded by a new completed evaluation
  after winner review rather than updated in place.

### cli_lifecycle

- Status: completed metadata foundation (2026-08-04)
- Scope: extend and validate normalized gdata fields needed by matching/scoring.
  Own `lib/exh.sh`, the metadata upsert portion of `bin/yomiko`, focused tests
  in `tests/run.sh`, and this section. Work window: 10 minutes.
- Findings:
  - Authoritative EHWiki `gdata` documentation shows `posted`, `filecount`, and
    chain GIDs as decimal strings in its example, `filesize` as a JSON number,
    and the chain token fields as `first_key`, `parent_key`, and `current_key`.
  - Chain GID/key fields are absent on galleries without the corresponding
    relationship, so normalization emits explicit nulls for all six optional
    fields.
- Changed files:
  - `lib/exh.sh`: validates and normalizes category, uploader, posted, filesize,
    thumb, and optional chain GID/key fields.
  - `bin/yomiko`: metadata upserts now bind and insert/update all normalized
    fields while preserving the existing feedback/file lifecycle columns.
  - `tests/run.sh`: focused normalization, rejection, absent-chain, and archive
    SQL-binding assertions.
  - `tests/fixtures/archive-bin/curl`: coordinator-approved minimal update so
    the archive fixture represents the newly required real gdata core fields.
- Verification:
  - `git diff --check` and `bash -n` passed for all changed shell files.
  - `shellcheck` passed for `lib/exh.sh`, `bin/yomiko`, `tests/run.sh`, and the
    archive curl fixture.
  - `bash tests/run.sh`: 52 passed; all metadata normalization/upsert/archive
    tests passed. Three existing SQLite-backed tests could not run because the
    environment's sqlite3 provider cannot access the Docker daemon.
  - Direct mixed numeric-string/number normalization smoke test passed.
- Blockers / handoff:
  - No fatal decisions or implementation blockers.
  - Upsert column names align with migration 005: `category`, `uploader`,
    `posted`, `filesize`, `thumb`, `first_gid`, `first_key`, `parent_gid`,
    `parent_key`, `current_gid`, `current_key`.

### test_review

- Status: complete (worker scheduling foundation)
- Scope: add the independent variants runtime paths/log/cron invocation without
  implementing worker internals. Own `lib/path.sh`, `cronjobs/cron-simulate`,
  relevant fixture copies, and this section. Work window: 10 minutes.
- Findings: the existing scheduler already backgrounds the scan pipeline, so the
  variants worker can be launched as a second background pipeline each cycle
  without either command waiting for the other. Dedicated exported scan and
  variants log paths prevent their persistent logs from being mixed. The
  entrypoint scheduler fixture is a trace-only stub and needs no matching path
  variables.
- Changed files: `lib/path.sh`, `cronjobs/cron-simulate`.
- Verification: `bash -n lib/path.sh cronjobs/cron-simulate`, `shellcheck
  lib/path.sh cronjobs/cron-simulate`, and `git diff --check` passed. The full
  suite reported 49 passed / 5 failed during concurrent foundation work; all
  four entrypoint fixture tests passed. Three failures require the unavailable
  Docker-backed SQLite provider, and two exercised concurrently changing gdata
  fixtures rather than these scheduler files.
- Blockers / handoff: worker command internals must own the nonblocking
  `/tmp/yomiko-variants.lockfile` lock. Until `yomiko variants work` is
  implemented, the new scheduled invocation will correctly expose that missing
  command in `logs/yomiko-variants.log`; integrate the command before release.

### phase2_variant_cli

- Status: completed (2026-08-04)
- Scope: implement new `lib/variants.sh` only, providing durable group/job
  enqueue helpers, JSON list primitives, and a non-overlapping worker entrypoint
  that never consumes unsupported jobs. Work window: 10 minutes.
- Findings:
  - Public integration contract: source `lib/variants.sh` after `common.sh` and
    `db.sh`; call `variants_enqueue_feedback <gid> <rating>` for an atomic
    8-11 feedback write/enqueue and capture its numeric-only group-id stdout.
    `variants_enqueue_group <gid>` is the stored-rating wrapper used by CLI
    enqueue. `cmd_variants "$@"` dispatches `enqueue`, `list`, and `work`;
    reusable reads/work entrypoints are `variants_list_json [gid-or-0]
    [status]` and `variants_work [--max-jobs N] [--dry-run]`.
  - Confirmed membership is considered across active and inactive groups,
    preferring an active group then the oldest group, so feedback on a
    non-source member correctly reactivates its existing group.
  - The foundation worker takes the independent nonblocking
    `/tmp/yomiko-variants.lockfile` and reports due jobs without leasing,
    consuming, or completing unsupported discovery/evaluation work.
- Changed files: `lib/variants.sh`; this section of the shared progress file.
- Verification:
  - `bash -n lib/variants.sh`, `shellcheck lib/variants.sh`, and targeted
    `git diff --check` passed.
  - A standalone SQLite smoke check applied migrations 001-005, atomically
    enqueued rating 11 twice with one group/job and remote desired rating 10,
    validated nested list JSON and API-mode work JSON, and confirmed work left
    the job queued.
  - A second smoke check confirmed feedback for a non-source member of an
    inactive group reactivated that same group without creating another.
- Blockers / handoff:
  - No fatal decision or implementation blocker. `bin/yomiko` should source
    the library and route its `variants` command to `cmd_variants`.
  - Feedback integration must use `variants_enqueue_feedback`, not separately
    update `galleries`, for rating 8-11 atomicity. Discovery/evaluation and all
    job leasing/completion deliberately remain for later worker phases.

### phase2_schema_tests

- Status: completed (2026-08-04)
- Scope: add focused migration-005 upgrade/fresh-schema/invariant tests in
  `tests/run.sh` without changing implementation files. Work window: 10
  minutes.
- Findings: Migration 005 can be exercised directly through the existing
  `db_init` test style. The focused coverage verifies a populated schema-004
  upgrade, a fresh all-migrations install, all eleven normalized gallery
  metadata columns and seven variant tables, the one active immutable seeded
  policy and its four fixed hashes, active confirmed-membership uniqueness,
  group and policy-sweep job coalescing, and transaction rollback/retry after a
  deliberately broken migration tail.
- Changed files: `tests/run.sh`; this section of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification: `bash -n tests/run.sh`, `shellcheck tests/run.sh`, and
  `git diff --check` passed. An executable in-memory validation through
  Python's built-in SQLite binding applied migrations 001-005 and confirmed
  the expected columns/tables, policy shape, active-membership rejection, both
  coalescing constraints, and `PRAGMA integrity_check = ok`. `bash
  tests/run.sh` reported 52 passed / 6 failed: the three new migration tests
  and three pre-existing SQLite-backed tests could not run because the local
  `sqlite3` provider is a Docker wrapper whose daemon is inaccessible.
- Blockers / handoff: No fatal decision or schema-test blocker. Rerun `bash
  tests/run.sh` in the project image or any environment with a functional
  SQLite CLI; the new tests intentionally follow the suite's existing
  `command -v sqlite3` convention and do not add a runtime dependency.

### phase2_feedback_integration

- Status: completed (2026-08-04)
- Scope: wire `lib/variants.sh` into the CLI and make rating 8-11 feedback use
  its atomic durable enqueue path, while preserving safe local deletion and
  emitting variant queue state for the API. Own `bin/yomiko` outside the
  metadata upsert, `web/api/feedback.sh`, and this section. Work window: 10
  minutes.
- Findings:
  - Rating 8 through 11 feedback now calls `variants_enqueue_feedback` directly,
    so local intent, group activation, discovery-job coalescing, and the source
    rating action share the module's single transaction and no ExHentai call is
    made on the request path.
  - For rating 8 through 10, archive cleanup is intentionally a post-transaction
    filesystem commit: `rated_then_deleted_at` is updated only after `rm`
    successfully removes a file that existed. An absent/unrecorded file leaves
    the timestamp unchanged. Rating 11 retains the source archive.
  - In API mode `yomiko feedback` reserves stdout for a small JSON result. The
    CGI validates that result before returning boolean `variant_queued` and
    numeric/null `variant_group_id`; malformed successful CLI output fails as a
    502 instead of corrupting the response.
- Changed files: `bin/yomiko` outside `gallery_upsert_metadata`,
  `web/api/feedback.sh`, and this section.
- Verification:
  - `bash -n` and `shellcheck` passed for `bin/yomiko`,
    `web/api/feedback.sh`, and the emerging `lib/variants.sh`.
  - `git diff --check` passed.
  - Mocked CGI checks passed for percent-decoded high feedback
    (`true`/numeric group), low feedback (`false`/null), zero-GID rejection,
    and malformed CLI-result rejection.
- Blockers / handoff:
  - Per assignment, below-8 confirmed-group propagation/deactivation is not
    implemented in this slice; current below-8 single-gallery behavior remains.
    A later worker/lifecycle slice must add the finalized group downgrade flow.
  - The legacy `--favorite` argument remains accepted for compatibility, but
    high feedback no longer submits it synchronously; configured canonical and
    alternate favorite routing belongs to durable worker actions.
  - Coordinated with `phase2_variant_cli` on inactive confirmed membership; it
    now reuses/reactivates that group and keeps numeric group-id-only stdout.

### phase2_foreign_keys

- Status: completed (2026-08-04)
- Scope: ensure SQLite foreign-key constraints are enabled on every CLI
  connection and add focused regression coverage. Own `lib/db.sh`, focused
  additions to `tests/run.sh`, and this section. Work window: 10 minutes.
- Findings:
  - SQLite documents foreign-key enforcement as connection-local, disabled by
    default, and ineffective when enabled after a transaction begins. Every
    `sqlite3` invocation in `lib/db.sh` now executes `PRAGMA foreign_keys=ON`
    before schema, migration transaction, parameter binding, or query work.
  - Supplying the pragma as the first post-database CLI command preserves the
    existing ordered argument contract for `.parameter` commands. The pragma
    assignment emits no result row, so plain and `--json` stdout remain clean.
- Changed files: `lib/db.sh`; focused additions to `tests/run.sh`; this section
  of `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`. No fixture changes were
  needed.
- Verification:
  - `bash -n lib/db.sh tests/run.sh`, `shellcheck lib/db.sh tests/run.sh`, and
    targeted `git diff --check` passed.
  - Existing mock-backed migration and archive/query-argument tests passed,
    including a trace assertion that migrations receive the pragma before
    `BEGIN IMMEDIATE`.
  - Added executable regressions for both `db_query` and `db_query_json`
    reporting `PRAGMA foreign_keys = 1`, generic orphan rejection, and
    migration-005 `gallery_variants` orphan rejection.
  - `bash tests/run.sh` reported 52 passed / 7 failed. All seven failures are
    SQLite-backed tests (including the new regression) because the installed
    `sqlite3` wrapper cannot access its Docker daemon; no mock/static failure
    occurred.
- Blockers / handoff: No fatal decision or code blocker. Rerun the suite in the
  project container or another environment with a functional SQLite CLI to
  execute the foreign-key regressions end to end.

### phase2_schema_audit

- Status: completed (2026-08-04)
- Scope: audit migration 005's cross-row/type invariants against the finalized
  plan and patch only demonstrable schema gaps. Own migration 005 and this
  section. Work window: 10 minutes.
- Findings:
  - Review checks previously allowed candidate reviews to resolve as `winner`,
    winner reviews to resolve as same/different-book, and selected GIDs on
    candidate decisions. The type/status/decision/selection shape is now exact.
  - Updating or deleting `gallery_variants` could orphan a group's canonical
    pointer. Guard triggers now require clearing/changing that pointer before
    its confirmed membership row can be moved, demoted, or deleted.
  - A completed evaluation could select a gallery that was absent from its
    group's confirmed membership. Evaluation insertion now rejects that state.
  - Active evaluation updates already checked group ownership, but group
    inserts and primary-key updates did not. Symmetric insert/update checks now
    cover the full pointer lifecycle.
  - `policy_scoring_sweep` accepted a non-null group ID, bypassing its global
    runnable-job coalescing index. Its global scope is now enforced, while all
    other job types must remain group-scoped.
- Changed files: `migrations/005_gallery_variants.sql`; this section of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification:
  - Applied migrations 001-005 in Python SQLite with foreign keys enabled;
    positive and negative cases passed for review shapes, canonical membership
    mutation/deletion, evaluation canonical ownership, active-evaluation
    ownership, global/group job scope, and both coalescing indexes.
  - `PRAGMA foreign_key_check` returned no rows and `PRAGMA integrity_check`
    returned `ok`.
  - Recomputed the full seeded policy hash and all three section hashes; all
    remain unchanged. `git diff --check` and relevant `bash -n` checks passed.
- Blockers / handoff: No fatal decision or schema blocker. Worker/review code
  must clear or change `canonical_gid` before demoting/deleting that membership
  row, and policy scoring sweeps must always use a null `group_id`.

### phase3_variant_tests

- Status: completed (2026-08-04)
- Scope: add focused CLI/library/API regression coverage for the completed
  enqueue/list/work/feedback foundation. Own `tests/run.sh`, new test fixtures
  if needed, and this section. Work window: 10 minutes.
- Findings:
  - Enqueue coverage proves duplicate rating-11 feedback coalesces to one group
    and runnable discovery job, maps remote desired rating to 10, preserves an
    already-succeeded exact action, supersedes it on rating 8, and reopens it
    only after returning to 11.
  - Confirmed membership lookup is covered through a non-source member of an
    inactive group. List/work assertions validate nested JSON, status filters,
    dry-run output, non-consumption, and the nonblocking worker lock.
  - The real feedback CLI is exercised with a curl executable that always
    fails if called: rating 11 still succeeds and retains its archive, while
    rating 8 removes it and records the completed deletion timestamp.
- Changed files: `tests/run.sh`,
  `tests/fixtures/feedback-result-yomiko.sh`,
  `tests/fixtures/fail-if-called.sh`; this section of the shared progress file.
- Verification:
  - `bash -n`, `shellcheck`, and targeted `git diff --check` passed for all
    owned shell files.
  - `bash tests/run.sh`: 54 passed / 11 failed. The CLI-input and API tests
    added here passed. All 11 failures require SQLite and hit the repository's
    Docker-backed sqlite3 wrapper, whose daemon is inaccessible on this host;
    four of those are the new SQLite-backed regressions.
- Blockers / handoff: No fatal decision. Rerun the full suite inside the
  project Alpine image to execute the new SQLite-backed tests end to end.

### phase3_group_downgrade

- Status: completed (2026-08-04)
- Scope: add an atomic durable below-8 confirmed-group downgrade primitive in
  `lib/variants.sh` only. Own that library and this section. Work window: 10
  minutes.
- Findings:
  - `variants_downgrade_feedback <gid> <rating>` selects confirmed membership
    across active and inactive groups, preferring an active group and then the
    oldest group, and performs the complete desired-state transition in one
    `BEGIN IMMEDIATE` transaction.
  - A handled downgrade updates every confirmed member locally, deactivates
    the group, creates exact rating, `favorite_remove=favdel`, and
    `archive_cleanup=delete` actions under the active policy, supersedes every
    action outside that desired set, and coalesces one priority-1000
    `reconcile_actions` job. It neither leases work nor deletes an archive.
  - Status `VARIANTS_NOT_GROUPED_STATUS=3` is the documented no-membership
    result. It emits no stdout and commits no persistent mutations, allowing
    the CLI integration to retain legacy single-gallery feedback behavior.
  - Repeated identical downgrades reuse the queued job and action identities;
    existing terminal identical actions remain terminal, matching the existing
    enqueue helper's desired-action conflict behavior.
- Changed files: `lib/variants.sh`; this section of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification:
  - `bash -n lib/variants.sh`, `shellcheck lib/variants.sh`, and targeted
    `git diff --check` passed.
  - A Python-SQLite-backed CLI shim executed the actual Bash transaction after
    migrations 001-005. It verified oldest inactive-group selection, updates
    to all and only confirmed members, exact actions for two members, stale
    rating/favorite/H@H supersession, one coalesced reconcile job after a
    repeated downgrade, numeric-only group output, and status 3/no mutation
    for an ungrouped gallery.
- Blockers / handoff:
  - No fatal decision or implementation blocker. Coordinator confirmed the
    stable internal cleanup value `delete` and that only `reconcile_actions`
    belongs in this transition; `reconcile_retention` remains reserved for the
    rating-11 replacement lifecycle.
  - `bin/yomiko` should call this primitive before its legacy below-8 path and
    branch specifically on status 3; any other nonzero result is a real error.

### phase3_docs

- Status: completed (2026-08-04)
- Scope: update architecture/README documentation for only the functionality
  actually implemented in this foundation, clearly identifying queued later
  phases. Own `docs/architecture.md`, `README.md`, and this section. Work
  window: 10 minutes.
- Findings:
  - High feedback now persists and enqueues durable intent atomically without
    synchronous remote rating/favorite calls. The independent scheduled worker
    currently acquires its own lock and reports due jobs only; it deliberately
    does not lease or complete them.
  - Migration 005 adds normalized matching/scoring metadata, seven variant
    lifecycle tables, a seeded immutable policy revision, and cross-row
    invariants. SQLite foreign-key enforcement is enabled per connection.
  - The current feedback page still sends its favorite compatibility argument
    but does not expose variant discovery, evaluation, reviews, policies, or
    action state.
  - The concurrently completed below-8 library primitive atomically
    deactivates a confirmed group and records per-member rating,
    favorite-removal, and cleanup actions plus a reconciliation job. It is not
    yet integrated into `yomiko feedback` and performs no remote/file work.
- Changed files: `docs/architecture.md`, `README.md`, and this section.
- Verification: compared documentation against the current diffs in migration
  005, `lib/variants.sh`, `bin/yomiko`, `lib/db.sh`, the scheduler/path helpers,
  and the feedback API; `git diff --check` passed for the owned documentation.
- Blockers / handoff: Discovery, evaluation, candidate/winner review, remote
  action execution, H@H replacement/cleanup reconciliation, policy CLI, and
  web review cards are explicitly documented as future phases. The below-8
  primitive is documented as internal durable state only, with CLI integration
  still future.

### phase3_downgrade_integration

- Status: completed (2026-08-04)
- Scope: wire grouped ratings 1-7 through the durable downgrade primitive in
  CLI/API feedback while leaving ungrouped low ratings unchanged. Own
  `bin/yomiko`, `web/api/feedback.sh` only if needed, and this section. Work
  window: 10 minutes.
- Findings:
  - Ratings 1 through 7 now call `variants_downgrade_feedback` before any
    legacy remote or local behavior. Status 0 marks the request as variant
    work, exposes its numeric group ID, and skips synchronous rating, direct
    database writes, and archive deletion; the durable group actions own all
    of that work.
  - Status 3 is handled only as the documented ungrouped result and falls
    through to the existing single-gallery remote/update/delete path. Every
    other nonzero status fails the command with status 5.
  - Low-feedback dry runs query confirmed membership with the same active-then-
    oldest ordering as the durable primitive and report the would-be queue
    state/group ID without invoking it or mutating state.
  - Archive filename validation remains ahead of every immediate deletion:
    ratings 8-10 are checked before durable enqueue, and ungrouped ratings 1-7
    are checked before legacy remote/database/file changes. Grouped low
    feedback leaves archive inspection and cleanup entirely to durable work.
  - `web/api/feedback.sh` required no change: its existing validated
    `variant_queued` boolean and numeric/null group ID contract already
    represents grouped downgrades without exposing CLI diagnostics.
- Changed files: `bin/yomiko`; this section of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification:
  - `bash -n bin/yomiko web/api/feedback.sh`, `shellcheck bin/yomiko
    web/api/feedback.sh`, and `git diff --check` passed.
  - `bash tests/run.sh` reported 54 passed / 11 failed. All non-SQLite tests,
    including feedback API JSON validation and high-feedback input coverage,
    passed. The 11 failures all require the repository's Docker-backed
    `sqlite3` provider, whose daemon is inaccessible on this host.
- Blockers / handoff: No fatal decision or implementation blocker. The focused
  grouped/ungrouped downgrade tests are owned by `phase3_downgrade_tests` and
  should be rerun where the SQLite CLI is functional.

### phase3_downgrade_tests

- Status: completed (2026-08-04)
- Scope: add focused regression coverage for grouped downgrade/deactivation
  and ungrouped fallback. Own `tests/run.sh`, fixtures if needed, and this
  section. Work window: 10 minutes.
- Findings:
  - Primitive coverage confirms active membership wins over an older inactive
    membership, an all-inactive lookup selects the oldest group, and an
    ungrouped GID returns status 3 without changing gallery/action/job state.
  - A handled downgrade updates all and only confirmed members, deactivates
    the selected group, creates exact rating, `favorite_remove=favdel`, and
    `archive_cleanup=delete` actions, supersedes stale rating/favorite/H@H
    intent, and reuses one priority-1000 reconciliation job on repetition.
  - CLI coverage confirms grouped low feedback returns queue/group state,
    avoids curl and synchronous archive deletion, while ungrouped low feedback
    retains its two-call remote-rating flow, local update, and archive cleanup.
    Grouped dry-run reports the group but leaves DB, files, and curl untouched.
- Changed files: `tests/run.sh`, `tests/fixtures/feedback-curl.sh`; this section
  of `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification:
  - `bash -n`, `shellcheck`, and `git diff --check` passed for both owned shell
    files.
  - Both new regressions passed end to end with a temporary Python-backed
    SQLite CLI shim after migrations 001-005. The shim run reported 63 passed / 4
    unrelated shim-compatibility failures.
  - The normal `bash tests/run.sh` reported 54 passed / 13 failed; all failures
    require SQLite because the configured provider cannot access Docker. The
    two new tests are among those environment-blocked failures.
- Blockers / handoff: No fatal decision or implementation blocker. Rerun the
  suite in the project image or with a functional SQLite CLI for authoritative
  native execution. The trace fixture is executable and deliberately supports
  only `/mytags` credential extraction and the rating API response needed by
  legacy low-feedback coverage.

## Decisions and blockers

- No fatal product decision was encountered.
- `archive_cleanup` uses stable internal desired value `delete`; favorite
  removal uses the plan-specified remote value `favdel`.
- The reporting-only worker intentionally leaves queued jobs untouched until a
  later phase implements their handlers.

## Verification ledger

- `git diff --check`: passed.
- `bash -n` on all changed shell entrypoints, libraries, API scripts, fixtures,
  and tests: passed.
- `shellcheck` on all changed shell files: passed.
- Host `bash tests/run.sh`: 66 passed / 1 host-provider failure because the
  Docker-backed sqlite3 shim consumes the tag-repair loop's stdin.
- Native project test image (`docker/Dockerfile`, target `test`): 67 passed / 0
  failed.
