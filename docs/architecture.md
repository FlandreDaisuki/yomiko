# Yomiko Architecture

This overview is based on the current repository contents, not inferred external context.

## Golden Assertions

These are project design rules and should guide future changes:

- The CLI is the main interface.
- The web service is optional.
- API scripts may call library functions or CLI commands to perform work.
- Only the CLI may manipulate or query the database directly.
- If an API needs DB-backed data, expose that data through a CLI subcommand and have the API call the CLI.
- CLI commands are used by both terminal users and CGI/API scripts, so command output must be designed for both contexts.
- Human-facing progress logs should go through `lib/common.sh` `log`/`log_err` helpers and stay quiet when `YOMIKO_CLI_IN_API_MODE=1`.
- Machine-readable commands should keep stdout reserved for their documented payload format, such as JSON.

## Current Purpose

Yomiko is a shell-based archive helper for ExHentai/E-Hentai galleries. It runs
as a small Alpine container with a SQLite database, a periodic scan loop, and a
CLI at `bin/yomiko`. An optional BusyBox `httpd` CGI server exposes the API, web
pages, and dynamically configured userscript.

The implemented workflow is:

1. Receive or refresh ExHentai cookies through a userscript/API endpoint.
2. Request Hath downloads by gallery GID.
3. Scan a Hath download directory for completed galleries.
4. Convert gallery images to WebP.
5. Compress converted files into `.7z` archives.
6. Fetch ExHentai metadata and store/update local SQLite records.
7. Record user feedback, optionally sync rating/favorite actions to ExHentai, and delete local archives for rated galleries.

## Runtime Layout

`lib/path.sh` defines the runtime directories under `$HOME`:

- `archived/`: stores final `.7z` archives.
- `cronjobs/`: stores the scan loop script.
- `hath/`: expected Hath download input directory.
- `logs/`: stores scan logs.
- `migrations/`: stores SQL migrations.
- `data/db.sqlite3`: SQLite database.
- `data/cookie-jar.txt`: Netscape-format ExHentai cookie jar.
- `data/api-token`: persisted web/API bearer token.

It also creates those directories and prepends `$HOME/bin` to `PATH`.

`lib/common.sh` defines shared shell helpers such as API-mode-aware `log` and `log_err`.

## Main Entrypoints

- `entrypoint.sh`
  - Validates `YOMIKO_ENABLE_WEB` as `true` or `false`; it defaults to `true`.
  - Sources path/database helpers.
  - Runs `db_init`.
  - With web enabled, starts `cronjobs/cron-simulate` in the background and
    executes BusyBox `httpd` on `0.0.0.0:80` using `server/httpd.conf`.
  - With web disabled, executes `cronjobs/cron-simulate` as the container's main
    process and does not start `httpd`.

- `bin/yomiko`
  - Main CLI.
  - Sources `lib/common.sh`, `lib/path.sh`, `lib/db.sh`, and `lib/exh.sh`.
  - Supports `login`, `whoami`, `scan`, `archive`, `rate`, `hath`, `favorite`, `feedback`, `list`, and `help`.

- `cronjobs/cron-simulate`
  - Replaces `crond` with a busy loop.
  - Every 300 seconds, runs `yomiko scan "$HATH_DOWNLOAD_DIR"`; the CLI owns
    the scan lock.
  - Tees scan output to container stdout and `logs/yomiko-scan.log`.

## CLI Commands

The CLI is not only a TTY tool. CGI endpoints also call `bin/yomiko` with `YOMIKO_CLI_IN_API_MODE=1`, so new commands should avoid unconditional stdout/stderr output. Source `lib/common.sh`, use `log`/`log_err` for human progress or diagnostics, and keep structured command output stable for API callers.

### `yomiko login --cookie <cookie-string>`

Writes a browser cookie string to the ExHentai cookie jar and validates it against `https://exhentai.org/uconfig.php`.

### `yomiko whoami`

Tests the current cookie jar by loading authenticated ExHentai API credentials from `/mytags`. It returns JSON containing authentication state and `apiuid`, but does not print the API key.

### `yomiko scan <downloaded_dir>`

Finds `galleryinfo.txt` files under the provided directory with `fd`, treats each parent directory as a gallery, and runs `yomiko archive <gallery_dir>`.

Yomiko treats `galleryinfo.txt` as the H@H completion marker. The
[H@H downloader contract](https://ehwiki.org/wiki/Hentai%40Home#H@H_Downloader)
states that the file is generated only after the download completes and its
files pass expected-hash verification, so the scanner does not add a separate
age or file-stability delay. The scheduled scanner uses `flock` to prevent its
own runs from overlapping. `yomiko scan` owns that non-blocking lock at
`/tmp/yomiko-scan.lockfile`, so independently started scans receive status `75`
instead of traversing the download directory concurrently. If a scan encounters
a gallery whose per-gallery archive lock is already held by a direct
`yomiko archive` call, it skips that gallery and continues scanning.

### `yomiko archive <gallery_dir>`

Requires the directory and `galleryinfo.txt` to exist.

Current behavior:

- Parses the gallery directory name with `exh_parse_path_meta`.
- Expected naming shape is like:
  - `[xyz] foobar [123456]`
  - `[xyz] foobar [123456-1280x]`
- Extracts:
  - `gid`
  - filesystem-compatible title
- Takes a non-blocking per-gallery lock keyed by GID at
  `/tmp/yomiko-archive-<gid>.lock`. A direct concurrent archive attempt exits
  with status `75` before metadata, conversion, compression, database, or
  source-directory changes.
- Fetches metadata before conversion:
  - gets token via ExHentai search
  - calls the E-Hentai API `gdata` endpoint
- Converts `jpg`, `jpeg`, `png`, `gif`, and `webp` files to WebP using ImageMagick:
  - `lib/encode_image.sh --quality 75 --max-dimension 8196 -- input`
- Re-encodes existing `.webp` files with the same quality option using a temporary output file first.
- Shrinks oversized images only when a side exceeds WebP encoder limits.
- Compresses matching WebP files into a unique staging directory on the archive
  filesystem.
- Writes or updates archive metadata in `galleries`, including `file_path` and
  `updated_at`, before making the archive visible.
- Atomically renames the staged archive to
  `$ARCHIVED_DIR/<parsed-title>.7z` after the database update succeeds.
- Preserves user feedback fields such as `self_rating`, `feedbacked_at`, and `rated_then_deleted_at`.
- If the gallery was already rated `1` through `10` and marked deleted before
  the archive existed, discards the staged archive after recording `file_path`.
- Uses a scoped cleanup trap to remove staging on failures and signals while
  leaving the source gallery and any existing final archive in place.
- Removes the original gallery directory only after successful
  metadata/database/archive work.

### `yomiko hath <gid>`

Looks up the gallery token, fetches gallery metadata, submits a Hath download request to ExHentai `archiver.php` with `hathdl_xres=org`, and writes or updates a `galleries` row with `hath_requested_at`.

### `yomiko rate <gid> <1~10>`

Looks up the token and submits a rating through the ExHentai API. API credentials are scraped from `/mytags`.

### `yomiko favorite <gid> <0~9>`

Looks up the token and posts an add-favorite request to ExHentai.

### `yomiko feedback <gid> [--rating <1~11>] [--favorite <0~9>] [--dry-run]`

Uses an existing database record for `token` and `file_path`.

Current behavior:

- Accepts local rating `1` through `11`.
- Sends rating `11` to ExHentai as API rating `10`.
- If rating is `8` or higher and `--favorite` is provided, submits favorite request.
- Updates:
  - `feedbacked_at`
  - `self_rating`
- If rating is `1` through `10`, also sets `rated_then_deleted_at` and deletes `$ARCHIVED_DIR/<file_path>`.
- If no archive file exists yet, still sets `rated_then_deleted_at` and logs that the file was already absent.
- `--dry-run` logs intended API, database, and file actions without making them.

### `yomiko list [gid ...] [--max-count <N>] [--format json|table] [--order-by <field>,<asc|desc>]`

Returns gallery rows from SQLite.

Current behavior:

- JSON format is implemented through `sqlite3 --json`.
- `--pending-feedback` returns downloaded galleries that have neither feedback nor a nonzero self-rating.
- `--order-by` sorts results with a whitelisted gallery field and direction.
- Table format is declared but exits with `TODO: Table format is not implemented yet.`

## ExHentai/E-Hentai Integration

`lib/exh.sh` contains the network integration:

- Converts browser cookie strings to a Netscape cookie jar.
- Validates/refetches cookies by calling `https://exhentai.org/uconfig.php`.
- Checks current credentials by extracting authenticated API identity from `/mytags`.
- Parses gallery directory names for `gid`.
- Finds gallery tokens by searching ExHentai pages, with a second attempt including expunged galleries.
- Scrapes `apiuid` and `apikey` from `https://exhentai.org/mytags`.
- Calls:
  - `https://api.e-hentai.org/api.php` for gallery metadata.
  - `https://s.exhentai.org/api.php` for rating.
  - `https://exhentai.org/archiver.php` for Hath download requests.
  - `https://exhentai.org/gallerypopups.php` for favorites.

## Database

`lib/db.sh` initializes SQLite and applies migrations from `migrations/*.sql` in version order.

The database uses WAL mode for queries. Helpers exist for plain and JSON query output:

- `db_query`
- `db_query_json`

### Schema State

`001_initial_schema.sql` creates `galleries` with:

- `gid`
- `token`
- `title`
- `title_jpn`
- `file_count`
- `expunged`
- `tags`
- `rating`
- `file_path`
- `self_rating`
- `is_synced`
- `created_at`
- `updated_at`
- `rated_then_deleted_at`
- `hath_requested_at`

`002_rename_is_synced.sql` adds:

- `feedbacked_at`

Then it backfills `feedbacked_at` based on `is_synced` and drops `is_synced`.

`003_add_hath_requested_at.sql` adds:

- `hath_requested_at`

After all current migrations, the effective `galleries` table is expected to use `feedbacked_at` instead of `is_synced` and include `hath_requested_at` for requested-but-not-yet-archived gallery queries.

## HTTP/API Surface

`server/httpd.conf` configures BusyBox `httpd`:

- `/health` is rewritten to `/api/health.sh`.
- `/yomiko.user.js` is rewritten to `/api/install_userscript.sh`.
- `*.sh` files execute via `/bin/bash`.
- `.webp` is served as `image/webp`.

Implemented API scripts:

Mutation endpoints (`update_cookies.sh`, `hath_download.sh`, and `feedback.sh`)
require `Authorization: Bearer <YOMIKO_API_TOKEN>`. They return `503 Service
Unavailable` if no token reaches the API layer, and reject missing or incorrect
credentials with `401 Unauthorized`. On web-enabled container startup, the
entrypoint uses a configured token, reloads one from `data/api-token`, or
generates and persists a new one. CLI-only mode does not create or require a
token. Read-only endpoints do not require this token. The debug Compose service
binds to `127.0.0.1:62080` by default; use a trusted reverse proxy and preserve
the authentication boundary before changing `YOMIKO_BIND_ADDRESS` to expose it
remotely.

- `web/api/health.sh`
  - Returns `200 OK`.

- `web/api/install_userscript.sh`
  - Serves `web/yomiko.user.js` as JavaScript.
  - Replaces placeholders:
    - `__YOMIKO_CONNECT_HOST__`
    - `__YOMIKO_API_BASE__`
    - `__YOMIKO_API_TOKEN__` with the configured token.

- `web/api/update_cookies.sh`
  - Accepts only `POST`.
  - Requires the bearer token.
  - Reads the raw request body as a browser cookie string.
  - Calls `yomiko login --cookie <cookie-string>`.
  - Returns JSON success or error.

- `web/api/hath_download.sh`
  - Accepts only `PUT`.
  - Reads `gid` from the query string, e.g. `/api/hath_download.sh?gid=123456`.
  - Calls `yomiko hath <gid>`.
  - Returns JSON success or error.

- `web/api/galleries.sh`
  - Accepts only `GET`.
  - Reads `gids` and optional `fields` from the query string.
  - Supports comma-separated values, bracketed comma-separated values, repeated `gids[]`/`fields[]` keys, and repeated plain `gids`/`fields` keys.
  - Raw square brackets must be URL-encoded or requested with `curl --globoff` when using `curl`.
  - Calls `yomiko list --format json`.
  - Returns `gid`, `is_found`, and any requested gallery fields for each requested GID.

- `web/api/pending_feedback_galleries.sh`
  - Accepts only `GET`.
  - Reads optional `max_count` and `order_by` from the query string.
  - `max_count` defaults to `50` and rejects values above `50`.
  - `order_by` uses `<field>,<asc|desc>` and defaults to `created_at,asc`.
  - Calls `yomiko list --format json --pending-feedback`.
  - Returns the pending-feedback fields used by the page: `gid`, `title`, `title_jpn`, `file_count`, and `file_path`.

- `web/api/feedback.sh`
  - Accepts only `PUT`.
  - Requires the bearer token.
  - Reads `gid`, `rating`, and optional `favorite` from the query string.
  - Calls `yomiko feedback <gid> --rating <rating> [--favorite <favorite>]`.
  - Returns JSON success or error.

- `debug/web/api/echo_inspector.sh`
  - Debug-only endpoint that returns request method, URI, query string, headers,
    full CGI environment, and body.
  - The Docker `debug` target copies it to `web/api/echo_inspector.sh`; the
    production `runtime` target does not contain it.

- `web/api/middleware/cors.sh`
  - Allows CORS only for:
    - `https://exhentai.org`
    - `https://e-hentai.org`
  - Handles `OPTIONS` preflight.

- `web/api/middlewares.sh`
  - Loads available API middleware functions.
  - Provides `api_apply_middlewares <middleware-fn>...` so endpoints can explicitly choose which middleware to run.

- `web/api/middleware/env.sh`
  - Sets API execution context for CGI scripts.
  - Exports `YOMIKO_CLI_IN_API_MODE=1` so CLI commands called from API scripts suppress normal CLI logs.

## Web Frontend and Userscript

`web/index.html` is currently a minimal page showing `200 ok`.

`web/index.css` only removes default body/html margin.

The HTML pages and dynamically installed userscript use `web/favicon.webp`.

`web/yomiko.user.js` is a Tampermonkey/Greasemonkey-style userscript:

- Matches ExHentai and E-Hentai pages.
- Requires `https://unpkg.com/winkblue/dist/winkblue.umd.js`, though current script code does not use it.
- Logs `document.cookie`.
- Posts `document.cookie` to `${API_BASE}/api/update_cookies.sh`.
- Uses a `localStorage` timestamp to limit cookie refresh attempts to once every two hours across tabs on the same origin.
- Keeps the cookie refresh and gallery polling intervals as constants near the top of the script.
- Sends the injected bearer token with that mutation request.
- Requests gallery status from `galleries.sh` without a token because it is
  read-only.

`web/feedback.html` loads pending galleries and archive downloads through
read-only `GET` endpoints. Its `feedback.sh` `PUT` request sends the token
entered in the page's password field. Clicking "Use token" saves it to
`localStorage` so it is restored into the input on the next page load; clearing
the field and clicking the button removes the saved token.

The userscript is served dynamically through `/yomiko.user.js` so its name,
container build version, host, API base, and token placeholders can be filled
based on the image target and request. Production uses the stable `Yomiko`
identity and debug uses `Yomiko (Debug)`; the userscript's own numeric version
is independent of the container build version shown in its description.

## Container and Compose Setup

`docker/Dockerfile`:

- Uses Alpine `3.23.2` by default.
- Installs:
  - `7zip`
  - `bash`
  - `busybox-extras`
  - `curl`
  - `fd`
  - `imagemagick`
  - `imagemagick-jpeg`
  - `imagemagick-webp`
  - `jq`
  - `ripgrep`
  - `sqlite`
- Creates non-root user `yomiko` with UID/GID `1000`.
- Defines separate test, debug, and production runtime targets on shared base
  stages.
- Copies the full repository into the test target, adds debug-only web files to
  the debug target, and excludes them from the production runtime target.
- Exposes port `80`.
- Defines a mode-aware healthcheck: web mode requests
  `http://localhost/health`, while CLI-only mode checks that the initialized
  SQLite file exists.
- Runs `/home/yomiko/entrypoint.sh`.
- Does not set a container memory cap for the debug Compose service and defaults image conversion to one worker.
- ImageMagick conversion limits default to 256 MiB memory, 256 MiB map, and one thread. Override `MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT`, `MAGICK_THREAD_LIMIT`, or `YOMIKO_CONVERSION_JOBS` when more throughput is needed.
- 7z compression has no extra virtual-memory cap when `YOMIKO_7Z_MEMORY_LIMIT` is unset or empty. Set it to `KiB`, `MiB`, or `GiB` (for example, `512MiB`) to apply a per-process virtual-memory limit.

`docker/docker-compose.yaml`:

- Runs the published `ghcr.io/flandredaisuki/yomiko:latest` production image.
- Pulls the image whenever the service starts, initializes a minimal PID 1, and
  restarts unless explicitly stopped.
- Publishes `0.0.0.0:62080` to container port `80` by default.
- Requires non-empty `HOST_HATH_DOWNLOAD_DIR` and `HOST_ARCHIVED_DIR` values
  during Compose interpolation.
- Accepts an optional `YOMIKO_API_TOKEN`; web mode persists the configured value
  or generates and persists a token in `/home/yomiko/data/api-token`.
- Passes optional runtime and ImageMagick settings through only when their
  corresponding environment variables are configured. `YOMIKO_ENABLE_WEB`
  defaults to `true` inside the container; `false` disables `httpd` while
  leaving database initialization and the periodic CLI scanner running.
- Mounts:
  - `${HOST_HATH_DOWNLOAD_DIR}` to `/home/yomiko/hath`
  - `${HOST_ARCHIVED_DIR}` to `/home/yomiko/archived`
  - `${HOST_DATA_DIR}` to `/home/yomiko/data` when configured
- Uses the Docker-managed `yomiko-data` volume for `/home/yomiko/data` when
  `HOST_DATA_DIR` is not configured.
- Uses the image's non-root `yomiko` user with UID/GID `1000`, so every mounted
  directory must be readable and writable by that user.
- Has no local build, source watch, or test service.

`docker/.env.example` is shared by the production and debug Compose files. It
documents the required host paths, optional API token override, network
binding, optional persistent data bind, conversion concurrency, ImageMagick
limits, and optional 7z memory limit. It also exposes
`YOMIKO_ENABLE_WEB=true` as the default and documents `false` as the standalone
CLI scan/archive mode.

`docker/docker-compose.debug.yaml`:

- Builds from the repo root.
- Builds `yomiko.debug` from the debug target and the one-shot `yomiko.test`
  service from the test target.
- Runs `tests/run.sh` during `compose up`; the test container exits without restarting while the debug service and Compose Watch continue.
- Publishes `127.0.0.1:62080` to container port `80` by default.
- Generates and persists an API token under `../data` when none is configured.
  Set `YOMIKO_BIND_ADDRESS` and place an authenticated, trusted reverse proxy in
  front before allowing non-loopback access.
- Mounts:
  - `${HOST_HATH_DOWNLOAD_DIR}` to `/home/yomiko/hath`
  - `${HOST_ARCHIVED_DIR}` to `/home/yomiko/archived`
  - `../data` to `/home/yomiko/data`
  - `../logs` to `/home/yomiko/logs`

## Current Dependencies and Assumptions in Code

The code currently assumes these commands are available:

- `bash`
- `sqlite3`
- `jq`
- `curl`
- `rg`
- `fd`
- `magick`
- `7z`
- `flock`
- `awk`
- `sed`
- `head`

The Dockerfile installs most of these directly. `flock` is expected to be available in the container environment.

## Notable Current Gaps / Risks

- `yomiko list --format table` is advertised but not implemented.
- `web/yomiko.user.js` logs browser cookies to the console.
- `web/api/update_cookies.sh` now calls `yomiko login`, but there is no general API wrapper pattern yet for future CLI-backed endpoints.
- `cmd_archive` moves the generated archive before confirming metadata fetch success, so a metadata failure can leave an archive on disk without a database row.
- `cmd_archive` writes converted images to temporary sibling files before moving them into place, so failed conversions do not leave partial `.webp` outputs.
- `cmd_archive` compresses with `"${gallery_dir}/*.webp"` as a quoted argument; this relies on `7z` handling the wildcard itself rather than shell expansion.
- Migrations require SQLite support for `ALTER TABLE ... DROP COLUMN`, as noted in `002_rename_is_synced.sql`.
- `cron-simulate` has a TODO for log rotation.
- There are no test files in the current repository.
