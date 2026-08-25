# llm-hub-lite

Reproducible multi-node Docker platform for Caddy, Woodpecker CI, Beszel, LibreChat, and OpenObserve. Optional single-node deployment is also supported.

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
MongoDB and Upstash Redis state. This provides consumer availability.

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

Service disablement is committed in each app's `config/cluster/apps/*.policy`

file; there are no
per-service `*_DISABLE` switches. Foundation placement is policy-controlled;
consumer placement is declared by `PLACEMENT=follower` or
`PLACEMENT=single-follower` in each v3 app manifest. A follower app is deployed
on every follower; a single-follower app is deployed only on the follower named
by its manifest `TARGET_NODE_KEY` , with the value stored in the app policy file
declared by `POLICY_FILE` (for example `config/cluster/apps/aichorouter.policy` ).
When a consumer is active, the Leader can generate the initial shared random
secrets once, while every Follower must receive the same values from the
root-only bundle or explicit environment variables. A non-interactive
bootstrap fails closed instead of inventing per-node credentials. Disabled
consumers do not require their database or application secrets.
To add a consumer, add an app descriptor under `apps/<id>/` , its two route
templates, Compose file, and digest-pinned image key. No second placement list
is required. The next normal push deploys it to every follower and adds its
load-balanced route on the Leader. For a stateful service that does not need
HA, use `PLACEMENT=single-follower` , declare `ROUTE_GROUPS` , `SECRET_KEYS` , and
`MOVE_MODE=fresh` , and provide a dedicated origin field in every follower
descriptor. Generated stage/switch/stop workflows deploy the selected target,
switch the Leader after a health check, and stop old containers while retaining
their data and runtime secrets. A target move starts with a fresh data
directory; any previous local state is archived for manual recovery. The
controller records an in-progress target transition under
`/etc/llm-hub-lite/singleton-state` so an overlapping normal application
workflow cannot accidentally reuse stale SQLite data; the marker is removed
after the staged target is prepared. The journal records the old and new
targets, release SHA, archive path, and phase ( `prepared` , `origin-healthy` ,
`switched` , or `failed` ). A failed stage leaves the old Leader route serving
and preserves the journal/archive for an idempotent retry; do not delete the
journal until the target has been verified or deliberately rolled back.

Legacy New API remains as a dormant manifest and is disabled by the committed
policy. CPAPI is an enabled singleton consumer at `cpapi.aichorage.de` and is
unrelated to the legacy New API. OpenObserve is an enabled singleton consumer
at `observer.aichorage.de` . LibreChat is enabled on Followers and is published at
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

Aichorouter is the enabled singleton example at `aichorouter.aichorage.de` .
It uses the upstream New API image plus a tiny HTTP health-probe sidecar, a
bind-mounted SQLite database at `data/prod/aichorouter/aichorouter.db` , and
no Redis, PostgreSQL, or other local dependency. `SESSION_SECRET` and `CRYPTO_SECRET` are stored in
`/etc/llm-hub-lite/aichorouter.env` on the selected follower. The image is
memory-capped and has no host-published port; all public traffic enters through
the Leader's Caddy route. SQLite is intentionally local and is not replicated,
so a target move is intentionally a fresh local deployment. Previous local
state is retained in an archive directory until manually removed.

The default profile gives Aichorouter `0.9` CPU, `768m` container memory, one
Go runtime thread ( `GOMAXPROCS=1` ), and a `500MiB` Go heap limit. This leaves
headroom for the Go runtime and SQLite while avoiding the 503 overloads caused
by the previous 384 MiB cap. SQLite is limited to one idle and four open
connections; relay pools, request body buffers, stream buffers, and downloads
are bounded, while the optional memory cache, error log, and batch updater remain
disabled. These defaults are set in `.env.prod` ; override the `AICHOROUTER_*`
values there only when measured
load requires it. Keep `AICHOROUTER_GOMEMLIMIT` below the container memory limit
and leave at least enough headroom for the Go runtime and SQLite pages.
An already-bootstrapped host keeps its explicit `.env.prod` values for
operator overrides; updating `.env.prod.example` does not rewrite that file.
For an existing target follower, update the four Aichorouter profile keys in
`/opt/apps/llm-hub-lite/shared/.env.prod`, then use `platformctl recreate` so
Compose applies the new limits and environment. A plain `platformctl restart`
only restarts the old container definition.

If a previous interactive paste stored an invalid control byte in the session
secret, replace it on the target follower and recreate only Aichorouter:

```bash
sudo env AICHOROUTER_SESSION_SECRET="$(openssl rand -hex 32)" \
  /usr/local/bin/configure-app-secrets aichorouter
sudo platformctl recreate app:/opt/platform/control/current/apps/aichorouter
```

Rotating `AICHOROUTER_SESSION_SECRET` invalidates existing Aichorouter sessions;
keep the existing `AICHOROUTER_CRYPTO_SECRET` unless it is also being rotated.

Select its follower interactively before committing a policy change:

```bash
ops/configure-single-follower.sh aichorouter
git diff -- config/cluster/apps/aichorouter.policy
git add config/cluster/apps/aichorouter.policy && git commit -m 'target aichorouter follower' && git push
```

OpenObserve is the enabled singleton observability service at
`observer.aichorage.de` . It runs the official single-binary image in local disk
mode with no Redis, PostgreSQL, NATS, or object-storage dependency. Its data is
stored at `data/prod/observer` and its root credentials are kept in
`/etc/llm-hub-lite/observer.env` on the selected follower. The default profile
uses `512m` memory, `0.50` CPU, one query/HTTP worker, a disabled in-memory
cache, and 30 days of local retention. Inverted indexes are disabled by default
to reduce CPU and disk use; set `OBSERVER_ENABLE_INVERTED_INDEX=true` only when
faster full-text searches justify the cost. Moving observer to another follower
is intentionally a fresh deployment; the old local directory is archived and
not copied to the new node.

The selected follower also runs a read-only Docker socket proxy and a small
Vector shipper. Only containers carrying the platform ownership label are
collected, and records are sent over the private Compose network to the local
OpenObserve instance. Vector uses a disk queue capped at 8 GiB by default with
`drop_newest` when full; `OBSERVER_LOG_BUFFER_MAX_BYTES` may lower the cap but
cannot exceed 8 GiB. The queue is an outage buffer, not durable application
data. It is excluded from Restic while OpenObserve's durable data remains in
the backup. During a singleton move the shipper is stopped and the old buffer
is discarded before any durable data is retained, so moving observer can lose
logs that were waiting to upload. Docker log collection is best effort and has
no historical checkpoint guarantee after a prolonged outage or restart. The
shipper's private health endpoint checks process health but does not prove that
every event has reached OpenObserve. Logs may contain request data or
credentials; restrict OpenObserve access and avoid logging secrets.

Select its follower interactively before committing a policy change:

```bash
ops/configure-single-follower.sh observer
git diff -- config/cluster/apps/observer.policy
git add config/cluster/apps/observer.policy && git commit -m 'target observer follower' && git push
```

On the selected follower, provision the OpenObserve administrator once:

```bash
sudo /opt/platform/control/current/ops/configure-app-secrets.sh observer
```

Useful observer checks on its target follower and through the Leader are:

```bash
docker compose -p app-observer ps
docker logs app-observer-observer-log-shipper-1
docker compose -p app-observer exec -T observer-log-shipper wget -q -O - http://localhost:8686/health
curl -fsS https://worker1-observer-origin.aichorage.de/healthz
curl -fsS https://observer.aichorage.de/healthz
```

OpenObserve's production image is distroless and does not contain an HTTP
client. A tiny pinned `health-probe` sidecar performs the HTTP readiness check
against `/healthz` ; the same sidecar pattern is used by Aichorouter and CPAPI.
`platformctl health` requires the application containers to be running and
the declared `health-probe` container to be `healthy` . The Observer log proxy
and Vector shipper retain their own private healthchecks.

On the selected follower, provision its root-only secrets once:

```bash
sudo /opt/platform/control/current/ops/configure-app-secrets.sh aichorouter
sudo /opt/platform/control/current/ops/configure-app-secrets.sh cpapi
```

CPAPI exposes an unauthenticated `/healthz` endpoint that returns `{"status":"ok"}` .
Its main container also has a native liveness check for the persisted config
and init process; the `health-probe` sidecar verifies the HTTP endpoint without
requiring `curl` or `wget` in the minimal CPAPI image. Verify the complete
project state with:

```bash
docker compose -p app-cpapi ps
curl -fsS https://worker1-cpapi-origin.aichorage.de/healthz
curl -fsS https://cpapi.aichorage.de/healthz
```

The helper reads `SECRET_KEYS` , `RUNTIME_ENV_FILE` , and `POLICY_FILE` from the
manifest, so a future singleton can use the same command without adding a new
script branch. Moving a singleton does not copy secrets or data to the new
Follower. The stage job creates a fresh `DATA_ROOT/DATA_ROOT_REL` directory and
retains any previous directory as `*.retained.<UTC timestamp>` ; the stop jobs
remove only old containers. After verifying the new deployment, manual cleanup
is deliberately explicit: stop the old project first, inspect the retained
directory, then remove that exact directory and the old runtime file under
`/etc/llm-hub-lite` when it is no longer needed.

The generated Woodpecker singleton workflow stages the new image/configuration
on that follower, verifies its origin health, switches the Leader route, then
stops old singleton containers in stable node order. Data and runtime secrets
are retained. Normal application workflows set `DEPLOY_SKIP_SINGLETONS=1` and
leave configured singleton containers untouched; they only reconcile normal
follower applications such as LibreChat.

CPAPI's checked-in configuration seed is reconciled by hash at container start.
Provider/auth state under its runtime directory is retained. To rotate the
management or API key and deliberately replace the persisted configuration,
run this on the selected follower during maintenance:

```bash
sudo /opt/platform/control/current/ops/configure-app-secrets.sh cpapi --reset-config
sudo platformctl recreate app:/opt/platform/control/current/apps/cpapi
```

The reset marker is consumed once and the previous config is saved beside the
new one. A normal restart does not reset CPAPI configuration.

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

## 🚀 First deployment

- Leader leader:
    - Caddy
    - Woodpecker server/controller
    - Woodpecker deployer
    - Beszel Hub and agent
- Follower worker-1:
    - Caddy
    - Woodpecker agent
    - Beszel agent
    - LibreChat
    - Aichorouter (the default singleton target)
    - CPAPI (the default singleton target)
    - OpenObserve (the default singleton target)
- Follower worker-2:
    - Caddy
    - Woodpecker agent
    - Beszel agent
    - LibreChat

SSH is used only for this one-time host bootstrap. Before starting, prepare the
three VPS hosts, Cloudflare DNS, and the R2 Restic repositories. The Leader
creates `shared-secrets.env` and `beszel-enrollment.env` during bootstrap; those
files are transferred to Followers before they start. Public domains
`ci` , `ci-grpc` , `status` , `chat` , `chat-admin` , `aichorouter` , `cpapi` ,
and `observer` point to
the Leader. The
DNS-only origins using the `worker1-` prefix point to Worker 1, including the
`worker1-observer-origin` record, while the stable-ID `worker2-` origin records point to Worker 2. The `leader` stable ID is the public Leader and therefore does not need a private origin record for ingress. The Follower origin records must remain DNS-only. The Follower firewall only permits Docker HTTPS traffic from the Leader IP. After certificates work, the public records may be proxied through Cloudflare.

Initialize each remote Restic repository once, before bootstrap. Keep the R2
credentials and password in protected local files. This checkout uses
`./restic-r2.env` for the R2 S3 credentials; that filename is ignored by Git.
The Restic repositories use the `llm-hub-lite-backups` bucket and a separate
prefix for each stable node:

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

The three-node bootstrap order is Leader ( `leader` ), then Follower
`worker-1` , then Follower `worker-2` :

```bash
LEADER='<leader-host-or-ip>'
WORKER_1='<worker-1-host-or-ip>'
WORKER_2='<worker-2-host-or-ip>'

set -Eeuo pipefail

for host in "$LEADER" "$WORKER_1" "$WORKER_2"; do
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

ssh -tt "root@$LEADER" \
  "NODE_ID=leader \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    RESTIC_REMOTE_REPOSITORY='$RESTIC_BASE/leader' \
    RESTIC_REMOTE_PASSWORD_FILE=/etc/llm-hub-lite/restic-remote-password \
    RESTIC_REMOTE_ENV_FILE=/etc/llm-hub-lite/restic-remote.env \
    /root/llm-hub-lite-bootstrap.sh"

# Copy these root-only files before starting either Follower. Use a protected
# local temporary directory, or transfer them through an equivalent secure
# one-time channel, then remove the local copies.

tmp_secrets="$(mktemp -d)"
chmod 700 "$tmp_secrets"
scp "root@$LEADER:/etc/llm-hub-lite/shared-secrets.env" "$tmp_secrets/"
scp "root@$LEADER:/etc/llm-hub-lite/beszel-enrollment.env" "$tmp_secrets/"

for host in "$WORKER_1" "$WORKER_2"; do
  ssh "root@$host" 'install -d -m 700 /etc/llm-hub-lite'
  scp "$tmp_secrets/shared-secrets.env" "root@$host:/etc/llm-hub-lite/shared-secrets.env"
  scp "$tmp_secrets/beszel-enrollment.env" "root@$host:/etc/llm-hub-lite/beszel-enrollment.env"
  ssh "root@$host" 'chmod 600 /etc/llm-hub-lite/shared-secrets.env /etc/llm-hub-lite/beszel-enrollment.env'
done
rm -rf "$tmp_secrets"

# bootstrap workers

ssh -tt "root@$WORKER_1" \
  "NODE_ID=worker-1 \
    LEADER_PUBLIC_IP=$LEADER \
    DOMAIN_NAME=aichorage.de \
    SSL_EMAIL=admin@aichorage.de \
    WOODPECKER_ADMIN=uptonking \
    RESTIC_REMOTE_REPOSITORY='$RESTIC_BASE/worker-1' \
    RESTIC_REMOTE_PASSWORD_FILE=/etc/llm-hub-lite/restic-remote-password \
    RESTIC_REMOTE_ENV_FILE=/etc/llm-hub-lite/restic-remote.env \
    /root/llm-hub-lite-bootstrap.sh"

ssh -tt "root@$WORKER_2" \
    "NODE_ID=worker-2 \
     LEADER_PUBLIC_IP=$LEADER \
     DOMAIN_NAME=aichorage.de \
     SSL_EMAIL=admin@aichorage.de \
     WOODPECKER_ADMIN=uptonking \
     RESTIC_REMOTE_REPOSITORY='$RESTIC_BASE/worker-2' \
     RESTIC_REMOTE_PASSWORD_FILE=/etc/llm-hub-lite/restic-remote-password \
     RESTIC_REMOTE_ENV_FILE=/etc/llm-hub-lite/restic-remote.env \
     /root/llm-hub-lite-bootstrap.sh"
```

Validate the complete cluster

```sh
for host in "$LEADER" "$WORKER_1" "$WORKER_2"; do
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
Each bootstrap confirms the role derived from the committed inventory.
Bootstrap prefetches only images active for that node role (Caddy and the
foundation services on a Leader; consumer images on Followers) and retries
transient registry failures before aborting.

The bootstrap program itself is not self-updating. Before a first deployment,
recovery, or retry after changing bootstrap logic, copy the current
`ops/bootstrap-vps.sh` from this checkout to `/root/llm-hub-lite-bootstrap.sh`
on every target VPS. The program then fetches the latest repository revision
for the rest of the deployment.

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
On the Aichorouter, CPAPI, and OpenObserve target follower, the interactive bootstrap also
prompts for `AICHOROUTER_SESSION_SECRET` , `AICHOROUTER_CRYPTO_SECRET` ,
`CPAPI_API_KEY` , `CPAPI_MANAGEMENT_KEY` , `OBSERVER_ROOT_USER_EMAIL` , and
`OBSERVER_ROOT_USER_PASSWORD` ; these singleton-local secrets are
intentionally not copied from the Leader. The CPAPI management panel is enabled
and protected by its management key.

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

Leader promotion is deliberately manual because Woodpecker Server and Beszel
Hub are SQLite controllers. Freeze deployments, restore the latest verified
remote Restic snapshot on the candidate, set `LEADER_NODE_ID` in the policy,
and move `NEW_API_MIGRATION_NODE_ID` and `NEW_API_BACKUP_NODE_ID` to follower
IDs if either currently points at the
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
`/healthz` over the private network.

OpenObserve is a separate singleton consumer at `observer.aichorage.de` .
Its target follower is stored in the observer app policy, and its local disk
data and administrator credentials are intentionally not copied during a move.
The default local retention is 30 days, with no external database or object
store dependency. Its data is included in the node's Restic snapshot, but
moving the service to another follower starts with an empty data directory.
The co-located Vector shipper collects only platform-labelled Docker logs,
filters its own sidecars using an ownership label, and keeps an ephemeral 8 GiB
disk buffer by default. That buffer is excluded from Restic and discarded during
the move. Collection is best effort, and logs can contain sensitive request
data.

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

Use the workflow that matches the changed paths. A normal LibreChat or legacy
New API source/configuration change is handled by the generated `deploy-*`
chain. Aichorouter, CPAPI, and Observer changes are handled by that app's
generated `singleton-stage-*` -> `singleton-switch-*` -> `singleton-stop-*`
chain. Image digest changes are run through the generated manual
`app-upgrade-worker-1` and `app-upgrade-worker-2` workflows, in order, for
active-active consumer images. A singleton image change follows that
singleton's stage/switch/stop chain. Do not start an app-upgrade for an
unchanged image manifest.

For a local runtime-only change, edit the target node's root-owned
`/opt/apps/llm-hub-lite/shared/.env.prod` or the app secret file under
`/etc/llm-hub-lite/`, then apply it without pulling an image:

```bash
ssh root@<target-follower> 'platformctl recreate app:/opt/platform/control/current/apps/aichorouter && platformctl health'
```

The same command applies to `cpapi` or `observer`. It is intentionally a
local maintenance operation; put durable Compose/default changes in Git so
the next release remains reproducible.

Push consumer application changes to `main` . Woodpecker validates the exact commit, creates a verified
backup, updates the Leader controller bundle, reconciles every follower node,
reloads Caddy only after health checks pass, and runs public smoke tests.  Foundation changes, image upgrades, and runner upgrades remain explicit reviewed workflows.

The automatic push workflows are intentionally limited to enabled
non-singleton app paths under `apps/<id>/` , their policy files under
`config/cluster/apps/` , and the non-cluster Caddy route/config files. Singleton
app changes use their generated stage/switch/stop workflow chain instead;
they are excluded from the normal rollout to prevent concurrent deployments.
Changes under `ops/` ,
`compose/foundation/` , foundation image manifests, or the deployment runner do
not start a consumer rollout. Keep those control-plane changes in a separate
commit from consumer changes: after pushing them, run the generated manual
`foundation-upgrade-leader` workflow and let its dependencies update the
Followers before resuming normal delivery. A commit that mixes a control-plane
path with an app path is intentionally rejected by the deployment scope check.
App image manifest changes for active-active consumers use the generated manual
`app-upgrade-<follower-id>` workflows instead of the normal source deployment;
singleton image changes use the singleton chain described above. If an image
digest and source change must ship together, use the workflow for that app and
do not rely on the normal deploy job.

The automatic consumer path is ordered `Leader -> worker-1 -> worker-2` . Each
node fetches the same full commit over HTTPS and keeps its own release and
rollback pointers. A failed node rolls back locally and stops the dependency
chain, so a later Follower is not updated against an unverified predecessor.
Consumer source, manifests, and application Compose files under `apps/` are
included in this path. Non-cluster committed runtime configuration under
`config/` (including Caddy and route files) is also rendered and reloaded by
this path. The committed cluster policy and node inventory under
`config/cluster/policy.env` , `config/cluster/nodes/` , and non-singleton app
policies under `config/cluster/apps/` use the separate `cluster-reconcile`

path. Foundation Compose
files, foundation images, deployment scripts, and runner images remain explicit
reviewed workflows; they are deliberately rejected by an ordinary consumer
deployment. Singleton source or target-policy changes use their own generated
stage/switch/stop chain; the stage validates the selected target directly and
does not wait for an unrelated cluster-reconcile pipeline.

The rollout is ordered rather than a distributed transaction. If a node is
offline or fails health checks, its deployment rolls back locally and the
dependency chain stops before the next node. Retry the same Woodpecker build
after recovery; no SSH fan-out is required.

Runtime secrets and external service values in `/etc/llm-hub-lite/` and
`/opt/apps/llm-hub-lite/shared/.env.prod` are intentionally not synchronized by
GitHub pushes. Change those values on each affected node through the approved
maintenance/bootstrap process, then recreate the affected project and verify
health before ending maintenance. Use `platformctl sync apps` only when several
consumer projects need reconciliation after a release change.
Manifest-declared singleton runtime env files are included in Restic snapshots
and restore swaps, but are still never copied between Followers during a fresh
singleton move.

The generated manual workflows are per-node and serialized: foundation and
runner upgrades run Leader first, then Followers; rollback runs Followers
before the Leader. This keeps image and configuration changes consistent
without SSH fan-out.

Useful commands on a node:

```sh
platformctl status
platformctl health

# reconcile the checked-out release after a normal source/configuration change
platformctl sync all

# restart containers when only a process restart is needed; this does not
# apply changed Compose limits or environment values
platformctl restart all
platformctl restart caddy
platformctl restart app:/opt/platform/control/current/apps/librechat
platformctl restart app:/opt/platform/control/current/apps/cpapi

# apply changed Compose limits, environment, or a local runtime secret
platformctl recreate app:/opt/platform/control/current/apps/aichorouter
platformctl recreate app:/opt/platform/control/current/apps/cpapi
platformctl recreate app:/opt/platform/control/current/apps/observer

# useful for boot recovery, missing containers, or unhealthy projects
platformctl recover
platformctl backup snapshot manual
platformctl restore extract latest
RESTORE_SOURCE=remote RESTORE_NODE_ID=leader platformctl restore extract latest

# use it only when a normal restart or sync cannot fix a project
platformctl recreate <project>
```

Docker restart policies, live-restore, `platform-recovery.service` , and the recovery timer make reboot recovery idempotent.
Production snapshots require an initialized and verified remote Restic repository. Restic snapshots include runtime configuration, Caddy certificates, Woodpecker/Beszel SQLite online backups, release pointers, and application data without deleting live data. The scheduled timer wakes every 15 minutes for reboot recovery, but `reason=scheduled` snapshots are throttled to one per hour by `RESTIC_SCHEDULE_INTERVAL=3600`; manual, pre-deployment, post-bootstrap, and recovery snapshots remain immediate. Restic uses a persistent mode-700 cache, one reader, `fastest` compression, `--skip-if-unchanged`, and low CPU/I/O priority (`nice`/`ionice`) to reduce contention with consumer services. Override these `RESTIC_*` settings in the root-only `.env.prod` only after measuring the impact.
Local-only snapshots are available only when the explicit production backup gate is disabled for beta/development use.
