# AGENTS.md

## Purpose
self-hosted deployment template for Caddy reverse proxy with automatic TLS.

## Repository Role
- Category: `*-self-hosted` (public GitHub repository).
- Related local stack: `../caddy-docker`.
- Main entrypoint: `docker-compose.base.yml` with explicit development and production overlays.

## Stack Summary
- Service: `caddy`.
- Exposed ports: `80`, `443/tcp`, `443/udp`.
- External network: `shared_network`.

## Data and Config
- Caddy config: `./config`.
- Runtime/cert data: `./data`.
- Optional custom build: `Dockerfile` exists, but compose uses `caddy:latest` by default.
- Woodpecker control plane: `./ops/woodpecker` (kept as a separate Compose project).
- VPS release controller: `./ops/deploy-controller.sh`.

## Operations
- Local development: `./stack.sh dev ...`.
- Production control on the VPS: `platformctl ...`.
- Caddy reload: `platformctl reload caddy`.
- Deploy an exact Git SHA through Woodpecker: `.woodpecker/deploy.yml`.

## AI Working Notes
- Keep development settings in `.env.dev` and production domain and certificate settings in `.env.prod` (`DOMAIN_NAME`, `SSL_EMAIL`).
- Production `DATA_ROOT` must be an absolute shared path; production image references must not use `:latest`.
- Do not remove UDP 443 mapping if HTTP/3 support is expected.
- Preserve `shared_network` to keep upstream service routing consistent.
- The production Woodpecker agent is trusted and Docker-socket backed; do not run unrelated repositories or pull-request pipelines on it.
- Bootstrap the VPS with `ops/bootstrap-vps.sh`; use `platformctl` for later operations.
- Normal rollback is the manual `.woodpecker/rollback.yml` workflow; direct SSH rollback is emergency-only.
