# Follower VPS Migration

`ops/change-vps-for-consumer-node.sh` moves an active follower to a fresh VPS while retaining its logical node ID, application data, generated routes, foundation identities, and runtime secrets. The source is deliberately left stopped after the cutover so Woodpecker and Beszel do not run twice.

## Before You Start

Update every `worker<N>-*-origin.aichorage.de` DNS-only record for the node in
Cloudflare to the new VPS address. Remove stale AAAA records. The command
checks enabled proxy routes and direct/orphan public origins placed on the
source node; disabled-app origins do not block a migration. For each active
direct app it also verifies the node-local runtime environment and persistent
data directory before shutdown, then repeats those checks and runs
`platformctl direct-smoke` on the target. Keep `observer-ingest.<domain>` pointed
directly at the Leader. Public records such as `ci`, `status`, and public app
names may be Cloudflare-proxied and are checked manually after the cutover.

The target must be a new VPS reachable as `root` ; the source must be healthy.
If reusing a VPS that was cleaned with `clean-vps.sh` , remove its preserved local Restic tree first ( `/opt/backups/llm-hub-lite` ). Migration intentionally
does not copy local Restic data, and the target freshness check rejects that
tree so an old node's backup state cannot be reused accidentally.
Pre-populate both VPS host keys in the operator's SSH known-hosts file; the command uses strict host-key verification and never accepts new keys.

DNS checks are advisory by default. This allows operation from VPN/proxy
environments that synthesize DNS answers (for example, `198.18.0.0/15` ). The
script still prints every observed answer. Use `--strict-dns` when the local
resolver is known to return authoritative DNS results and you want mismatches
to block the migration.

If MongoDB Atlas is used, remember to add related vps ip to the `IP Access List` .

## Run

From this repository on macOS or Linux:

```sh
ops/change-vps-for-consumer-node.sh \
  --assume-yes \
  --known-hosts ~/.ssh/known_hosts \
  sourceIp targetIp
```

Use `--dry-run` to perform only SSH, identity, target-safety, health, and DNS
checks without creating migration state. Use `--strict-dns` to make the DNS
checks blocking. Use `--resume --backup-dir ~/backup-vps` after a transient
failure; exactly one matching run is required, and verified
artifacts and completed phases are rechecked before reuse.

The transfer mode is persisted in migration state:

- `--transfer-mode local` is the default. The source creates a gzip-compressed archive, the operator computer downloads and verifies it, and then uploads it
  to the target. Interrupted downloads and uploads retry once, then retain their
  partial files so `--resume` can continue through SFTP. Checksum-valid completed
  files are reused after a crash. The full verified archive remains under
`~/backup-vps` until manual cleanup.
- `--transfer-mode direct` sends the same gzip-compressed archive from the
  source VPS straight to the target VPS with a short-lived, forced-SFTP SSH key.
  This avoids routing the large file through the operator computer. Direct mode
  keeps only migration metadata locally and retains the recovery archive on the
  stopped source. Interrupted transfers retry once from zero. On resume,
  incomplete target and legacy local partial files and stale temporary keys are
  deleted before a fresh direct upload; a complete target archive is reused only
  when its SHA-256 checksum passes.

The target validates the compressed archive and its manifest before extracting
it into the original absolute paths. Target-side archive, checksum, manifest,
and staging files are removed before bootstrap to conserve disk space.

For a node whose committed descriptor sets `BACKUP_ENABLED=false` , pass
`--disable-restic-backup` . The option is off by default. It refuses to proceed
unless the source is already running a release with that policy, persists the
choice across `--resume` , and disables the snapshot, prune, and repository-check
timers on the target. This is the required mode for the small worker-3 VPS.
Commit and deploy the descriptor change to the source before running the
migration; the preflight checks both the deployed release and runtime copy.

In local mode, the archive is stored at `~/backup-vps/<migration>/` with mode
700 (archive and manifest mode 600). In direct mode, that directory contains
only state and the bootstrap copy. The archive preserves application databases
(including SQLite WAL files and PGlite), releases, certificates,
Woodpecker/Beszel identities, Observer durable data, and runtime secrets. It
excludes local Restic repositories/caches, the Observer collector buffer,
maintenance markers, transaction state, and ephemeral application logs.

## Worker-3 Example

Worker-3 runs the singleton Flowy consumer. Its PGlite database and runtime
secrets are migrated with the managed-state archive. Before cutover, point the
DNS-only `worker3-flowy-origin.aichorage.de` record to the target VPS, while
leaving the public `flowy.aichorage.de` record routed through the Leader.

First commit and deploy the worker-3 `BACKUP_ENABLED=false` descriptor change.
Set `SOURCE_IP` and `TARGET_IP` to the worker's old and new addresses, then run:

```sh
SOURCE_IP='replace-with-old-worker-3-ip'
TARGET_IP='replace-with-new-worker-3-ip'

ops/change-vps-for-consumer-node.sh \
  --dry-run \
  --disable-restic-backup \
  --backup-dir "$HOME/backup-vps" \
  --known-hosts "$HOME/.ssh/known_hosts" \
  "$SOURCE_IP" "$TARGET_IP"

ops/change-vps-for-consumer-node.sh \
  --assume-yes \
  --disable-restic-backup \
  --backup-dir "$HOME/backup-vps" \
  --known-hosts "$HOME/.ssh/known_hosts" \
  "$SOURCE_IP" "$TARGET_IP"
```

If a post-quiesce step fails, correct the reported cause and repeat the second
command with `--resume` . The stored migration state retains the backup choice,
but repeating `--disable-restic-backup` makes the intended mode explicit.

For direct transfer mode:

```sh
ops/change-vps-for-consumer-node.sh \
  --resume \
  --assume-yes \
  --disable-restic-backup \
  --transfer-mode direct \
  --backup-dir "$HOME/backup-vps" \
  --known-hosts "$HOME/.ssh/known_hosts" \
  "$SOURCE_IP" "$TARGET_IP"
```

Do not omit `--transfer-mode direct` on this first resume from legacy state.
After it is persisted as state version 4, later resumes automatically retain
direct mode and reject attempts to change the route.

After the command reports success, verify the migrated node and its disabled
backup policy:

```sh
ssh "root@$TARGET_IP" '
  platformctl status
  platformctl health
  platformctl diagnose foundation
  platformctl diagnose consumers
  grep "^BACKUP_ENABLED=false$" /etc/llm-hub-lite/node.env
  systemctl is-enabled \
    platform-backup.timer \
    platform-backup-prune.timer \
    platform-backup-check.timer
  docker ps
'
```

All three timer results must be `disabled` . Then verify the Leader-routed
public service and cluster control surfaces:

```sh
curl -fsS https://flowy.aichorage.de/api/v1/health
curl -fsS https://status.aichorage.de/api/health
curl -fsS https://ci.aichorage.de/ >/dev/null

LEADER_IP='replace-with-leader-ip'
WORKER_1_IP='replace-with-worker-1-ip'
WORKER_2_IP='replace-with-worker-2-ip'
for ip in "$LEADER_IP" "$WORKER_1_IP" "$WORKER_2_IP" "$TARGET_IP"; do
  ssh "root@$ip" 'platformctl health'
done
```

Also confirm that worker-3 is connected in the Beszel and Woodpecker user
interfaces before cleaning the old VPS.

## Verify

The command verifies target identity, release SHA, `platformctl health` , the
policy-selected foundation and consumer containers, and that the source has no managed containers. It derives every origin from the enabled manifest route groups, including multi-route consumers such as LibreChat's public and admin
origins. Public checks remain manual because some records may be
proxied through Cloudflare:

```sh
ssh root@targetIp 'platformctl status; platformctl health; docker ps'
dig +short worker1-chat-origin.aichorage.de
dig +short observer-ingest.aichorage.de
curl -fsS https://ci.aichorage.de/
curl -fsS https://status.aichorage.de/api/health
```

Confirm Beszel and Woodpecker agents reconnect with their existing identities.

## Failure And Cleanup

On failure after quiescing begins, do not restart both nodes. The source is
left stopped and all artifacts are retained. The printed recovery command can
re-enable the source only when you decide to roll back. Preflight failures do
not change either VPS. After successful verification, manually remove the
local `~/backup-vps/<migration>/` directory, then copy
`ops/clean-vps.sh` outside managed paths on the old VPS (for example
`/root/clean-vps.sh` ) and run it there with its normal confirmation flow.
