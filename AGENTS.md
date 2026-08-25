# AGENTS.md

## Purpose

Self-hosted, reproducible multi-node Docker platform for Caddy, Woodpecker CI,
Beszel, and LibreChat.
LibreChat is the enabled active-active follower consumer. Aichorouter, CPAPI,
and OpenObserve (`observer`) are enabled singleton consumers targeted to a
configured follower. Observer also collects platform-labelled Docker logs on
its target host through a read-only socket proxy and bounded Vector buffer.
Legacy New API remains retained and disabled by policy.

## Architecture

- Foundation Compose projects: `compose/foundation/`.
- Cluster inventory and policy: `config/cluster/`.
- Declarative applications: `apps/<id>/manifest.env`,  `compose.yml`, and role
  route templates.
- Generated runtime Caddy configuration: `/opt/apps/llm-hub-lite/shared/runtime/config`.
- Persistent app data: `/opt/apps/llm-hub-lite/shared/data/prod`.
- Foundation state: `/opt/platform/{caddy,woodpecker,beszel}`.
- Root-only runtime configuration: `/etc/llm-hub-lite`.
- Observer durable data is under `shared/data/prod/observer`; its transient
  `log-buffer` is excluded from Restic and discarded when the singleton moves.

## Operations

`ops/bootstrap-vps.sh` is for first deployment only. Daily changes are GitHub push → Woodpecker → `deploy-controller` ; do not add SSH-based daily procedures. `platformctl recover` must remain safe after a VPS reboot and must never pull mutable images.

Production images stay digest-pinned in `ops/images.foundation.prod.env` and
`ops/images.apps.prod.env` . Caddy remains mandatory and exposes 80, 443/TCP,
and 443/UDP on the external `platform_edge` network. Role placement and
intentional service disablement are committed in `config/cluster/policy.env` ;
there are no per-service disable environment variables.

## Validation

Run `bash -n stack.sh ops/*.sh ops/tests/*.sh` and all scripts under `ops/tests/` . Validate every Compose project and the generated Caddy configuration before committing. Keep Bash 3.2 compatibility for local macOS execution.
