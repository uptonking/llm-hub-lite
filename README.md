# llm-hub-lite

Reproducible multi-node Docker platform for Caddy, Woodpecker CI, Beszel, LibreChat, and OpenObserve. Optional single-node deployment is also supported.

## Architecture

The committed inventory is in `config/cluster/` . The current Leader has stable
node ID `leader` ; it runs Caddy, Woodpecker server, a trusted deployment agent, Beszel Hub, and a Beszel agent. Followers have stable node IDs `worker-1` through `worker-4` ; they run Caddy, Woodpecker workers, Beszel agents, and consumer applications. Worker-4 is active, with scheduled Restic work disabled by committed policy. The IDs are stable labels; the role is selected only by
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

The control plane is intentionally single-controller: Woodpecker, Beszel, and
OpenObserve use persistent local state on the Leader. Lightweight Observer
collectors run on every node and send platform-labelled Docker logs to the
Leader. LibreChat replicas share external Atlas MongoDB and Upstash Redis
state.

Configuaration for services: [Configuration and DevOps for Docker Services](./docs/config-services.md)

## Local checks

```bash
cp .env.dev.example .env.dev
./stack.sh dev validate
./stack.sh dev up
```

`stack.sh dev` uses each app's committed `config.env` as a baseline and lets
`.env.dev` override local, non-secret tuning. Digest-pinned image manifests and
the selected node descriptor remain authoritative, so local settings cannot
silently replace production image or topology identity.

## 🚀 First deployment

See the concise operator runbook: [first-deployment.md](docs/first-deployment.md).

- Leader:
    - Caddy
    - Woodpecker server/controller
    - Woodpecker deployer
    - Beszel Hub and agent
    - OpenObserve controller and log collector
- Follower worker-1:
    - Caddy
    - Woodpecker agent
    - Beszel agent
    - LibreChat
    - Aichorouter (the default singleton target)
    - CPAPI (the default singleton target)
    - Cursorapi (the default singleton target)
- Follower worker-2:
    - Caddy
    - Woodpecker agent
    - Beszel agent
    - LibreChat
    - Wapdf (BentoPDF) singleton
    - Aichor (Paseo) singleton
    - Pigeon package retained but disabled
- Follower worker-3:
    - Flowy (Activepieces)
- Follower worker-4:
    - Wabase (Grist) singleton
    - Scheduled Restic work disabled by policy

SSH is used only for this one-time host bootstrap. Before starting, prepare the
five VPS hosts, Cloudflare DNS, and any enabled R2 Restic repositories. The Leader
creates `shared-secrets.env` and `beszel-enrollment.env` during bootstrap; those
files are transferred to Followers before they start. Public domains `ci` ,
`ci-grpc` , `status` , `chat` , `chat-admin` , `aichorouter` , `cpapi` , `cursorapi` , `wapdf` ,
and `observer` point to the Leader. Add `observer-ingest` as a DNS-only record
directly to the Leader; collectors use it for HTTPS ingestion. The DNS-only
origins using the `worker1-` prefix point to Worker 1, while the stable-ID
`worker2-` origin records point to Worker 2. The
`worker4-wabase-origin.<domain>` record points to Worker 4, while
`wabase.<domain>` points to the Leader. Pigeon origin records are not
required while it is disabled; create the selected Follower's DNS-only origin
before opting it in. The `leader` stable ID is the public Leader and therefore
does not need a private origin record for ingress.
The default Cursorapi placement specifically requires the DNS-only
`worker1-cursorapi-origin.<domain>` record to resolve to Worker 1; the public
`cursorapi.<domain>` record resolves to the Leader and may be Cloudflare-proxied.
The Follower origin records must remain DNS-only. The Follower firewall only
permits Docker HTTPS traffic from the Leader IP. After certificates work, the
public records may be proxied through Cloudflare.
Wapdf follows the same two-hop ingress pattern: the DNS-only
`worker2-wapdf-origin.<domain>` record resolves to Worker 2, while
`wapdf.<domain>` resolves to the Leader. It is a stateless BentoPDF singleton
with no runtime secret, persistent payload, host port, database, or Redis
dependency; its app container is capped at 900 MiB and 0.60 CPU.

Aichor is the Paseo singleton at `aichor.aichorage.de`, targeting worker-2 by
default. Its DNS-only origin is `worker2-aichor-origin.<domain>`; public traffic
always enters through the Leader and then crosses the selected follower Caddy.
Paseo state and the managed `/workspace` directory live under
`data/prod/aichor`. The official image runs without bundled agent CLIs, host
repository mounts, Docker socket access, or published ports, and starts with a
900 MiB / 0.80 CPU profile. Change `NODES` in
`config/cluster/apps/aichor.policy` to move it to another active follower; the
move is fresh and does not copy sessions, credentials, or workspace contents.

Remote Restic/R2 backup is optional. Local Restic repositories are initialized
automatically on each VPS. If off-host recovery is required, initialize a
separate remote repository per stable node once before bootstrap. Keep the R2
credentials and password in protected local files. This checkout uses
`./restic-r2.env` for the R2 S3 credentials; that filename is ignored by Git.
The Restic repositories use the `llm-hub-lite-backups` bucket and a separate
prefix for each stable node:
If MongoDB Atlas is used, remember to add related vps ip to the `IP Access List` .

```bash
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
RESTIC_ENV_FILE="$PWD/restic-r2.env"
RESTIC_PASSWORD_FILE="$PWD/restic-password"
RESTIC_BASE='s3:https://<account-id>.r2.cloudflarestorage.com/llm-hub-lite-backups/llm-hub-lite'

LIBRECHAT_AWS_ENDPOINT_URL='https://<account-id>.r2.cloudflarestorage.com'

# edit $RESTIC_PASSWORD_FILE to set password for restic

# If a repository already exists, verify it with restic snapshots instead of running restic init again.
set -a
. "$RESTIC_ENV_FILE"
set +a
for node in leader worker-1 worker-2; do
  RESTIC_REPOSITORY="$RESTIC_BASE/$node" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic init
done
```

The bootstrap order is Leader ( `leader` ), then each Follower in inventory
order ( `worker-1` , `worker-2` , `worker-3` , `worker-4` , ...):

```bash
LEADER='<leader-host-or-ip>'
WORKER_1='<worker-1-host-or-ip>'
WORKER_2='<worker-2-host-or-ip>'
WORKER_3='<worker-3-host-or-ip>'
WORKER_4='<worker-4-host-or-ip>'
DOMAIN_NAME=your-top-level-domain
SSL_EMAIL=admin@xx.xx
WOODPECKER_ADMIN=xx

# for redeployment, clean up might help
for host in "$LEADER" "$WORKER_1" "$WORKER_2" "$WORKER_3" "$WORKER_4"; do
  scp ops/clean-vps.sh root@"$host":/root/clean-vps.sh
  ssh -tt root@"$host" 'chmod 700 /root/clean-vps.sh &&
    /root/clean-vps.sh --confirm --delete-local-backups'
done

set -Eeuo pipefail

for host in "$LEADER" "$WORKER_1" "$WORKER_2" "$WORKER_3" "$WORKER_4"; do
  ssh "root@$host" 'install -d -m 700 /etc/llm-hub-lite'

  scp ops/bootstrap-vps.sh \
    "root@$host:/root/llm-hub-lite-bootstrap.sh"

  scp "$RESTIC_ENV_FILE" \
    "root@$host:/etc/llm-hub-lite/restic-remote.env"

  scp "$RESTIC_PASSWORD_FILE" \
    "root@$host:/etc/llm-hub-lite/restic-remote-password"

  ssh "root@$host" \
    'chmod 700 /root/llm-hub-lite-bootstrap.sh &&
      chmod 600 /etc/llm-hub-lite/restic-remote.env \
                /etc/llm-hub-lite/restic-remote-password'
done

# or only update bootstrap scripts
for host in "$LEADER" "$WORKER_1" "$WORKER_2" "$WORKER_3"; do

  scp ops/bootstrap-vps.sh \
    "root@$host:/root/llm-hub-lite-bootstrap.sh"

  ssh "root@$host" \
    'chmod 700 /root/llm-hub-lite-bootstrap.sh'
done

# RESTIC_REMOTE_REPOSITORY='$RESTIC_BASE/leader' \
# RESTIC_REMOTE_PASSWORD_FILE=/etc/llm-hub-lite/restic-remote-password \
# RESTIC_REMOTE_ENV_FILE=/etc/llm-hub-lite/restic-remote.env \

ssh -tt "root@$LEADER" \
  "NODE_ID=leader \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"

# or repair leader
ssh -tt "root@$LEADER" \
  "NODE_ID=leader \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=$DOMAIN_NAME \
    SSL_EMAIL=$SSL_EMAIL \
    WOODPECKER_ADMIN=$WOODPECKER_ADMIN \
    BOOTSTRAP_MODE=repair \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"
```

```sh
# Copy these root-only files before starting either Follower. Use a protected
# local temporary directory, or transfer them through an equivalent secure
# one-time channel, then remove the local copies.

tmp_secrets="$(mktemp -d)"
chmod 700 "$tmp_secrets"
scp "root@$LEADER:/etc/llm-hub-lite/shared-secrets.env" "$tmp_secrets/"
scp "root@$LEADER:/etc/llm-hub-lite/beszel-enrollment.env" "$tmp_secrets/"

for host in "$WORKER_1" "$WORKER_2" "$WORKER_3"; do
  ssh "root@$host" 'install -d -m 700 /etc/llm-hub-lite'
  scp "$tmp_secrets/shared-secrets.env" "root@$host:/etc/llm-hub-lite/shared-secrets.env"
  scp "$tmp_secrets/beszel-enrollment.env" "root@$host:/etc/llm-hub-lite/beszel-enrollment.env"
  ssh "root@$host" 'chmod 600 /etc/llm-hub-lite/shared-secrets.env /etc/llm-hub-lite/beszel-enrollment.env'
done
rm -rf "$tmp_secrets"

# bootstrap workers

# if remote restic is enabled
# RESTIC_REMOTE_REPOSITORY='$RESTIC_BASE/worker-1' \
# RESTIC_REMOTE_PASSWORD_FILE=/etc/llm-hub-lite/restic-remote-password \
# RESTIC_REMOTE_ENV_FILE=/etc/llm-hub-lite/restic-remote.env \

ssh -tt "root@$WORKER_1" \
  "NODE_ID=worker-1 \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"

# or repair worker_1
ssh -tt "root@$WORKER_1" \
  "NODE_ID=worker-1 \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=$DOMAIN_NAME \
    SSL_EMAIL=$SSL_EMAIL \
    WOODPECKER_ADMIN=$WOODPECKER_ADMIN \
    BOOTSTRAP_MODE=repair \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"

ssh -tt "root@$WORKER_2" \
    "NODE_ID=worker-2 \
     LEADER_PUBLIC_IP=$LEADER \
     DOMAIN_NAME=aichorage.de \
     SSL_EMAIL=admin@aichorage.de \
     WOODPECKER_ADMIN=uptonking \
     BOOTSTRAP_ASSUME_YES=1 \
     /root/llm-hub-lite-bootstrap.sh"

ssh -tt "root@$WORKER_3" \
  "NODE_ID=worker-3 \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"

ssh -tt "root@$WORKER_4" \
  "NODE_ID=worker-4 \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    BOOTSTRAP_ASSUME_YES=1 \
    /root/llm-hub-lite-bootstrap.sh"
```

Validate the complete cluster

```sh
for host in "$LEADER" "$WORKER_1" "$WORKER_2" "$WORKER_3" "$WORKER_4"; do
  ssh "root@$host" 'platformctl health'
done
```

Set the shared LibreChat Atlas/Upstash values, Woodpecker OAuth values, and
any optional consumer values in the
root-only environment or bundle before running the commands. The Leader public
IPv4 address may also be supplied as `LEADER_PUBLIC_IP` ; otherwise it is loaded
from existing runtime configuration or the shared bundle, then prompted for.
Use the Upstash Redis TLS connection string beginning with `rediss://` ; the
plaintext `redis://` form cannot connect to Upstash's TLS endpoint and is
rejected during bootstrap validation.
If LibreChat reports `mongodb+srv URI cannot have port number` , or bootstrap
reports `LIBRECHAT_MONGO_URI must be one valid ... URI` , repair the value on the
Leader before retrying any Follower. Run `configure-app-secrets librechat` on
the Leader and enter the provider's original single Mongo URI at the prompt;
do not concatenate a URI with an existing value or place it in shell history.
Then copy the corrected `/etc/llm-hub-lite/shared-secrets.env` to each Follower
and rerun bootstrap. Bootstrap and `platformctl validate` reject duplicate
Mongo schemes and SRV ports before starting LibreChat, while preserving all
other existing secrets.
When `NODE_ID` is omitted on an interactive first deployment, bootstrap first
asks whether the VPS is the Leader or a Follower. Choosing Leader selects the
committed `LEADER_NODE_ID` ; choosing Follower asks for one of the committed
logical Follower IDs. Supplying `NODE_ID` remains the unambiguous
non-interactive interface. In both cases bootstrap confirms the role derived
from committed policy; it never stores a second `NODE_ROLE` setting.
Bootstrap prefetches only images active for that node role (Caddy and the
foundation services on a Leader; consumer images on Followers) and retries
transient registry failures before aborting.

The bootstrap program itself is not self-updating. Before a first deployment,
recovery, or retry after changing bootstrap logic, copy the current
`ops/bootstrap-vps.sh` from this checkout to `/root/llm-hub-lite-bootstrap.sh`

on every target VPS. The program then fetches the latest repository revision
for the rest of the deployment. Bootstrap is not the normal update mechanism:
rerunning both host bootstraps repeats host configuration, validates the remote
backup, prefetches images, and reconciles the full node, so it is slower and has
a larger restart scope than a normal application deployment. It is safe to use
for recovery or a bootstrap-script fix, but do not use it for every Compose or
application change. A retry deliberately recreates every active foundation
Compose project after installing its files. This ensures bind-mounted
configuration such as Vector's `observer-vector.toml` cannot remain attached
to an older replaced file, but it also causes a brief interruption to local
foundation services. Run the same current bootstrap revision on the Leader,
worker-1, and worker-2 before treating an all-node Observer smoke failure as an
incident.

Bootstrap is safe to retry after a partial failure. It merges missing image
keys from the fetched repository into `/etc/llm-hub-lite/images.apps.env` and
`images.foundation.env` ; it does not overwrite existing digest pins. If a
retry reports an image key as missing, push the current repository first and
recopy `ops/bootstrap-vps.sh` to the host so the bootstrap script and fetched
source are from the same revision, then rerun the original command.

The interactive prompts are expected on the first run. Provide the remote
Restic repository and password, LibreChat Atlas/Upstash/R2 values, and the
Woodpecker OAuth values when prompted. For non-interactive bootstrap, provide
the same values through environment variables or root-only files; never create
different shared secrets independently on different nodes.
When invoking a remote bootstrap with SSH, use `ssh -tt` so the confirmation
and secret prompts receive a terminal. You may set `BOOTSTRAP_ASSUME_YES=1` to
skip only the role confirmation; required secrets are still validated and must be supplied through the environment, bundle, or remaining prompts.
On the Aichorouter, CPAPI, and Cursorapi target Followers, the interactive
bootstrap prompts for their singleton-local secrets. For Cursorapi, provide
the existing Cursor credential as `CURSORAPI_CURSOR_API_KEY` and generate
`CURSORAPI_BRIDGE_API_KEY` with `openssl rand -hex 32` . Disabled applications
such as Pigeon do not prompt for secrets. On the Leader, bootstrap prompts for the
OpenObserve root credentials and creates a named write-only ingestion token;
only the ingestion username/token are copied in `shared-secrets.env` to
Followers. The CPAPI management panel is enabled and protected by its
management key.

### Add or replace a VPS

A new node uses a two-commit enrollment so it cannot receive consumers before
its foundation is healthy:

1. Run `DOMAIN_NAME=aichorage.de ops/configure-cluster-node.sh add worker-4`,
   validate the generated diff, commit, and push. The node remains `joining` .
2. Create DNS-only origin records from
`config/cluster/nodes/worker-4.env` , all pointing to the new VPS. Public app
   records continue to point only to the Leader. Copy the Leader's root-only
   shared-secret and Beszel enrollment bundles through the same protected
   one-time channel used for the first two Followers.
3. Copy the current bootstrap script to the new VPS and run it once with
`NODE_ID=worker-4` . Caddy, the Woodpecker worker, Beszel agent, and Observer
   collector start; consumers remain absent because the node is still joining.
4. Verify `platformctl health` and the Woodpecker agent, then run
`ops/configure-cluster-node.sh state worker-4 active` , commit, and push.
   Woodpecker now creates the node's secret workflows and makes it eligible for
   explicit consumer placement.
5. Put the node in an app's ordered `NODES` using
`ops/configure-app-placement.sh` , review, commit, and push. The helper updates
   policy and generated workflows as one local transaction; generation failure
   restores the prior policy. Add `--enable` when activating a reserved app.
   The generated stage/publish/stop chain performs deployment without SSH.

To remove a host, first move every consumer out of its app policies and push
that change. Transition `active -> draining` , verify the stop workflows, then
transition `draining -> retired` and run the generated
`node-retire-<node-id>` workflow before decommissioning the VPS. To replace a
VPS without changing logical placement, ensure the old host is stopped, update
its origin DNS records to the replacement IP, and bootstrap the replacement
with the same stable `NODE_ID` ; IP addresses never enter Git. For a complete
state-preserving cutover, use
[docs/vps-migration.md](docs/vps-migration.md) and
`ops/change-vps-for-consumer-node.sh`.

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
curl -fsS https://cursorapi.<domain>/healthz
```

Then enable the repository in Woodpecker and confirm that the generated
`consumer-stage-*` , `consumer-publish-*` , `consumer-stop-*` , and singleton
`consumer-finalize-*` workflows are visible. SSH is no longer part of routine
delivery; keep it only as an initial-bootstrap and recovery channel.

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

To redeploy a VPS from a clean local stack state, copy `ops/clean-vps.sh` to a temporary location outside `/opt/platform` (for example `/root/clean-vps.sh` )
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
does not run `docker system prune` , delete unrelated containers or networks, change UFW/iptables rules, remove `/swapfile` , or contact any remote service.

Local encrypted Restic data under `/opt/backups/llm-hub-lite` is preserved by default. Delete it only after verifying the remote repository and any required restore points:

```bash
/root/clean-vps.sh --confirm --delete-local-backups
```

The cleanup removes local Restic password/remote-environment files under `/etc/llm-hub-lite` along with the rest of the stack configuration. Keep a separate protected copy of those credentials if you intend to inspect or restore the preserved local repository later.

Docker images are also preserved for a fast redeploy. To remove only images referenced by this stack when they are not used by another container, add `--delete-images` . Remote Restic/R2 objects, MongoDB Atlas data, Upstash data,
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

Leader promotion is deliberately manual because Woodpecker Server, Beszel Hub,
and OpenObserve are local-state controllers. Freeze deployments, restore the
latest verified remote Restic snapshot on the candidate, set `LEADER_NODE_ID`

in the committed cluster policy, and update any New API ownership fields in
`config/cluster/apps/newapi.policy` so they still name Followers. During the
maintenance window, set the candidate's public address as `LEADER_PUBLIC_IP` in
every node's root-only runtime configuration and in the candidate's shared
bundle. Apply the reviewed foundation release and reconcile each node, verify
with `curl --resolve` , demote the old Leader, and only then change public
Cloudflare DNS. The generated `cluster-reconcile-*` workflow intentionally
refuses `LEADER_NODE_ID` changes, so this recovery remains an explicit repair
operation. The recovery point is the last successful remote backup; there is no automatic controller failover. Restores preserve the
target node's `/etc/llm-hub-lite/node.env` by default, preventing a snapshot
from silently changing stable identity or address. Set `RESTORE_IDENTITY=1`

only for an intentional, reviewed controller promotion.

New API is the consumer HA exception: every replica uses the same Neon
PostgreSQL DSN, `SESSION_SECRET` , and `CRYPTO_SECRET` . If it is enabled, its
generic consumer stages follow the ordered policy `NODES` ; keep the migration
owner first so it becomes healthy before the other replicas. Never deploy two
replicas concurrently. `NEW_API_MIGRATION_NODE_ID` and
`NEW_API_BACKUP_NODE_ID` live in `config/cluster/apps/newapi.policy` , and both
must name selected followers. Only the backup owner runs `pg_dump` ; every node
still backs up its local runtime and SQLite state.

CPAPI is a separate singleton consumer at `cpapi.aichorage.de` , unrelated to
the retained legacy New API. Its target follower is stored in the CPAPI app
policy, and its local auth/configuration state is intentionally not replicated.
Moving it is a fresh deployment with data loss allowed; provision its API and
management keys on the target follower before running the generated singleton
stage/switch workflow. The management panel remains enabled and is protected
by `CPAPI_MANAGEMENT_KEY` . CPAPI has no host-published ports and no Redis or
database dependency; its default profile is capped at 256 MiB and 0.25 CPU.
Its native container healthcheck verifies the persisted configuration and
process liveness, while the small pinned `health-probe` sidecar verifies
`/healthz` over the private network. Application access logging is persisted by
default under the node-local CPAPI data directory with a 50 MiB total cap. Each
line includes the client IP verified and canonicalized by both Caddy hops; full
request/response logging remains disabled so bodies and authorization headers
are not written to these files.

Cursorapi is a separate ephemeral singleton at `cursorapi.aichorage.de` . Its
target is stored in `config/cluster/apps/cursorapi.policy` and defaults to
`worker-1` . The repository-built image bundles a checksum-pinned Cursor Agent;
the runtime has no host port, database, persistent volume, or Docker socket.
Its native and sidecar healthchecks both verify the unauthenticated `/healthz`

endpoint. The Leader exposes `/healthz` for deployment smoke checks and
authenticated `/v1/*` API traffic, while dashboard and control paths remain
unpublished. A target change intentionally starts a fresh container and
discards its ephemeral home/session state.

Wapdf is a separate stateless singleton at `wapdf.aichorage.de` and defaults
to `worker-2` . Moves retain the normal singleton route transaction but create
no app data or runtime secrets. BentoPDF is a browser-side utility, not an
authenticated document store; do not use it for documents requiring durable
server-side retention or access control.

OpenObserve is a Leader-only foundation service at `observer.aichorage.de` .
Its durable local disk data is included in the Leader's Restic snapshot and is
retained for 30 days. Collectors run on every VPS, use the dedicated
`observer-ingest` host and write-only ingestion token, and keep a bounded
transient buffer excluded from Restic. Collection is best effort, and logs can
contain sensitive request data. There is no singleton move workflow or private
Observer origin record. Use `platformctl diagnose foundation` on each node to
inspect durable-data and buffer utilization; the 8 GiB and 80% values are
warning thresholds only.

LibreChat accounts and conversations live in MongoDB Atlas, while shared cache
and stream state lives in Upstash. Local Restic snapshots include LibreChat
logs, runtime configuration, and the shared secret bundle, but do not
automatically back up Atlas, Upstash, or R2. Set `MONGO_BACKUP_ENABLED=true`

and `MONGO_BACKUP_NODE_ID=<selected-follower>` in
`config/cluster/apps/librechat.policy` , then install `mongodump` on that owner
to include an Atlas archive. Verify the archive before treating it as a
disaster-recovery copy.

## Daily delivery

After the first deployment, normal updates require only a GitHub push. From a
clean checkout, review the diff, run the local checks, and push the intended
commit:

```bash
git status
pre-commit run --all-files
git push origin main
```

```
git push
  -> Woodpecker on Leader
  -> node-labelled stage jobs
  -> Leader publish job
  -> follower stop/finalize jobs
```

For a committed Docker Compose, manifest, route, or application configuration
change, this push is the deployment action. Woodpecker selects the appropriate
ordered workflow and recreates only the affected projects after validation. Do
not rerun bootstrap SSH commands for a routine update. Bootstrap remains a
first-deployment and repair tool with a wider restart scope.

For planned restarts, VPS reboots, and controller recovery, follow
[docs/restart-recover.md](docs/restart-recover.md).

All consumers use one generated workflow contract:

1. `consumer-stage-<app>-<node>` deploys each selected node in policy `NODES`
   order and requires local health before the next stage can start.
2. `consumer-publish-<app>` runs on the Leader, builds the upstream set from
   the selected healthy nodes, reloads Caddy, and performs the public smoke.
3. `consumer-stop-<app>-<node>` stops stale instances on every unselected
   follower only after publication succeeds.
4. For an enabled singleton,  `consumer-finalize-<app>-<node>` runs on the
   selected follower after all stale-node stops and closes the matching release
   journal without stopping the active service.

Enabled apps also receive independent manual
`consumer-secrets-<app>-<node>` workflows for the Leader and every active
Follower that needs their declared keys. Run the future Follower's workflow
before changing singleton placement. Routine deployments and placement changes
then remain Git push driven; SSH is reserved for initial bootstrap and repair.

For a singleton, this is a health-gated target transition. For active-active,
all selected replicas are staged before their complete upstream set is
published. A failed stage rolls back only that node and stops the dependency
chain; a failed publish restores the prior route and does not stop old targets.
Disabled consumers generate no stage jobs: their publish job removes the route,
then their stop jobs retire the project from every follower. This makes both
enablement and placement changes convergent without a second reconciliation
workflow.

Consumer workflows accept app source, app policy, node inventory, committed
per-node overrides, route configuration, and the application image manifest.
An image digest change therefore uses the same reviewed consumer chain; there
is no separate generated `app-upgrade-*` family. Keep unrelated app changes in
separate commits so a shared image-manifest change does not trigger unnecessary
consumer rollouts.

Foundation/controller changes under `ops/` , `compose/foundation/` , foundation
policies, or the foundation image manifest use the generated manual
`foundation-upgrade-leader` workflow. Its dependencies update the remaining
nodes in inventory order. Runner changes use the separate manual
`runner-upgrade-leader` chain. The scope guards reject a consumer job that also
contains control-plane or foundation files; split mixed changes and apply the
foundation commit before pushing dependent consumer changes.

Observer is a foundation service, so Observer controller, collector, and
retention changes use `foundation-upgrade-*` . Consumer defaults belong in
`apps/<id>/config.env` ; committed host-specific tuning belongs in
`config/cluster/overrides/<node-id>/<app-id>.env` . Both flow through Git and the
consumer workflow. Root-only app secrets and emergency runtime overrides are
the exception. Changing those requires an approved host maintenance session,
followed by `platformctl recreate` and `platformctl health` ; do not turn that
break-glass procedure into the daily deployment path. Use `platformctl restart`

only when no Compose or environment definition changed.

Each node fetches the same exact commit and keeps independent current, previous,
and rollback pointers. Workflows are serialized through the shared deployment
concurrency group. If a node is offline or unhealthy, recover it and retry the
same Woodpecker build; no SSH fan-out is required for routine delivery.

## Testing

Use `ops/tests/run-all.sh fast` for the local feedback loop and
`ops/tests/run-all.sh full` before release. Suites run in a bounded worker
queue (`TEST_PARALLELISM=2` on macOS by default, `4` on Linux); set
`TEST_PARALLELISM=1` to diagnose an order-sensitive failure. CI runs the fast
profile with two workers and keeps deployment and platform-controller suites in
isolated jobs.

## License

MIT
