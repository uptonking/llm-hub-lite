# Restart and Recovery

The platform is designed to recover after a VPS reboot without pulling
mutable images. Docker restart policies start individual containers; systemd
then recreates the shared network, applies the firewall, and runs
`platformctl recover`. Foundation projects are started and health-checked
before consumers. A failed consumer leaves the last valid Caddy routes in
place and is retried by the recovery timer. Direct/orphan consumers are part
of the same ordered consumer recovery, so their bind-mounted runtime files and
persistent data are available before the service is started.
Recovery also derives Caddy's UDP bind from the live node role before starting
foundation services: the Leader owns public UDP/443, while followers keep
Caddy on the configured loopback fallback so reviewed direct listeners can own
their public UDP ports.

The bootstrap script uses the same ordering: it holds the platform lock while
installing and reconciling files, completes the post-bootstrap snapshot, then
releases the lock before queuing `platform.target`. This avoids a systemd
dependency waiting on a lock held by its parent SSH process. The target handoff
is asynchronous and bounded; a slow recovery is reported through systemd and
continues via the recovery/retry timers.

Recovery uses a root-only validation stamp at
`/etc/llm-hub-lite/validation.stamp`. When the current release, committed
policies, image locks, node configuration, runtime environment, and Compose
tool identity still match the stamp, recovery performs structural validation
and skips the expensive external Compose/Caddy validation. A changed or
missing input automatically falls back to full validation. Use
`platformctl recover --full` when deliberately rechecking every Compose model
after a Docker or Compose upgrade.

## Planned restart while healthy

Use the smallest scope that matches the change:

```sh
platformctl restart app:/opt/platform/control/current/apps/aichorouter
platformctl restart observer-controller
platformctl restart all
```

`restart` only restarts existing containers. Use `recreate` when an environment
file, image digest, resource limit, or Compose definition changed. Use
`platformctl sync all` after a release has been installed and several projects
must be reconciled. The normal release path remains GitHub push to Woodpecker;
these commands are break-glass host maintenance.

## After a VPS reboot

Wait for systemd recovery, then inspect the local node:

```sh
systemctl status platform-recovery.service --no-pager
platformctl status
platformctl health
platformctl diagnose foundation
```

On the Leader, also verify end-to-end ingestion:

```sh
platformctl observer-smoke
```

The smoke check expects recent heartbeat records only from active collector
nodes. Immediately after bringing up the Leader alone, missing Follower
heartbeats are expected. Recover the Followers and run it again.

## If services remain down

Run recovery once from the affected VPS. It is idempotent and uses the
installed digest-pinned images:

```sh
platformctl recover
platformctl health
```

The periodic `platform-health.service` uses a non-blocking read lock. If a
deployment is active it logs that the check was skipped and exits successfully;
the next timer run checks the completed transaction. Manual `platformctl
health`, `status`, and `diagnose` calls wait up to 30 seconds for a consistent
snapshot. `platformctl observer-smoke` takes the same short local snapshot
lock, releases it before network retries, and cannot hold a deploy lock during
a slow Observer query.

For an unhealthy project, inspect its Compose state and recent diagnostics:

```sh
platformctl diagnose foundation
platformctl diagnose consumers
platformctl diagnose app:aichorouter
platformctl diagnose app:verge
journalctl -u platform-recovery.service -n 200 --no-pager
```

Correct the root cause, then retry the same Woodpecker build or run
`platformctl sync <scope>`. Do not delete bind-mounted data while diagnosing.
Observer durable data is under `/opt/platform/observer/data`; collector
buffers are transient and bounded. Restic snapshots include durable state and
runtime configuration.

## Controller outage or replacement

There is no automatic controller failover. Recover the Leader first, then the
Followers. If the Leader is lost, restore the last verified remote snapshot to
the replacement host with `RESTORE_IDENTITY=1` only as an explicit promotion,
verify foundation health and Caddy routes, and change public DNS after the
replacement is serving. Keep the previous node identity and route files until
recovery is complete.
