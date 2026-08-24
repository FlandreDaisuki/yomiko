# Gallery Variant Feedback — Shared Progress

This file coordinates implementation of `GALLERY_VARIANT_FEEDBACK_PLAN.md`.
Every agent must read it before starting, update only its assigned section, and
record concrete findings, changed files, verification, blockers, and handoff
notes before its bounded work window ends.

## Coordination rules

- Coordinator: `/root`.
- Agent work window: at most 5 minutes per assigned task for every phase.
- Do not overwrite or revert another agent's edits.
- Do not guess about external behavior; record unknowns and verify against
  repository code or authoritative sources.
- Stop and mark `FATAL DECISION` if implementation depends on a product choice
  not settled by the finalized plan.
- Keep changes in small, independently verifiable slices.

## Current phase

The foundation, local scoring/evaluation, and review-interface milestones are
complete and user-reviewed in the isolated environment. CLI review
listing/resolution, CLI-backed CGI endpoints, and candidate/winner cards use
review IDs and gallery GIDs without exposing relational group IDs.

The independent discovery worker/scheduler handler is implemented in the
current staged milestone: fixed `matching_revision`, bounded normal/expunged
search, `gdata` and popularity refresh, atomic remote-candidate publication,
review creation, retry/continuation handling, stale-group scheduling, and local
evaluation dispatch. Remote actions, policy-sweep consumption, and retention
reconciliation remain later work. Multi-candidate presentation is confirmed
and implemented; the operational-policy boundary remains open but does not
block discovery persistence.

On 2026-08-24 the coordinator expanded the next phase into a schema, remote
adapter, matching, continuation, publication, dispatcher, dry-run, and test
contract in the main plan. The user confirmed Sørensen–Dice title similarity,
all-confirmed-member recurring seeds, continuation through every result page,
and manual review for every independently found in-scope candidate. Discovery
implementation is now authorized. The deferred operational-policy question
remains generally nonblocking for this phase. During worker contract drafting,
the coordinator found that the exact bounded authenticated popularity-detail
request count, exact creator-component formula, and exact creator/title query
construction were never specified. The user subsequently confirmed the
recommended `25`-detail budget, binary exact-overlap creator score, per-creator
queries, and longest-three title query. Official documentation plus public
read-only checks fixed minimum title terms at 2 Unicode code points for CJK and
3 for other scripts. No account cookie was used or persisted.

## Active implementation assignments (2026-08-09)

Every assignment has a maximum 5-minute effort window and must update only its
named progress subsection before handing back to `/root`.

### discovery_phase_planning

- Status: completed; implementation released (2026-08-24).
- Owner: `/root`.
- Findings:
  - The existing schema can represent coalesced jobs, leases, cursors, mutable
    membership projections, immutable evaluations, and pairwise reviews, but it
    cannot identify the fixed matching revision or durably separate an
    unfinished remote collection from the last completed discovery snapshot.
  - Migration 007 therefore needs explicit completed matching revision plus
    resumable discovery-run/candidate staging state. The active scoring
    policy's legacy matching JSON/hash remains audit compatibility only and
    must not drive the new discovery handler.
  - The current worker is reporting-only and must filter supported
    `discover`/`evaluate` jobs so already queued action and policy-sweep jobs do
    not starve this phase. The independent cron invocation, lock, and log are
    already present.
  - Official documentation confirms separate expunged search, disabled user
    filters, a three-second search limit, five inclusion terms/200 query
    characters, and `gdata` batches of at most 25. It does not settle the four
    product-level matching/search decisions recorded in the main plan.
- Changed files: `GALLERY_VARIANT_FEEDBACK_PLAN.md` and this subsection only.
- Verification: reviewed migrations 005/006, `lib/variants.sh`, `lib/exh.sh`,
  `bin/yomiko`, the scheduler/path wiring, tests, and current official EHWiki
  search/API contracts. No database or remote account state was changed.
- Blockers / handoff: All four Discovery matching/search answers are confirmed
  in the main plan. `/root` may create bounded, nonoverlapping `5.6 luna`
  assignments for schema/staging, read-only remote adapters, and pure
  matching/query logic while retaining worker integration and final
  verification.

### discovery_schema

- Status: completed (2026-08-24).
- Owner: `/root/discovery_schema` (`5.6 luna`).
- Scope: migration 007 only plus this subsection. Add fixed matching-revision
  persistence and durable discovery-run/candidate staging state with upgrade,
  uniqueness, revision-staleness, integrity, and foreign-key invariants. Do not
  edit migrations 005/006, runtime libraries, CLI, or shared tests.
- Findings:
  - Migration 007 adds nullable `variant_groups.completed_matching_revision`
    (pre-007 groups are revision-stale), non-null revision `1` backfill on
    published `gallery_variants`, and candidate-only `variant_reviews` revision
    persistence; winner reviews remain scoring evidence with NULL revision.
  - `variant_discovery_runs` durably stores group/job ownership, fixed revision,
    phase, cursor, lease/retry/error state, and completion state. Triggers
    require a matching `discover` job for the group. Partial indexes enforce
    one unfinished run per job and group, with work/group/stale-revision indexes.
  - `variant_discovery_candidates` stages deduplicated `(run_id,gid,token)`
    origins, gdata, popularity, evidence, and bounded work/error state. A
    trigger requires staged revision to equal the owning run revision; the run
    foreign key cascades abandoned staging safely.
- Changed files: `migrations/007_discovery_state.sql` and this subsection only.
- Verification: Applied migrations 001-007 to an in-memory Python SQLite
  database with foreign keys enabled; confirmed schema columns, `integrity_check`
  `ok`, empty `foreign_key_check`, unfinished-run uniqueness, discover-job
  ownership, and staged-revision constraints. Coordinator audit follow-up also
  exercised fresh and schema-006 upgrade paths with existing candidate/winner
  reviews (candidate backfilled to revision `1`, winner remained NULL), plus
  rejected empty tokens, non-array origins, non-object cursors, incomplete
  timestamps, and half-populated leases. `integrity_check` remained `ok`,
  `foreign_key_check` remained empty, and `git diff --check` passed. No project
  or production database was opened or migrated.
- Blockers / handoff: No blocker. Worker integration should use
  `completed_matching_revision`, `variant_discovery_runs`, and
  `variant_discovery_candidates`; run phase values are `seed_refresh`,
  `chain_walk`, `search`, `gdata`, `popularity`, and `publish`.

### discovery_remote

- Status: completed (2026-08-24).
- Owner: `/root/discovery_remote` (`5.6 luna`).
- Scope: read-only remote adapters in `lib/exh.sh`, new adapter fixtures owned
  by this assignment, and this subsection. Implement normalized paginated
  normal/expunged search, at-most-25 `gdata`, and popularity parsing without DB
  or filesystem mutation. Do not edit migrations, worker libraries, CLI, or
  `tests/run.sh`.
- Findings:
  - `lib/exh.sh` now exposes pure `exh_parse_search_response <html> <normal|expunged> [current-page]` returning `{mode,results:[{gid,token}],terminal,next_page}`; duplicate GID/token pairs are removed and invalid modes fail. `exh_search_gallery <query> <mode> [page]` is its read-only curl wrapper and always sends `f_sft`, `f_sfu`, and `f_sfl`; expunged additionally sends `f_sh`.
  - `exh_normalize_gallery_data_batch <requested-json> <response-json>` enforces at most 25 unique `[positive-integer-gid,nonempty-token]` pairs and returns per-entry `{gid,token,status:"ok",metadata}` or `{...,status:"error",error}`. `exh_api_get_gallery_data_batch <requested-json>` is the POST wrapper. Successful entries pass through the existing metadata validator; missing, malformed, and API-error entries remain visible.
  - `exh_parse_gallery_popularity <html> [fetched-at]` recognizes underscore/hyphen DOM IDs as well as text labels, returning nonnegative parsed `favorite_count`/`rating_count` or null values with bounded error evidence, plus the supplied fetch timestamp. `exh_get_gallery_popularity <gid> <token> [fetched-at]` is the authenticated detail-page read wrapper.
- Changed files: `lib/exh.sh`, `tests/fixtures/variant-discovery-remote/*`, and this subsection only.
- Verification: `bash -n lib/exh.sh tests/fixtures/variant-discovery-remote/smoke.sh`, `shellcheck -x lib/exh.sh tests/fixtures/variant-discovery-remote/smoke.sh`, standalone `tests/fixtures/variant-discovery-remote/smoke.sh`, and `git diff --check`; fixtures cover quoted search links/deduplication, page 0→1 and terminal pagination, gdata success/API error/missing entries and duplicate rejection, plus popularity success/missing counts. No SQLite, filesystem, or remote account state was changed.
- Blockers / handoff: None. Worker should call the parser/wrapper contracts above and treat `terminal:false` plus integer `next_page` as the continuation cursor. The gdata adapter preserves requested order and per-gallery failures.

### discovery_matching

- Status: completed (2026-08-24).
- Owner: `/root/discovery_matching` (`5.6 luna`).
- Scope: a new pure `lib/variant_matching.sh`, standalone matching fixtures or
  focused test script owned by this assignment, and this subsection. Implement
  confirmed query planning, normalization, Sørensen–Dice title scoring,
  creator/content/page components, contradictions, scope checks, and stable
  evidence JSON without DB/network mutation. Do not edit migrations,
  `lib/exh.sh`, worker libraries, CLI, or `tests/run.sh`.
- Findings: Added pure JSON contracts in `lib/variant_matching.sh`. Query
  planning consumes `{seeds:[metadata...]}` (or an array) and emits stable,
  deduplicated `{queries:[{query,origins}]}` with exact scope prefixes. Creator
  queries contain one exact `artist:`/`group:` tag (with `$`) per unique tag
  across all seeds. Title queries use up to three longest eligible distinct
  normalized terms from title/title_jpn, preserve volume/part tokens, and drop
  whole lowest-priority terms to stay within 200 characters. Scope emits the
  exact required-tag decision. Evidence
  consumes `{source,candidate,chain_gids?,origins?}` and emits official-chain
  versus independent/out-of-scope category, reviewability, 0-100 integer score,
  raw and normalized features, title/creator/content/page components,
  contradictions, and origins. Creator overlap is binary (30 or 0), with
  disjoint nonempty creators visible as a contradiction. Independently found
  in-scope candidates remain reviewable regardless of score.
- Changed files: `lib/variant_matching.sh`,
  `tests/fixtures/variant-discovery-matching/smoke.sh`, and this subsection.
- Verification: `bash -n`, ShellCheck, `git diff --check`, and standalone
  smoke tests for deterministic query output, scope, title
  Dice/bigram scoring, creator/content/page points, volume contradiction, and
  independent reviewability passed. No database, network, or filesystem data
  was accessed by the library.
- Blockers / handoff: Public functions are
  `variants_matching_plan_queries` (stdin `{seeds:[...]}` ->
  `{queries:[{query,origins:[...]}]}`), `variants_matching_scope_json`, and
  `variants_matching_evidence_json`; each reads JSON on stdin and writes one
  compact JSON document. The worker should pass all confirmed-member metadata
  as seeds and retain each query origin with returned candidates. No fatal
  product decision remains.

### review_cli

- Status: completed and integrated (2026-08-24).
- Owners: delegated draft `/root/review_cli`; integration and verification
  `/root`.
- Findings:
  - `variants reviews [--status pending|resolved]` emits enriched candidate and
    winner records with frozen evidence, gallery metadata/tokens, current
    archive state, and full score breakdowns. Relational group IDs are absent.
  - Candidate resolution rechecks pending membership in `BEGIN IMMEDIATE`,
    persists manual `+9999`/`-9999` evidence, and coalesces reevaluation.
    Same-book approval merges the exact active peer set into the older group,
    retains historical loser rows, selects the latest feedback intent, and
    cancels queued loser work.
  - Pending candidate reviews retained on an inactive merged group remain
    resolvable through the active survivor, keep survivor evaluation blocked,
    and queue survivor reevaluation when resolved.
  - Winner resolution validates the selected frozen choice and active
    evaluation, then creates an immutable completed evaluation with an explicit
    `manual_winner_override` component. The old blocked evaluation remains
    unchanged and action reconciliation is coalesced.
  - Stale/concurrent resolution has stable status `3`; all success payloads use
    JSON booleans and public review/gallery identities only.
- Changed files: `lib/variants.sh`, `bin/yomiko`, focused portions of
  `tests/run.sh`, and `tests/fixtures/reviews-yomiko.sh`.
- Verification: native Alpine SQLite tests cover enriched listing, same-book
  merge, different-book rejection, latest-intent selection, stale no-op,
  immutable winner override, canonical projection, and queued follow-up work.
- Blockers / handoff: No review CLI blocker. The matching boundary is confirmed;
  discovery worker/scheduler implementation is next.

### review_api

- Status: completed and integrated (2026-08-24).
- Owners: delegated draft `/root/review_api`; integration and verification
  `/root`.
- Findings:
  - `web/api/reviews.sh` is a read-only GET adapter for the review CLI with an
    allowlisted pending/resolved filter and strict public JSON validation.
  - `web/api/review_resolve.sh` is an authenticated PUT adapter. It validates a
    review ID, allowlisted decision, and winner-only GID before invoking the
    CLI; stable stale status maps to `409 Conflict` without leaking CLI output.
  - Both endpoints enter API mode before calling the CLI and never access
    SQLite directly.
- Changed files: `web/api/reviews.sh`, `web/api/review_resolve.sh`, focused
  portions of `tests/run.sh`, and `tests/fixtures/reviews-yomiko.sh`.
- Verification: method/input/authentication, malformed CLI JSON, private-error
  suppression, success forwarding, and stale conflict paths passed.
- Blockers / handoff: None.

### review_web

- Status: completed and integrated (2026-08-24).
- Owners: delegated draft `/root/review_web`; integration and verification
  `/root`.
- Findings:
  - The feedback page loads pending reviews alongside pending feedback and
    displays a live pending count. Feedback and review are separate tabs at the
    same URL with the same token; every load defaults to Feedback and does not
    persist tab selection.
  - Candidate cards render source/candidate titles, tags, page counts,
    separate expunged/archive states, cover thumbnails, token-aware gallery
    links, evidence components, contradictions, and same/different actions.
    Reviews sharing a feedback/source GID are grouped into one visual batch:
    the source renders once and every candidate remains independently
    resolvable.
  - Winner cards render every eligible choice, cover thumbnail, archive state,
    full persisted score breakdown, and an explicit canonical selection action.
  - Mutations reuse the existing localStorage bearer-token flow. Both success
    and stale/error paths refresh review state, with user-visible feedback.
- Changed files: `web/feedback.html` and focused portions of `tests/run.sh`.
- Verification: static frontend contract tests, CGI integration tests, and the
  full native project image passed.
- Blockers / handoff: None.

### gid_centric_public_interface

- Status: completed (2026-08-09).
- Owner: `/root`.
- Findings:
  - Gallery GIDs and review IDs are the public identity model. Relational
    variant-group IDs remain available to database and worker primitives but
    are no longer accepted by the public evaluation command or emitted by
    normal enqueue, list, work, evaluation, feedback CLI, or feedback CGI
    payloads.
  - `yomiko variants evaluate <gid>` resolves exactly one active group from
    either its source or any confirmed member. Missing or ambiguous active
    membership fails without evaluating an arbitrary historical group.
  - Review resolution can remain review-ID based, with a selected gallery GID
    for winner decisions; no planned review phase requires a public group ID.
- Changed files: `bin/yomiko`, `lib/variants.sh`,
  `lib/variant_scoring.sh`, `web/api/feedback.sh`,
  `tests/fixtures/feedback-result-yomiko.sh`, `tests/run.sh`,
  `GALLERY_VARIANT_FEEDBACK_PLAN.md`, `docs/architecture.md`, and this section.
- Verification:
  - `bash -n`, `shellcheck -x`, and `git diff --check` passed.
  - All database-backed variant tests and the focused feedback CGI tests
    passed with the Docker-backed SQLite provider, including confirmed-member
    GID evaluation and assertions that public payloads omit group IDs.
  - The full suite reported 71 passed and one unrelated failure in the existing
    tag-repair test: this host's Docker-backed `sqlite3` wrapper consumes the
    process-substitution input after the first repair row, while the native
    Alpine suite used by the project previously passed that test.
- Blockers / handoff: No blocker for the GID-centric interface. The next
  implementation milestone, when authorized, is review listing/resolution and
  web cards.

### score_schema_006

- Status: completed (2026-08-09).
- Owner: `/root/score_schema_006`.
- Findings:
  - Migration 006 adds nullable, nonnegative `favorite_count` and
    `rating_count` fields plus nullable `popularity_fetched_at`; null counts
    retain the required unavailable/unknown distinction for score breakdowns.
  - The migration preserves migration 005's immutable legacy policy row and
    hashes, deactivates it, and inserts the initial compact policy's canonical
    expanded representation as the sole active revision. The expanded content,
    matching, scoring, and operations hashes are fixed in the migration and
    aligned with `score_policy_lifecycle`'s expander contract.
  - The shared runtime/test base image now installs Python 3, providing full
    Unicode NFKC normalization plus `str.casefold()` for policy validation and
    title scoring; lowercase-only ICU transliteration was explicitly avoided.
- Changed files: `migrations/006_variant_scoring.sql`, `docker/Dockerfile`, and
  this subsection.
- Verification:
  - Applied migrations 001-006 to an in-memory Python SQLite database only; no
    real or project database was opened or migrated. Confirmed both policy rows
    remain, only the expanded row is active, the legacy scoring hash remains
    `70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69`,
    all four expanded hashes match recomputed canonical JSON, negative counts
    fail constraints, `foreign_key_check` is empty, and `integrity_check` is
    `ok`.
  - A Python smoke check proved NFKC plus case folding equates full-width
    `ＳＴＲＡＳＳＥ` with `Straße`; focused whitespace checks passed.
- Blockers / handoff: No blocker. The policy loader/expander must reproduce
  migration 006's exact canonical expanded bytes and hashes, including
  `title_normalization: "NFKC_Casefold"`; Docker image build remains for the
  coordinator's integrated verification.

### score_policy_lifecycle

- Status: completed (2026-08-09).
- Owner: `/root/score_policy_lifecycle`.
- Findings:
  - The exact expanded format preserves migration 005's matching and operations
    sections, adds top-level `format_version: 1`, and replaces scoring with the
    compact tag/title/posted projection plus explicit fixed popularity,
    confidence, normalization, expunged, and manual-winner behavior.
  - ICU `uconv` lowercasing is not Unicode case folding (`Straße` is the
    counterexample). Validation therefore uses the Python 3 Unicode database
    supplied by migration 006's Docker dependency for NFKC plus `casefold()`.
  - The initial canonical hashes reproduce migration 006: compact
    `22ec640858bb6f3df2446869df29c5fc9634e1d3a7da84c72f5761b97dcaf0c3`,
    expanded `da687dc4a0474cec0e02f2005144864e8e655533bfba6b525209e92f2d4e560f`,
    matching `a5b5228c5df4491ce150e5d8b9845804c0328b1571810bda082cdb973470c18e`,
    scoring `6a6e344ae547ba271252717a3e983b04e0e7e1b6df38f4e4664ff828bb6af2e0`,
    operations `7d0ce0dbf170349516910705288f226b21e891a95f59623a3a21b96a2087200d`.
- Changed files: `lib/variant_policy.sh`, `variant-policy.example.json`, and this
  subsection.
- Verification:
  - `bash -n`, `shellcheck -x`, `git diff --check`, canonical hash generation,
    preservation of full-width title keys in the compact import, and
    NFKC/casefold collision rejection passed.
  - Database activation smoke testing was unavailable because this host's
    `sqlite3` wrapper requires Docker daemon access; the coordinator should run
    activation/no-op/coalescing tests in the project container.
- Handoff:
  - Source `common.sh`, `db.sh`, then `variant_policy.sh`. Public primitives are
    `variants_policy_show [--pretty] [--expanded]`,
    `variants_policy_check <path|->`, `variants_policy_activate <path|->`, and
    `variants_policy_load_active` (returns canonical JSON with `revision_id`,
    hashes, and `.policy`). Check/activate emit stable compact JSON; stdout is
    payload-only and diagnostics go through API-aware `log_err`.
  - Activation performs lookup/reuse, active switching, and one global
    scoring-sweep coalescing in `BEGIN IMMEDIATE`; already-active content is a
    successful no-op. Legacy migration-005 rows remain readable for audit but
    intentionally fail the executable loader; migration 006 supplies the active
    expanded-format row.

### score_evaluator

- Status: completed (2026-08-09).
- Owner: `/root/score_evaluator`.
- Scope: implement deterministic confirmed-member scoring and immutable
  evaluation persistence, including NFKC/casefold title matches, posted ranks,
  popularity formulas, breakdowns, natural winner, and tie review. Own a new
  scoring library plus this subsection; do not edit `bin/yomiko`, migration
  files, or tests.
- Findings:
  - Public integration contract: source `lib/variant_scoring.sh` after
    `lib/db.sh`; call `variants_evaluate_group <group_id>
    [expected-active-policy-revision-id]`. Success emits one compact JSON
    summary with `evaluated`, group/evaluation/policy IDs, state, canonical,
    tied GIDs, and top score. A pending candidate review emits a stable blocked
    JSON result and returns status `VARIANTS_EVALUATION_REVIEW_BLOCKED_STATUS`
    (`4`).
  - `variants_score_members_json` is the pure JSON scoring seam. It consumes
    the active expanded policy shape and confirmed metadata snapshots, uses
    Python `unicodedata.normalize("NFKC", value).casefold()` for full Unicode
    folding, ranks distinct non-null posted timestamps with ties, and applies
    exact additive tag/title, favorite, and rating-confidence components.
  - Complete raw/null metadata, normalization results, matches, formulas,
    component points, subtotals, and totals are retained. Expunged state is
    visible and neutral. Member/evaluation JSON ordering is deterministic.
  - Persistence rechecks the active revision, pending candidate reviews, the
    confirmed GID set, and exact stored snapshot text inside one immediate
    transaction before inserting an immutable evaluation. A unique winner is
    projected canonical/alternate; a top-score difference below `5` clears the
    mutable canonical projection and creates a frozen winner review.
- Changed files: `lib/variant_scoring.sh`; this subsection of
  `.agents/GALLERY_VARIANT_FEEDBACK_PROGRESS.md`.
- Verification:
  - `bash -n lib/variant_scoring.sh`, `shellcheck lib/variant_scoring.sh`, and
    `git diff --check -- lib/variant_scoring.sh` passed.
  - The pure scorer fixture verified exact-tag addition, `Straße`/`STRASSE`
    full casefold equivalence, distinct posted ranks, favorite/rating floor
    formulas, null count zeroes, and neutral visible expunged state.
- Blockers / handoff:
  - Runtime dependencies are `jq` and `python3`; the schema/package slice is
    adding Python to runtime and test images. The evaluator consumes the policy
    lifecycle slice's exact `.policy.scoring` expanded shape.
  - End-to-end SQLite persistence could not run locally because this checkout's
    `sqlite3` executable is a Docker wrapper and its daemon is unavailable.
    Coordinator tests should cover completed and tied transactions, immutable
    history, pending-candidate no-mutation behavior, and race-guard rollback.

### score_integration_tests

- Status: completed (2026-08-09).
- Owner: `/root`.
- Findings:
  - Wired policy and scoring libraries into `bin/yomiko`; added `evaluate`,
    `policy-show`, `policy-check`, and `policy-activate` dispatch and help.
  - Source feedback snapshots now include rating/popularity inputs, and gallery
    listing accepts the new normalized popularity columns for ordering.
  - Evaluation validates the active expanded policy before scoring. Native
    verification corrected two test assertions: completed evaluations freeze
    every confirmed member, and tied reviews persist their full choice array.
  - Documentation distinguishes implemented local policy/scoring behavior from
    pending discovery, worker handlers, remote actions, retention, and web UI.
- Changed files: `bin/yomiko`, `lib/variants.sh`, `lib/variant_scoring.sh`,
  `tests/run.sh`, `README.md`, `docs/architecture.md`, and this subsection.
- Verification:
  - `bash -n`, `shellcheck`, and `git diff --check` passed for changed shell
    files.
  - The native Alpine test image passed all 71 tests, including migration 006,
    policy preview/activation/no-op/coalescing, score formulas, persisted unique
    winners, exact-tie reviews, and near-tie reviews.
- Blockers / handoff: No scoring implementation blocker. The real database was
  not copied, opened, or migrated. Policy scoring sweeps remain durable queued
  intent until a later worker-handler phase consumes them.

### score_tests

- Status: completed (2026-08-09).
- Owner: `/root/score_tests`.
- Findings:
  - Fresh-schema coverage now expects schema v6, the preserved inactive legacy
    revision and its fixed scoring hash, one active expanded revision, nullable
    popularity columns, and nonnegative count constraints. The explicit
    schema-004-to-005 upgrade expectation remains v5.
  - Compact policy regressions cover strict keys/types/ranges/tag syntax,
    stable canonical hashes across whitespace/key order, preservation of
    original title keys, and NFKC/casefold duplicate rejection.
  - Lifecycle regressions verify preview does not mutate, activation inserts or
    reuses immutable revisions, an already-active policy is a no-op, and
    repeated scoring changes coalesce to one queued sweep.
  - Score regressions cover exact tag matching, one Unicode substring
    contribution across both title fields, posted ties, formula floors/caps and
    NULL evidence, expunged neutrality, unique-winner persistence, immutable
    evaluations, and exact/near-tie winner-review creation.
- Changed files: `tests/run.sh` and this subsection.
- Verification:
  - `bash -n tests/run.sh`, `shellcheck tests/run.sh`, and `git diff --check`
    passed.
  - Pure policy/scoring checks passed with expected scores `112`, `1004`, and
    `4`; an in-memory Python SQLite application of migrations 001-006 passed
    revision, legacy compatibility, column, and negative-count checks.
  - The full database-backed shell suite could not run because this host's
    `sqlite3` command is a Docker-backed wrapper and the Docker daemon is not
    accessible. No real or project database was opened or migrated.
- Blockers / handoff: No implementation blocker. Coordinator should run
  `bash tests/run.sh` in the project container to exercise activation and
  persisted evaluation paths with the SQLite CLI.

### near_tie_review_update

- Status: completed (2026-08-09).
- Owner: `/root`.
- Findings:
  - Winner review now uses the user-confirmed exclusive score-gap rule `< 5`.
    Every member within that distance of the top score is frozen as a choice;
    a gap of exactly `5` remains an automatic result.
  - The compact policy shape is unchanged. Expanded fixed behavior now stores
    `winner_review_score_gap_exclusive: 5`; migration 006 and runtime expansion
    share content hash `da687dc4a0474cec0e02f2005144864e8e655533bfba6b525209e92f2d4e560f`
    and scoring hash `6a6e344ae547ba271252717a3e983b04e0e7e1b6df38f4e4664ff828bb6af2e0`.
  - Winner-review evidence records the reason (`exact_tie` or `near_tie`),
    runner-up score, actual gap, exclusive threshold, choices, and complete
    member scores.
  - The next implementation phase explicitly includes CLI review list/resolve,
    authenticated CGI endpoints, and candidate/winner cards in the feedback
    page.
- Changed files: `GALLERY_VARIANT_FEEDBACK_PLAN.md`,
  `migrations/006_variant_scoring.sql`, `lib/variant_policy.sh`,
  `lib/variant_scoring.sh`, `tests/run.sh`, `README.md`,
  `docs/architecture.md`, and this subsection.
- Verification:
  - `bash -n`, `shellcheck`, canonical expanded/section hash checks, and
    `git diff --check` passed.
  - Native Alpine suite: 72 passed / 0 failed. Coverage proves gaps `0` through
    `4` review, gap `5` automatically selects, and persisted evidence/choices
    match the score result.
  - Rebuilt the disposable migration-006 fixture database from the previously
    fetched 16-gallery snapshots. The `2785447` group now has no canonical,
    `winner_pending` state, and one review choosing between `1850435` (1102)
    and `2275636` (1099), with reason `near_tie` and gap `3`.
- Blockers / handoff: Review resolution is intentionally next-phase work; the
  current phase creates and exposes durable pending review state but cannot yet
  select a winner through CLI or Web.

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
- 2026-08-09: Recorded four additional user-confirmed same-book GID groups and
  one similar-title negative fixture in the plan. Confirmed that
  `~/docker/yomiko/data/db.sqlite3` exists and the project `data/db.sqlite3` is
  an empty ignored placeholder; no database was copied or migrated.
- 2026-08-09: Finalized the operator-facing compact scoring document, fixed
  matching/operations boundary, import-preview-activation flow, popularity
  formulas, missing-data behavior, and Unicode comparison requirement. Favorite
  score uses floor; ExHentai average rating uses the stored `rating` field.
- 2026-08-09: Implemented and natively verified migration 006, compact policy
  lifecycle, and deterministic local scoring/evaluation.
- 2026-08-09: User set the following phase order: review interfaces; matching
  policy refinement with hard-coding/no-hash as an option; operational policy
  refinement with the same option; then discussion of replacing Python for
  NFKC comparison and scoring. These are sequential checkpoints rather than one
  combined implementation phase.
- 2026-08-09: Corrected the current public identity boundary: gallery GIDs and
  review IDs are user-facing, while variant-group IDs are internal relational
  keys. Public evaluation now resolves an active group from a GID, and normal
  enqueue/list/work/evaluation/feedback payloads omit group IDs.
- 2026-08-24: Implemented review listing/resolution through CLI and CGI plus
  candidate/winner cards in the existing feedback page. Native Alpine
  verification passed 78 tests with SQLite-backed merge, rejection, immutable
  winner override, stale conflict, API, and page coverage.
- 2026-08-24: Began the confirmed discovery phase. Migration 007, read-only
  remote adapters/fixtures, and worker scheduling/lease/retry/local-evaluation
  primitives are implemented in the working tree. Coordinator review found
  three formerly implicit decisions still needed before integrating discovery:
  popularity detail-page budget, binary versus proportional creator scoring,
  and exact creator/title query construction. These are recorded in the main
  plan; the pure matching draft is not accepted until they are confirmed.
- 2026-08-24: Integrated the discovery handler after all seven user decisions.
  The five-minute scheduler now dispatches bounded durable discovery and local
  evaluation; publication is atomic, preserves local gallery fields and manual
  labels, routes independent matches to review, and schedules annual revision.
  Luna's read-only audit findings were resolved with lease-guarded staging,
  zero-row transition failures, preserved retry backoff, empty-search handling,
  and strict complete-batch validation.
- Next milestone: confirm and implement the operational worker boundary for
  policy sweeps, remote rating/favorite actions, H@H replacement, and archive
  retention reconciliation.

## Completed phase: compact policy specifications and scoring implementation

- Status: implemented and verified on 2026-08-09 after explicit user
  authorization.
- Goal: define a decision-complete compact policy format, deterministic expanded
  database representation, lifecycle CLI, migration compatibility, scoring
  inputs, and acceptance contract for later implementation agents.
- Current source of truth: `GALLERY_VARIANT_FEEDBACK_PLAN.md` and this section.
  The superseded full-policy memo that follows is preserved only as historical
  context and must not be used as the implementation contract.

### Agreed compact operator policy

```json
{
  "format_version": 1,
  "tag_scores": {
    "other:full color": 100,
    "other:uncensored": 100
  },
  "title_substring_scores": {},
  "posted_rank_step": 1
}
```

- Operators may edit only exact tag scores, title-substring scores, and the
  relative `posted` rank step. Tag/title values are signed integers from
  `-1000` through `1000`; initial title rules are empty.
- Exact tag and title rules add independently. Each title rule contributes at
  most once per gallery across `title` and `title_jpn` after NFKC normalization
  and Unicode case folding.
- Add a full Unicode normalization dependency to runtime and test images;
  ASCII-only case conversion does not satisfy the contract.
- Hard-code the required `language:chinese` and `other:tankoubon` scope, manual
  match `+9999`/`-9999`, reviewed-winner `+9999`, exclusive winner-review gap
  `5`, scoring formulas/caps, and all
  operational limits outside the editable policy.

### Fixed scoring and metadata contract

- Favorite points:
  `floor(min(favorite_count / 10, 500))`.
- Rating-confidence points:
  `floor(min(max((rating - 3) * rating_count / 2, 0), 500))`, where `rating`
  is the existing ExHentai average-rating column.
- Posted points: `rank * posted_rank_step`; oldest distinct timestamp has rank
  `1`, newer distinct timestamps increment the rank, and equal timestamps share
  a rank.
- Missing favorite/rating counts contribute zero but retain null raw values and
  visible fetch/parse evidence in snapshots and score breakdowns.
- A future migration 006 adds `favorite_count`, `rating_count`, and
  `popularity_fetched_at`. Authenticated gallery-detail parsing supplies the two
  counts through bounded continuation/retry work.
- Do not edit migration 005. Preserve its active legacy revision and hashes;
  its correct scoring hash is
  `70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69`.
  The policy specs must define how migration 006 and the loader transition from
  that legacy full policy to the new expanded representation.

### Lifecycle and hashing contract

- The external file is an import/export surface. Workers read only the active
  immutable expanded revision in `variant_policy_revisions`.
- Canonicalize compact and expanded JSON recursively by object key with no
  trailing newline before SHA-256. Whitespace and object-key order do not change
  identity.
- `policy-show [--pretty]` exports compact policy; `--expanded` exports the
  stored internal representation. `policy-check <path|->` previews without
  mutation. `policy-activate <path|->` revalidates and atomically activates.
- Activation reuses identical immutable content, treats already-active content
  as a no-op, and coalesces one global scoring sweep. Version one has no
  dedicated rollback command; saved older compact files use normal activation.
- Favorite categories remain deployment environment variables and never enter
  either compact or expanded policy content.

### Policy specification slices

1. Specify the compact JSON schema, strict validation errors, Unicode-normalized
   key uniqueness, and compact canonical hash.
2. Specify the exact expanded JSON shape, fixed-field values, section hashes,
   and compact-to-expanded mapping.
3. Specify stable JSON stdout for show/check/activate, stdin behavior,
   no-mutation preview, activation transaction, and scoring-sweep coalescing.
4. Specify migration 006, legacy migration-005 compatibility, popularity
   metadata provenance, missing/error snapshots, and loader version handling.
5. Specify component-level score breakdowns and acceptance fixtures for exact
   tags, Unicode titles, posted ties, formula caps/rounding, and missing counts.
6. Convert the approved specifications into bounded multi-agent implementation
   assignments without altering the completed historical assignment records.

### Specification acceptance gate

- No implementer must choose a JSON field, default, validation range, hashing
  input, migration/legacy behavior, CLI output field, rounding rule, Unicode
  behavior, or error outcome.
- The confirmed same-book fixture groups and negative GID remain the score and
  matching review corpus; a top-score difference below `5` requires review.
- The real-database rehearsal remains limited to a consistent copy and requires
  explicit user permission. The source database must never be migrated.

### Open questions

None.

## Superseded phase memo: original full-policy lifecycle proposal

This memo is intentionally preserved as implementation history. Its editable
matching/scoring/operations design was replaced by the compact scoring-only
contract above and must not guide new work.

- Status: design review; not authorized for implementation.
- Goal: turn the policy seeded by migration 005 from inert database data into a
  validated, operator-manageable, revisioned input that later worker handlers
  can consume deterministically.
- Source-of-truth rule: the active row in `variant_policy_revisions` is
  authoritative. A JSON file is only an import/export and editing format; the
  worker must never watch a mutable file or treat it as live configuration.

### Gates before implementation

- Discuss why the current policy JSON feels too complex and decide which fields
  an operator actually needs to edit.
- Agree whether updates replace the whole policy document or target individual
  sections, plus activation, rollback, validation, and work-routing behavior.
- Use the newly confirmed GID groups and negative fixture to evaluate the
  proposed matching/scoring policy and expose full score breakdowns. The exact
  minimum score gap for decisive evidence is still open.
- After the user grants edit/test permission, copy
  `~/docker/yomiko/data/db.sqlite3` to the project's ignored `data/db.sqlite3`
  while the source is quiescent, or create an equivalent SQLite-consistent
  backup, and test migrations only on that copy. Confirm the schema version,
  integrity, foreign keys, and preservation of existing gallery/feedback rows;
  do not modify the source database.
- Begin policy implementation only after the preceding decisions and explicit
  edit permission.

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
  - scoring: `70119b24d58ec197f22b5fa079fc5b8760b6694e7958ffdff7e1c011fd4b5f69`
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
  `migrations/005_*.sql` plus this section. Work window: 5 minutes.
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
  in `tests/run.sh`, and this section. Work window: 5 minutes.
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
  relevant fixture copies, and this section. Work window: 5 minutes.
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
  that never consumes unsupported jobs. Work window: 5 minutes.
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
  `tests/run.sh` without changing implementation files. Work window: 5
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
  metadata upsert, `web/api/feedback.sh`, and this section. Work window: 5
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
  additions to `tests/run.sh`, and this section. Work window: 5 minutes.
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
  section. Work window: 5 minutes.
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
  if needed, and this section. Work window: 5 minutes.
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
  `lib/variants.sh` only. Own that library and this section. Work window: 5
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
  window: 5 minutes.
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
  window: 5 minutes.
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
  section. Work window: 5 minutes.
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

### operational_worker_coordination

- Status: implemented and verified (2026-08-24).
- Owner: `/root`; bounded drafts from `/root/operational_schema_impl`,
  `/root/remote_actions_plan`, and `/root/retention_sweep_plan` (`5.6 luna`).
- Schema/claim/sweep assignment:
  - Added migration 008 with scoring revision targets, action leases and error
    classifications, winner-review supersession evidence, operational indexes,
    and consistency triggers. Pre-008 in-flight actions upgrade to uncertain
    retryable state.
  - Generalized claims to all five supported job types and implemented
    revision-bound 100-group scoring sweeps with cursor reset on activation
    races.
- Remote-action assignment:
  - Added rating, favorite/favdel, and H@H adapters with stable result JSON,
    login/authentication detection, transport/HTTP/API classification, rating
    JSON validation, and response/token redaction fixtures.
  - Favorite and H@H retain compatible HTTP-200 non-login success semantics.
    Results record whether a mutation request was actually sent so only those
    requests consume the 25-call budget.
- H@H/retention assignment:
  - Added shared per-GID H@H locks, same-GID tree detection without requiring
    `galleryinfo.txt`, safe regular-file gates, rename-to-retention handoff, and
    startup repair of the rename/enqueue crash window.
  - Cleanup preserves stale/missing paths as visible evidence and writes
    `rated_then_deleted_at` only after actual deletion. Manual and worker H@H
    success update the request timestamp and applicable action atomically.
- Coordinator integration:
  - Added current-intent action projection, fixed rating → favorite → H@H →
    cleanup execution, global 25-mutation enforcement, retries, configuration
    recovery, successful-state carry-forward, and unmetered completion of all
    claimed local cleanup.
  - Expanded `variants work --dry-run` with public job identities, archive/H@H
    preflight, separate remote/local budgets, errors, and continuation without
    taking the worker lock or changing DB/files/remote state.
  - Updated policy activation, review supersession presentation, CLI archive
    and H@H integration, README, architecture, and the main plan.
- Verification:
  - `bash -n`, `shellcheck -x`, and `git diff --check` pass.
  - Native Alpine test image reports 85 passed / 0 failed, including 100-group
    sweep/race and 25-call cap regressions plus remote/retention fixtures.
  - Disposable schema-007 → 008 rehearsal converted an in-flight action to
    `retryable_error|uncertain`, backfilled scoring revision `2`, returned
    `integrity_check=ok`, zero foreign-key violations, and rejected a scoring
    target on a non-scoring job.
- Production safety: no production database, copy, archive, or remote account
  mutation was accessed. No files were staged or committed. Existing unrelated
  untracked files remain untouched.
- Blockers / handoff: no operational product decision or release blocker
  remains. Python Unicode/scoring replacement remains the next separate design
  checkpoint.

## Decisions and blockers

- Resolved 2026-08-09: the former `FATAL DECISION` about policy complexity and
  updates is replaced by the compact scoring-only import/preview/activation
  contract in the current phase memo.
- Scoring implementation and dependency edits were explicitly authorized and
  completed. The copied real-database migration rehearsal still requires
  separate permission and was not performed.
- `archive_cleanup` uses stable internal desired value `delete`; favorite
  removal uses the plan-specified remote value `favdel`.
- The reporting-only worker intentionally leaves queued jobs untouched until a
  later phase implements their handlers.

## Verification ledger

- 2026-08-09 plan/progress synchronization: recorded favorite-score flooring,
  standardized the ExHentai average-rating field name as `rating`, required full
  Unicode normalization support, and preserved the superseded phase memo and
  every completed agent assignment.
- 2026-08-09 documentation update: `git diff --check` passed; no database was
  copied, opened for migration, or modified.
- `git diff --check`: passed.
- `bash -n` on all changed shell entrypoints, libraries, API scripts, fixtures,
  and tests: passed.
- `shellcheck` on all changed shell files: passed.
- Host `bash tests/run.sh`: 66 passed / 1 host-provider failure because the
  Docker-backed sqlite3 shim consumes the tag-repair loop's stdin.
- Native project test image (`docker/Dockerfile`, target `test`): 67 passed / 0
  failed.
- 2026-08-09 scoring milestone native project test image: 71 passed / 0 failed.
  Host suite: 56 passed / 15 environment failures, all requiring the host's
  unavailable Docker-backed SQLite provider.
- 2026-08-09 near-tie update native project test image: 72 passed / 0 failed;
  disposable four-group migration/scoring rerun: schema 6, integrity `ok`, zero
  foreign-key violations, four evaluations, one pending near-tie review.
- 2026-08-24 review-interface milestone: `bash -n`, `shellcheck -x`, and
  `git diff --check` passed. Host non-database/API/static suite and the native
  Alpine SQLite suite both reported 78 passed / 0 failed.
- 2026-08-24 user-authorized review environment: created a transactionally
  consistent SQLite backup from the running production container, copied it to
  `/tmp/yomiko-review-test-env`, migrated only that disposable copy from schema
  4 to 6, and verified `integrity_check=ok` with no foreign-key violations.
  Production data was not migrated or modified. The isolated localhost web/CLI
  environment contains one candidate and one winner review fixture.
- 2026-08-24 user review outcome: review `1` rejected GID `3159956` as
  `different_book`, persisted manual match score `-9921`, and queued local
  evaluation for source GID `2785447`. Review `2` selected GID `2785385` as
  canonical, retained the blocked evaluation, created its immutable completed
  successor, and queued action reconciliation. No pending reviews remain;
  `integrity_check` is `ok` with no reported foreign-key violations.
- 2026-08-24 grouped-review fixture: the user selected layout A. The page now
  renders feedback source GID `2275636` once above independent candidate tiles
  for `3159956`, `2785447`, `1866032`, `1850435`, and `1776212`. Authenticated
  search was used read-only to obtain three missing public gallery tokens; the
  production cookie jar was neither copied nor persisted. The disposable DB
  contains one Archived and four Not Archived candidates, five real covers and
  five pending pairwise reviews. The native suite remains 78 passed / 0 failed,
  public API output omits group IDs, and `integrity_check` is `ok` with no
  reported foreign-key violations.
- 2026-08-24 grouped rematching/canonical outcome: the user confirmed same-book
  membership for GIDs `2785447`, `1866032`, `1850435`, and `1776212`, rejected
  `3159956`, and completed winner review `8` by selecting `2275636`. Blocked
  evaluation `3` remains immutable; completed successor `4` applies the manual
  `+9999` override, projects `2275636` as canonical with score `10099`, marks
  the other four confirmed members alternate, and queues action reconciliation.
  The reporting-only worker leaves its evaluate/reconcile jobs queued, directly
  motivating the next worker-handler phase. `integrity_check` remains `ok` with
  no reported foreign-key violations.
- 2026-08-24 discovery phase partial verification: migration 007 standalone
  fresh/schema-006 checks, remote adapter fixture smoke tests, `bash -n`,
  `shellcheck -x`, and `git diff --check` passed. The integrated host suite now
  reports 79 passed / 0 failed, including stale-revision scheduling, atomic
  claims, retry delays, expired leases, permanent-failure visibility,
  unsupported-job non-starvation, and local evaluation dispatch. No production
  database, live ExHentai request, remote mutation, or archive mutation was
  performed.
- 2026-08-24 discovery handler integration: the host/native SQLite suite reports
  82 passed / 0 failed. Coverage now includes every resumable phase through
  atomic publication, official-chain auto-confirmation, independent candidate
  review creation with frozen source/candidate covers and evidence, local-field
  preservation, stale-lease rejection, retry-backoff preservation, empty search
  pages, strict gdata batches, and matching/remote fixtures. `bash -n`,
  `shellcheck`, and `git diff --check` pass. Production data and authenticated
  ExHentai state were not read or modified.

## Discovery audit

- 2026-08-24 read-only audit: the discovery implementation is still partial;
  `lib/variant_discovery.sh` is not sourced by `bin/yomiko`/`tests/run.sh`,
  `variants_work` remains reporting-only, and there is no top-level discovery
  dispatcher or `publish` phase yet. Therefore no durable run can currently
  reach the staged-candidate-to-review transition.
- Lease ownership is not enforced consistently. `variants_discovery_stage_candidate`
  and `variants_discovery_store_gdata_entry` update rows using only `run_id`,
  and `variants_discovery_set_phase` does not assert that one row was updated.
  If a lease expires during a remote call, a stale worker can still mutate
  staging or continue after losing the lease. Worker claim/complete/retry/fail
  helpers also return success with zero affected rows for a stale owner; callers
  can report success without having changed the job.
- Retry backoff can be bypassed: `variants_worker_schedule_discovery` updates
  every queued due discovery job's `available_at` to now, including jobs whose
  run is `retryable`. Since the group remains stale until publish, a scheduler
  tick can immediately undo the 300/900/3600/21600/86400-second backoff.
- `exh_parse_search_response` builds `rows` from an unguarded `rg` pipeline.
  With `set -o pipefail`, a valid empty-result page makes `rg` exit 1 and the
  parser fails instead of returning `results:[]`; empty normal/expunged search
  pages need a regression fixture. The gdata phase similarly does not validate
  `.entries` before a process-substitution loop, so malformed/short responses
  can leave candidates pending indefinitely.
- Migration 007 has useful revision/ownership/referential constraints, but it
  does not constrain run/candidate status and lease pairing, nor does it enforce
  that staged candidate writes belong to the currently leased job. Add tests
  for stale-owner writes, zero-row worker transitions, retry-backoff scheduling,
  empty search pages, malformed/short gdata responses, and migration integrity
  after each rejected mutation.

### Discovery audit follow-up — 2026-08-24

- The previously reported integration/lease/backoff/empty-page issues are now
  addressed. `bash tests/run.sh` passes 82/82, including publish atomicity,
  bounded-phase resumption, stale-owner rejection, and retry-backoff
  preservation.
- One release-level behavior remains to verify/fix: publication automatically
  confirms an `official_chain` candidate only when that GID is not already
  confirmed in another active group. If it is already confirmed elsewhere, the
  code leaves a candidate review instead of applying the plan's direct-chain
  bypass / older-group merge invariant. This case has no integrated test.
- The documented dry-run contract says remote reads are permitted while all
  mutations are suppressed, but `variants_work --dry-run` currently only lists
  queued DB rows and performs no discovery reads. This is a contract gap if
  dry-run is intended to preview a real discovery snapshot.
- No other release-blocking issue was found in the exercised path. The
  process-substitution error paths in evidence/search iteration remain useful
  hardening tests, but validated adapters and the integrated suite currently
  cover the normal path.

### Coordinator resolution of audit follow-up

- The cross-group official-chain case is intentionally reviewable, not an
  automatic merge. Plan section C.5 explicitly requires a candidate already
  confirmed in another active group to remain reviewable so the existing
  manual `same_book` decision can use the older-group merge path. This avoids
  merging two user-confirmed groups without a human decision.
- Plan section F.4 says dry-run *may* perform bounded remote reads; it does not
  require them. The implemented dry-run takes no lease and performs no remote,
  database, or filesystem mutation, and now reports both runnable supported
  jobs and annual/revision-stale groups that do not yet have a queued job.
- Inactive groups are now cancelled both before scheduler claims and when a
  leased continuation observes a downgrade/merge. The final host checks and
  native Alpine image both pass 82/82, with `bash -n`, `shellcheck`, and
  `git diff --check` clean. No remaining release blocker was accepted.
