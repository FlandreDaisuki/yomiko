# Yomiko Architecture

This overview describes the current repository contents. The external H@H
completion-marker behavior is cited where the implementation relies on it.
For operator-facing rating semantics, review steps, scoring policy management,
worker limits, retention guarantees, and troubleshooting, see
[Gallery Variants](./gallery-variants.md).

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
4. Fetch and validate ExHentai gallery metadata.
5. Convert gallery images to WebP.
6. Compress converted files into `.7z` archives and store/update local SQLite
   records.
7. Record user feedback. Ratings below `8` keep the existing synchronous path
   when ungrouped and durably deactivate confirmed groups; ratings `8` through
   `11` persist local intent and enqueue durable variant work without waiting
   for ExHentai.

## Runtime Layout

`lib/path.sh` defines the runtime directories under `$HOME`:

- `archived/`: stores final `.7z` archives.
- `cronjobs/`: stores the scan loop script.
- `hath/`: expected Hath download input directory.
- `logs/`: stores separate scan and gallery-variant worker logs.
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
  - Sources `lib/common.sh`, `lib/path.sh`, `lib/db.sh`, `lib/exh.sh`, and
    `lib/variants.sh`.
  - Supports `login`, `whoami`, `scan`, `archive`, `rate`, `hath`, `favorite`,
    `feedback`, `variants`, `repair-tags`, `list`, and `help`.

- `cronjobs/cron-simulate`
  - Replaces `crond` with a busy loop.
  - Every two minutes, starts `yomiko variants work`; every five minutes, it
    independently starts `yomiko scan "$HATH_DOWNLOAD_DIR"`.
  - Each command owns a separate non-blocking lock and log. Output is teed to
    container stdout plus `logs/yomiko-scan.log` or
    `logs/yomiko-variants.log`.

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
  - validates and normalizes the metadata schema before any conversion or SQL:
    `gid`, `token`, `title`, `filecount`, `expunged`, `tags`, and `rating` are
    required; numeric strings are converted to numbers; and a missing or null
    `title_jpn` remains null
- Converts `jpg`, `jpeg`, `png`, `gif`, and `webp` files to WebP using ImageMagick:
  - `lib/encode_image.sh --quality 75 --max-dimension 8196 -- input`
- Re-encodes existing `.webp` files with the same quality option using a temporary output file first.
- Shrinks an image only when a side exceeds the configured `8196`-pixel
  maximum.
- Compresses matching WebP files into a unique staging directory on the archive
  filesystem.
- Writes or updates archive metadata in `galleries`, including `file_path` and
  `updated_at`, before making the archive visible.
- Atomically renames the staged archive to
  `$ARCHIVED_DIR/[<gid>]<parsed-title>.7z` after the database update succeeds.
- Preserves user feedback fields such as `self_rating`, `feedbacked_at`, and `rated_then_deleted_at`.
- If the existing DB row has `self_rating` from `1` through `10` and a nonempty
  `rated_then_deleted_at`, removes any destination archive and discards the
  staged archive after recording `file_path`.
- Uses a scoped cleanup trap to remove staging on failures and signals while
  leaving the source gallery and any existing final archive in place.
- Removes the original gallery directory only after successful
  metadata/database/archive work.

### `yomiko hath <gid>`

Looks up the gallery token, fetches gallery metadata, and submits an explicit
H@H download request to ExHentai `archiver.php` with `hathdl_xres=org`. Manual
requests bypass automatic archive, H@H-tree, and cooldown preflight, but take
the shared per-GID lock and write `galleries.hath_last_attempted_at`
immediately before the adapter call. Successful requests also update the
historical `hath_requested_at` timestamp.

### `yomiko rate <gid> <1~10>`

Looks up the token and submits a rating through the ExHentai API. API credentials are scraped from `/mytags`.

### `yomiko favorite <gid> <0~9>`

Looks up the token and posts an add-favorite request to ExHentai.

### `yomiko feedback <gid> [--rating <1~11>] [--favorite <0~9>] [--dry-run]`

Uses an existing database record for `token` and `file_path`.

Current behavior:

- Accepts local rating `1` through `11`.
- For ratings below `8` on an ungrouped gallery, preserves the existing
  single-gallery path: submits the rating synchronously, updates local feedback
  state, and applies the existing archive-deletion behavior.
- For ratings below `8` on a confirmed member, atomically deactivates the group,
  propagates local intent to confirmed members, records rating, favorite
  removal, and archive cleanup actions, and coalesces action reconciliation.
  It makes no remote call or filesystem mutation on the request path.
- For ratings `8` through `11`, atomically updates `self_rating` and
  `feedbacked_at`, creates or reactivates a variant group, confirms the source
  gallery, coalesces a high-priority discovery job, and records a pending
  rating action. Local `11` is stored as desired remote rating `10`.
- The `8` through `11` request path makes no remote rating or favorite call.
  `--favorite` remains accepted for compatibility; the independent worker
  routes confirmed canonical and alternate members using the two configured
  favorite categories.
- Ratings `8` through `10` delete an existing source archive after the enqueue
  transaction and set `rated_then_deleted_at` only after that deletion
  succeeds. Rating `11` retains the source archive.
- If no source archive exists for rating `8` through `10`,
  `rated_then_deleted_at` remains unchanged.
- `--dry-run` logs intended API, database, and file actions without making them.

### `yomiko variants <enqueue|list|work|evaluate|reviews|resolve|policy-*>`

Provides the durable gallery-variant workflow:

- `enqueue <gid>` queues variant work for a gallery whose stored local rating
  is `8` through `11`.
- `list [--gid <gid>] [--status <status>]` returns one JSON document containing
  matching groups and their members, jobs, reviews, and actions.
- `work [--max-jobs <N>] [--dry-run]` takes the independent non-blocking lock at
  `/tmp/yomiko-variants.lockfile`. A mutating run schedules stale discovery,
  recovers expired leases, repairs the archive-handoff gap, performs locked
  rating-11 archive/H@H recovery, and dispatches `discover`, `evaluate`,
  `policy_scoring_sweep`, `reconcile_actions`, and `reconcile_retention`. One
  invocation advances at most one network discovery group and sends at most 25
  remote mutations. Dry-run takes no lock or lease and makes no database,
  filesystem, or remote mutation; it reports canonical archive, H@H-tree, and
  cooldown state for rating-11 groups.
- Action reconciliation projects the group's desired `self_rating` and effective
  `feedbacked_at` onto confirmed galleries idempotently. A no-op projection does
  not advance `galleries.updated_at`; that watermark advances only when projected
  gallery metadata actually changes. Rating-11 cleanup is projected only when
  the current canonical archive is a safe regular file. When it is unavailable,
  alternate cleanup is superseded or deferred and the canonical H@H action is
  scheduled instead. A matching canonical GID directory anywhere in the H@H
  tree suppresses automatic requests indefinitely, even without
  `galleryinfo.txt`; otherwise automatic requests use the per-GID
  `hath_last_attempted_at` watermark and a 12-hour cooldown. This keeps
  retention self-healing and the durable retention-to-action handoff
  convergent while preserving action audit history and job coalescing.
- `evaluate <gid>` resolves the gallery's unique active confirmed group
  internally, then evaluates its members from their frozen metadata snapshots
  and the active expanded policy. It persists an immutable score breakdown,
  reuses an active durable manual canonical decision when its selected member
  and confirmed-member fingerprint remain valid, projects a winner whose lead
  is at least 30 points, or creates a winner review for exact and near ties
  with a score difference below 30. Evaluate jobs carry an expected active
  evaluation ID, so a job racing with a manual resolution is stale-guarded
  before it can overwrite the newer decision.
- `reviews [--status pending|resolved]` returns candidate and winner reviews as
  JSON addressed only by review IDs and gallery GIDs. Candidate cards include
  frozen source/candidate metadata, cover thumbnails, and evidence; winner
  choices include cover thumbnails, archive state, and their complete frozen
  score breakdowns.
- `resolve <review-id> --decision <same-book|different-book|winner> [--gid
  <gid>]` atomically resolves one still-current review. Candidate decisions
  persist manual membership and review provenance without changing the
  automatic match score, then coalesce reevaluation; a same-book decision
  merges active groups into the older group while retaining
  historical rows and the latest feedback intent. Candidate reviews retained
  on merged inactive history remain resolvable through the active survivor and
  continue to block its evaluation until resolved. Winner decisions create a
  durable canonical decision plus a new immutable completed evaluation that
  copies the automatic member scores unchanged, cancel queued evaluations for
  the group, and coalesce action reconciliation. The resolved source review
  remains unsuperseded audit history (`superseded_at IS NULL`).
- `ungroup <gid>... [--force]` takes the worker lock and destructively
  removes each selected GID from every membership, identity pair, and candidate
  identity review while preserving its exact local rating and feedback
  timestamp. It resets affected durable canonical decisions with reason
  `identity_reset`, then atomically creates a fresh singleton source group for
  each selected GID using the old group's desired rating and queues discovery
  without a remote rating action. Each non-selected group remainder is also
  rebuilt under a fresh active group before discovery is queued.
- `policy-show [--pretty] [--expanded]`, `policy-check <path|->`, and
  `policy-activate <path|->` provide the compact scoring-policy lifecycle.
  Preview is read-only; activation reuses immutable content and coalesces one
  global scoring sweep when scoring changes.

The feedback command uses an internal durable downgrade primitive for a rating
`1` through `7` on a confirmed group member. It atomically deactivates the
group, applies local rating intent to every confirmed member, records pending
rating, favorite-removal, and archive-cleanup actions, and coalesces an action
reconciliation job. It performs no remote call or deletion. An ungrouped low
rating falls back to the single-gallery path described above.

Variant-group IDs are relational database keys, not public identifiers. CLI and
API users address variant work by gallery GID or review ID. Normal list,
evaluation, enqueue, feedback, and worker-reporting payloads omit group IDs;
internal worker and database functions may continue to use them.

The independent discovery worker/scheduler handler uses fixed-rule integer
`matching_revision = 3`. It refreshes every confirmed seed, follows official
chain links, constructs deduplicated creator/title queries with the required
Chinese tankoubon scope, and searches normal and expunged results separately.
Search, `gdata`, and popularity work use durable bounded continuations. Only a
terminal staged snapshot is published: remote gallery metadata is upserted
without changing local archive/feedback fields. Valid official-chain matches
are confirmed, while malformed or contradictory chain references and
independently discovered matches create candidate reviews. A known replaced
gallery (`current_gid` is non-null and differs from `gid`) is retained as
historical evidence but is excluded from canonical candidates and user-facing
reviews; `current_gid = null` remains eligible and is not rewritten. When a
current child is available, discovery confirms it, retargets the group source,
and queues evaluation; if it is unavailable, the prior canonical/action state
is preserved for retry. Retryable jobs preserve their cursor and backoff.
Matching-only migration work queues rediscovery but does not create a scoring
sweep. Scoring-policy activation still coalesces a revision-bound sweep in
batches of 100 groups. Action reconciliation reprojects current intent before
enforcing rating → favorite → H@H → cleanup order; only requests actually sent
consume the global 25-call budget. Rating `11` cleanup requires a regular
canonical archive, while missing or unsafe paths remain visible without
falsely recording deletion.

### `yomiko repair-tags [--max-count <1~5>] [--dry-run] [--force]`

Repairs gallery records whose `tags` field is null. It reads the stored GID and
token, fetches and validates current metadata from the E-Hentai API, and writes
only the missing tags. Each successful record is committed independently, so a
partially successful run can be resumed safely. Every invocation reports the
total remaining backlog and attempts at most five API requests; `--max-count`
can lower that batch size. `--dry-run` reports the backlog and selected batch
size without making API requests or database changes. A real repair requires
confirmation that defaults to no; `--force` skips the prompt for unattended
execution. The command refuses to run before schema migration 004 is applied.

Migration 004 prevents new invalid tag writes but deliberately leaves legacy
null values untouched. The repair command remains necessary for installations
that upgrade from an affected image later, even after another installation has
already cleared its backlog.

### `yomiko list [gid ...] [--max-count <N>] [--format json|table] [--pending-feedback] [--group-by artist] [--order-by <field>,<asc|desc>]`

Returns gallery rows from SQLite.

Current behavior:

- JSON format is implemented through `sqlite3 --json`.
- `--pending-feedback` returns downloaded galleries that have neither feedback
  nor a nonzero self-rating and have not already been deleted after rating.
- `--order-by` accepts only `gid` and `hath_requested_at` with an `asc` or `desc`
  direction.
- `--group-by artist` sorts groups by the first normalized `artist:` tag in
  ascending order, then sorts rows within each group using `--order-by`. Without
  `--order-by`, grouped results use `gid,asc`; the internal artist sort key is
  not part of the returned row.
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

`lib/db.sh` enables SQLite foreign-key enforcement on every connection,
initializes WAL mode, and applies migrations from `migrations/*.sql` in version
order. Before each pending migration of an existing database, it creates a
consistent SQLite backup beside the database named `before-<version>.sqlite3`;
for example, migration 011 creates `data/before-11.sqlite3`. The backup is
written to a temporary file and moved into place only after SQLite completes
it, and a backup failure prevents the migration from starting. Brand-new
databases skip these backups. Each migration and its schema-version record then
run in one `BEGIN IMMEDIATE` transaction, so an error rolls back both before
initialization fails.

The query helpers stream the foreign-key pragma, parameter commands, and SQL
through SQLite stdin, return SQLite's exit status directly, and support plain
and JSON output:

- `db_query`
- `db_query_json`

Arbitrary text parameters are converted to hexadecimal SQLite expressions by
`db_parameter_text`. This keeps quotes, backslashes, newlines, and other text
out of the SQLite CLI dot-command tokenizer while preserving the original
UTF-8 value.

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

`002_rename_is_synced.sql` adds:

- `feedbacked_at`

Then it backfills `feedbacked_at` based on `is_synced` and drops `is_synced`.

`003_add_hath_requested_at.sql` adds:

- `hath_requested_at`

`004_validate_gallery_tags.sql` adds insert and targeted-update triggers that
reject null tags, malformed JSON, and JSON values that are not arrays. Existing
null values are left in place so they can be restored with `repair-tags`.

After all current migrations, the effective `galleries` table uses
`feedbacked_at` instead of `is_synced`, includes `hath_requested_at` for the
latest successful H@H request, and includes nullable
`hath_last_attempted_at` for the latest authorized automatic or manual attempt,
including uncertain outcomes.

`005_gallery_variants.sql` adds normalized metadata needed by later matching
and scoring: `category`, `uploader`, `posted`, `filesize`, `thumb`, and the
`first`, `parent`, and `current` chain GID/key pairs. Metadata refreshes populate
these fields while preserving established feedback and archive lifecycle
columns.

Migration 005 also creates:

- immutable, independently hashed `variant_policy_revisions`, seeded with one
  active initial policy;
- `variant_groups` and `gallery_variants` for desired rating, lifecycle,
  membership, evidence, metadata snapshots, and canonical state;
- immutable `variant_evaluations`, plus `variant_reviews` for candidate and
  winner decisions (`ungroup` intentionally deletes affected candidate
  reviews);
- durable `variant_jobs` and `variant_actions` with status, retry, scheduling,
  lease, error, and audit fields.

Migration 006 adds nullable nonnegative favorite/rating counts and their detail-
page fetch timestamp. It preserves the legacy migration-005 policy revision for
audit and activates the canonical expanded form of the initial compact scoring
policy. A small native `utf8proc` helper supplies two-pass NFKC normalization
and full Unicode case folding; `jq` owns policy validation, matching, and local
score computation.

Migration 007 adds the fixed matching revision plus leased discovery runs and
candidate staging, allowing bounded discovery to resume without replacing the
last completed snapshot.

Migration 008 adds scoring targets to evaluation/sweep jobs, action leases and
error classifications, winner-review supersession evidence, and the indexes
and triggers used by operational claims, retries, and cursors. Pre-upgrade
in-flight actions become retryable with an uncertain outcome.

Migration 009 materializes every historical `self_rating` from `1` through
`11` as an active variant-discovery group unless the gallery is already a
confirmed member. It creates only confirmed source memberships and queued
discovery jobs; normal actions are projected later, after discovery and any
required reviews and evaluation.

Migration 010 advances only the known default scoring policy with the canonical
page-count component while preserving customized active policies.

Migration 011 creates `gallery_identity_pairs`, keyed by normalized
`(low_gid, high_gid)` and pointing at the current resolved candidate review.
It backfills agreeing reviews deterministically and aborts after printing exact
GID pairs when historical decisions disagree or contradict active membership.
Active confirmed groups form the current same-book equivalence classes;
different-book edges are lifted across those classes. A reusable reconciliation
projection suppresses same-class, known-negative, and duplicate raw pending
rows while retaining their frozen evidence, leaving one actionable review for
each unknown unordered class pair. Discovery, resolution, evaluation routing,
worker scheduling, and ungroup consume that projection. Ungroup recomputes it,
so questions reopen when their former class inference no longer holds. The
lowest active group ID survives a merge independently of review direction.

Migration 012 compacts legacy variant evaluation snapshots to the authoritative
scoring fields and keeps `variant_evaluations.member_scores_json` as the sole
durable score breakdown. Winner-review output and list output derive compact
breakdowns by joining the referenced evaluation; `gallery_variants` no longer
stores a duplicate JSON breakdown. The migration queues a durable post-commit
`VACUUM`, and startup remains blocked until that maintenance succeeds.

Migration 013 updates the built-in scoring policy while preserving customized
active policies and queues the corresponding scoring sweep. Migration 014
installs the fixed official-chain matching policy and derives replacement
visibility from live `current_gid` chain metadata. It preserves the previous
policy revision and scoring/operations hashes, activates the new revision, and
queues matching-revision rediscovery without a scoring sweep. Review list/API
serialization, candidate projection, winner choices, and review resolution all
exclude definitely replaced galleries while retaining historical rows and
frozen evidence.

Migration 015 applies the current scoring weights to the active policy,
preserves unrelated operator-owned policy choices, and queues a scoring sweep
for existing variant groups.

Migration 016 adds the H@H attempt watermark and conservatively backfills it
from successful-request and possibly-sent action history. It normalizes the
known blocked rating-11 cleanup state by superseding cleanup retries, preserving
their diagnostics and attempt counts, and coalescing immediately runnable
reconciliation jobs. Filesystem truth is intentionally left to runtime
recovery under the per-GID archive lock.

Migration 017 adds the read-only `variant_job_diagnostics` view. It emits one
row per variant job and derives scheduling, lease, and job-error fields from
`variant_jobs`. For current queued or leased `reconcile_actions` jobs only, it
also aggregates active group actions, retry availability, action lease
expiries, and CLI-readable action summaries. Historical jobs and other job
types intentionally expose empty action diagnostics because actions do not have
durable parent-job ownership. The view does not infer worker, remote-write, or
filesystem health.

Migration 018 adds `variant_canonical_decisions`, the durable current projection
of manual winner choices. Each active row is tied to its source winner review,
policy revision, selected confirmed member, and sorted confirmed-member
fingerprint; a partial unique index permits at most one active choice per
group. The migration backfills only the latest unambiguous resolved winner that
still selects a confirmed member, accepts the historical
`resolved_at = superseded_at` resolver-ordering signature, and marks pending
duplicate winner reviews non-actionable. It also adds
`variant_jobs.expected_evaluation_id` and validation/fill triggers so queued
evaluation work is bound to the active evaluation generation. Runtime scoring
reuses a still-valid decision, explicitly supersedes decisions invalidated by
member removal or member-set changes, and preserves policy-change choices;
`ungroup` uses the `identity_reset` status and reason.

Migration 019 adds nullable `variant_evaluations.canonical_decision_id` with an
index and insert validation. Resolver-created and later evaluations that
project an active manual canonical link to that decision; automatic and
review-blocked evaluations remain unlinked. It normalizes only the mutable
legacy identity projection by subtracting the recorded integer `+9999` or
`-9999` once and removing that field, while preserving review provenance and
membership state. Unexpected adjustment types or values abort the migration.
Active groups whose current evaluation contains the historical manual-winner
component receive one coalesced local evaluate job; immutable historical
evaluations are not rewritten and no remote action is created by migration.

For operational inspection, the compact queue query is:

```sql
SELECT job_id, job_type, group_id, source_gid, status,
       job_attempt_count, diagnostic_state, active_action_count,
       next_action_available_at, wait_until, reason
  FROM variant_job_diagnostics
 WHERE status IN ('queued', 'leased')
 ORDER BY job_available_at ASC, priority DESC, job_id ASC;
```

Use structured columns such as `diagnostic_state`, action counts, and
timestamps for monitoring. `reason`, `active_actions`, and `action_errors` are
human-readable SQLite CLI summaries and must not be parsed by application code.

Constraints, partial indexes, and triggers enforce active policy uniqueness,
coalesced runnable jobs, one active confirmed group per gallery, valid review
shapes, valid canonical/evaluation relationships, revision-bound scoring work,
one active durable canonical decision per group, evaluation-generation guards,
and action lease/error consistency.

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
    - `__YOMIKO_USERSCRIPT_NAME__`
    - `__YOMIKO_BUILD_VERSION__`
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
  - Requires the bearer token.
  - Reads `gid` from the query string, e.g. `/api/hath_download.sh?gid=123456`.
  - Calls `yomiko hath <gid>`.
  - Returns JSON success or error.

- `web/api/galleries.sh`
  - Accepts only `GET`.
  - Reads `gids` from the query string and rejects the removed `fields` parameter.
  - Supports comma-separated values, bracketed comma-separated values, repeated `gids[]` keys, and repeated plain `gids` keys.
  - Raw square brackets must be URL-encoded or requested with `curl --globoff` when using `curl`.
  - Calls `yomiko gallery-status`.
  - Returns only `{success, galleries:[{gid,state}]}`; unknown GIDs have a null state.

- `web/api/pending_feedback_galleries.sh`
  - Accepts only `GET`.
  - Reads optional `max_count` and `order_by` from the query string.
  - `max_count` defaults to `50` and rejects values above `50`.
  - `order_by` accepts only `gid` or `hath_requested_at` with an `<asc|desc>`
    direction and defaults to `hath_requested_at,asc`.
  - The endpoint always calls `yomiko list` with `--group-by artist`; grouping
    cannot be disabled for this queue.
  - The feedback page has no sort selector and requests at most 20 galleries.
  - Calls `yomiko list --format json --pending-feedback --group-by artist`.
  - Returns the pending-feedback fields used by the page: `gid`, `title`, `title_jpn`, `file_count`, and `file_path`.

- `web/api/feedback.sh`
  - Accepts only `PUT`.
  - Requires the bearer token.
  - Reads `gid`, `rating`, and optional `favorite` from the query string.
  - Calls `yomiko feedback <gid> --rating <rating> [--favorite <favorite>]`.
  - Returns JSON success or error, including `variant_queued`. It is `true` for
    ratings `8` through `11` and confirmed-group downgrades; ungrouped low
    feedback returns `false`.

- `web/api/reviews.sh`
  - Accepts only `GET` and optional `status=pending|resolved`.
  - Calls `yomiko variants reviews` and validates that its JSON omits relational
    group IDs before returning review cards.
  - Is read-only and does not require the bearer token.

- `web/api/review_resolve.sh`
  - Accepts only `PUT` and requires the bearer token.
  - Reads `review_id`, an allowlisted `same-book`, `different-book`, or `winner`
    decision, and a required `gid` only for winner decisions.
  - Calls `yomiko variants resolve`; stale or concurrently resolved reviews
    return `409 Conflict` so clients can refresh cleanly.

- `web/api/archive_download.sh`
  - Accepts only `GET`.
  - Reads and validates `gid`, then calls `yomiko list --format json` to resolve
    the recorded archive filename.
  - Rejects unsafe recorded paths and serves only validated regular,
    non-symlink archives as `application/x-7z-compressed`.
  - Is read-only and does not require the bearer token.

- `debug/web/api/echo_inspector.sh`
  - Debug-only endpoint that returns request method, URI, query string, headers,
    full CGI environment, and body.
  - The Docker `debug` target copies it to `web/api/echo_inspector.sh`; the
    production `runtime` target does not contain it.

- `web/api/_middleware.sh`
  - Centralizes API-mode setup, command-failure logging, mutation bearer-token
    authentication, and CORS handling.
  - Exports `YOMIKO_CLI_IN_API_MODE=1` so CLI commands called from API scripts
    suppress normal CLI logs.
  - Allows requests without an `Origin`, requests from
    `https://exhentai.org` or `https://e-hentai.org`, and same-host origins.
    Other origins receive `403 Forbidden`.
  - Handles `OPTIONS` preflight and advertises `GET`, `POST`, `PUT`, and
    `OPTIONS`.

## Web Frontend and Userscript

`web/index.html` is currently a minimal page showing `200 ok`.

`web/index.css` only removes default body/html margin.

The HTML pages and dynamically installed userscript use `web/favicon.webp`.

`web/yomiko.user.js` is a Tampermonkey/Greasemonkey-style userscript:

- Matches ExHentai and E-Hentai pages.
- Posts `document.cookie` to `${API_BASE}/api/update_cookies.sh`.
- Uses a `localStorage` timestamp to limit cookie refresh attempts to once every two hours across tabs on the same origin.
- Keeps the cookie refresh and gallery polling intervals as constants near the top of the script.
- Sends the injected bearer token with that mutation request.
- Requests derived gallery status from `galleries.sh` without a token because
  it is read-only. The five states are `hath_requested` (a request has been
  attempted and there is no current archive), `downloaded_unrated`,
  `rated_non_11`, `rated_11_canonical` (the retained rating-11 canonical
  archive), and `rated_11_alternate`.
- Polls for unchecked gallery cards every 500 milliseconds and annotates cards
  from the returned state, with the ExHentai DOM rating as a fallback when no
  local state is available.

`web/feedback.html` uses **Feedback** and **Variant reviews** tabs at one URL
with one API token. Every load defaults to **Feedback** and tab selection is
not persisted; the review tab retains a visible pending count. The page loads
pending galleries, pending candidate/winner reviews, and archive downloads
through read-only `GET` endpoints. Candidate cards show
the source/candidate cover thumbnails, metadata, evidence components,
separate Expunged/Not Expunged and Archived/Not Archived states,
contradictions, and manual same/different actions. Category is omitted because
variant discovery is scoped to Chinese tankoubon. Candidate reviews sharing a
feedback/source GID render as one batch: the source appears once and each
candidate tile keeps independent evidence and Same/Different controls. Winner
cards show each
eligible choice's cover thumbnail, archive state, and full score breakdown with
an explicit canonical action. Successful review
mutations refresh the review list; stale conflicts surface an error and also
refresh it. Review and feedback `PUT` requests send the token entered in the
page's password field. Clicking "Use token" saves it to `localStorage` so it is
restored into the input on the next page load; clearing the field and clicking
the button removes the saved token. The page requests at most 20 pending
galleries, has no sort selector, offers ratings `1` through `11`, and still
sends favorite category `5` for compatibility. Feedback success removes only
the requested GID from
the current SPA state, closes the dialog, and shows a success toast; it does
not reload, re-request the queue, or automatically fill the vacant slot.
High-rating feedback queues work. The page loads Petite Vue 0.4.1 from
`unpkg.com`.

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
  - `utf8proc`
- Compiles `/usr/local/bin/yomiko-unicode` in a separate build stage using
  `build-base` and `utf8proc-dev`; compiler packages are absent from runtime
  images.
- Creates non-root user `yomiko` with UID/GID `1000`.
- Defines separate test, debug, and production runtime targets on shared base
  stages.
- Copies the complete Docker build context into the test target, adds debug-only
  web files to the debug target, and excludes them from the production runtime
  target.
- Exposes port `80`.
- Defines a mode-aware healthcheck: web mode requests
  `http://localhost/health`, while CLI-only mode checks that the initialized
  SQLite file exists.
- Runs `/home/yomiko/entrypoint.sh`.
- Does not set a container memory cap. Archive conversion defaults to four
  concurrent jobs.
- Each ImageMagick process defaults to a 1 GiB memory limit, a 1 GiB map limit,
  and one thread. Override `MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT`,
  `MAGICK_THREAD_LIMIT`, or `YOMIKO_CONVERSION_JOBS` to change these limits.
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
- Passes `YOMIKO_CANONICAL_FAVORITE_CATEGORY` and
  `YOMIKO_ALTERNATE_FAVORITE_CATEGORY` to the operational worker. Both must be
  distinct digits from `0` through `9`; invalid values pause only favorites.
- Mounts:
  - `${HOST_HATH_DOWNLOAD_DIR}` to `/home/yomiko/hath`
  - `${HOST_ARCHIVED_DIR}` to `/home/yomiko/archived`
  - `${HOST_DATA_DIR}` to `/home/yomiko/data` when configured
- Uses the Docker-managed `yomiko-data` volume for `/home/yomiko/data` when
  `HOST_DATA_DIR` is not configured.
- Uses the image's non-root `yomiko` user with UID/GID `1000`, so every mounted
  directory must be readable and writable by that user.
- Has no local build, source watch, or test service.

`docker/.env.example` documents the production Compose settings: required host
paths, optional API token override, network binding, optional persistent data
bind, conversion concurrency, ImageMagick limits, optional 7z memory limit, and
the two reserved variant favorite categories. It also exposes
`YOMIKO_ENABLE_WEB=true` as the default and documents `false` as the standalone
CLI scan/archive mode. `HOST_LOG_DIR` is only a ready-to-use value for the
commented log bind in `docker/docker-compose.yaml`; the production service does
not mount it unless that volume line is uncommented.

Development and verification use the `yomiko-playground` skill. Its generated,
self-contained Compose file builds the current worktree, initializes and
migrates an isolated production snapshot, starts a loopback-only web service,
and exposes a one-shot test service. The repository intentionally has no
separate debug Compose file.

## Tests and Development Checks

`tests/run.sh` is a Bash test harness with 123 registered test cases. It uses
temporary directories and repository fixtures rather than an external test
framework. The suite covers shared logging and memory helpers, database query
and migration failure behavior, gallery parsing and metadata validation, cookie
conversion, CLI argument validation, archive failure recovery and locks, API
CORS/authentication/error isolation, userscript and feedback-page integration,
variant schema/policy/scoring/enqueue/list/worker/feedback behavior, queued
H@H retry recovery and cooldowns, guarded cleanup, and both entrypoint modes.

Run it through the `yomiko-playground` skill from the repository root:

```bash
.agents/skills/yomiko-playground/scripts/create_playground.sh --start
# in the generated playground:
./playground test
```

The Dockerfile's `test` target copies the Docker build context and runs
`/home/yomiko/tests/run.sh`; the playground Compose file exposes the same
target as the one-shot `yomiko.test` service. The runtime images do not contain
the test tree. Use `./playground up` to apply migrations to the copied database
before targeted migration or CLI checks.

## Current Dependencies and Assumptions in Code

The runtime directly uses Bash, SQLite, jq, curl, ripgrep, fd, ImageMagick,
7-Zip, `utf8proc` through the compiled `yomiko-unicode` helper, `flock`, and
standard Alpine/BusyBox utilities. The image is expected to provide that
complete command set through the Dockerfile's explicit package list and its
Alpine/BusyBox base environment. Python is not a runtime or test-image
dependency.

## Notable Current Gaps / Risks

- `yomiko list --format table` is advertised but not implemented.
- Read-only API endpoints, including archive downloads, do not require the
  bearer token. Network exposure must therefore be limited to trusted clients.
- The feedback page depends on `unpkg.com` at runtime for Petite Vue.
- `cmd_feedback` logs remote rating or favorite failures but continues with its
  local database and file updates, so a successful API response does not prove
  that those remote actions succeeded.
- `cmd_archive` passes `"${gallery_dir}/*.webp"` as one quoted argument and
  relies on 7-Zip, rather than the shell, to expand the wildcard.
- Migrations require SQLite support for `ALTER TABLE ... DROP COLUMN`, as noted in `002_rename_is_synced.sql`.
- `cron-simulate` appends indefinitely to `logs/yomiko-scan.log` and
  `logs/yomiko-variants.log`; no log rotation is implemented.
