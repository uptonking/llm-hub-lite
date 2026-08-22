# llm-hub-lite

Reproducible single-server Docker platform for Caddy, Woodpecker CI, Beszel, New API, and CLIProxyAPI. Caddy is the only public ingress; UDP 443 remains enabled for HTTP/3.

## Architecture

- Foundation Compose projects are independent: `compose/foundation/caddy.yml`, `woodpecker.yml`, and `beszel.yml`.
- Applications are declarative descriptors under `apps/<id>/` (manifest, Compose file, Caddy route, and optional SQLite backup metadata).
- Every project joins the external `platform_edge` network; each application also has a private network.
- `stack.sh` manages the foundation projects and application descriptors together for local development; on a VPS, `platformctl` keeps the same projects independently reconciled.
- Production image references are digest-pinned in `ops/images.foundation.prod.env` and `ops/images.apps.prod.env`.
- `SERVICE_WOODPECKER_DISABLE`, `SERVICE_BESZEL_DISABLE`, `APP_NEWAPI_DISABLE`, and `APP_CLIPROXYAPI_DISABLE` independently disable services. Disabled applications retain their data and backup metadata, but their containers are stopped, removed, and excluded from active Caddy configuration. Removed app descriptors retain their last route and backup metadata as dormant records. Foundation toggles remove their public routes as well; Caddy is mandatory.

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

Bootstrap is the only normal SSH operation. The target should be a clean Debian or Ubuntu VPS with systemd, a public IPv4 address, and root access. Prepare Cloudflare first:

1. Create `A` records for `@` and `*` under `aichorage.de`, both pointing to `166.88.160.139`. Remove stale `AAAA` records unless IPv6 is configured on the VPS. Keep the records DNS-only (gray cloud) until Caddy has issued certificates and the endpoints have been verified.
2. Create a GitHub **OAuth App** (not a GitHub App) with homepage `https://ci.aichorage.de` and callback `https://ci.aichorage.de/authorize`.
3. From the repository checkout, copy and run bootstrap. It prompts for the OAuth client ID and secret and generates all other application secrets:

```bash
scp ops/bootstrap-vps.sh root@166.88.160.139:/root/llm-hub-lite-bootstrap.sh
ssh root@166.88.160.139 \
  'chmod 700 /root/llm-hub-lite-bootstrap.sh && \
   REPO_URL=https://github.com/uptonking/llm-hub-lite.git \
   REPO_SLUG=uptonking/llm-hub-lite \
   DOMAIN_NAME=aichorage.de \
   SSL_EMAIL=your-email@example.com \
   WOODPECKER_ADMIN=uptonking \
   MAIN_BRANCH=main \
   /root/llm-hub-lite-bootstrap.sh'
```

Replace the repository, slug, and email values as needed. The script installs Docker, Compose, UFW rules for `22/tcp`, `80/tcp`, `443/tcp`, and `443/udp`, configures Docker live-restore and log rotation, installs systemd recovery/backup timers, builds the pinned deployment runner, starts the foundation, and enrolls the Beszel agent. It is idempotent and does not remove persistent data. On ARM64, the script uses the pinned Compose checksum for that architecture automatically. If the repository is private, arrange a read-only GitHub deploy key or another source-access mechanism before running bootstrap; the default HTTPS clone assumes the repository is publicly readable.

After bootstrap, retrieve the one-time Beszel login from `/etc/llm-hub-lite/beszel-initial-credentials`, sign in at `https://status.aichorage.de`, change the generated password, and retain or remove the root-only file according to your recovery policy. Verify the host before enabling Cloudflare proxying:

```bash
ssh root@166.88.160.139 '/usr/local/bin/platformctl status && /usr/local/bin/platformctl health'
curl -fsS https://ci.aichorage.de/
curl -fsS https://status.aichorage.de/api/health
```

In Woodpecker, sign in with GitHub, synchronize and activate `uptonking/llm-hub-lite`, and mark only this private repository as **trusted**. The trusted setting is required because the production agent has Docker socket access; do not enable arbitrary repositories on this agent. Confirm the project is configured for the `target=production` and `repo=uptonking/llm-hub-lite` labels.

## Deployment lifecycle

`.woodpecker/deploy.yml` validates the exact commit, snapshots persistent state, stages a versioned control bundle, synchronizes application projects, and runs smoke checks. Foundation-owned changes (Compose foundation files, ingress, environment templates, workflows, systemd units, and controller scripts) are rejected by the application controller and must use the reviewed foundation workflow. Application image upgrades and foundation upgrades use separate manual workflows. A failed deployment restores the previous complete bundle, including its control pointer, image manifests, foundation files, and descriptor registry.

The deployment runner is built locally as `llm-hub-lite/deploy-runner:current` from `ops/deploy-runner/Dockerfile`; its Alpine package versions and Compose binary are checksum-locked. The host records and verifies the immutable image ID before each deployment. Use the manual `runner-upgrade` workflow (or `/usr/local/bin/upgrade-runner` during emergency maintenance) to rebuild and verify the runner.

`platformctl recover` is health-first and never pulls images. It starts unhealthy projects without serial Compose waits under one global recovery deadline, then reports degraded components. Docker restart policies plus `platform-recovery.service` restore the stack after a VPS reboot; periodic health checks repair drift. Generated Caddy configuration is staged and validated before it replaces the live bundle, then Caddy is explicitly reloaded during reconciliation.

## Operations

```text
platformctl status
platformctl health
platformctl recover
platformctl sync all
platformctl restart all
restart-platform all
platformctl recreate beszel
platformctl reload
platformctl logs woodpecker
platformctl backup snapshot manual
platformctl backup prune
platformctl backup check
platformctl restore extract latest
platformctl restore apply latest
upgrade-runner
```

SQLite databases declared by an app descriptor's `SQLITE_PATHS` are copied with SQLite online backup and integrity-checked before Restic snapshots. Woodpecker and every Beszel SQLite database are handled the same way, with collision-safe source maps. Live database/WAL files are excluded recursively from filesystem backup. Keep the Restic password in an external password manager.

Local Restic storage is the default, but it is on the same VPS and therefore is not disaster recovery. Before treating the installation as production, explicitly initialize an S3-compatible repository, provision its root-only password file, then set `RESTIC_REMOTE_ENABLED=true`, `RESTIC_REMOTE_REPOSITORY`, and `RESTIC_REMOTE_PASSWORD_FILE`; snapshots, checks, and pruning will run against both repositories. An unavailable or uninitialized remote repository fails the operation instead of being initialized implicitly.

Beszel is served at `https://status.<your-domain>`. Its agent uses an outbound connection, reads Docker through a loopback-only socket proxy, and does not expose its agent port publicly. Configure `BESZEL_HEARTBEAT_URL` for an external dead-man alert if desired.

## Adding an application

Create `apps/<id>/manifest.env`, `compose.yml`, and `route.caddy`. The manifest must set `MANIFEST_VERSION=1` and define the disable variable, Compose project/service, network alias, digest manifest key, data directory, health endpoint, smoke URL key, and route template. `SQLITE_PATHS` is optional and lists files relative to `DATA_ROOT_REL` for online database backups. `platformctl validate` discovers descriptors automatically, removes orphaned labeled containers from deleted descriptors, and enforces the descriptor contract.

Foundation files do not import or enumerate application descriptors. Add an application by adding its descriptor and image key; disable it with its declared `DISABLE_ENV` (for example `APP_NEWAPI_DISABLE=true`). Disabled projects are stopped and removed during reconciliation while their persistent data remains intact.

## Daily operations

Push application changes to `main` and Woodpecker validates, snapshots, deploys, reconciles, and smoke-tests the exact commit. Foundation/control-plane changes are intentionally rejected by the normal deployment workflow; use the reviewed manual `foundation-upgrade` workflow. Use `app-upgrade` for intentional application image changes, `runner-upgrade` for the deployment runner, and `rollback` for a retained release. A VPS reboot is handled by Docker restart policies plus `platform-recovery.service` and its retry timer; SSH is reserved for first bootstrap and emergency host recovery.

## Security

Only ports 22, 80, 443/TCP, and 443/UDP are opened. Secrets are root-readable only. The Woodpecker agent has Docker-socket access and must be restricted to this trusted repository.
