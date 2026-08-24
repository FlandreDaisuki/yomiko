<p align="center">
  <img src="./web/favicon@orig.webp" alt="Yomiko" width="220">
</p>

# Yomiko

Yomiko is a self-hosted archive companion for ExHentai/E-Hentai and Hath.
It turns completed Hath downloads into compact WebP/7z archives, records their
state in SQLite, and shows that state directly on gallery pages through a
userscript.

Yomiko does not replace Hath. You must already have a working Hath client that
writes completed gallery directories into the path mounted as
`HOST_HATH_DOWNLOAD_DIR`. A completed Hath download is the trigger for Yomiko's
scan, conversion, archive, and database workflow.

The CLI owns all database access and the archive workflow. The optional HTTP
API and browser UI call the CLI for DB-backed queries and mutations; the
archive-download endpoint only serves a filename that it resolves through the
CLI.

## CLI first, web optional

Yomiko's CLI, SQLite database, filesystem workflow, and periodic scanner work
without the API, web pages, or userscript. The dependency only points inward:
web features call the CLI, while the CLI never calls the web layer.

The container enables web features by default. To run only the CLI scan/archive
service, set:

```dotenv
YOMIKO_ENABLE_WEB=false
```

CLI-only mode does not start `httpd`, serve an API, publish web pages, or require
a userscript. The container stays alive by running the periodic scanner, and
you can invoke commands with `docker compose exec yomiko yomiko ...`.

Without the userscript, initialize and verify ExHentai credentials directly:

```bash
docker compose exec yomiko \
  yomiko login --cookie 'YOUR_EXHENTAI_COOKIE_STRING'
docker compose exec yomiko yomiko whoami
```

The cookie string is sensitive and may be stored in shell history. Use your
shell's private-history mechanism or another protected invocation method.

## What Yomiko does

- Refreshes ExHentai cookies from the browser through `yomiko.user.js`.
- Requests gallery downloads through the API or CLI.
- Scans the Hath download directory for completed galleries.
- Converts gallery images to WebP and packages them as `.7z` archives.
- Stores gallery, archive, request, and feedback state in SQLite.
- Durably queues gallery-variant intent for ratings `8` through `11` without
  waiting for remote work.
- Marks downloaded, archived, and rated galleries on ExHentai/E-Hentai pages.
- Provides a small feedback page for downloading archives and recording ratings.

## Workflow

```mermaid
flowchart TD
    subgraph OptionalWeb["Optional web layer — YOMIKO_ENABLE_WEB=true"]
        Site["ExHentai / E-Hentai"]
        Userscript["yomiko.user.js<br>sync cookies and display status"]
        Client["Feedback page<br>or another API client"]
        API["BusyBox httpd CGI"]
        Site --> Userscript
        Userscript -->|"POST cookies<br>GET gallery status"| API
        API -->|"status response"| Userscript
        Client -->|"download / feedback request"| API
    end

    Operator["User or scheduler"]
    CLI["yomiko CLI<br>the state boundary"]
    DB[("SQLite")]
    ExHentai["ExHentai APIs"]
    Hath["Existing H@H client"]
    DownloadDir["Mounted Hath<br>download directory"]
    Pipeline["WebP conversion<br>and 7z packaging"]
    Archive["Archive directory"]

    API -->|"login, list, hath, feedback"| CLI
    Operator -->|"direct CLI commands"| CLI
    CLI <--> DB
    CLI -->|"request H@H download"| ExHentai
    ExHentai --> Hath
    Hath --> DownloadDir
    DownloadDir -->|"completed download<br>triggers periodic scan"| CLI
    CLI --> Pipeline
    Pipeline --> Archive
```

The userscript currently synchronizes cookies and displays gallery status.
Download requests can be sent through the API or CLI.

The gallery-variant foundation currently stores groups, jobs, actions, reviews,
evaluations, and versioned policy data. Compact scoring policies can be checked,
shown, and activated through the CLI, and confirmed groups can be evaluated
locally with explainable deterministic scores. Winner review is required when
the top two scores differ by less than five points. The independent scheduled worker
still reports due jobs without processing them. Discovery, automatic job
handling, review UI, remote rating/favorite execution, H@H replacement requests,
and cleanup reconciliation remain future work. Feedback below `8` durably
deactivates an existing confirmed group; ungrouped feedback keeps the existing
single-gallery behavior.

## Install with Docker Compose

### Requirements

- Docker Engine with Docker Compose
- A configured Hath client that successfully downloads galleries
- The host path to that Hath download directory
- Access to ExHentai/E-Hentai
- A userscript manager such as Violentmonkey or Tampermonkey if you install the
  optional userscript

### 1. Download the deployment files

```bash
mkdir -p yomiko
cd yomiko

curl --fail --location --remote-name \
  https://raw.githubusercontent.com/FlandreDaisuki/yomiko/master/docker/docker-compose.yaml
curl --fail --location --remote-name \
  https://raw.githubusercontent.com/FlandreDaisuki/yomiko/master/docker/.env.example

cp .env.example .env
```

### 2. Configure Yomiko

Edit `.env` and set at least:

```dotenv
HOST_ARCHIVED_DIR=/absolute/path/to/yomiko-archives
HOST_HATH_DOWNLOAD_DIR=/absolute/path/to/hath/downloads
```

`YOMIKO_ENABLE_WEB=true` enables the API, feedback page, and userscript. Set it
to `false` for the standalone CLI scan/archive service; CLI-only mode does not
create or require an API token.

On the first web-enabled start, Yomiko generates a random API token and stores
it as `api-token` in the persistent `yomiko-data` volume or configured
`HOST_DATA_DIR`. Image updates therefore keep the same token, so an installed
userscript does not need to be reinstalled just because the container changed.
To supply your own token instead, set:

```dotenv
YOMIKO_API_TOKEN=replace-with-a-long-random-secret
```

The configured value replaces the persisted token, so reinstall the userscript
after intentionally changing it. Display the active token when needed with:

```bash
docker compose exec yomiko cat /home/yomiko/data/api-token
```

The Hath download and archive directories must be readable and writable by the
container user, UID/GID `1000`. Application data uses a Docker-managed volume
by default. Set `HOST_DATA_DIR` to bind it to a host directory instead; that
directory must also be writable by UID/GID `1000`.

The Compose files also forward the planned variant favorite categories:

```dotenv
YOMIKO_CANONICAL_FAVORITE_CATEGORY=
YOMIKO_ALTERNATE_FAVORITE_CATEGORY=
```

Before variant favorite actions are enabled, assign two distinct values from
`0` through `9`. The current foundation worker only reports queued jobs, so it
does not read, validate, or apply these values yet.

The example publishes Yomiko on every host interface at port `62080`:

```dotenv
YOMIKO_BIND_ADDRESS=0.0.0.0
YOMIKO_PORT=62080
```

Use a firewall or trusted reverse proxy if the host is reachable by untrusted
clients.

### 3. Start Yomiko

```bash
docker compose config --quiet
docker compose up --detach
docker compose ps
```

Verify the service:

```bash
curl --fail http://127.0.0.1:62080/health
```

Skip the HTTP health request in CLI-only mode. Verify the CLI instead:

```bash
docker compose exec yomiko yomiko help
```

### 4. Install the userscript

Skip this step when `YOMIKO_ENABLE_WEB=false`.

Open the following URL through the same host that your browser uses to reach
Yomiko:

```text
http://YOUR_YOMIKO_HOST:62080/yomiko.user.js
```

Accept the installation in your userscript manager, then open an
ExHentai/E-Hentai gallery list. The userscript periodically refreshes cookies,
queries local gallery state, and overlays the known status.

Production images install the script as `Yomiko`; local debug images use
`Yomiko (Debug)` so both variants can be installed independently. The
userscript's numeric version tracks userscript changes, while its description
shows the version of the Yomiko image that served it.

The served userscript contains the active API token. Treat access to the Yomiko
HTTP service and persistent data volume as trusted, and do not expose the
service directly to the public internet.

## Request a gallery

With web enabled, through the HTTP API:

```bash
curl --request PUT \
  --header 'Authorization: Bearer YOUR_YOMIKO_API_TOKEN' \
  'http://127.0.0.1:62080/api/hath_download.sh?gid=123456'
```

In either mode, directly through the CLI:

```bash
docker compose exec yomiko yomiko hath 123456
```

Yomiko asks ExHentai to send the gallery to Hath. Its periodic scanner then
detects the completed download, converts the images, creates the archive, and
updates SQLite.

## Feedback and archives

This page is available when `YOMIKO_ENABLE_WEB=true`.

Open:

```text
http://YOUR_YOMIKO_HOST:62080/feedback.html
```

The page lists up to 20 downloaded galleries that still need feedback plus all
pending candidate-identity and canonical-winner reviews. Review cards expose
the frozen evidence and score breakdown used for the decision; resolving one
requires the API token and refreshes the list, including after a stale conflict.
Archive downloads use the read-only download endpoint. Submitting a rating from
`1` through `11` also requires the API token. A rating below `8` on a confirmed
member durably deactivates and queues actions for its group; an ungrouped low
rating keeps the existing single-gallery path. Ratings `8` through `11` persist
local intent and queue a variant group without waiting for ExHentai; `8`
through `10` delete an existing source archive and record deletion only after
it succeeds, while `11` retains the source archive. The page's favorite value
remains a compatibility argument and is not submitted synchronously for queued
feedback.

The same review interface is available through the CLI:

```bash
docker compose exec yomiko yomiko variants reviews --status pending
docker compose exec yomiko yomiko variants resolve REVIEW_ID --decision same-book
docker compose exec yomiko yomiko variants resolve REVIEW_ID --decision winner --gid GALLERY_GID
```

## Operate and update

```bash
# Follow HTTP server, scheduled scan, and variant-worker logs
docker compose logs --follow yomiko

# Pull the newest image and recreate the service
docker compose pull
docker compose up --detach

# Stop the service
docker compose down
```

To inspect and repair gallery tags left null by a failed metadata binding:

```bash
docker compose exec yomiko yomiko repair-tags --dry-run
docker compose exec yomiko yomiko repair-tags
# For an unattended invocation (still limited to five records):
docker compose exec yomiko yomiko repair-tags --force
```

The repair is resumable and updates only null tag fields. Each invocation shows
the total backlog and attempts no more than five API requests. Failed requests
are reported and remain eligible for a later retry. Interactive repair defaults
to no; use `--force` only when confirmation cannot be supplied. Schema migration
004 must already be applied.

Scheduled scan output is also written inside the container to
`/home/yomiko/logs/yomiko-scan.log`. Variant-worker output is written separately
to `/home/yomiko/logs/yomiko-variants.log`; use Docker's log stream for
persistent operator access.

Persistent state remains in the configured Hath and archive directories and
the `yomiko-data` volume or configured `HOST_DATA_DIR`.

## Project details

See [Architecture](./docs/architecture.md) for CLI behavior, API contracts,
database schema, runtime layout, development setup, design rules, and known
limitations.

## License

Yomiko is available under the [MIT License](./LICENSE).
