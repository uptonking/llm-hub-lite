# First Deployment

This runbook bootstraps a new cluster. It is intentionally the only normal
workflow that uses SSH. After the cluster is healthy, push commits to GitHub
and let Woodpecker run the generated deployment workflows.

## Prerequisites

- The Leader and every Follower have DNS-only origin records for Caddy. Public
  application records point to the Leader; `observer-ingest.<domain>` also
  points directly to the Leader and must not be proxied by Cloudflare.
- The remote Restic repository is initialized, or the first bootstrap is run
  with credentials that allow `restic init` to be performed explicitly.
- The repository contains the final logical inventory in
  `config/cluster/nodes/`. Node IDs are stable labels and are not VPS IPs.
- Prepare the shared secret bundle from the Leader before bootstrapping a
  Follower. Keep it root-readable only.

## Bootstrap order

Copy the reviewed `ops/bootstrap-vps.sh` to `/root/llm-hub-lite-bootstrap.sh`
on each VPS. Run the Leader first, then each Follower. Use `ssh -tt` when
prompts are expected; use `BOOTSTRAP_ASSUME_YES=1` only to skip role
confirmation, not to bypass required secrets.

```bash
ssh -tt root@<leader> \
  'NODE_ID=leader LEADER_PUBLIC_IP=<leader-ip> \
   DOMAIN_NAME=<domain> SSL_EMAIL=<email> WOODPECKER_ADMIN=<github-user> \
   RESTIC_REMOTE_REPOSITORY=<repository> \
   /root/llm-hub-lite-bootstrap.sh'

ssh -tt root@<worker-1> \
  'NODE_ID=worker-1 LEADER_PUBLIC_IP=<leader-ip> \
   DOMAIN_NAME=<domain> SSL_EMAIL=<email> WOODPECKER_ADMIN=<github-user> \
   RESTIC_REMOTE_REPOSITORY=<repository>/worker-1 \
   /root/llm-hub-lite-bootstrap.sh'
```

Repeat the second command for every configured Follower. Supply
`RESTIC_REMOTE_PASSWORD_FILE`, `RESTIC_REMOTE_ENV_FILE`,
`PLATFORM_SECRET_BUNDLE_FILE`, or corresponding environment variables when
running non-interactively. Never generate shared secrets independently on
different nodes. The Leader owns Woodpecker, Beszel Hub, and Observer;
Followers run worker components and only consumers selected by app policy.

Bootstrap performs the foreground Compose reconciliation before registering
the reboot units. It then releases its platform lock and queues
`platform.target` asynchronously; this final systemd handoff is intentionally
bounded so an unhealthy consumer cannot leave the SSH session waiting for the
full recovery timeout. A message that recovery continues in the background is
normal. Inspect it with `systemctl status platform-recovery.service` and
`journalctl -u platform-recovery.service -n 200 --no-pager`.
The final public endpoint probes are warning-only and bounded to one retry by
default; use `BOOTSTRAP_ENDPOINT_RETRIES` and
`BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS` when a slower network needs more time.

## Verify and hand off

Run these checks after all nodes have finished:

```bash
for host in <leader> <worker-1> <worker-2>; do
  ssh root@"$host" platformctl health
done
ssh root@<leader> platformctl observer-smoke
curl -fsS https://ci.<domain>/
curl -fsS https://status.<domain>/api/health
curl -fsS https://observer.<domain>/healthz
```

If a Follower is still `joining`, it receives foundation services and the
Observer collector but no consumer. Promote it only after local health passes:

```bash
DOMAIN_NAME=<domain> ops/configure-cluster-node.sh state worker-1 active
git add config/cluster .woodpecker && git commit -m 'activate worker-1' && git push
```

Review the generated workflows in Woodpecker, run the manual secret workflows
for enabled consumers, and confirm each consumer's stage, publish, and stop
jobs. From this point onward, routine changes are `git push` followed by the
appropriate Woodpecker workflow. Do not rerun bootstrap for a normal
application or Compose update.
