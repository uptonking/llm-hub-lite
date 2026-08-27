# AGENTS.md

## Purpose

Self-hosted, reproducible multi-node Docker platform for Caddy, Woodpecker CI,
Beszel, and LibreChat.
LibreChat is the enabled active-active follower consumer. Aichorouter, CPAPI,
and Cursorapi are enabled singleton consumers targeted to configured followers.
Pigeon (OutlookEmail) is retained but disabled by committed policy. OpenObserve
(`observer`) is a Leader-only foundation service; read-only socket-proxy and
bounded Vector collectors run on every node and forward platform-labelled logs
to the Leader.
Legacy New API remains retained and disabled by policy.

## Architecture

- Foundation Compose projects: `compose/foundation/`.
- Cluster inventory and policy: `config/cluster/`.
- Declarative applications: `apps/<id>/manifest.env`,  `compose.yml`, and role
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

## Operations

`ops/bootstrap-vps.sh` is for first deployment only. Daily changes are GitHub push → Woodpecker → `deploy-controller` ; do not add SSH-based daily procedures. `platformctl recover` must remain safe after a VPS reboot and must never pull mutable images.

Production images stay digest-pinned in `ops/images.foundation.prod.env` and
`ops/images.apps.prod.env` . Caddy remains mandatory and exposes 80, 443/TCP,
and 443/UDP on the external `platform_edge` network. Role placement and
intentional service disablement are committed in `config/cluster/policy.env`
and `config/cluster/apps/*.policy`;
there are no per-service disable environment variables.

## Validation

Run `bash -n stack.sh ops/*.sh ops/tests/*.sh` and all scripts under `ops/tests/` . Validate every Compose project and the generated Caddy configuration before committing. Keep Bash 3.2 compatibility for local macOS execution.
