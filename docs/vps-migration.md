# Follower VPS Migration

`ops/change-vps-for-consumer-node.sh` moves an active follower to a fresh VPS
while retaining its logical node ID, application data, generated routes,
foundation identities, and runtime secrets. The source is deliberately left
stopped after the cutover so Woodpecker and Beszel do not run twice.

## Before You Start

Update every `worker<N>-*-origin.aichorage.de` DNS-only record for the node in
Cloudflare to the new VPS address. Remove stale AAAA records. The command
checks only enabled routes placed on the source node; disabled-app origins do
not block a migration. Keep `observer-ingest.<domain>` pointed directly at the
Leader. Public records such as `ci` , `status` , and public app names may be
Cloudflare-proxied and are checked manually after the cutover.

The target must be a new VPS reachable as `root` ; the source must be healthy.
Pre-populate both VPS host keys in the operator's SSH known-hosts file; the
command uses strict host-key verification and never accepts new keys.

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
checks blocking. Use `--resume --backup-dir ~/backup-vps`

after a transient failure; exactly one matching run is required, and verified
artifacts and completed phases are rechecked before reuse.

The archive is stored at `~/backup-vps/<migration>/` with mode 700 (archive and
manifest mode 600). It preserves application databases (including SQLite WAL
files and PGlite), releases, certificates, Woodpecker/Beszel identities,
Observer durable data, and runtime secrets. It excludes local Restic
repositories/caches, the Observer collector buffer, maintenance markers,
transaction state, and ephemeral application logs.

## Verify

The command verifies target identity, release SHA, `platformctl health` , the
policy-selected foundation and consumer containers, and that the source has no
managed containers. Public checks remain manual because some records may be
proxied through Cloudflare:

```sh
ssh root@targetIp'platformctl status; platformctl health; docker ps'
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
