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

The CLI owns all database and filesystem operations. The optional HTTP API and
browser UI call the CLI instead of managing state themselves.

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
- Marks downloaded, archived, and rated galleries on ExHentai/E-Hentai pages.
- Provides a small feedback page for downloading archives and recording ratings.

## Workflow

[View in mermaid.live](https://mermaid.live/edit#pako:eNp1UtuO2jAQ_RXLT60UWAiB0Gi1UllQWWmlUkFVqZs-mMQkLomd2s4uWZbXfkA_sV_Sca6AVL8kPjNzxnPOHHEgQoo9vEvESxATqdFm7nMEZ800ffLx4rCkXBOGbtCiV_36-EeV8lVRqQLJMg2JhUjZXvRzwPo_1e1W3qmCBygQYs-oQoSHKGQqS0iBlCY6Vy3NfcKAFygMn4V2lIZbEuxRRiJqGSIhoVzomEr0cfWAgjK_LQcIame5KmbigJabzcpAHfvjQ_s6czGEQFU-gqKtyHlIZNGmz2dP73y8_vII4_v4fY02KpwLAk26GZZExxA0n_p9pk8oXngiiJlc0kCLsz4rltGEcSOxCghHf3__Qd_odgWC8WeQlQluGAzsviIig5g9027m6g7F9d9Vh85C1OvdnRl1bZwJv_l49Xm9aawybT8tNigiSUJl59ZbKWsjeV1YBZGkKhNcUZN13ayyt85vFbnpfJb0V06V_k-HRESMWyhhSlsoBn27DTEV4GjrM7o1w85nV0Dj2KWVpTDGr87AEmqMubSpDF30MkAtfgViC0eShdjTMqcWTqlMibnio4n7GJYuBYE8-IWNg8f7_AQ1GeHfhUibMinyKMbejiQKbnkWwpbOGYkkSVtUUh5SeQ-rq7Fn2yUH9o74gD1nbPfdsWO7tjMZfBi5YwsX2HMHfWfkOq47HA6nw4lzsvBr2XPQn7rjAZzR2Bx7Ojn9A2JBTTE)

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

## Install with Docker Compose

### Requirements

- Docker Engine with Docker Compose
- A configured Hath client that successfully downloads galleries
- The host path to that Hath download directory
- Access to ExHentai/E-Hentai
- A userscript manager such as Violentmonkey or Tampermonkey when web features
  are enabled

### 1. Download the deployment files

```bash
mkdir -p yomiko
cd yomiko

curl --fail --location --remote-name \
  https://raw.githubusercontent.com/FlandreDaisuki/yomiko/master/docker/docker-compose.yaml
curl --fail --location --remote-name \
  https://raw.githubusercontent.com/FlandreDaisuki/yomiko/master/docker/.env.example

cp .env.example .env
mkdir -p data logs
```

### 2. Configure Yomiko

Edit `.env` and set at least:

```dotenv
HOST_ARCHIVED_DIR=/absolute/path/to/yomiko-archives
HOST_HATH_DOWNLOAD_DIR=/absolute/path/to/hath/downloads
YOMIKO_API_TOKEN=replace-with-a-long-random-secret
```

`YOMIKO_ENABLE_WEB=true` enables the API, feedback page, and userscript. Set it
to `false` for the standalone CLI scan/archive service.

Generate a token with:

```bash
openssl rand -hex 32
```

The Hath download, archive, data, and log directories must be readable and
writable by the container user, UID/GID `1000`.

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

The served userscript contains `YOMIKO_API_TOKEN`. Treat access to the Yomiko
HTTP service as trusted and do not expose it directly to the public internet.

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

The page lists downloaded galleries that still need feedback. It can download
the local archive and submit a rating or favorite using your API token.

## Operate and update

```bash
# Follow service logs
docker compose logs --follow yomiko

# Pull the newest image and recreate the service
docker compose pull
docker compose up --detach

# Stop the service
docker compose down
```

Persistent state remains in the configured Hath, archive, data, and log
directories.

## Project details

See [Architecture](./docs/architecture.md) for CLI behavior, API contracts,
database schema, runtime layout, development setup, design rules, and known
limitations.
