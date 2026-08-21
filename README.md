# llm-hub-lite

Reproducible single-VPS Docker platform for Caddy, Woodpecker CI, Beszel, New API, and CLIProxyAPI. Caddy is the only public ingress; UDP 443 remains enabled for HTTP/3.

## Architecture

- Foundation Compose projects are independent: `compose/foundation/caddy.yml`, `woodpecker.yml`, and `beszel.yml`.
- Applications are declarative descriptors under `apps/<id>/` (manifest, Compose file, and Caddy route).
- Every project joins the external `platform_edge` network; each application also has a private network.
- Production image references are digest-pinned in `ops/images.foundation.prod.env` and `ops/images.apps.prod.env`.
- `SERVICE_WOODPECKER_DISABLE`, `SERVICE_BESZEL_DISABLE`, `APP_NEWAPI_DISABLE`, and `APP_CLIPROXYAPI_DISABLE` independently disable services. Disabled applications retain their data and routes, but their containers are stopped and removed during reconciliation.

## Local validation

```bash
cp .env.dev.example .env.dev
./stack.sh dev validate
./stack.sh dev up

cp .env.prod.example .env.prod
chmod 600 .env.prod
STACK_ENV_FILE=.env.prod.example ./stack.sh prod validate
```

The production runtime file is `.env.prod`; `.env.prod.example` is only a template. Development follows the same convention with `.env.dev`.

## First VPS bootstrap

Bootstrap is the only SSH operation. Copy `ops/bootstrap-vps.sh` to a new host and run it as root. It installs Docker Compose, firewall rules, systemd recovery/timers, root-only secrets, the split foundation/app manifests, and the initial Beszel enrollment. It is idempotent and does not remove persistent data.

Set the GitHub OAuth callback to `https://ci.<your-domain>/authorize` before bootstrap. After bootstrap, daily operation is GitHub push → Woodpecker → deployment controller; no SSH is needed.

## Deployment lifecycle

`.woodpecker/deploy.yml` validates the exact commit, snapshots persistent state, stages a versioned control bundle, reconciles only the changed application configuration, and runs smoke checks. Foundation upgrades use the separate manual `.woodpecker/foundation-upgrade.yml` workflow. A failed deployment restores the previous complete bundle (control pointer, app/foundation manifests, and foundation Compose files).

`platformctl recover` is health-first and never pulls images. Docker restart policies plus `platform-recovery.service` restore the stack after a VPS reboot; periodic health checks repair drift.

## Operations

```text
platformctl status
platformctl health
platformctl recover
platformctl restart all
platformctl recreate beszel
platformctl reload
platformctl logs woodpecker
platformctl backup snapshot manual
platformctl backup prune
platformctl backup check
platformctl restore extract latest
platformctl restore apply latest
```

SQLite databases are copied with SQLite online backup and integrity-checked before Restic snapshots. Live database/WAL files are excluded from filesystem backup. Keep the Restic password in an external password manager and configure an off-site repository for protection from VPS loss.

Beszel is served at `https://status.<your-domain>`. Its agent uses an outbound connection, reads Docker through a loopback-only socket proxy, and does not expose its agent port publicly. Configure `BESZEL_HEARTBEAT_URL` for an external dead-man alert if desired.

## Adding an application

Create `apps/<id>/manifest.env`, `compose.yml`, and `route.caddy`. The manifest must define the disable variable, Compose project/service, network alias, digest manifest key, data directory, health endpoint, smoke URL key, and route template. `platformctl validate` enforces the descriptor contract automatically.

## Security

Only ports 22, 80, 443/TCP, and 443/UDP are opened. Secrets are root-readable only. The Woodpecker agent has Docker-socket access and must be restricted to this trusted repository.
