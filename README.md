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

The control plane is intentionally single-controller: Woodpecker, Beszel, and
OpenObserve use persistent local state on the Leader. Lightweight Observer
collectors run on every node and send platform-labelled Docker logs to the
Leader. LibreChat replicas share external Atlas MongoDB and Upstash Redis
state. This provides consumer availability without making the logging store a
consumer dependency.

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

Service enablement and placement are committed policy. Foundation services use
`config/cluster/foundation/*.policy`; consumer applications use
`config/cluster/apps/*.policy`, where `ENABLED` is explicit and `NODES` is the
ordered list of stable follower IDs. There are no per-service `*_DISABLE`
environment switches. Caddy is the mandatory exception: its foundation
manifest declares `MANDATORY=true`, it runs on every node, and validation
rejects any attempt to disable it.

Add logical Followers with the repository helper instead of assembling a node
descriptor by hand:

```bash
DOMAIN_NAME=aichorage.de ops/configure-cluster-node.sh add worker-3
git diff -- config/cluster .woodpecker
```

The helper appends `worker-3` to `NODE_IDS`, creates it in `joining` state,
derives every origin hostname from the application manifests, and regenerates
the node-labelled Woodpecker workflows. It never accepts or commits a VPS IP.
The optional `NODE_ORIGIN_PREFIX` changes only the DNS prefix; by default
`worker-3` becomes `worker3`. Missing arguments are prompted on a terminal, and
`CLUSTER_NODE_ASSUME_YES=1` supports a reviewed non-interactive repository
change. The helper rejects a prefix that would reuse an origin hostname already
assigned to another node. Node state changes use the same tool and reject unsafe
transitions or a drain while an app policy still targets the node.

Every application manifest uses version 5 with `PLACEMENT=consumer` and an
`UPSTREAM_MODE` of `singleton`, `active-active`, or `active-passive`. Placement
comes only from the policy's `NODES`; applications are never implicitly placed
on every follower. A singleton requires exactly one active follower, while an
active-active application accepts one or more ordered followers. This keeps
logical placement independent of physical VPS addresses: changing which host
owns `worker-1` changes root-only runtime identity and DNS, not app policy.
When a consumer is active, the Leader can generate the initial shared random
secrets once, while every Follower must receive the same values from the
root-only bundle or explicit environment variables. A non-interactive
bootstrap fails closed instead of inventing per-node credentials. Disabled
consumers do not require their database or application secrets.
Non-secret defaults live in `apps/<id>/config.env`; durable per-node tuning
overrides live in `config/cluster/overrides/<node-id>/<app-id>.env`. Secrets
remain in root-only files under `/etc/llm-hub-lite` and are never committed.

To add a consumer, add `apps/<id>/manifest.env`, `config.env`, its Compose and
route templates, a policy under `config/cluster/apps/`, and digest-pinned image
keys. The workflow generator derives all stage, publish, stop, and singleton
finalizer jobs from that contract. `PUBLIC_ENDPOINTS` maps each public URL key
to a DNS label; both Caddy and Compose derive the full URL from that declaration
and `DOMAIN_NAME`. Shared credentials belong in `CLUSTER_SECRET_KEYS`, while
host-local credentials belong in `NODE_SECRET_KEYS`. For a stateful singleton,
declare its node secret keys,
`MOVE_MODE=fresh`, and its state paths. A target move stages the selected
follower, publishes the Leader route after health checks, then stops containers
on unselected followers while retaining old data and runtime secrets. The new
target starts with a fresh data directory; previous local state is archived for
manual recovery. The controller records an in-progress transition under
`/etc/llm-hub-lite/singleton-state` so an overlapping normal application
workflow cannot accidentally reuse stale SQLite data; the marker is removed
after the staged target is prepared. The journal records the old and new
targets, release SHA, archive path, and phase ( `prepared` , `origin-healthy` ,
`switched` , `completed` , or `failed` ). A failed stage leaves the old Leader route serving
and preserves the journal/archive for an idempotent retry; do not delete the
journal until the target has been verified or deliberately rolled back.

Legacy New API remains as a dormant manifest and is disabled by the committed
policy. CPAPI and Cursor API Proxy are enabled singleton consumers at
`cpapi.aichorage.de` and `cursorapi.aichorage.de`; both are unrelated to the
legacy New API. Pigeon (OutlookEmail) remains packaged for a
future opt-in but is disabled by committed policy and has no target stage,
route, container, or secret prompt. Its generated publish/stop jobs are
cleanup-only so an earlier deployment can be retired safely. OpenObserve
is an enabled Leader foundation service at `observer.aichorage.de`. LibreChat is
enabled on Followers and is published at
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

Cursorapi packages `cursor-api-proxy` and a checksum-pinned Cursor Agent into
the repository-owned `ghcr.io/uptonking/cursor-api-proxy` image because the
upstream project does not publish a deployable image. It is an ephemeral
singleton on `worker-1` by default, with no database, persistent volume, host
port, or Docker socket. Its read-only non-root container is capped at `512m`
memory, `0.50` CPU, and 128 processes. Moving it to another follower is a fresh
deployment; no local application data is copied.

`CURSORAPI_CURSOR_API_KEY` maps to upstream `CURSOR_API_KEY` and must be entered
manually from the Cursor account credential. `CURSORAPI_BRIDGE_API_KEY` protects
all public `/v1/*` requests and should be generated with `openssl rand -hex 32`.
The public route exposes only `/v1/*` and the unauthenticated `/healthz`; the
upstream dashboard and `/api/*` control endpoints remain private. Clients use
`https://cursorapi.aichorage.de/v1` as their base URL and
`CURSORAPI_BRIDGE_API_KEY` as the API key.

Cursorapi images are never built by GitHub Actions, Woodpecker, bootstrap, or
the normal deployment controller. To publish a reviewed upstream revision
manually, update the pinned source commit, Cursor Agent version, download
checksum, and a new unique tag in `images/cursorapi/release.env`, authenticate
Docker to GHCR, then run from the operator workstation:

```bash
ops/publish-cursorapi-image.sh /path/to/cursor-api-proxy
```

The publisher refuses to replace an existing release tag, exports the exact Git
commit into a clean temporary context, runs type checking and all upstream
tests with at most two workers, builds only `linux/amd64`, pushes SBOM and
provenance metadata, and verifies anonymous pull access. Commit the printed
immutable `tag@sha256:digest` in `ops/images.apps.prod.env`. That shared manifest
change, not the image build, triggers the generated consumer workflows on push;
keep it in a dedicated commit because Woodpecker path filters cannot select an
individual assignment inside the shared file.
A new GHCR package must be made public once in its package settings; later
publications verify that state but never try to change package visibility
through an API.

When introducing Cursorapi to an already-running cluster, push the reviewed
control-plane commit, run the manual `foundation-upgrade-leader` chain for that
exact commit, and wait for both follower foundation upgrades. Provision its two
secrets on the selected follower, then retry
`consumer-stage-cursorapi-<node>`. `consumer-publish-cursorapi` publishes the
route only after origin health succeeds, and the generated
`consumer-stop-cursorapi-<old-node>` jobs retire stale placements. The first
automatic consumer attempt may fail before the foundation chain because the
installed controller does not yet know the new app; this is a fail-closed
ordering guard, not a reason to rerun bootstrap.

Pigeon is the dormant single-node OutlookEmail package for
`pigeon.aichorage.de`.
It uses the pinned `ghcr.io/assast/outlookemail:v3.0.6` release, a local SQLite
database at `data/prod/pigeon/outlook_accounts.db`, and the same directory for
encrypted account tokens and uploaded skins. It has no Redis, PostgreSQL, host
port, or Docker-socket dependency. The default profile is capped at `512m`
memory and `0.50` CPU with one Gunicorn worker and four threads; the one-worker
limit is required because scheduler and streaming state are process-local.
Pigeon has no upstream `/healthz`; its native and sidecar checks use the
unauthenticated `/login` page. `PIGEON_SECRET_KEY` must remain stable for
encrypted data and sessions. `PIGEON_LOGIN_PASSWORD` initializes the database
only; after initialization, change the password with the upstream
`scripts/reset_login_password.py` maintenance command rather than by editing
the environment variable. Optional provider settings are root-only runtime
overrides and are not required for the base deployment.
The manifest requires at least 32 characters for `PIGEON_SECRET_KEY` and 12 for
the initial login password. Generate the encryption/session key with
`openssl rand -hex 32`, and use a password-manager-generated login password.

Pigeon retains `worker-2` as its future target in
`config/cluster/apps/pigeon.policy`, but `ENABLED=false` keeps it out of runtime
placement. To opt in later, select the target with
`ops/configure-app-placement.sh pigeon <node-id>`, set `ENABLED=true`, regenerate
the Woodpecker workflows, run all validation, and deploy that reviewed
control-plane change before provisioning secrets. Disabled consumers retain a
publish/stop reconciliation chain but have no target stage. Singleton data
remains local: moving Pigeon does not copy it, and the previous target directory
is retained as a timestamped archive.

The default profile gives Aichorouter `0.9` CPU, `768m` container memory, one
Go runtime thread ( `GOMAXPROCS=1` ), and a `500MiB` Go heap limit. This leaves
headroom for the Go runtime and SQLite while avoiding the 503 overloads caused
by the previous 384 MiB cap. SQLite is limited to one idle and four open
connections; relay pools, request body buffers, stream buffers, and downloads
are bounded, while the optional memory cache, error log, and batch updater remain
disabled. These defaults are committed in `apps/aichorouter/config.env`. Put a
durable node-specific override in
`config/cluster/overrides/<node-id>/aichorouter.env`; reserve root-only runtime
files for secrets. Keep `AICHOROUTER_GOMEMLIMIT` below the container memory
limit and leave enough headroom for the Go runtime and SQLite pages. A committed
default or override is applied by its consumer workflow. For an emergency local
override, update the host's runtime environment and use `platformctl recreate`
so Compose applies the new limits; `platformctl restart` only restarts the old
container definition and does not apply changed Compose configuration.

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
ops/configure-app-placement.sh aichorouter worker-1
git diff -- config/cluster/apps/aichorouter.policy
git add config/cluster/apps/aichorouter.policy && git commit -m 'target aichorouter follower' && git push
```

OpenObserve is a Leader foundation service at `observer.aichorage.de` . It runs
the official single-binary image in local disk mode with no Redis, PostgreSQL,
NATS, or object-storage dependency. Durable data is stored at
`/opt/platform/observer/data` on the Leader and retained for 30 days. The
default profile uses `512m` memory, `0.50` CPU, one query/HTTP worker, a
disabled in-memory cache, and inverted indexes disabled by default. The 8 GiB
data size is a monitored operational target, not a hard quota; inspect it with
`platformctl diagnose foundation`. Its SQLite metadata catalog is captured
through an online SQLite backup before each Restic snapshot.

Every VPS runs a read-only Docker socket proxy and a small Vector collector.
Only containers carrying `com.aichorage.platform=llm-hub-lite` are collected.
Every enrolled service also declares `com.aichorage.application` and
`com.aichorage.component`; those values become top-level `application` and
`component` fields alongside `node_id`, container, image, and stream. Compose
workloads also expose normalized `compose_project` and `compose_service`
fields. Health probes, socket proxies, Observer itself, and other noisy or
recursive sidecars opt out with
`com.aichorage.observer.ignore-logs=true`. Records
are sent to `observer-ingest.<domain>` using a write-only OpenObserve ingestion
token. The ingestion hostname must be DNS-only and resolve directly to the
Leader; the public UI hostname may be proxied through Cloudflare. Each node's
collector has a bounded 512 MiB disk buffer under
`/opt/platform/observer/collector-buffer`; it is transient and excluded from
Restic. The default `OBSERVER_LOG_BUFFER_WHEN_FULL=block` applies backpressure
instead of discarding new records when the buffer fills. Set it to
`drop_newest` only when keeping collectors attached to Docker is more important
than retaining every record during an extended ingestion outage.
`platformctl diagnose foundation` reports the Leader's durable data,
the local collector buffer on every node, and bounded, redacted samples of
recent Vector delivery errors and OpenObserve ingestion errors. It warns at 8
GiB of durable data or 80% of the configured buffer, but never deletes recent
logs. Logs may contain request data or credentials, so restrict UI access and
avoid logging secrets.

The Docker API returns logs and events as long-lived HTTP responses. The pinned
read-only socket proxy defaults to a ten-minute idle timeout, which would break
Vector's stream on quiet nodes. The collector uses a reviewed wrapper that
preserves the image's endpoint ACLs while setting both sides of the stream to
`OBSERVER_LOG_PROXY_STREAM_TIMEOUT=24h`; Vector reconnects after that bounded
interval. `platformctl validate` accepts values from one hour through seven
days. Direct Docker socket access from Vector remains prohibited.

Each collector also runs a 16 MiB, 0.02 CPU heartbeat container after Vector is
healthy. It writes one platform-labelled line every five minutes and retains at
most two 1 MiB local log files. This provides a stable end-to-end signal without
depending on application traffic. On the Leader, `platformctl observer-smoke`
queries OpenObserve for a recent heartbeat from every inventory node; the
periodic health service and deployment smoke workflow run this check
automatically. Container health alone is not considered proof of log delivery.
The command prints every retry
and the currently missing nodes or query error. It does not take the deployment
lock, so a concurrent health timer cannot make an interactive diagnostic wait
silently. Immediately after deploying only the Leader, missing Follower
heartbeats are expected; deploy the identical foundation commit to both
Followers and rerun the check.

Foundation health also checks the Observer sidecar contracts: the controller's
`observer-health-probe` must be healthy, and each collector's
`observer-log-shipper` must be healthy. A running container by itself is not
reported as ready when either contract is unavailable.

The smoke check is bounded by default: six attempts, a ten-second request
timeout, and a 120-second overall deadline. Override
`OBSERVER_SMOKE_ATTEMPTS`, `OBSERVER_SMOKE_RETRY_DELAY`,
`OBSERVER_SMOKE_REQUEST_TIMEOUT_SECONDS`, or `OBSERVER_SMOKE_TIMEOUT_SECONDS`
for a deliberately slower recovery check; all values are validated and capped.

In the OpenObserve UI, select organization `default`, open Logs, select the
`docker` stream, and use a time range covering at least the last 15 minutes.
The `node_id`, `application`, and `component` fields identify the source. A
healthy installation includes records where
`component = 'foundation-observer-heartbeat'`; Woodpecker records use
`application = 'woodpecker'`, and Aichorouter records use
`application = 'aichorouter'`. The configured root account, including a custom
email such as `admin@qq.com`, has access to this same `default` organization.

Pinned Vector requires a disk buffer of at least `268435488` bytes (about 256
MiB); the platform default remains 512 MiB. The collector intentionally uses one
Vector worker thread by default to limit idle CPU and memory use. Increase
`OBSERVER_LOG_SHIPPER_THREADS` only after observing sustained ingestion backlog.

This replaces the earlier singleton-consumer Observer layout. A clean bootstrap
creates the new Leader-owned data directory; it does not automatically move
Observer data that was previously stored on a Follower. Preserve an old
installation only through an explicit export/restore procedure. Otherwise, the
old Follower-local data may be discarded after the new Leader deployment is
verified. During an in-place release, reconciliation retires old
`app-observer` containers but deliberately leaves their bind-mounted data and
volumes untouched for that decision.

OpenObserve's production image is distroless and does not contain an HTTP
client. A tiny pinned `health-probe` sidecar performs the HTTP readiness check
against `/healthz` ; the same sidecar pattern is used by Aichorouter, CPAPI,
and Cursorapi.
`platformctl health` requires the application containers to be running and
the declared `health-probe` container to be `healthy` . Pigeon follows the same
project-level contract, using its unauthenticated `/login` page because the
upstream image has no dedicated health endpoint. The Observer log proxy
and Vector shipper retain their own private healthchecks.

The non-secret Observer defaults are maintained in
`ops/foundation/observer.env.example` and copied only when a host does not
already have an override. `configure-observer-ingest` serializes token
reconciliation, validates the organization/stream path, and keeps the root
credential on the Leader; Followers receive only the write-only collector
token.

Provision each enabled singleton's root-only secrets once with its manual
Woodpecker workflow. For the default placement, run:

```bash
consumer-secrets-aichorouter-worker-1
consumer-secrets-cpapi-worker-1
consumer-secrets-cursorapi-worker-1
```

These workflow names are selected in the Woodpecker UI, not executed in a
shell. They use protected repository secrets and avoid an SSH maintenance
session. Direct `configure-app-secrets.sh` execution is reserved for initial
bootstrap or repair when Woodpecker is unavailable.

CPAPI exposes an unauthenticated `/healthz` endpoint that returns `{"status":"ok"}` .
Its main container also has a native liveness check for the persisted config
and init process; the `health-probe` sidecar verifies the HTTP endpoint without
requiring `curl` or `wget` in the minimal CPAPI image. Verify the complete
project state with:

```bash
docker compose -p app-cpapi ps
curl -fsS https://worker1-cpapi-origin.aichorage.de/healthz
curl -fsS https://cpapi.aichorage.de/healthz
curl -fsS https://worker1-cursorapi-origin.aichorage.de/healthz
curl -fsS https://cursorapi.aichorage.de/healthz
```

The helper reads `CLUSTER_SECRET_KEYS`, `NODE_SECRET_KEYS`,
`RUNTIME_ENV_FILE`, and `POLICY_FILE` from the manifest, so a future consumer
can use the same command without adding a new script branch. Moving a singleton
does not copy node-local secrets or data to the new
Follower. The stage job creates a fresh `DATA_ROOT/DATA_ROOT_REL` directory and
retains any previous directory as `*.retained.<UTC timestamp>` ; the stop jobs
remove only old containers. After verifying the new deployment, manual cleanup
is deliberately explicit: stop the old project first, inspect the retained
directory, then remove that exact directory and the old runtime file under
`/etc/llm-hub-lite` when it is no longer needed.

For an enabled singleton target move, provision the future follower before
committing the policy change. Secret values remain outside Git, while generated
manual Woodpecker workflows deliver protected repository secrets to an active
Follower without modifying cluster policy. Then update placement from the
operator checkout. For example, to move Cursorapi to `worker-2`:

First run the manual `consumer-secrets-cursorapi-worker-2` workflow in
Woodpecker. It uses protected repository secrets and validates the target node
without an SSH session. Then commit the placement and generated workflow
changes:

```bash
ops/configure-app-placement.sh cursorapi worker-2
ops/generate-woodpecker-workflows.sh generate
ops/generate-woodpecker-workflows.sh --check
git diff -- config/cluster/apps/cursorapi.policy .woodpecker/
git add config/cluster/apps/cursorapi.policy .woodpecker/
git commit -m 'move cursorapi to worker-2'
git push origin main
```

Wait for `consumer-stage-cursorapi-worker-2`,
`consumer-publish-cursorapi`, and the generated stop job for each unselected
follower, followed by `consumer-finalize-cursorapi-worker-2`, in that order. The
finalizer retains the active service and closes its node-local transition journal
only after the route and stale-node steps succeed. The publish job snapshots the installed Leader route
and checks the manifest's expected health response at the origin and public
endpoint. If publication or the public smoke fails, it atomically restores the
old route, reloads Caddy, keeps the previous-target marker, and returns failure,
so Woodpecker does not stop the old target. A failed rollback reload leaves a
`*.route-backup.caddy` or `*.route-was-missing` file under
`/etc/llm-hub-lite/singleton-state`; resolve and verify the Caddy route before
removing that artifact and retrying.

The same generated consumer contract handles active-active applications. It
stages each configured node in `NODES` order, publishes the complete healthy
upstream set on the Leader, and stops the project on unselected followers.
Singleton-specific state journaling remains an internal controller mechanism;
operators use only the generic consumer workflows.

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
On a 1 GB VPS, bootstrap enables a 1 GB `/swapfile` with `nofail` persistence
and low swappiness when no swap is already active. Override
`LOW_MEMORY_SWAP_ENABLED` , `LOW_MEMORY_SWAPFILE` , `LOW_MEMORY_SWAP_SIZE` , or
`LOW_MEMORY_SWAP_SWAPPINESS` before bootstrap if the provider supplies swap or
uses a different storage policy. Swap is a pressure buffer, not a substitute
for external MongoDB, Redis, and R2. Keep `MONGO_BACKUP_NODE_ID` in
`config/cluster/apps/librechat.policy` fixed to one selected Follower; only that
node performs the optional `mongodump` export, avoiding duplicate Atlas
backups.

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

See the concise operator runbook: [docs/first-deployment.md](docs/first-deployment.md).

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
    - Pigeon package retained but disabled

SSH is used only for this one-time host bootstrap. Before starting, prepare the
three VPS hosts, Cloudflare DNS, and the R2 Restic repositories. The Leader
creates `shared-secrets.env` and `beszel-enrollment.env` during bootstrap; those
files are transferred to Followers before they start. Public domains `ci`,
`ci-grpc`, `status`, `chat`, `chat-admin`, `aichorouter`, `cpapi`, `cursorapi`,
and `observer` point to the Leader. Add `observer-ingest` as a DNS-only record
directly to the Leader; collectors use it for HTTPS ingestion. The DNS-only
origins using the `worker1-` prefix point to Worker 1, while the stable-ID
`worker2-` origin records point to Worker 2. Pigeon origin records are not
required while it is disabled; create the selected Follower's DNS-only origin
before opting it in. The `leader` stable ID is the public Leader and therefore
does not need a private origin record for ingress.
The default Cursorapi placement specifically requires the DNS-only
`worker1-cursorapi-origin.<domain>` record to resolve to Worker 1; the public
`cursorapi.<domain>` record resolves to the Leader and may be Cloudflare-proxied.
The Follower origin records must remain DNS-only. The Follower firewall only
permits Docker HTTPS traffic from the Leader IP. After certificates work, the
public records may be proxied through Cloudflare.

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

# or only update bootstrap scripts
for host in "$LEADER" "$WORKER_1" "$WORKER_2"; do

  scp ops/bootstrap-vps.sh \
    "root@$host:/root/llm-hub-lite-bootstrap.sh"

  ssh "root@$host" \
    'chmod 700 /root/llm-hub-lite-bootstrap.sh'
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
When `NODE_ID` is omitted on an interactive first deployment, bootstrap first
asks whether the VPS is the Leader or a Follower. Choosing Leader selects the
committed `LEADER_NODE_ID`; choosing Follower asks for one of the committed
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
`CURSORAPI_BRIDGE_API_KEY` with `openssl rand -hex 32`. Disabled applications
such as Pigeon do not prompt for secrets. On the Leader, bootstrap prompts for the
OpenObserve root credentials and creates a named write-only ingestion token;
only the ingestion username/token are copied in `shared-secrets.env` to
Followers. The CPAPI management panel is enabled and protected by its
management key.

### Add or replace a VPS

A new node uses a two-commit enrollment so it cannot receive consumers before
its foundation is healthy:

1. Run `DOMAIN_NAME=aichorage.de ops/configure-cluster-node.sh add worker-3`,
   validate the generated diff, commit, and push. The node remains `joining`.
2. Create DNS-only origin records from
   `config/cluster/nodes/worker-3.env`, all pointing to the new VPS. Public app
   records continue to point only to the Leader. Copy the Leader's root-only
   shared-secret and Beszel enrollment bundles through the same protected
   one-time channel used for the first two Followers.
3. Copy the current bootstrap script to the new VPS and run it once with
   `NODE_ID=worker-3`. Caddy, the Woodpecker worker, Beszel agent, and Observer
   collector start; consumers remain absent because the node is still joining.
4. Verify `platformctl health` and the Woodpecker agent, then run
   `ops/configure-cluster-node.sh state worker-3 active`, commit, and push.
   Woodpecker now creates the node's secret workflows and makes it eligible for
   explicit consumer placement.
5. Put the node in an app's ordered `NODES` using
   `ops/configure-app-placement.sh`, review, commit, and push. The generated
   stage/publish/stop chain performs the deployment without SSH.

To remove a host, first move every consumer out of its app policies and push
that change. Transition `active -> draining`, verify the stop workflows, then
transition `draining -> retired` and run the generated
`node-retire-<node-id>` workflow before decommissioning the VPS. To replace a
VPS without changing logical placement, ensure the old host is stopped, update
its origin DNS records to the replacement IP, and bootstrap the replacement
with the same stable `NODE_ID`; IP addresses never enter Git.

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
`consumer-stage-*`, `consumer-publish-*`, `consumer-stop-*`, and singleton
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
with `curl --resolve`, demote the old Leader, and only then change public
Cloudflare DNS. There is intentionally no generated `cluster-reconcile-*`
workflow for this recovery operation. The recovery point is the last successful
remote backup; there is no automatic controller failover. Restores preserve the
target node's `/etc/llm-hub-lite/node.env` by default, preventing a snapshot
from silently changing stable identity or address. Set `RESTORE_IDENTITY=1`
only for an intentional, reviewed controller promotion.

New API is the consumer HA exception: every replica uses the same Neon
PostgreSQL DSN, `SESSION_SECRET`, and `CRYPTO_SECRET`. If it is enabled, its
generic consumer stages follow the ordered policy `NODES`; keep the migration
owner first so it becomes healthy before the other replicas. Never deploy two
replicas concurrently. `NEW_API_MIGRATION_NODE_ID` and
`NEW_API_BACKUP_NODE_ID` live in `config/cluster/apps/newapi.policy`, and both
must name selected followers. Only the backup owner runs `pg_dump`; every node
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
`/healthz` over the private network.

Cursorapi is a separate ephemeral singleton at `cursorapi.aichorage.de`. Its
target is stored in `config/cluster/apps/cursorapi.policy` and defaults to
`worker-1`. The repository-built image bundles a checksum-pinned Cursor Agent;
the runtime has no host port, database, persistent volume, or Docker socket.
Its native and sidecar healthchecks both verify the unauthenticated `/healthz`
endpoint. The Leader exposes `/healthz` for deployment smoke checks and
authenticated `/v1/*` API traffic, while dashboard and control paths remain
unpublished. A target change intentionally starts a fresh container and
discards its ephemeral home/session state.

OpenObserve is a Leader-only foundation service at `observer.aichorage.de`.
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
`config/cluster/apps/librechat.policy`, then install `mongodump` on that owner
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
4. For an enabled singleton, `consumer-finalize-<app>-<node>` runs on the
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

Foundation/controller changes under `ops/`, `compose/foundation/`, foundation
policies, or the foundation image manifest use the generated manual
`foundation-upgrade-leader` workflow. Its dependencies update the remaining
nodes in inventory order. Runner changes use the separate manual
`runner-upgrade-leader` chain. The scope guards reject a consumer job that also
contains control-plane or foundation files; split mixed changes and apply the
foundation commit before pushing dependent consumer changes.

Observer is a foundation service, so Observer controller, collector, and
retention changes use `foundation-upgrade-*`. Consumer defaults belong in
`apps/<id>/config.env`; committed host-specific tuning belongs in
`config/cluster/overrides/<node-id>/<app-id>.env`. Both flow through Git and the
consumer workflow. Root-only app secrets and emergency runtime overrides are
the exception. Changing those requires an approved host maintenance session,
followed by `platformctl recreate` and `platformctl health`; do not turn that
break-glass procedure into the daily deployment path. Use `platformctl restart`
only when no Compose or environment definition changed.

Each node fetches the same exact commit and keeps independent current, previous,
and rollback pointers. Workflows are serialized through the shared deployment
concurrency group. If a node is offline or unhealthy, recover it and retry the
same Woodpecker build; no SSH fan-out is required for routine delivery.

### Enabling Pigeon later

Pigeon is disabled by default. Enabling it is a reviewed control-plane change:

1. Create the selected Follower's DNS-only origin, run
   `ops/configure-app-placement.sh pigeon <node-id>`, and set `ENABLED=true` in the app
   policy.
2. Run `ops/generate-woodpecker-workflows.sh generate`, repository validation,
   and pre-commit, then commit the policy and generated workflows together.
3. Push the control-plane commit and run the reviewed
   `foundation-upgrade-leader` chain so every node installs the new workflows.
4. Run the generated manual `consumer-secrets-pigeon-<node-id>` workflow, then
   push a consumer-scoped commit or retry the Pigeon consumer chain for that
   release. Publication occurs only after target health succeeds. Use direct
   `configure-app-secrets.sh pigeon` only as a repair fallback.

## Woodpecker troubleshooting

Mutating workflows share the `llm-hub-lite-deployment` concurrency group. This
is intentional: every deployment can update release pointers and generated
Caddy configuration, so a consumer stage/publish/stop transition, foundation
upgrade, runner upgrade, or rollback must finish before another one starts. A
queued build is not stuck; wait for the earlier mutating workflow or cancel the
obsolete build and rerun the newest commit.

The `platform-submit` step streams the deployment runner log into the
Woodpecker step while it runs. The first useful line is the deployment metadata
record (`node`, `role`, `mode`, commit SHA, workflow, pipeline, and build). A
scope rejection then lists every changed path, which makes a mixed commit easy
to correct. `.env.prod.example` and `.env.dev.example` are templates and may be
committed with application changes; they never overwrite a host's live
`/opt/apps/llm-hub-lite/shared/.env.prod`. Foundation files, runner code, and
foundation image manifests still require their reviewed manual workflows;
application image manifests use the affected generated consumer workflows.

When a pipeline fails, copy the complete failed step log, including the
`--- host deployment diagnostics ---` block printed at the end. For a consumer
failure, the block is limited to that app; for a foundation failure, it covers
the local foundation and active consumer projects. The diagnostics
include the current/previous release pointers, maintenance marker, Compose
state, container exit/OOM/restart counts, and recent healthcheck output. Do not
paste `/etc/llm-hub-lite/*.env` files or any secret values.

If the pipeline log is truncated, collect the same safe summary directly from
the affected node:

```bash
ssh root@<leader> 'platformctl diagnose foundation'
ssh root@<worker-1> 'platformctl diagnose consumers'
ssh root@<worker-1> 'platformctl diagnose foundation'
ssh root@<worker-1> 'platformctl diagnose app:aichorouter'
ssh root@<worker-1> 'platformctl health'
```

For a transient runner error, also copy the latest host deployment log (it is
root-only and contains no secret files):

```bash
ssh root@<node> 'tail -n 240 /opt/apps/llm-hub-lite/shared/logs/deploy.log'
```

OpenObserve collects platform-labelled Docker logs from every VPS. Woodpecker,
Aichorouter, CPAPI, Cursorapi, LibreChat, Caddy, and Beszel containers are
collected unless they carry the opt-out label. Pigeon is enrolled when it is enabled. The
short-lived deployment runner is intentionally
excluded because `platform-submit` already streams its complete log into the
Woodpecker step. The dedicated collector credentials are write-only; the
OpenObserve root password is never distributed to Followers. The pipeline log
and `platformctl diagnose` output remain useful when the logging path itself is
unavailable.

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

Workflow generation is transactional. `ops/generate-woodpecker-workflows.sh`
renders and dependency-checks the complete generated set in a temporary sibling
tree, then applies it as one operation; a failed render or copy restores the
previous generated workflows and image locks.

Useful commands on a node:

```sh
platformctl status
platformctl health
platformctl observer-smoke
platformctl diagnose foundation

# reconcile the checked-out release after a normal source/configuration change
platformctl sync all

# restart containers when only a process restart is needed; this does not
# apply changed Compose limits or environment values
platformctl restart all
platformctl restart caddy
platformctl restart app:/opt/platform/control/current/apps/librechat
platformctl restart app:/opt/platform/control/current/apps/cpapi
platformctl restart app:/opt/platform/control/current/apps/cursorapi

# apply changed Compose limits, environment, or a local runtime secret
platformctl recreate app:/opt/platform/control/current/apps/aichorouter
platformctl recreate app:/opt/platform/control/current/apps/cpapi
platformctl recreate app:/opt/platform/control/current/apps/cursorapi
platformctl recreate observer-controller
platformctl recreate observer-collector

# useful for boot recovery, missing containers, or unhealthy projects
platformctl recover
platformctl backup snapshot manual
platformctl restore extract latest
RESTORE_SOURCE=remote RESTORE_NODE_ID=leader platformctl restore extract latest

# use it only when a normal restart or sync cannot fix a project
platformctl recreate <project>
```

Docker restart policies, live-restore, `platform-recovery.service` , and the recovery timer make reboot recovery idempotent. Recovery starts and verifies foundation projects first; if a consumer cannot start, be stopped, or become healthy, `platformctl recover` still publishes the last valid routes but exits nonzero so systemd records the failure and the retry timer attempts recovery again. Recovery uses the root-only `/etc/llm-hub-lite/validation.stamp` to skip repeated external Compose/Caddy validation when all committed and host-local inputs are unchanged; use `platformctl recover --full` after changing Docker or Compose itself. Periodic health checks skip cleanly while a deployment lock is held, while manual health and diagnostics wait briefly for a consistent snapshot.
Production snapshots require an initialized and verified remote Restic repository. Restic snapshots include runtime configuration, Caddy certificates, Woodpecker/Beszel SQLite online backups, release pointers, and application data without deleting live data. The scheduled timer wakes every 15 minutes for reboot recovery, but `reason=scheduled` snapshots are throttled to one per hour by `RESTIC_SCHEDULE_INTERVAL=3600`; manual, pre-deployment, post-bootstrap, and recovery snapshots remain immediate. Restic uses a persistent mode-700 cache, one reader, portable `auto` compression, `--skip-if-unchanged` when supported, and low CPU/I/O priority (`nice`/`ionice`) to reduce contention with consumer services. Older Restic clients that cannot use a newer requested compression mode automatically fall back to `auto`; clients without `--skip-if-unchanged` continue without that optional optimization. Override these `RESTIC_*` settings in the root-only `.env.prod` only after measuring the impact.
If a bootstrap reports `invalid compression mode`, the installed Restic client is older than the configured mode. Copy the current `ops/bootstrap-vps.sh` to the host and rerun bootstrap; it normalizes the mode to a supported value and persists it in `.env.prod`. The error occurs before a snapshot is written, so do not delete or reinitialize the remote repository. Verify the repair with `platformctl backup snapshot manual`; inspect remote snapshots with the configured Restic credentials or use `RESTORE_SOURCE=remote platformctl restore extract latest` when a restore test is appropriate.
Local-only snapshots are available only when the explicit production backup gate is disabled for beta/development use.
