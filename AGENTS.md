# Agent Instructions

## Project Context

- Read [docs/architecture.md](docs/architecture.md) before broad changes or when CLI, API, and database boundaries are unclear.
- Yomiko is a shell-based ExHentai/E-Hentai archive helper. `bin/yomiko` is the main interface; the BusyBox `httpd` CGI service is optional.
- `lib/path.sh` places runtime directories under `$HOME`, including `archived/`, `hath/`, `logs/`, `migrations/`, and `data/db.sqlite3`.

## Bug Triage

- For bug reports, first check whether the current system reproduces the issue or whether it is limited to legacy data left incomplete by an earlier migration.
- For legacy-data-only issues, prefer a one-time repair script and document that it must run after `docker compose down`.
- Change application code when the current system reproduces the bug.

## Architecture and Implementation

### CLI, API, and database

- The CLI owns access to the application SQLite database. For API features that need database-backed data, add or use a CLI command and call it from the API.
- Before an API script invokes `bin/yomiko`, call `middleware_cli_in_api_mode` so CLI logs do not corrupt CGI responses. Keep CORS handling in `web/api/_middleware.sh`.
- API scripts must emit CGI headers before response bodies and return JSON errors with an appropriate status. Public endpoints should call the CLI for shared business logic instead of duplicating it.
- Keep stdout reserved for documented machine-readable output. Send human-facing progress and diagnostics through `log` and `log_err` in `lib/common.sh`; they are quiet in API mode.
- Preserve `self_rating`, `feedbacked_at`, `rated_then_deleted_at`, and `hath_requested_at` when updating gallery metadata unless the change targets those fields.

### Shell and database changes

- Use `SCREAM_SNAKE_CASE` for top-level/script variables and `snake_case` for function-local variables. In `bin/yomiko`, source project files through `YOMIKO_ROOT` rather than `$HOME`.
- Use `set -euo pipefail` for executable Bash entrypoints when compatible with their behavior.
- Validate CLI/API inputs with allowlists before interpolating them into SQL or shell commands. Decode CGI query values before validating them.
- Put schema changes in ordered files under `migrations/`; keep initialization and migration application in `lib/db.sh`.
- Use the existing `db_query`/`db_query_json` helpers and SQLite parameters for user-controlled values.
- When adding sortable or filterable gallery fields, update CLI validation and any API validation that forwards those options.

## Shared Vocabulary and Product Projections

- Use [Yomiko Domain Language](docs/domain-language.md) as the normative source for domain terms and identifiers; follow its review checklist when changing schema or projections.
- Keep shared concepts semantically consistent across CLI, API, web, and metrics. Check the current contracts in [Architecture](docs/architecture.md) and the [metrics inventory](docs/metrics.md), plus the accepted decisions in [ADR-0001](docs/adr/0001-class-lifted-identity-review-projection.md), [ADR-0004](docs/adr/0004-userscript-local-state-hath-deduplication.md), and [ADR-0010](docs/adr/0010-pending-only-variant-review-surface.md). Cross-check an ADR's decision against later changes and explicit implementation gaps; do not treat historical context or old verification snapshots as current behavior.
- Product-facing outputs should describe user-relevant workflow states and decisions, not expose raw implementation flags, cached summaries, or transient worker lifecycle as product states. Metrics and database diagnostics may expose implementation details for operators when clearly identified as diagnostics and kept within the metrics' bounded-label rules.
- When changing a shared concept, compare its meaning and counts across CLI, API, web, and metric projections, then update the applicable documentation and tests. The projections may use different queries or views, but must satisfy the same semantic contract where outputs are intended to agree; for example, the actionable-review metric count must match the pending CLI/API queue.

## Development and Verification

- Use the `yomiko-playground` skill for migrations, tests, and code changes that need verification. Documentation-only changes do not require a playground.
- Follow the `yomiko-playground` skill description for current commands and invocation details. Keep only one playground running at a time; stop the prior one before creating another, and stop the active one when work is complete unless the user asks to keep observing it. Leave its directory in place.
- Keep `YOMIKO_REMOTE_WRITES_ENABLED=false` unless the user explicitly authorizes remote writes. Do not add a project-level `docker/docker-compose.debug.yaml` workflow; the skill owns its generated Compose file.

## Change Review

- Review the diff and nearby call paths before removing functions or tests. Check runtime, CLI, external, and dynamic references, preserve tests for live behavior, and rerun relevant checks.
- If cleanup surfaces specific renaming candidates, discuss them with the user after cleanup.
- For changes that could affect API response time, run `tests/bench-api-latency.sh` in an isolated playground and compare warm p95 with [ADR-0009](docs/adr/0009-external-interface-latency-budgets.md).
- For changes that could slow `db_write`, time representative writes and run the relevant writer-gate regression tests in a playground. Investigate new waits or holds of at least 1,000 ms using the diagnostics in [ADR-0002](docs/adr/0002-bounded-sqlite-writer-coordination.md).

## Checks

- Test observable behavior, data, I/O contracts, and domain rules; do not use substring checks of source or generated code to assert implementation details.
- For every new migration, test, or code change, run focused regression tests and then the complete suite in the playground. Use the skill's full-suite workflow, which runs the Dockerfile `test` target with dependencies such as `utf8proc-nfkc` that may be unavailable on the host. Run all tests and SQLite checks inside the playground; do not use host Bash or SQLite commands for testing.
- For shell changes, run relevant CLI checks and `shellcheck` when available. For API scripts, exercise representative CGI requests with `REQUEST_METHOD` and `QUERY_STRING` values when feasible.
- Do not check in runtime artifacts from `data/`, `logs/`, `archived/`, or Hath download output.
