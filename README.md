# llm-hub-lite

Reproducible multi-node Docker platform for Caddy, Woodpecker CI, Beszel, and LibreChat.

## Architecture

The committed inventory is in `config/cluster/` . The current Leader has stable
node ID `leader` ; it runs Caddy, Woodpecker server/controller, a trusted
deployment agent, Beszel Hub, and a Beszel agent. Followers have stable node
IDs `worker-1` and `worker-2` ; they run Caddy, Woodpecker workers, Beszel
agents, and LibreChat. The IDs are stable labels; the role is selected only by
`LEADER_NODE_ID` in the policy.

Caddy is installed on every node. Public DNS names point to the Leader. The
Leader derives consumer upstreams from every follower entry in
`config/cluster/nodes/*.env` ; adding a follower therefore does not require
editing a Caddy route. Keep origin records DNS-only and restrict follower
Docker-published HTTPS/HTTP3 to the Leader IP with the `DOCKER-USER` chain.
UFW keeps TCP and UDP port 443 allowed on every node. The Docker restriction
is scoped to the detected default-route interface so it cannot block outbound
HTTPS from Woodpecker, LibreChat, or deployment containers. Set
`PLATFORM_PUBLIC_INTERFACE` in `/etc/llm-hub-lite/platform.env` only when the
VPS public ingress does not use its default-route interface.
Set `REPO_SLUG` in `config/cluster/policy.env` to the GitHub owner/repository
that runs this stack; generated Woodpecker labels use that value.

The control plane is intentionally single-controller: Woodpecker and Beszel
use persistent SQLite on the Leader. LibreChat replicas share external Atlas
MongoDB and Upstash Redis state. This provides consumer availability without claiming automatic
control-plane failover.

## Configuration

Copy `.env.prod.example` to `.env.prod` and keep it root-readable only. Put
OAuth, Neon, application keys, and all other secrets in that runtime file or
the root-only foundation files under `/etc/llm-hub-lite` . Never commit them.
The runtime filenames `node.env` and `shared-secrets.env` are ignored as a
second line of defense. Run `ops/check-ip-privacy.sh --cached` before committing;
CI rejects globally routable IPv4 literals anywhere in tracked content.
Production backup policy requires `RESTIC_REMOTE_ENABLED=true` , a verified
`RESTIC_REMOTE_REPOSITORY` , and the root-only password file named by
`RESTIC_REMOTE_PASSWORD_FILE` before the first bootstrap. If the remote
backend needs provider credentials (for example S3 or B2), put the required
Restic variables in a root-only file at `RESTIC_REMOTE_ENV_FILE` ; pass
`RESTIC_REMOTE_ENV_SOURCE_FILE=/path/to/file` during bootstrap so it is
installed on the VPS and reused by all backup timers. Prefer a separate remote
repository or backend prefix for each stable node ID. Shared repositories are
supported: snapshots and retention are scoped by the `node:<NODE_ID>` tag.

Service disablement is committed in `config/cluster/policy.env` ; there are no
per-service `*_DISABLE` switches. Foundation placement is policy-controlled;
consumer placement is declared by `PLACEMENT=follower` in each app manifest.
When a consumer is active, the Leader can generate the initial shared random
secrets once, while every Follower must receive the same values from the
root-only bundle or explicit environment variables. A non-interactive
bootstrap fails closed instead of inventing per-node credentials. Disabled
consumers do not require their database or application secrets.
To add a consumer, add an app descriptor under `apps/<id>/` , its two route
templates, Compose file, and digest-pinned image key. No second placement list
is required. The next normal push deploys it to every follower and adds its
load-balanced route on the Leader.

New API and CLIProxyAPI remain as dormant manifests and are disabled by the
committed policy. LibreChat is enabled on Followers and is published at
`chat.aichorage.de` and `chat-admin.aichorage.de` . It uses MongoDB Atlas and
Upstash Redis; provide `LIBRECHAT_MONGO_URI` and `LIBRECHAT_REDIS_URI` (plus
the generated JWT and admin-panel secrets) in the root-only bundle or during
interactive bootstrap. Production also requires the shared Cloudflare R2
endpoint, access key, secret key, region ( `auto` ), and bucket through the
`LIBRECHAT_AWS_*` settings. LibreChat uses `fileStrategy: s3` , so R2 is the
source of truth for uploads and images across Followers. The initial profile
intentionally omits local MongoDB, Redis, Meilisearch, RAG, and pgvector.
Registration is enabled by default as an explicit product choice. URL-encode
reserved characters in Atlas and Upstash credentials before placing them in
the connection URI.

The minimal LibreChat profile runs exactly three containers on each Follower:
the API, admin panel, and Nginx client. The API is capped at 512 MiB and 384
MiB of Node heap, with small Mongo connection pools and bounded Redis retry-delay and scan settings; the admin panel and client have 128 MiB and 32 MiB caps. Search, RAG, pgvector, Meilisearch, code execution, local process-backed MCP, schedules, and deployment hooks are disabled in the checked-in profile. Remote MCP and the normal agent/tool orchestration remain available through the operator YAML.
Uploads use R2, and the Compose API does not join the public edge network.
Foundation services also have explicit low-memory caps: Caddy 64 MiB, Woodpecker server 256 MiB, Woodpecker workers 128 MiB, Beszel Hub 128 MiB, and Beszel agent 64 MiB by default. These are configurable through the `*_MEMORY_LIMIT` , `*_CPUS` , and `*_PIDS_LIMIT` variables in `.env.prod` .

On a 1 GB VPS, bootstrap enables a 1 GB `/swapfile` with `nofail` persistence
and low swappiness when no swap is already active. Override
`LOW_MEMORY_SWAP_ENABLED` , `LOW_MEMORY_SWAPFILE` , `LOW_MEMORY_SWAP_SIZE` , or
`LOW_MEMORY_SWAP_SWAPPINESS` before bootstrap if the provider supplies swap or
uses a different storage policy. Swap is a pressure buffer, not a substitute
for external MongoDB, Redis, and R2. Keep `LIBRECHAT_MONGO_BACKUP_NODE_ID`

fixed to one Follower; only that node performs the optional `mongodump` export,
avoiding duplicate Atlas backups.

## Local checks

```bash
cp .env.dev.example .env.dev
./stack.sh dev validate
./stack.sh dev up
```

## First deployment

SSH is used only for this one-time host bootstrap. Before starting, prepare the
three VPS hosts, Cloudflare DNS, and the R2 Restic repositories. The Leader
creates `shared-secrets.env` and `beszel-enrollment.env` during bootstrap; those
files are transferred to Followers before they start. Public domains
`ci` , `ci-grpc` , `status` , `chat` , and `chat-admin` point to the Leader. The
DNS-only origins using the `worker1-` prefix point to Worker 1, while the
stable-ID `worker2-` origin records point to Worker 2. The `leader` stable ID is
the public Leader and therefore does not need a private origin record for
ingress.

Initialize each remote Restic repository once, before bootstrap. Keep the R2
credentials and password in protected local files; the endpoint is the S3 URL
for the R2 account, and each stable node should use its own repository prefix:

```bash
RESTIC_ENV_FILE='/secure/r2.env'       # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
RESTIC_PASSWORD_FILE='/secure/restic-password'
RESTIC_BASE='s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>/llm-hub-lite'
set -a
. "$RESTIC_ENV_FILE"
set +a
for node in leader worker-1 worker-2; do
  RESTIC_REPOSITORY="$RESTIC_BASE/$node" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic init
done
```

When the bootstrap prompts for `Remote Restic repository`, enter the matching
`$RESTIC_BASE/<node-id>` value. Alternatively pass
`RESTIC_REMOTE_REPOSITORY`, `RESTIC_REMOTE_ENV_SOURCE_FILE`, and
`RESTIC_REMOTE_PASSWORD_FILE` in the bootstrap environment.

The three-node bootstrap order is Leader ( `leader` ), then Follower
`worker-1` , then Follower `worker-2` :

```bash
LEADER_HOST='<leader-host-or-ip>'
WORKER_1_HOST='<worker-1-host-or-ip>'
WORKER_2_HOST='<worker-2-host-or-ip>'
for host in "$LEADER_HOST" "$WORKER_1_HOST" "$WORKER_2_HOST"; do
  scp ops/bootstrap-vps.sh "root@$host:/root/llm-hub-lite-bootstrap.sh"
done
ssh -t "root@$LEADER_HOST" 'chmod 700 /root/llm-hub-lite-bootstrap.sh && NODE_ID=leader DOMAIN_NAME=aichorage.de SSL_EMAIL=admin@aichorage.de /root/llm-hub-lite-bootstrap.sh'

# Copy these root-only files before starting either Follower. Use a protected
# local temporary directory, or transfer them through an equivalent secure
# one-time channel, then remove the local copies.
tmp_secrets="$(mktemp -d)"
chmod 700 "$tmp_secrets"
scp "root@$LEADER_HOST:/etc/llm-hub-lite/shared-secrets.env" "$tmp_secrets/"
scp "root@$LEADER_HOST:/etc/llm-hub-lite/beszel-enrollment.env" "$tmp_secrets/"
for host in "$WORKER_1_HOST" "$WORKER_2_HOST"; do
  ssh "root@$host" 'install -d -m 700 /etc/llm-hub-lite'
  scp "$tmp_secrets/shared-secrets.env" "root@$host:/etc/llm-hub-lite/shared-secrets.env"
  scp "$tmp_secrets/beszel-enrollment.env" "root@$host:/etc/llm-hub-lite/beszel-enrollment.env"
  ssh "root@$host" 'chmod 600 /etc/llm-hub-lite/shared-secrets.env /etc/llm-hub-lite/beszel-enrollment.env'
done
rm -rf "$tmp_secrets"

ssh -t "root@$WORKER_1_HOST" 'chmod 700 /root/llm-hub-lite-bootstrap.sh && NODE_ID=worker-1 DOMAIN_NAME=aichorage.de SSL_EMAIL=admin@aichorage.de /root/llm-hub-lite-bootstrap.sh'
ssh -t "root@$WORKER_2_HOST" 'chmod 700 /root/llm-hub-lite-bootstrap.sh && NODE_ID=worker-2 DOMAIN_NAME=aichorage.de SSL_EMAIL=admin@aichorage.de /root/llm-hub-lite-bootstrap.sh'
```

Set the shared LibreChat Atlas/Upstash values, Woodpecker OAuth values, and
any optional consumer values in the
root-only environment or bundle before running the commands. The Leader public
IPv4 address may also be supplied as `LEADER_PUBLIC_IP` ; otherwise it is loaded
from existing runtime configuration or the shared bundle, then prompted for.
Use the Upstash Redis TLS connection string beginning with `rediss://` ; the
plaintext `redis://` form cannot connect to Upstash's TLS endpoint and is
rejected during bootstrap validation.
Each bootstrap confirms the role derived from the committed inventory.
Bootstrap prefetches only images active for that node role (Caddy and the
foundation services on a Leader; consumer images on Followers) and retries
transient registry failures before aborting.

The interactive prompts are expected on the first run. Provide the remote
Restic repository and password, LibreChat Atlas/Upstash/R2 values, and the
Woodpecker OAuth values when prompted. For non-interactive bootstrap, provide
the same values through environment variables or root-only files; never create
different shared secrets independently on different nodes.

After bootstrapping the Leader, copy the root-only
`/etc/llm-hub-lite/beszel-enrollment.env` bundle to each follower (or pass its
base64 form as `BESZEL_ENROLLMENT_BUNDLE_B64` during follower bootstrap). The
follower bootstrap provisions the Hub public key and permanent universal token
idempotently; it never creates a second Hub or replaces matching credentials.
Also copy `/etc/llm-hub-lite/shared-secrets.env` to each follower, or provide
the same file through `PLATFORM_SECRET_BUNDLE_FILE` . Bootstrap rejects a
runtime configuration that conflicts with the shared bundle. If no bundle is
provided, the follower prompts for the shared values; do not accept generated
values independently on different nodes.
Mark only the private repository as trusted in Woodpecker. The deployment
agent has Docker socket access and must never run untrusted repositories.

After all three bootstraps finish, verify the local foundation state and the
public entry points before enabling normal delivery:

```bash
ssh root@<leader-host-or-ip> platformctl health
ssh root@<worker-1-host-or-ip> platformctl health
ssh root@<worker-2-host-or-ip> platformctl health
curl -fsS https://ci.<domain>/
curl -fsS https://status.<domain>/api/health
curl -fsS https://chat.<domain>/health
```

Then enable the repository in Woodpecker and confirm that the generated
`deploy-*` workflows are visible. SSH is no longer part of routine delivery;
keep it only as a recovery channel.

The following values must be identical on every New API replica: Neon
`NEW_API_SQL_DSN` , `NEW_API_SESSION_SECRET` , and `NEW_API_CRYPTO_SECRET` .
Supply them as bootstrap environment variables or from the same root-only
shared secret bundle on every node. Worker 1 is the committed New API migration
node ( `NEW_API_NODE_TYPE=master` in its node descriptor); the other Follower
uses `slave` . The current Leader is not a consumer node. The pinned external
image runs startup migrations on every non-slave process and does not provide
an advisory-lock migration gate, so keep exactly one migration node and
upgrade it before the other replica if New API is re-enabled.

Follower deployment smoke checks use the local Compose health status, while
the Leader smoke workflow checks the public DNS endpoints. This avoids a
Follower appearing healthy merely because its request was served by the
Leader.

For private repositories, provision a root-only GitHub fine-grained token (or
GitHub App token) file during first bootstrap with `GITHUB_TOKEN_FILE` . The
controller uses non-interactive HTTPS Git transport internally. VPS SSH is
bootstrap-only; daily delivery remains GitHub push to Woodpecker and does not
require SSH keys or SSH connections.

## Clean up deployment

To redeploy a VPS from a clean local stack state, copy `ops/clean-vps.sh` to a temporary location outside `/opt/platform` (for example `/root/clean-vps.sh`)
and run it separately on each host. Start with the read-only inventory:

```bash
chmod 700 /root/clean-vps.sh
/root/clean-vps.sh --dry-run
```

Review the complete list, then confirm the destructive cleanup interactively:

```bash
/root/clean-vps.sh --confirm
```

The confirmed run logs each systemd stop, Docker container stop/removal, network removal, wrapper deletion, and managed path deletion.

The confirmed command stops and removes this stack's containers, empty stack-owned networks, systemd units, installed wrappers, generated Caddy and application state, releases, runtime secrets, and `/etc/llm-hub-lite` data. It
does not run `docker system prune`, delete unrelated containers or networks, change UFW/iptables rules, remove `/swapfile`, or contact any remote service.

Local encrypted Restic data under `/opt/backups/llm-hub-lite` is preserved by default. Delete it only after verifying the remote repository and any required
restore points:

```bash
/root/clean-vps.sh --confirm --delete-local-backups
```

The cleanup removes local Restic password/remote-environment files under `/etc/llm-hub-lite` along with the rest of the stack configuration. Keep a separate protected copy of those credentials if you intend to inspect or restore the preserved local repository later.

Docker images are also preserved for a fast redeploy. To remove only images referenced by this stack when they are not used by another container, add `--delete-images`. Remote Restic/R2 objects, MongoDB Atlas data, Upstash data,
Cloudflare DNS, and firewall policy are always outside the cleanup scope.

## Changing node IPs or the Leader

Stable IDs are never renamed when an IP changes. A Follower address change
requires only updates to its DNS-only origin records. A Leader address change
is private maintenance: update `LEADER_PUBLIC_IP` in the root-only
`/etc/llm-hub-lite/node.env` on every node and in the Leader's
`/etc/llm-hub-lite/shared-secrets.env` , then restart
`platform-firewall.service` on every Follower before completing the DNS
cutover. No address change belongs in Git. Verify each origin with
`curl --resolve <origin>:443:<new-ip> https://<origin>/...` .

Leader promotion is deliberately manual because Woodpecker Server and Beszel
Hub are SQLite controllers. Freeze deployments, restore the latest verified
remote Restic snapshot on the candidate, set `LEADER_NODE_ID` in the policy,
and move `CLIPROXY_PRIMARY_NODE_ID` , `NEW_API_MIGRATION_NODE_ID` , and
`NEW_API_BACKUP_NODE_ID` to follower IDs if any currently points at the
candidate. During the maintenance window, set the candidate's public address
as `LEADER_PUBLIC_IP` in every node's root-only runtime configuration and in
the candidate's shared bundle. Run `cluster-reconcile` ,
verify with `curl --resolve` , demote the old Leader, and only then change
public Cloudflare DNS. The recovery point is the last successful remote
backup; there is no automatic controller failover. Restores preserve the
target node's `/etc/llm-hub-lite/node.env` by default, preventing a snapshot
from silently changing stable identity or address. Set `RESTORE_IDENTITY=1`

only for an intentional, reviewed controller promotion.

New API is the consumer HA exception: every replica uses the same Neon
PostgreSQL DSN, `SESSION_SECRET` , and `CRYPTO_SECRET` . The workflow generator
creates an `app-upgrade-<follower-id>` manual workflow for every follower. Run
the migration follower first, wait for health and smoke checks, then upgrade
the remaining followers; never upgrade two replicas concurrently. The node
named by `NEW_API_BACKUP_NODE_ID` is the only node that runs `pg_dump` ; every
node still backs up its local runtime and SQLite state.

CLIProxyAPI is active-passive. `CLIPROXY_PRIMARY_NODE_ID` controls the first
Caddy origin; health checks fail over to the remaining follower origins. Change
that policy field and push it when moving the primary. Its local auth/plugin
state is not replicated, so failover requires persisted state on the target.

LibreChat accounts and conversations live in MongoDB Atlas, while shared cache
and stream state lives in Upstash. Local Restic snapshots include LibreChat
logs, runtime configuration, and the shared secret bundle, but do not
automatically back up Atlas, Upstash, or R2. Set
`LIBRECHAT_MONGO_BACKUP_ENABLED=true` and install `mongodump` on the backup
owner to include an Atlas archive; verify that archive before treating it as
a disaster-recovery copy.

## Daily delivery

After the first deployment, normal updates require only a GitHub push. From a
clean checkout, review the diff, run the local checks, and push the intended
commit:

```bash
git status
pre-commit run --all-files
git push origin main
```

Push consumer application changes to `main` . Woodpecker validates the exact commit, creates a verified
backup, updates the Leader controller bundle, reconciles every follower node,
reloads Caddy only after health checks pass, and runs public smoke tests.  Foundation changes, image upgrades, and runner upgrades remain explicit reviewed workflows.

The automatic push workflows are intentionally limited to `apps/**` and the
non-cluster Caddy route/config files. Changes under `ops/`,
`compose/foundation/`, foundation image manifests, or the deployment runner do
not start a consumer rollout. After pushing those reviewed control-plane
changes, run the generated manual `foundation-upgrade-leader` workflow and let
its dependencies update the Followers before resuming normal delivery. App
image manifest changes under `ops/images.apps.prod.env` use the generated
manual `app-upgrade-<follower-id>` workflows instead of the normal source
deployment.

The automatic consumer path is ordered `Leader -> worker-1 -> worker-2` . Each
node fetches the same full commit over HTTPS and keeps its own release and
rollback pointers. A failed node rolls back locally and stops the dependency
chain, so a later Follower is not updated against an unverified predecessor.
Consumer source, manifests, and application Compose files under `apps/` are
included in this path. Non-cluster committed runtime configuration under
`config/` (including Caddy and route files) is also rendered and reloaded by
this path. The committed cluster policy and node inventory under
`config/cluster/` use the separate `cluster-reconcile` path. Foundation Compose
files, foundation images, deployment scripts, and runner images remain explicit
reviewed workflows; they are deliberately rejected by an ordinary consumer
deployment.

The rollout is ordered rather than a distributed transaction. If a node is
offline or fails health checks, its deployment rolls back locally and the
dependency chain stops before the next node. Retry the same Woodpecker build
after recovery; no SSH fan-out is required.

Runtime secrets and external service values in `/etc/llm-hub-lite/` and
`/opt/apps/llm-hub-lite/shared/.env.prod` are intentionally not synchronized by
GitHub pushes. Change those values on each affected node through the approved
maintenance/bootstrap process, then run `platformctl sync apps` (or the
appropriate foundation workflow) and verify health before ending maintenance.

The generated manual workflows are per-node and serialized: foundation and
runner upgrades run Leader first, then Followers; rollback runs Followers
before the Leader. This keeps image and configuration changes consistent
without SSH fan-out.

Useful commands on a node:

```text
platformctl status
platformctl health
platformctl recover
platformctl sync all
platformctl restart all
platformctl backup snapshot manual
platformctl restore extract latest
RESTORE_SOURCE=remote RESTORE_NODE_ID=leader platformctl restore extract latest
```

Docker restart policies, live-restore, `platform-recovery.service` , and the
recovery timer make reboot recovery idempotent. Production snapshots require
an initialized and verified remote Restic repository. Restic snapshots include
runtime configuration, Caddy certificates, Woodpecker/Beszel SQLite online
backups, release pointers, and application data without deleting live data.
Local-only snapshots are available only when the explicit production backup
gate is disabled for beta/development use.
