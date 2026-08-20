# llm-hub-lite

Make it easy to deploy Caddy, New API, and CLIProxyAPI on a single server using Docker. 
The same stack supports HTTP-only local development and automatic HTTPS.

## Services

| Service | Purpose | Internal port |
| --- | --- | ---: |
| Caddy | Public reverse proxy and TLS termination | 80 / 443 |
| New API | LLM aggregation, relay, and administration | 3000 |
| CLIProxyAPI | OpenAI/Gemini/Claude/Codex-compatible proxy | 8317 |

New API uses SQLite by default. Its database is stored under the selected `DATA_ROOT` (development defaults to `data/dev`, production to `data/prod`). 

Development and production use separate runtime roots (`data/dev` and `data/prod`). This prevents a local database, certificate cache, or CLIProxy credential file from being reused accidentally.

The application containers are never published directly. Caddy is the only public entry point. CLIProxyAPI's OAuth callback listeners are bound to the server loopback interface and are not internet-facing.

## Prerequisites

- Docker Engine and Docker Compose v2
- A Docker network named `shared_network` (the helper script creates it when absent)
- For production: DNS records for `newapi.<your-domain>` and `cpa.<your-domain>` pointing to the server

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

Caddy stores ACME certificates and state under `data/prod/caddy`. Keep that directory in backups. `SSL_EMAIL`, `NEW_API_SESSION_SECRET`, `CLIPROXY_API_KEY`, `CLIPROXY_MANAGEMENT_KEY`, `NEW_API_SITE`, `CLIPROXY_SITE`, `SESSION_COOKIE_TRUSTED_URL`, and `DATA_ROOT` are required by the production helper. Production site and trusted-origin values must use `https://`.

The CLIProxyAPI management panel is protected by its management key. The latest CLIProxyAPI also writes management changes back to its configuration, so the generated runtime config is persisted at `data/prod/cliproxy/config.yaml`. `CLIPROXY_MANAGEMENT_KEY` is supplied through the upstream `MANAGEMENT_PASSWORD` environment override and therefore takes effect after container recreation. `CLIPROXY_API_KEY` seeds a new config only; rotate it later through the management API or replace the persisted config only after taking a backup.

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

Images default to the latest upstream tags. Override `CADDY_IMAGE`, `NEW_API_IMAGE`, or `CLIPROXY_IMAGE` in the selected environment file when a specific image reference is required.

## Persistence and backups

Back up these paths:

- `data/dev/new-api` or `data/prod/new-api` - SQLite database and New API data
- `data/dev/cliproxy` or `data/prod/cliproxy` - writable CLIProxyAPI configuration, auth files, logs, and plugins
- `data/dev/caddy` or `data/prod/caddy`, plus the matching `caddy-config` directory - certificates and Caddy state

Existing data under the old top-level `data/` directory is not migrated automatically; back it up and copy it deliberately if it is needed.

## License

This repository is licensed under the MIT License. 
