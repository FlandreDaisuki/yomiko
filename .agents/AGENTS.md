# Agent Instructions

## Project Context

- `docs/architecture.md` is the project big-picture reference. Read it before broad changes or when the CLI/API/database boundaries are unclear.
- Yomiko is a shell-based ExHentai/E-Hentai archive helper. The CLI at `bin/yomiko` is the primary interface; the BusyBox `httpd` CGI web service is optional.
- Runtime paths are defined in `lib/path.sh` under `$HOME`, including `archived/`, `hath/`, `logs/`, `migrations/`, and `data/db.sqlite3`.

## Subagent Budget

- Every subagent assignment has a maximum five-minute work credit. Scope each
  assignment so it can finish, verify, and hand back within that limit.
- A follow-up assignment starts a new five-minute credit only when the
  coordinator explicitly sends it; subagents must not extend their own window.

## Architecture Rules

- Only the CLI should manipulate or query SQLite directly. If an API endpoint needs DB-backed data, expose it through a CLI command and have the API call the CLI.
- CLI commands are used by terminal users and CGI scripts. Keep stdout reserved for documented machine-readable payloads when a command emits JSON or another structured format.
- Human-facing progress and diagnostics should use `log` and `log_err` from `lib/common.sh`; these stay quiet when `YOMIKO_CLI_IN_API_MODE=1`.
- API scripts should call `middleware_cli_in_api_mode` before invoking `yomiko` so CLI logs do not corrupt JSON responses.
- Preserve existing feedback fields such as `self_rating`, `feedbacked_at`, `rated_then_deleted_at`, and `hath_requested_at` when updating gallery metadata unless the change explicitly targets them.

## Bash Style

- Use `SCREAM_SNAKE_CASE` for top-level/script variables and `snake_case` for function-local variables.
- Prefer project-root-relative sourcing in `bin/yomiko` via `YOMIKO_ROOT` rather than `$HOME` so local checkouts and containers behave the same.
- Use `set -euo pipefail` for executable Bash entrypoints when compatible with the script.
- Validate CLI/API inputs with allowlists before interpolating values into SQL or shell commands.
- For URL query handling in CGI scripts, decode percent-encoded parameter values before validation.

## Database And Migrations

- Put schema changes in ordered files under `migrations/`.
- Keep `lib/db.sh` responsible for initialization and migration application.
- Prefer SQLite parameters through existing `db_query`/`db_query_json` helpers for user-controlled values.
- When adding sortable/filterable gallery fields, update both CLI validation and any API validation that forwards those options.

## Web/API Notes

- API scripts live in `web/api/` and should return CGI-style headers before bodies.
- Return JSON errors with a suitable status string; avoid leaking CLI progress output into response bodies.
- Keep CORS behavior centralized in `web/api/_middleware.sh`.
- Public endpoints generally call `bin/yomiko` instead of duplicating business logic.

## Variant Matching Reviews

- Candidate identity (matching) reviews must not expose or render concrete
  gallery tag lists in `yomiko variants reviews`, the review API, or the web
  review interface.
- Remove tags from the public source and candidate projections, nested metadata
  snapshots, and normalized matching-evidence fields that contain creator or
  content tag names. Derived matching scores, component point totals, and
  contradiction labels may remain visible.
- Preserve the original tags and full matching evidence in the database.
  Discovery, identity matching, scoring, and review resolution must continue to
  use the unredacted internal data.
- Cover this boundary in CLI/API and web tests. Run the complete suite with the
  Dockerfile `test` target when host-only dependencies such as
  `yomiko-unicode` are unavailable.

## Checks

- For shell changes, run targeted CLI commands where practical and use `shellcheck` if available.
- Run `bash tests/run.sh` for the unit test suite when utility functions change; it needs no test framework beyond the project's existing tools.
- For API scripts, test the CGI path with representative `REQUEST_METHOD` and `QUERY_STRING` values when feasible.
- Avoid checking in runtime artifacts from `data/`, `logs/`, `archived/`, or Hath download output.
