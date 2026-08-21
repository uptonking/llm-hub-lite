# llm-hub-lite

A single-VPS, self-hosted platform for Caddy, New API, CLIProxyAPI,
Woodpecker CI, and Beszel monitoring. Caddy is the only public application
entry point and keeps HTTP/3 enabled on UDP 443.

## Compose model

The application stack uses an explicit base plus one environment overlay:

- `docker-compose.base.yml` — shared service definitions.
- `docker-compose.dev.yml` — local development ports and settings.
- `docker-compose.prod.yml` — production TLS and secret requirements.

Environment naming is symmetric:

- `.env.dev.example` → `.env.dev`
- `.env.prod.example` → `.env.prod`

Production image pins are non-secret and maintained separately in
`ops/images.prod.env`. Every production image must use an immutable digest.

## Local development

```bash
cp .env.dev.example .env.dev
./stack.sh dev validate
./stack.sh dev up
./stack.sh dev logs
```

New API is available at `http://newapi.localhost:4080` and CLIProxyAPI at
`http://cpa.localhost:4080`.

To validate the production model locally:

```bash
cp .env.prod.example .env.prod
chmod 600 .env.prod
./stack.sh prod validate
```

## Production layout

- Application releases: `/opt/apps/llm-hub-lite/releases/<commit-sha>`
- Stable runtime: `/opt/apps/llm-hub-lite/shared/runtime`
- Production secrets: `/opt/apps/llm-hub-lite/shared/.env.prod`
- Woodpecker state: `/opt/platform/woodpecker`
- Beszel state: `/opt/platform/beszel`
- Active image manifest: `/etc/llm-hub-lite/images.env`
- Encrypted Restic repository: `/opt/backups/llm-hub-lite/repository`

`shared_network` connects only Caddy and the upstream control-plane services.
New API and CLIProxyAPI remain on a private backend. The Woodpecker agent has a
dedicated network and is restricted to the trusted production repository.

## GitHub push deployment

Pushes to `main` trigger `.woodpecker/deploy.yml`. Woodpecker passes the exact
commit SHA to the VPS deployment controller, which:

1. Validates Compose and Caddy configuration.
2. Creates a verified Restic snapshot.
3. Stages runtime files under the stable runtime directory.
4. Reconciles containers without pulling images.
5. Reloads Caddy and runs public smoke checks.
6. Automatically restores the prior release if validation fails.

Image upgrades are deliberately separate from source deployments.

## VPS bootstrap

Create the GitHub OAuth application with callback
`https://ci.aichorage.de/authorize`, then run:

```bash
scp ops/bootstrap-vps.sh root@166.88.160.139:/root/llm-hub-lite-bootstrap.sh
ssh -t root@166.88.160.139 /root/llm-hub-lite-bootstrap.sh
```

Bootstrap is idempotent. It preserves credentials and persistent data, installs
a checksum-pinned Docker Compose binary, installs systemd recovery/timers,
enrolls Beszel, and performs a verified backup. This beta stack intentionally
has no compatibility layer for legacy filenames or service units.

## Production operations

`platformctl` is the only supported VPS operations interface:

```bash
platformctl status
platformctl status --json
platformctl health
platformctl recover
platformctl restart app
platformctl recreate beszel
platformctl upgrade app
platformctl reload caddy
platformctl logs woodpecker
```

Semantics are intentionally distinct:

- `recover` is health-first, never pulls, and repairs only broken projects.
- `restart` performs a real restart.
- `recreate` reapplies the active configuration and image manifest.
- `upgrade` snapshots, promotes reviewed pins, pulls, recreates, verifies, and
  automatically rolls back on failure.

Use `platformctl maintenance begin <reason>` before manual data work and
`platformctl maintenance end` afterwards. Recovery timers do not start writers
while maintenance mode is active.

## Beszel monitoring

Beszel is served at `https://status.aichorage.de`. Its agent uses an outbound
WebSocket and does not expose port 45876 publicly. Docker metrics pass through a
loopback-only, read-filtered socket proxy; the agent never mounts the real
Docker socket. Systemd monitoring uses the read-only system D-Bus socket.

Bootstrap configures baseline system-down, CPU, memory, and disk alerts.
`BESZEL_HEARTBEAT_URL` can point to Healthchecks.io, Better Stack, or another
dead-man endpoint so a complete VPS outage is detectable externally.

After saving the initial login in a password manager, remove the VPS copy with:

```bash
platformctl credentials purge-beszel-initial
```

## Reboot recovery

Docker restart policies start all containers concurrently. `platform.target`
then runs a single health-first recovery service with one global deadline.
`platform-health.timer` checks every five minutes and repairs drift. A normal
reboot must restore all public services within five minutes without changing
persistent data.

## Backups and restore

SQLite databases are copied with SQLite's online backup operation and verified
with `PRAGMA integrity_check`. Live database/WAL files are excluded from the
filesystem portion of the snapshot.

```bash
platformctl backup snapshot manual
platformctl backup prune
platformctl backup check
platformctl restore extract latest
platformctl restore apply latest
```

Snapshots run every 15 minutes, prune runs daily, and repository checks run
weekly. Restore extracts and validates first; apply enters persistent
maintenance mode, stops writers, swaps state on the same filesystem, verifies
the platform, and restores the previous directories on failure.

The Restic password must also be kept in an external password manager. Local
backups protect against application and operator mistakes but not complete VPS
or disk loss; an S3-compatible offsite repository can be added later.

## Security boundaries

- Only ports 22, 80, 443/TCP, and 443/UDP are public.
- CLIProxyAPI OAuth callback ports bind to loopback only.
- Production secrets remain in root-only host files.
- Beszel container details/log access is disabled by default.
- Woodpecker's Docker socket is root-equivalent; only the trusted deployment
  repository may run on that agent.
- Production images and the Compose executable are digest/checksum pinned.

## License

MIT
