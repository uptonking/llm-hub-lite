# AGENTS.md

## Purpose

Self-hosted, reproducible multi-node Docker platform for Caddy, Woodpecker CI, Beszel, and LibreChat.
LibreChat is the enabled active-active follower consumer. Aichorouter, CPAPI, Cursorapi, CPAMP,
and Aichor1 are enabled singleton consumers targeted to configured followers; Aichor1 (Paseo) is
at `aichor1.aichorage.de` on worker-1, and CPAMP (CPA-Manager-Plus Full Mode) is the management/observability
panel for CPAPI at `cpamp.aichorage.de` on worker-1.
Auther (Authelia OIDC) is an enabled leader-proxy singleton on worker-1 at `auther.aichorage.de`; it is the
platform's general-purpose OpenID Connect provider (issuer `https://auther.aichorage.de`), backed by Authelia's
file authentication backend and SQLite storage, exposing `/.well-known/openid-configuration`, `/jwks.json`, and
`/api/oidc/{authorization,token,userinfo}`. Its JWKS RSA key, bootstrap admin digest, and OIDC client-secret
digests are generated on first start by an app-owned `entrypoint.sh` (authelia `crypto pair` / `crypto hash` CLI);
registered relying parties live in the committed `clients.yml` (Authelia replaces lists on `--config` merge, so all
clients occupy one file).
Ladocs (La Suite Docs) is an enabled leader-proxy singleton on worker-5 at `ladocs.aichorage.de`, the
collaborative document editor from Lasuite: nginx frontend proxy plus Django backend, yhub collaboration
server, y-provider converter, and node-local stores (PostgreSQL with `docs` + `yhub` databases, Redis cache,
durable yhub Valkey, silo object storage with the versioned `ladocs-media` bucket). It authenticates through
Auther's `ladocs` OIDC client (shared `auther_ladocs_oidc_secret` repository secret). All initialization runs
inside the long-running containers via wrapper entrypoints (RSA keypair generation, idempotent `yarn
init-db`, Django `migrate`, bucket+versioning bootstrap) so the project never keeps exited one-shot
containers that would fail the platform's all-containers-healthy gate; memory limits keep the whole
project under ~2GB to fit the 3GB budget VPS.
Flowy is enabled on worker-3 alongside Verge3 (Hysteria) as a direct orphan service at `verge3.aichorage.de`. Wabase (Grist) is enabled as a SQLite-backed singleton on active worker-4; scheduled Restic work remains disabled there. Paperlex (Paperless-ngx) is enabled as a singleton on active worker-2. Filer (FileBrowser Quantum) is enabled as a SQLite-backed singleton on active worker-2 at `filer.aichorage.de`, with shared and personal directories, storage quotas, and minimal resource consumption. OpenClouds (OpenCloud) is enabled as a PosixFS-backed singleton on active worker-2 at `openclouds.aichorage.de`, with OIDC authentication through Auther, default 5GB user role quotas, and minimal single-node resource tuning. Verge4 is an orphan service on worker-4 (`verge4.aichorage.de`) and Verge2 is an orphan service on worker-2 (`verge2.aichorage.de`). Verge5 (Hysteria) is a direct orphan service on worker-5 at `verge5.aichorage.de`; that node has `BACKUP_ENABLED=false` and no scheduled Restic work. Verge-relay is a stateless direct UDP forwarder on worker-5 at `verge-relay.aichorage.de:2053` (hop range 31000-36000) that relays raw hysteria2 traffic to `verge3.aichorage.de:443` on worker-3; the forwarding is kernel-level iptables DNAT+MASQUERADE (`DIRECT_FORWARD_TARGET` manifest field) rather than the gost container, because gost's session-managed `udp://` handler fragments QUIC traffic; the gost container stays as a health-check placeholder. Relay clients keep `sni=verge3.aichorage.de` and the real verge3 ACME certificate still validates because DNAT never terminates TLS.
Pigeon (OutlookEmail) is retained but disabled by committed policy. OpenObserve
( `observer` ) is a Leader-only foundation service; read-only socket-proxy and
bounded Vector collectors run on every node and forward platform-labelled logs
to the Leader.
Legacy New API and legacy Verge remain retained and disabled by policy. Aichor is a
repository-owned Paseo child image with durable single-node state and must
recover from an unexpected VPS restart without losing completed conversations.

## Architecture

- Foundation Compose projects: `compose/foundation/`.
- Cluster inventory and policy: `config/cluster/`.
- Declarative applications: `apps/<id>/manifest.env`,                   `compose.yml`, and role
  route templates.
- Generated runtime Caddy configuration: `/opt/apps/llm-hub-lite/shared/runtime/config`.
- Persistent app data: `/opt/apps/llm-hub-lite/shared/data/prod`.
- Foundation state: `/opt/platform/{caddy,woodpecker,beszel,observer}`.
- Root-only runtime configuration: `/etc/llm-hub-lite`.
- Observer durable data is under `/opt/platform/observer/data`; per-node
  collector buffers under `/opt/platform/observer/collector-buffer` are
  transient and excluded from Restic. `platformctl diagnose foundation` reports
  both paths where applicable and warns at the configured thresholds without
  deleting data.

- The current architecture of Foundation apps/services and Consumer apps/services is good.
  - Most requests should go to leader node first, then proxying to follower/worker nodes.
  - orphan services like verge4 can handle requests directly without leader.

- Most docker images this repo used are published by upstream/vendors. The
  repository-owned images are cursorapi, Aichor, and Relaichor; all are manually
  published, digest-pinned, and then deployed by Woodpecker.

## Operations

`ops/bootstrap-vps.sh` is for first deployment only. Daily changes are GitHub push -> Woodpecker -> `deploy-controller` ; do not add SSH-based daily procedures. `platformctl recover` must remain safe after a VPS reboot and must never pull mutable images.

Production images stay digest-pinned in `ops/images.foundation.prod.env` and
`ops/images.apps.prod.env` . Caddy remains mandatory and exposes 80, 443/TCP,
and 443/UDP on the external `platform_edge` network.
Role placement and intentional service disablement are committed in
`config/cluster/policy.env` and `config/cluster/apps/*.policy` ; logical
Follower inventory is managed with `ops/configure-cluster-node.sh` : new nodes
enter `joining` , are bootstrapped for foundation only, and become
consumer-eligible only after an explicit `active` policy change.

- Most re-deployments of services should be handled by woodpecker ci after changes are pushed to github. Few re-deployments of foundational services might require manual work.
  - For changes related to foundational services like caddy/woodpecker, deploying changes with foundational services might require manual work. Multi-stage deployment might be used to avoid self-disruption if it helps.
- use woodpecker-cli to inspect the ci progress/status, related auth/config has been set.
  - just run woodpecker-cli commands like `woodpecker-cli pipeline ps uptonking/llm-hub-lite 216` to inspect ci status.

## Code Conventions

-  make sure all bash scripts and tests files should have less than **700** lines of code(auto-generated files, other code-unrelated or unimportant files are not required). because large file is bad for long-term maintenance. small files and modular architecture are always preferred.

## Validation

Run `bash -n stack.sh ops/*.sh ops/tests/*.sh` and `ops/tests/run-all.sh fast` for the local loop; run `ops/tests/run-all.sh full` before release. Validate every Compose project and the generated Caddy configuration before committing. Keep Bash 3.2 compatibility for local macOS execution.
