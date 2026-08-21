# llm-hub-lite

Make it easy to deploy Caddy, New API, and CLIProxyAPI on a single server using Docker. 
The same stack supports HTTP-only local development and automatic HTTPS.

## Services

| Service | Purpose | Internal port |
| --- | --- | ---: |
| Caddy | Public reverse proxy and TLS termination | 80 / 443 |
| New API | LLM aggregation, relay, and administration | 3000 |
| CLIProxyAPI | OpenAI/Gemini/Claude/Codex-compatible proxy | 8317 |
| Beszel hub | VPS monitoring UI and agent enrollment | 8090 (internal) |

New API uses SQLite by default. Its database is stored under the selected `DATA_ROOT` (development defaults to `data/dev`; production should use an absolute shared path such as `/opt/apps/llm-hub-lite/shared/data/prod`).

Development and production use separate runtime roots. Production keeps its runtime root and environment file outside Git release directories, preventing a local database, certificate cache, or CLIProxy credential file from being reused accidentally.

The application containers are never published directly. Caddy is the only public entry point. CLIProxyAPI's OAuth callback listeners are bound to the server loopback interface and are not internet-facing.

## Prerequisites

- Docker Engine and Docker Compose v2
- A Docker network named `shared_network` (the helper script creates it when absent)
- For production: DNS records for `newapi.<your-domain>`, `cpa.<your-domain>`, `ci.<your-domain>`, and `status.<your-domain>` pointing to the server

## Local development

Create a local environment file and start the explicit development Compose profile:

```bash
cp .env.dev.example .env.dev
./stack.sh dev up
```

The supported wrapper requires `.env.dev`.

Services:

- New API: http://newapi.localhost:4080
- CLIProxyAPI: http://cpa.localhost:4080
- CLIProxyAPI management panel: http://cpa.localhost:4080/management.html

The local overlay publishes only Caddy's HTTP port and the loopback-only OAuth callback ports (`8085`, `1455`, `54545`, and `51121`). 

## Production deployment

Create a production environment file and configure the options:

```bash
cp .env.production.example .env.production
# chmod 600 .env.production
./stack.sh prod validate
./stack.sh prod up
```

Set the complete HTTPS site addresses in the production environment file:

- `NEW_API_SITE=https://newapi.<DOMAIN_NAME>` -> New API
- `CLIPROXY_SITE=https://cpa.<DOMAIN_NAME>` -> CLIProxyAPI
- `WOODPECKER_SITE=https://ci.<DOMAIN_NAME>` -> Woodpecker, when enabled
- `BESZEL_SITE=https://status.<DOMAIN_NAME>` -> Beszel monitoring

Caddy stores ACME certificates and state under the configured production data root. Keep that directory in backups. `SSL_EMAIL`, `NEW_API_SESSION_SECRET`, `CLIPROXY_API_KEY`, `CLIPROXY_MANAGEMENT_KEY`, `NEW_API_SITE`, `CLIPROXY_SITE`, `WOODPECKER_SITE`, `SESSION_COOKIE_TRUSTED_URL`, and `DATA_ROOT` are required by the production helper. Production site and trusted-origin values must use `https://`, and `DATA_ROOT` must be absolute.

The CLIProxyAPI management panel is protected by its management key. The latest CLIProxyAPI also writes management changes back to its configuration, so the generated runtime config is persisted under `${DATA_ROOT}/cliproxy/config.yaml`. `CLIPROXY_MANAGEMENT_KEY` is supplied through the upstream `MANAGEMENT_PASSWORD` environment override and therefore takes effect after container recreation. `CLIPROXY_API_KEY` seeds a new config only; rotate it later through the management API or replace the persisted config only after taking a backup.

## CLIProxyAPI OAuth

The latest CLIProxyAPI uses local callback URLs for provider login. For remote administration, forward the loopback ports from the server to your workstation before starting OAuth:

```bash
ssh -N \
  -L 8085:127.0.0.1:8085 \
  -L 1455:127.0.0.1:1455 \
  -L 54545:127.0.0.1:54545 \
  -L 51121:127.0.0.1:51121 \
  user@your-server
```

Then use `https://cpa.<your-domain>/management.html` in the forwarded browser session.

## Operations

The mode argument is always explicit:

```bash
./stack.sh dev up
./stack.sh dev logs
./stack.sh prod pull
./stack.sh prod restart
./stack.sh prod reload
./stack.sh prod validate
```

`validate` checks the Compose model without creating networks or printing secrets. Production `config` output is intentionally rejected because it would expose interpolated credentials. `reload` validates the Caddyfile before applying it. The compatibility scripts use production by default for updates/reloads and development by default for restarts:

```bash
./update-docker.sh prod
./caddy-reload.sh prod
./restart-docker.sh dev
```

Development images may use upstream tags. Production should set `CADDY_IMAGE`, `NEW_API_IMAGE`, and `CLIPROXY_IMAGE` to approved versioned references or immutable digests. Production validation rejects `:latest`; `update-docker.sh` remains a manual image-upgrade helper and is not called by the Woodpecker source deployment workflow.

## Woodpecker deployment

The repository includes a non-secret Woodpecker workflow in `.woodpecker/deploy.yml`. It deploys only successful `push` events on `main`, serializes production deployments, and passes the exact commit SHA to a VPS-side release controller. Pull requests are validated by GitHub Actions in `.github/workflows/validate.yml` and never receive production access.

The Woodpecker control plane is a separate Compose project under `ops/woodpecker`. It is exposed through the existing Caddy instance at `WOODPECKER_SITE`, persists its database under `/opt/platform/woodpecker`, and uses a dedicated agent labelled `target=production` and `repo=uptonking/llm-hub-lite`.

The production Woodpecker project must have pull-request and fork events disabled and must be marked trusted before the deployment workflow can mount the Docker socket. Docker socket access is root-equivalent on the VPS, so the agent must not run unrelated repositories.

The first VPS installation is reproducible and interactive. Create a GitHub
OAuth App first with callback URL `https://ci.aichorage.de/authorize`, then run
the bootstrap script as root on the VPS:

```bash
scp ops/bootstrap-vps.sh root@166.88.160.139:/root/llm-hub-lite-bootstrap.sh
ssh -t root@166.88.160.139 /root/llm-hub-lite-bootstrap.sh
```

The script prompts for OAuth credentials without echoing the secret, installs
`restic`, `sqlite3`, and `jq`, generates application and agent credentials,
enables the firewall, installs the controller and systemd units, performs the
initial exact-SHA deployment, and starts Woodpecker and Beszel. It preserves
existing host environment files, releases, databases, certificates, and OAuth
credentials on repeated runs. Production credentials live only under
`/opt/apps/llm-hub-lite/shared`, `/opt/platform/woodpecker`, and
`/opt/platform/beszel`; they are never copied into Git releases.

After bootstrap, activate `uptonking/llm-hub-lite`, disable pull-request and
fork events, and mark only this repository trusted. Releases are stored under
`/opt/apps/llm-hub-lite/releases/<commit-sha>` with `current` and `previous`
symlinks.

The controller performs Compose/Caddy validation, backs up persistent data,
stages reviewed runtime files under `/opt/apps/llm-hub-lite/shared/runtime`,
reconciles the stack from that stable path, reloads Caddy, and runs remote smoke
checks. The stable path prevents Docker Compose from recreating unchanged
containers only because the Git release path changed. The first deployment
after adopting this layout recreates the stack once to migrate Compose metadata.

A failed deployment remains available for inspection and is not automatically
reverted. Roll back through the audited manual Woodpecker workflow and set
`ROLLBACK_TARGET` to `previous` or an existing full commit SHA. The CLI equivalent is:

```bash
woodpecker-cli pipeline start uptonking/llm-hub-lite last \
  --param ROLLBACK_TARGET=previous
```

SSH rollback remains an emergency recovery path only. Normal operation is
GitHub push -> Woodpecker -> deployment controller.

Woodpecker upgrades are explicit and backed up first:

```bash
ops/woodpecker/manage.sh upgrade
```

Change only reviewed digest pins in `/opt/platform/woodpecker/.env` or the
application production environment. Never replace production pins with mutable
tags.

## Beszel monitoring

Beszel is available at `https://status.<your-domain>` through Caddy. The agent
uses host networking and an outbound WebSocket, so there is no public listener
on port `45876`; UFW only permits SSH, HTTP/HTTPS, and HTTP/3. The hub database,
agent fingerprint, key, and token are under `/opt/platform/beszel` and are
included in encrypted backups.

## Persistence, backups, and reboot recovery

Back up these paths:

- the selected runtime root's `new-api` directory - SQLite database and New API data
- the selected runtime root's `cliproxy` directory - writable CLIProxyAPI configuration, auth files, logs, and plugins
- the selected runtime root's `caddy` and `caddy-config` directories - certificates and Caddy state
- `/opt/platform/woodpecker/data` - Woodpecker's SQLite database and repository state
- `/opt/platform/beszel/hub` and `/opt/platform/beszel/agent` - monitoring history and agent identity

The bootstrap creates an encrypted local Restic repository at
`/opt/backups/llm-hub-lite/repository`, protected by
`/etc/llm-hub-lite/restic-password` (root-only). A systemd timer runs every 15
minutes, keeps hourly/daily/weekly/monthly retention, and runs `restic check`
at least weekly. SQLite databases are copied with SQLite's online `.backup`
operation and integrity-checked; live database, journal, WAL, and SHM files are
excluded from the filesystem portion of the snapshot so an inconsistent copy
cannot override the verified one. `platformctl backup manual` creates an
immediate snapshot; `platformctl restore latest` extracts to a new directory
for validation and deliberate atomic replacement.

All platform services are enabled through `platform.target`; Docker/network
ordering, health-gated Compose startup, and bounded retries make a VPS reboot
reconcile the complete platform automatically. `platform-health.timer` checks
and repairs drift every 15 minutes. `platformctl status` and
`platformctl recover` are the primary diagnostics/recovery commands.

Existing data under the old top-level `data/` directory is not migrated automatically; back it up and copy it deliberately if it is needed.

## License

This repository is licensed under the MIT License. 
