# Restart and Recovery

The platform is designed to recover after a VPS reboot without pulling
mutable images. Docker restart policies start individual containers; systemd
then recreates the shared network, applies the firewall, and runs
`platformctl recover`. Foundation projects are started and health-checked
before consumers. A failed consumer leaves the last valid Caddy routes in
place and is retried by the recovery timer. Stateful consumers declare durable
recovery paths; recovery fails closed when those paths are missing or empty,
so a reboot can never turn a previously configured app into a blank instance.
Direct/orphan consumers are part
of the same ordered consumer recovery, so their bind-mounted runtime files and
persistent data are available before the service is started.
Recovery also derives Caddy's UDP bind from the live node role before starting
foundation services: the Leader owns public UDP/443, while followers keep
Caddy on the configured loopback fallback so reviewed direct listeners can own
their public UDP ports.
For a direct service, recovery also verifies the manifest-selected runtime env,
rendered `RUNTIME_CONFIG_FILE`, data directory, process state, and every
declared published listener before reporting success. It uses `--pull never`,
so a reboot cannot replace a digest-pinned image with mutable registry state.

The boot fallback timer runs once, 120 seconds after boot. It does not repeat
on every timer activation while the platform is healthy. If recovery fails,
`platform-recovery-retry.service` retries the failure after 60 seconds, with a
maximum of five starts in 15 minutes; a successful retry becomes inactive.
This prevents a healthy node from spending CPU on perpetual reconciliation.
Recovery runs with a lower scheduler priority (`Nice=10`, `CPUWeight=20`) so
maintenance work cannot compete with foreground applications on an
oversubscribed VPS. `platformctl diagnose` reports a one-second CPU-steal
sample and warns when the VPS host is withholding more than 20% of scheduled
CPU time; CPU steal is provider contention and cannot be fixed by container
configuration.

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
and skips the expensive external Compose/Caddy validation. If the stamp and
runtime Caddyfile are current, all managed containers are healthy, durable
recovery state is present, no singleton transition is pending, and no inactive
containers require cleanup, recovery exits through a lightweight no-op path
without starting Compose projects or reloading Caddy. A changed or missing
input automatically falls back to full validation. Use
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

Foundation diagnostics include recovery timer/service state, trigger timing,
retry CPU time and restart count, retry journal activity from the last 24
hours, and whether the installed host units match the current control release.

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

### Aichor state after restart

Aichor stores its Paseo identity, conversation/workspace metadata, agent
credentials, and workspace files under
`/opt/apps/llm-hub-lite/shared/data/prod/aichor`. The generated
`AICHOR_PASSWORD` remains in `/etc/llm-hub-lite/aichor.env`. Docker restarts the
same digest-pinned container with those mounts after a crash or reboot; the
recovery controller does not archive or recreate this directory. On recovery,
`.paseo/server-id`, `.paseo/daemon-keypair.json`, and `.paseo/config.json` must
exist and be non-empty. `.paseo/runtime` is disposable runtime cache and is
excluded from backups and fresh singleton moves.

After a worker restart, reconnect to `https://aichor.<domain>`, confirm the
conversation list is unchanged, open a prior conversation and verify its
messages, then confirm the expected workspace files are present. A hard crash
can interrupt an in-flight request, but it must not erase completed history.

## Controller outage or replacement

There is no automatic controller failover. Recover the Leader first, then the
Followers. If the Leader is lost, restore the last verified remote snapshot to
the replacement host with `RESTORE_IDENTITY=1` only as an explicit promotion,
verify foundation health and Caddy routes, and change public DNS after the
replacement is serving. Keep the previous node identity and route files until
recovery is complete.
