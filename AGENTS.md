# AGENTS.md

## Purpose

Self-hosted, reproducible Docker platform for Caddy, Woodpecker CI, Beszel, New API, and CLIProxyAPI on one VPS.

## Layout

- Foundation Compose projects: `compose/foundation/`.
- Declarative applications: `apps/<id>/manifest.env`, `compose.yml`, `route.caddy`.
- Generated runtime Caddy configuration: `/opt/apps/llm-hub-lite/shared/runtime/config`.
- Persistent app data: `/opt/apps/llm-hub-lite/shared/data/prod`.
- Foundation state: `/opt/platform/{caddy,woodpecker,beszel}`.
- Root-only runtime configuration: `/etc/llm-hub-lite`.

## Operations

`ops/bootstrap-vps.sh` is for first deployment only. Daily changes are GitHub push → Woodpecker → `deploy-controller`; do not add SSH-based daily procedures. `platformctl recover` must remain safe after a VPS reboot and must never pull mutable images.

Production images stay digest-pinned in `ops/images.foundation.prod.env` and `ops/images.apps.prod.env`. Caddy remains mandatory and exposes 80, 443/TCP, and 443/UDP on the external `platform_edge` network. Woodpecker and Beszel are independently disableable with `SERVICE_WOODPECKER_DISABLE` and `SERVICE_BESZEL_DISABLE`; applications use their descriptor `DISABLE_ENV` variables.

## Validation

Run `bash -n stack.sh ops/*.sh ops/tests/*.sh` and all scripts under `ops/tests/`. Validate every Compose project and the generated Caddy configuration before committing. Keep Bash 3.2 compatibility for local macOS execution.
