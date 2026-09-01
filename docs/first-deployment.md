# First Deployment

This runbook bootstraps a new cluster. It is intentionally the only normal
workflow that uses SSH. After the cluster is healthy, push commits to GitHub
and let Woodpecker run the generated deployment workflows.

## Prerequisites

- The Leader and every Follower have DNS-only origin records for Caddy. Public
  application records point to the Leader; `observer-ingest.<domain>` also
  points directly to the Leader and must not be proxied by Cloudflare.
- Restic is local-only by default. For off-host recovery, set
`RESTIC_REMOTE_ENABLED=true` , provide a verified repository and password
  file, and optionally set `PRODUCTION_REQUIRE_REMOTE_BACKUP=true` .
- The repository contains the final logical inventory in
`config/cluster/nodes/` . Node IDs are stable labels and are not VPS IPs.
- Prepare the shared secret bundle from the Leader before bootstrapping a
  Follower. Keep it root-readable only.
- If MongoDB Atlas is used, remember to add related vps ip to the `IP Access List` .

## Bootstrap order

Copy the reviewed `ops/bootstrap-vps.sh` to `/root/llm-hub-lite-bootstrap.sh`

on each VPS. Run the Leader first, then each Follower. Use `ssh -tt` when
prompts are expected; use `BOOTSTRAP_ASSUME_YES=1` only to skip role
confirmation, not to bypass required secrets.

```bash
ssh -tt root@<leader> \
  'NODE_ID=leader LEADER_PUBLIC_IP=<leader-ip> \
   DOMAIN_NAME=<domain> SSL_EMAIL=<email> WOODPECKER_ADMIN=<github-user> \
   /root/llm-hub-lite-bootstrap.sh'

ssh -tt root@<worker-1> \
  'NODE_ID=worker-1 LEADER_PUBLIC_IP=<leader-ip> \
   DOMAIN_NAME=<domain> SSL_EMAIL=<email> WOODPECKER_ADMIN=<github-user> \
   /root/llm-hub-lite-bootstrap.sh'
```

Repeat the second command for every configured Follower ( `worker-1` through
`worker-4` ). Supply
`RESTIC_REMOTE_PASSWORD_FILE` , `RESTIC_REMOTE_ENV_FILE` ,
`PLATFORM_SECRET_BUNDLE_FILE` , or corresponding environment variables when
running non-interactively. Never generate shared secrets independently on
different nodes. The Leader owns Woodpecker, Beszel Hub, and Observer;
Followers run worker components and only consumers selected by app policy.

On a Follower, `shared-secrets.env` is authoritative for cluster-wide
Woodpecker credentials. If a partial or older installation left different
values in `foundation/env/woodpecker.env` , bootstrap replaces those local
values with the supplied bundle and recreates the worker. The Leader keeps the stricter mismatch check so an established cluster secret cannot be changed by accident.

The Beszel enrollment bundle is authoritative for the Follower's agent key and
token as well. Matching files are left untouched; stale or partial files are
moved to `/opt/platform/beszel/secrets/orphaned/` , replaced from the bundle, and
the Beszel worker is recreated.

Bootstrap and the daily deployment controller also remove image keys that are
no longer declared by the checked-in manifests (for example, a key renamed
during an app migration). This repairs stale installed image environments
without running `clean-vps.sh` or deleting application data.

Bootstrap performs the foreground Compose reconciliation before registering
the reboot units. It then releases its platform lock and queues
`platform.target` asynchronously; this final systemd handoff is intentionally
bounded so an unhealthy consumer cannot leave the SSH session waiting for the
full recovery timeout. A message that recovery continues in the background is
normal. Inspect it with `systemctl status platform-recovery.service` and
`journalctl -u platform-recovery.service -n 200 --no-pager` .
The final public endpoint probes are warning-only and bounded to one retry by
default; use `BOOTSTRAP_ENDPOINT_RETRIES` and
`BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS` when a slower network needs more time.

## Verify and hand off

Run these checks after all nodes have finished:

```bash
for host in <leader> <worker-1> <worker-2> <worker-3> <worker-4>; do
  ssh root@"$host" platformctl health
done
ssh root@<leader> platformctl observer-smoke
curl -fsS https://ci.<domain>/
curl -fsS https://status.<domain>/api/health
curl -fsS https://observer.<domain>/healthz
```

If a Follower is still `joining` , it receives foundation services and the
Observer collector but no consumer. Promote it only after local health passes:

```bash
DOMAIN_NAME=<domain> ops/configure-cluster-node.sh state worker-1 active
git add config/cluster .woodpecker && git commit -m 'activate worker-1' && git push
```

Cluster policy, node inventory, and foundation-policy changes are reconciled by
the generated `cluster-reconcile-leader` → active-Follower workflows. The
Leader ID is intentionally immutable in that workflow; a breaking Leader IP
or promotion uses `BOOTSTRAP_MODE=repair` over SSH, then normal operation
returns to push-driven reconciliation. Follower IP changes are DNS/origin
updates and do not change logical placement IDs.

Flowy (Activepieces) is enabled by default on `worker-3` at
`https://flowy.<domain>` . It uses a single PGlite volume, in-memory Redis, one
worker, and bounded CPU/RAM. The production profile uses Cloudflare R2 for
execution files ( `FLOWY_FILE_STORAGE_LOCATION=S3` ) while keeping metadata in
PGlite. Provision the four `FLOWY_S3_*` values with the generated
`consumer-secrets-flowy-worker-3` workflow before the first Flowy deployment.

Worker-4 is intentionally committed as `joining`, with Wobase disabled and
`BACKUP_ENABLED=false`. Bootstrap it with `NODE_ID=worker-4`, then verify
foundation health and confirm the backup timers are disabled:

```bash
ssh root@<worker-4> \
  'platformctl health &&
   test "$(systemctl is-enabled platform-backup.timer 2>/dev/null || true)" = disabled &&
   test "$(systemctl is-enabled platform-backup-prune.timer 2>/dev/null || true)" = disabled &&
   test "$(systemctl is-enabled platform-backup-check.timer 2>/dev/null || true)" = disabled'
```

After that gate, prepare one reviewed activation commit:

```bash
ops/configure-cluster-node.sh state worker-4 active
ops/configure-app-placement.sh wobase worker-4 --enable
ops/generate-woodpecker-workflows.sh --check
```

The helpers update inventory, policy, and workflows transactionally. Review
and push them together. The target stage creates
the two node-local Wobase secrets before Compose validation; no repository
secret is required. Publication succeeds only after
`worker4-wobase-origin.<domain>/status?ready=1&db=1` is healthy.

Retrieve `WOBASE_BOOT_KEY` from `/etc/llm-hub-lite/wobase.env` as root and
complete Protected Quick Setup at `https://wobase.<domain>/boot`. Then change
`WOBASE_IN_SERVICE=true` in `apps/wobase/config.env`, validate, and deploy that
follow-up commit. Wobase uses local SQLite and has no Restic coverage while
worker-4 remains opted out; changing its singleton target is a fresh deployment.

Review the generated workflows in Woodpecker. For each secret workflow, create
a manual pipeline on `main` and set its `MANUAL_WORKFLOW` variable to the
exact workflow name (for example, `consumer-secrets-librechat-worker-1` ); the
selector prevents unrelated manual workflows from running. Confirm each
consumer's stage, publish, and stop jobs. From this point onward, routine
changes are `git push` followed by the appropriate Woodpecker workflow. Do not
rerun bootstrap for a normal application or Compose update.
