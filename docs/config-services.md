# Configuration and DevOps for Docker Services

Copy `.env.prod.example` to `.env.prod` and keep it root-readable only. Put
OAuth, Neon, application keys, and all other secrets in that runtime file or
the root-only foundation files under `/etc/llm-hub-lite` . Never commit them.
The runtime filenames `node.env` and `shared-secrets.env` are ignored as a
second line of defense. Run `ops/check-ip-privacy.sh --cached` before committing;
CI rejects globally routable IPv4 literals anywhere in tracked content.
Local Restic snapshots are enabled by default on each VPS. Off-host recovery is
optional: set `RESTIC_REMOTE_ENABLED=true` , provide a verified
`RESTIC_REMOTE_REPOSITORY` and the root-only password file named by
`RESTIC_REMOTE_PASSWORD_FILE` , and set `PRODUCTION_REQUIRE_REMOTE_BACKUP=true`

when a deployment must fail unless the remote repository is available. If the
remote backend needs provider credentials (for example S3 or B2), put the
required Restic variables in a root-only file at `RESTIC_REMOTE_ENV_FILE` ;
pass `RESTIC_REMOTE_ENV_SOURCE_FILE=/path/to/file` during bootstrap so it is
installed on the VPS and reused by all backup timers. Prefer a separate remote
repository or backend prefix for each stable node ID. Shared repositories are
supported: snapshots and retention are scoped by the `node:<NODE_ID>` tag.

The following R2 initialization and transfer example is needed only when
`RESTIC_REMOTE_ENABLED=true` ; omit it for the default local-only deployment.

Service enablement and placement are committed policy. Foundation services use
`config/cluster/foundation/*.policy` ; consumer applications use
`config/cluster/apps/*.policy` , where `ENABLED` is explicit and `NODES` is the
ordered list of stable follower IDs. There are no per-service `*_DISABLE`

environment switches. Caddy is the mandatory exception: its foundation
manifest declares `MANDATORY=true` , it runs on every node, and validation
rejects any attempt to disable it.

Add logical Followers with the repository helper instead of assembling a node
descriptor by hand:

```bash
DOMAIN_NAME=aichorage.de ops/configure-cluster-node.sh add worker-4
git diff -- config/cluster .woodpecker
```

The helper appends the requested node to `NODE_IDS` , creates it in `joining` state,
derives every origin hostname from the application manifests, and regenerates
the node-labelled Woodpecker workflows. It never accepts or commits a VPS IP.
The optional `NODE_ORIGIN_PREFIX` changes only the DNS prefix; by default
`worker-3` becomes `worker3` . Missing arguments are prompted on a terminal, and
`CLUSTER_NODE_ASSUME_YES=1` supports a reviewed non-interactive repository
change. The helper rejects a prefix that would reuse an origin hostname already
assigned to another node. Node state changes use the same tool and reject unsafe
transitions or a drain while an app policy still targets the node.

Every application manifest uses version 5 with `PLACEMENT=consumer` and an
`UPSTREAM_MODE` of `singleton` , `active-active` , or `active-passive` . Placement
comes only from the policy's `NODES` ; applications are never implicitly placed
on every follower. A singleton requires exactly one active follower, while an
active-active application accepts one or more ordered followers. This keeps
logical placement independent of physical VPS addresses: changing which host
owns `worker-1` changes root-only runtime identity and DNS, not app policy.
When a consumer is active, the Leader can generate the initial shared random
secrets once, while every Follower must receive the same values from the
root-only bundle or explicit environment variables. A non-interactive
bootstrap fails closed instead of inventing per-node credentials. Disabled
consumers do not require their database or application secrets.
Manifests may declare `GENERATED_SECRET_BYTES` and `SECRET_REGEXES` for
application-specific formats; Flowy uses these to keep `AP_ENCRYPTION_KEY` at
the required 32-character length.
Generated node-local keys are reconciled idempotently on the selected Follower
before every consumer stage. Existing valid values are reused; missing values
are created with the manifest's byte count. Operator-provided and mapped
credentials remain in the explicit manual secret workflows.
Non-secret defaults live in `apps/<id>/config.env` ; durable per-node tuning
overrides live in `config/cluster/overrides/<node-id>/<app-id>.env` . Secrets
remain in root-only files under `/etc/llm-hub-lite` and are never committed.

Applications that render a runtime configuration from a template may set
`RUNTIME_CONFIG_FILE` in their manifest. The path is relative to
`/etc/llm-hub-lite` and defaults to `runtime/<app>/config.yaml`; the renderer,
Compose definition, recovery checks, and migration checks all use this same
contract.

To add a consumer, add `apps/<id>/manifest.env` , `config.env` , its Compose and
route templates, a policy under `config/cluster/apps/` , and digest-pinned image
keys. The workflow generator derives all stage, publish, stop, and singleton
finalizer jobs from that contract. It also emits a serial Leader-first
`cluster-reconcile-*` chain for cluster inventory, foundation policy, Caddy,
foundation Compose, and reviewed `ops/**` control-path pushes.
`PUBLIC_ENDPOINTS` maps each public URL key
to a DNS label; both Caddy and Compose derive the full URL from that declaration
and `DOMAIN_NAME` . Shared credentials belong in `CLUSTER_SECRET_KEYS` , while
host-local credentials belong in `NODE_SECRET_KEYS` . For a stateful singleton,
declare its node secret keys, `MOVE_MODE=fresh` , and its state paths. A target move stages the selected follower, publishes the Leader route after health checks, then stops containers on unselected followers while retaining old data and runtime secrets. The new target starts with a fresh data directory; previous local state is archived for manual recovery. The controller records an in-progress transition under
`/etc/llm-hub-lite/singleton-state` so an overlapping normal application
workflow cannot accidentally reuse stale SQLite data; the marker is removed
after the staged target is prepared. The journal records the old and new
targets, release SHA, archive path, and phase ( `prepared` , `origin-healthy` ,
`switched` , `completed` , or `failed` ). A failed stage leaves the old Leader route serving and preserves the journal/archive for an idempotent retry; do not delete the
journal until the target has been verified or deliberately rolled back.

SQLite applications declare fixed database paths with `SQLITE_PATHS` and may
declare files created at runtime with `SQLITE_GLOBS`. Glob directories are
literal and root-confined; only the filename may contain `*` or `?`. Backups
use SQLite's online API for every match, exclude live database/WAL companions
from the raw Restic tree, and restore from `sqlite/map.tsv` regardless of file
extension. This supports Grist's `.sqlite3` catalog and `.grist` documents.

Legacy New API remains as a dormant manifest and is disabled by the committed
policy. CPAPI and Cursor API Proxy are enabled singleton consumers at
`cpapi.aichorage.de` and `cursorapi.aichorage.de` ; both are unrelated to the
legacy New API. Pigeon (OutlookEmail) remains packaged for a
future opt-in but is disabled by committed policy and has no target stage,
route, container, or secret prompt. Its generated publish/stop jobs are
cleanup-only so an earlier deployment can be retired safely. OpenObserve
is an enabled Leader foundation service at `observer.aichorage.de` . LibreChat is
enabled on Followers and is published at
`chat.aichorage.de` and `chat-admin.aichorage.de` . It uses MongoDB Atlas and
Upstash Redis; provide `LIBRECHAT_MONGO_URI` and `LIBRECHAT_REDIS_URI` (plus
the generated JWT and admin-panel secrets) in the root-only bundle or during
interactive bootstrap. Production also requires the shared Cloudflare R2
endpoint, access key, secret key, region ( `auto` ), and bucket through the
`LIBRECHAT_AWS_*` settings. LibreChat uses `fileStrategy: s3` , so R2 is the
source of truth for uploads and images across Followers. Set `LIBRECHAT_APP_TITLE`
and `LIBRECHAT_HELP_AND_FAQ_URL` in `apps/librechat/config.env` to control the
product name and help link returned by the LibreChat API. OpenRouter is exposed
as a bounded custom endpoint using only `openrouter/free`; live model discovery
is disabled so paid models cannot appear unexpectedly. Store the shared key as
the protected Woodpecker repository secret `LIBRECHAT_OPENROUTER_KEY`, then
create three manual pipelines with `MANUAL_WORKFLOW` set to
`consumer-secrets-librechat-leader`, `consumer-secrets-librechat-worker-1`, and
`consumer-secrets-librechat-worker-2`. The runtime key remains root-only as
`LIBRECHAT_OPENROUTER_KEY` and is mapped to LibreChat's `OPENROUTER_KEY` only
inside the API container. Rotate the repository secret and rerun those three
manual workflows before recreating LibreChat. Registration is disabled;
existing accounts and conversations remain available. The initial profile
intentionally omits local MongoDB, Redis, Meilisearch, RAG, and pgvector.
URL-encode reserved characters in Atlas and Upstash credentials before placing
them in the connection URI.

Aichorouter is the enabled singleton example at `aichorouter.aichorage.de` .
It uses the upstream New API image plus a tiny HTTP health-probe sidecar, a
bind-mounted SQLite database at `data/prod/aichorouter/aichorouter.db` , and
no Redis, PostgreSQL, or other local dependency. `SESSION_SECRET` and `CRYPTO_SECRET` are stored in `/etc/llm-hub-lite/aichorouter.env` on the selected follower. The image is memory-capped and has no host-published port; all public traffic enters through the Leader's Caddy route. When a user enables **Record IP Address**, New API stores the address only on subsequent usage and error rows; open a row's **Details** dialog to view it. Caddy accepts `CF-Connecting-IP` only from the Cloudflare ranges declared in `config/Caddyfile`; Followers also trust the host-local `LEADER_PUBLIC_IP`. At each hop, the reusable `forward_verified_client_ip` snippet replaces `CF-Connecting-IP`, `X-Forwarded-For`, and `X-Real-IP` with Caddy's verified address. This makes the trust boundary explicit and prevents a direct origin caller from forwarding a spoofed address into New API. Keep Cloudflare's ranges synchronized with its published IP list. Existing rows are not rewritten when recording is enabled or proxy configuration changes. SQLite is intentionally local and is not replicated, so a target move is intentionally a fresh local deployment. Previous local state is retained in an archive directory until manually removed.
For the first login, open  https://aichorouter.aichorage.de/setup/.

Flowy is the Activepieces singleton at `flowy.aichorage.de` , enabled on the
active `worker-3` follower by default. Change `NODES` in `config/cluster/apps/flowy.policy` to move it to another active follower, then regenerate the reviewed workflows. Flowy uses one `WORKER_AND_APP` process with PGlite under `data/prod/flowy/config/pglite` , in-memory Redis, one worker, sandbox code-only execution, no automatic piece-catalog synchronization, and bounded memory/CPU. The default `FLOWY_FILE_STORAGE_LOCATION=S3` stores execution files in Cloudflare R2 while keeping metadata in PGlite. Warning-level logging avoids noisy periodic snapshots on a small VPS. The container is capped at 1.5 GB with a 768 MB Node heap, leaving headroom for the worker, PGlite, and native allocations; sandbox reuse is disabled so piece modules do not accumulate in a long-lived execution process. Provision `FLOWY_S3_ENDPOINT`, `FLOWY_S3_BUCKET`, `FLOWY_S3_ACCESS_KEY_ID`, and `FLOWY_S3_SECRET_ACCESS_KEY` with the generated `consumer-secrets-flowy-worker-3` workflow. These credentials are delivered only to the selected singleton follower; no Leader secret workflow is emitted. `FLOWY_ENCRYPTION_KEY` and
`FLOWY_JWT_SECRET` are node-local. Existing DB-backed files remain readable after switching to S3; no automatic blob migration is performed. Singleton moves are fresh deployments and archive the prior local PGlite directory; backups stop the running Flowy container before copying its PGlite state. Backup staging is kept under
`/opt/backups/llm-hub-lite/stage` by default rather than `/run` , because VPS
`/run` is commonly a small tmpfs that cannot hold the PGlite directory.

Wabase is the Grist OSS singleton at `wabase.aichorage.de`, enabled on active
`worker-4`. A fresh follower must pass foundation verification before it is
activated and selected with `ops/configure-app-placement.sh`. Wabase runs
one `gristlabs/grist-oss` container with `/persist/home.sqlite3` and
`/persist/docs/*.grist`, WAL mode, one document worker, warning-level logging,
and no Redis or PostgreSQL. The container is capped at `1500m`, `0.9` CPU, and
256 processes; the Node heap is capped at 768 MB. Protected Quick Setup starts
with `GRIST_IN_SERVICE=false`; the session and boot keys are generated only in
`/etc/llm-hub-lite/wabase.env`. After setup, commit
`WABASE_IN_SERVICE=true`. A placement change intentionally starts fresh and
archives the previous local data.

Direct/orphan applications such as Verge publish their declared
`DIRECT_LISTENERS` on the selected follower and do not create a Leader Caddy
route. The listener must bind a public wildcard (`0.0.0.0` or `[::]`) because
DNS points directly at that VPS. `DIRECT_PROBE=socket` validates the published
port while `HEALTH_MODE=process` treats a running container as health when the
image has no Docker healthcheck. Follower Docker ingress is scoped to the
public IPv4 interface and defaults to deny: only the Leader proxy and
policy-allowlisted direct listeners are accepted; egress and internal bridge
traffic are unaffected. Use Cloudflare DNS-only records for unproxied
protocols such as Verge UDP/443.

An intentional singleton identity rename may declare the temporary
`IDENTITY_MIGRATION_*` manifest contract. The generated target stage then runs
`ops/migrate-app-identity.sh`: it stops the source Compose project, atomically
moves the data directory, converts only the declared environment-key prefix,
and leaves a guarded compatibility symlink for rollback. The final target job
removes the source env, symlink, and private network only after the existing
origin health gate succeeds. Conflicting source and target paths fail closed;
the migration fields are removed in a follow-up release after live
verification.

Cursorapi packages `cursor-api-proxy` and a checksum-pinned Cursor Agent into the repository-owned `ghcr.io/uptonking/cursor-api-proxy` image because the upstream project does not publish a deployable image. It is an ephemeral singleton on `worker-1` by default, with no database, persistent volume, host port, or Docker socket. Its read-only non-root container is capped at `512m` memory, `0.50` CPU, and 128 processes. Moving it to another follower is a fresh deployment; no local application data is copied. `CURSORAPI_CURSOR_API_KEY` maps to upstream `CURSOR_API_KEY` and must be entered manually from the Cursor account credential. `CURSORAPI_BRIDGE_API_KEY` protects all public `/v1/*` requests and should be generated with `openssl rand -hex 32` . The public route exposes only `/v1/*` and the unauthenticated `/healthz` ; the upstream dashboard and `/api/*` control endpoints remain private. Clients use `https://cursorapi.aichorage.de/v1` as their base URL and `CURSORAPI_BRIDGE_API_KEY` as the API key. Cursorapi images are never built by GitHub Actions, Woodpecker, bootstrap, or
the normal deployment controller. To publish a reviewed upstream revision
manually, update the pinned source commit, Cursor Agent version, download
checksum, and a new unique tag in `images/cursorapi/release.env` , authenticate
Docker to GHCR, then run from the operator workstation:

```bash
ops/publish-cursorapi-image.sh /path/to/cursor-api-proxy
```

The publisher refuses to replace an existing release tag, exports the exact Git
commit into a clean temporary context, runs type checking and all upstream
tests with at most two workers, builds only `linux/amd64` , pushes SBOM and
provenance metadata, and verifies anonymous pull access. Commit the printed
immutable `tag@sha256:digest` in `ops/images.apps.prod.env` . That shared manifest
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
`consumer-stage-cursorapi-<node>` . `consumer-publish-cursorapi` publishes the
route only after origin health succeeds, and the generated
`consumer-stop-cursorapi-<old-node>` jobs retire stale placements. The first
automatic consumer attempt may fail before the foundation chain because the
installed controller does not yet know the new app; this is a fail-closed
ordering guard, not a reason to rerun bootstrap.

Pigeon is the dormant single-node OutlookEmail package for `pigeon.aichorage.de` .
It uses the pinned `ghcr.io/assast/outlookemail:v3.0.6` release, a local SQLite
database at `data/prod/pigeon/outlook_accounts.db` , and the same directory for
encrypted account tokens and uploaded skins. It has no Redis, PostgreSQL, host
port, or Docker-socket dependency. The default profile is capped at `512m` memory and `0.50` CPU with one Gunicorn worker and four threads; the one-worker limit is required because scheduler and streaming state are process-local. Pigeon has no upstream `/healthz` ; its native and sidecar checks use the unauthenticated `/login` page. `PIGEON_SECRET_KEY` must remain stable for
encrypted data and sessions. `PIGEON_LOGIN_PASSWORD` initializes the database
only; after initialization, change the password with the upstream
`scripts/reset_login_password.py` maintenance command rather than by editing
the environment variable. Optional provider settings are root-only runtime
overrides and are not required for the base deployment. The manifest requires at least 32 characters for `PIGEON_SECRET_KEY` and 12 for the initial login password. Generate the encryption/session key with `openssl rand -hex 32` , and use a password-manager-generated login password.

Pigeon retains `worker-2` as its future target in `config/cluster/apps/pigeon.policy` , but `ENABLED=false` keeps it out of runtime placement. To opt in later, select the target with
`ops/configure-app-placement.sh pigeon <node-id>` , set `ENABLED=true` , regenerate
the Woodpecker workflows, run all validation, and deploy that reviewed
control-plane change before provisioning secrets. Disabled consumers retain a
publish/stop reconciliation chain but have no target stage. Singleton data
remains local: moving Pigeon does not copy it, and the previous target directory
is retained as a timestamped archive.

If a previous interactive paste stored an invalid control byte in the session
secret, replace it on the target follower and recreate only Aichorouter:

OpenObserve is a Leader foundation service at `observer.aichorage.de` . It runs
the official single-binary image in local disk mode with no Redis, PostgreSQL,
NATS, or object-storage dependency. Durable data is stored at
`/opt/platform/observer/data` on the Leader and retained for 30 days. The
default profile uses `512m` memory, `0.50` CPU, one query/HTTP worker, a
disabled in-memory cache, and inverted indexes disabled by default. The 8 GiB
data size is a monitored operational target, not a hard quota; inspect it with
`platformctl diagnose foundation` . Its SQLite metadata catalog is captured
through an online SQLite backup before each Restic snapshot.

Every VPS runs a read-only Docker socket proxy and a small Vector collector.
Only containers carrying `com.aichorage.platform=llm-hub-lite` are collected.
Every enrolled service also declares `com.aichorage.application` and
`com.aichorage.component` ; those values become top-level `application` and
`component` fields alongside `node_id` , container, image, and stream. Compose
workloads also expose normalized `compose_project` and `compose_service` fields. Health probes, socket proxies, Observer itself, and other noisy or recursive sidecars opt out with `com.aichorage.observer.ignore-logs=true` . Records are sent to `observer-ingest.<domain>` using a write-only OpenObserve ingestion token. The ingestion hostname must be DNS-only and resolve directly to the
Leader; the public UI hostname may be proxied through Cloudflare. Each node's
collector has a bounded 512 MiB disk buffer under `/opt/platform/observer/collector-buffer` ; it is transient and excluded from Restic. The default `OBSERVER_LOG_BUFFER_WHEN_FULL=block` applies backpressure instead of discarding new records when the buffer fills. Set it to
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
`OBSERVER_LOG_PROXY_STREAM_TIMEOUT=24h` ; Vector reconnects after that bounded
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
`OBSERVER_SMOKE_ATTEMPTS` , `OBSERVER_SMOKE_RETRY_DELAY` ,
`OBSERVER_SMOKE_REQUEST_TIMEOUT_SECONDS` , or `OBSERVER_SMOKE_TIMEOUT_SECONDS`

for a deliberately slower recovery check; all values are validated and capped.

In the OpenObserve UI, select organization `default` , open Logs, select the
`docker` stream, and use a time range covering at least the last 15 minutes.
The `node_id` , `application` , and `component` fields identify the source. A
healthy installation includes records where
`component = 'foundation-observer-heartbeat'` ; Woodpecker records use
`application = 'woodpecker'` , and Aichorouter records use
`application = 'aichorouter'` . The configured root account, including a custom
email such as `admin@qq.com` , has access to this same `default` organization.

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

The helper reads `CLUSTER_SECRET_KEYS` , `NODE_SECRET_KEYS` ,
`RUNTIME_ENV_FILE` , and `POLICY_FILE` from the manifest, so a future consumer
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
operator checkout. For example, to move Cursorapi to `worker-2` :

First run the manual `consumer-secrets-cursorapi-worker-2` workflow in
Woodpecker. It uses protected repository secrets and validates the target node
without an SSH session. Then commit the placement and generated workflow
changes:

```bash
ops/configure-app-placement.sh cursorapi worker-2
ops/generate-woodpecker-workflows.sh --check
git diff -- config/cluster/apps/cursorapi.policy .woodpecker/
git add config/cluster/apps/cursorapi.policy .woodpecker/
git commit -m 'move cursorapi to worker-2'
git push origin main
```

Wait for `consumer-stage-cursorapi-worker-2` ,
`consumer-publish-cursorapi` , and the generated stop job for each unselected
follower, followed by `consumer-finalize-cursorapi-worker-2` , in that order. The
finalizer retains the active service and closes its node-local transition journal
only after the route and stale-node steps succeed. The publish job snapshots the installed Leader route
and checks the manifest's expected health response at the origin and public
endpoint. If publication or the public smoke fails, it atomically restores the
old route, reloads Caddy, keeps the previous-target marker, and returns failure,
so Woodpecker does not stop the old target. A failed rollback reload leaves a
`*.route-backup.caddy` or `*.route-was-missing` file under
`/etc/llm-hub-lite/singleton-state` ; resolve and verify the Caddy route before
removing that artifact and retrying.

The placement helper regenerates image locks and workflows transactionally. If
generation fails, it restores the previous policy so committed `NODES` cannot
drift from stage/publish/stop targets. The same generated consumer contract handles active-active applications. It
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

## Woodpecker troubleshooting

Mutating workflows share the `llm-hub-lite-deployment` concurrency group. This
is intentional: every deployment can update release pointers and generated
Caddy configuration, so a consumer stage/publish/stop transition, foundation
upgrade, runner upgrade, or rollback must finish before another one starts. A
queued build is not stuck; wait for the earlier mutating workflow or cancel the
obsolete build and rerun the newest commit.

The `platform-submit` step streams the deployment runner log into the
Woodpecker step while it runs. The first useful line is the deployment metadata
record ( `node` , `role` , `mode` , commit SHA, workflow, pipeline, and build). A
scope rejection then lists every changed path, which makes a mixed commit easy
to correct. `.env.prod.example` and `.env.dev.example` are templates and may be
committed with application changes; they never overwrite a host's live
`/opt/apps/llm-hub-lite/shared/.env.prod` . Foundation files, runner code, and
foundation image manifests still require their reviewed manual workflows;
application image manifests use the affected generated consumer workflows.

When a pipeline fails, copy the complete failed step log, including the
`--- host deployment diagnostics ---` block printed at the end. For a consumer
failure, the block is limited to that app; for a foundation failure, it covers
the local foundation and active consumer projects. The diagnostics
include the current/previous release pointers, maintenance marker, Compose
state, container exit/OOM/restart counts, and recent healthcheck output. Do not
paste `/etc/llm-hub-lite/*.env` files or any secret values.

If a Woodpecker agent reports `agent could not auth: AgentID not found in
database `,  ` platformctl ` automatically moves that node's stale ` agent.conf` to
the matching `agent/orphaned/` or `deployer/orphaned/` directory and recreates
the agent with the installed digest-pinned image. The agent then registers a
new identity; application data and shared cluster secrets are untouched. This
repair also runs during `platformctl recreate` , so a database restore or
controller redeploy does not require manually deleting the agent state.

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
Production snapshots use an initialized local Restic repository by default and include runtime configuration, Caddy certificates, Woodpecker/Beszel SQLite online backups, PGlite state, release pointers, and application data without deleting live data. When `RESTIC_REMOTE_ENABLED=true` , the same snapshot is also written to the verified remote repository; set `PRODUCTION_REQUIRE_REMOTE_BACKUP=true` to fail closed when that off-host copy is unavailable. The scheduled timer wakes every 15 minutes for reboot recovery, but `reason=scheduled` snapshots are throttled to one per hour by `RESTIC_SCHEDULE_INTERVAL=3600` ; manual, pre-deployment, post-bootstrap, and recovery snapshots remain immediate. Restic uses a persistent mode-700 cache, one reader, portable `auto` compression, `--skip-if-unchanged` when supported, and low CPU/I/O priority ( `nice` / `ionice` ) to reduce contention with consumer services. Older Restic clients that cannot use a newer requested compression mode automatically fall back to `auto` ; clients without `--skip-if-unchanged` continue without that optional optimization. Override these `RESTIC_*` settings in the root-only `.env.prod` only after measuring the impact.

Nodes with very small disks may set `BACKUP_ENABLED=false` in their committed
node descriptor (worker-3 and worker-4 are the current examples). Their backup
timer and pre-deployment snapshots exit cleanly without invoking Restic; this
removes local recovery coverage for that node, so keep important data in the
app's remote provider or configure an off-host backup strategy separately.
If a bootstrap reports `invalid compression mode` , the installed Restic client is older than the configured mode. Copy the current `ops/bootstrap-vps.sh` to the host and rerun bootstrap; it normalizes the mode to a supported value and persists it in `.env.prod` . The error occurs before a snapshot is written, so do not delete or reinitialize the remote repository. Verify the repair with `platformctl backup snapshot manual` ; inspect remote snapshots with the configured Restic credentials or use `RESTORE_SOURCE=remote platformctl restore extract latest` when a restore test is appropriate.
Local-only snapshots are the default. Enable the explicit production backup gate when your recovery policy requires an off-host copy.

## Enabling Pigeon later

Pigeon is disabled by default. Enabling it is a reviewed control-plane change:

1. Create the selected Follower's DNS-only origin, run
`ops/configure-app-placement.sh pigeon <node-id>` , and set `ENABLED=true` in the app
   policy.
2. Run `ops/generate-woodpecker-workflows.sh generate`, repository validation,
   and pre-commit, then commit the policy and generated workflows together.
3. Push the control-plane commit and run the reviewed
`foundation-upgrade-leader` chain so every node installs the new workflows.
4. Run the generated manual `consumer-secrets-pigeon-<node-id>` workflow, then
   push a consumer-scoped commit or retry the Pigeon consumer chain for that
   release. Publication occurs only after target health succeeds. Use direct
`configure-app-secrets.sh pigeon` only as a repair fallback.

## Direct/orphan applications

An application may declare `INGRESS_MODE=direct` and a reviewed
`DIRECT_LISTENERS` value such as `udp:443:443`. The selected follower publishes
that listener itself and no Leader Caddy route is created; the protocol/port
must also appear in the cluster policy's `DIRECT_PORT_ALLOWLIST`. The
`platformctl direct-smoke` operation verifies the selected Compose service,
health state, and exact published host-port mapping. Direct-only manifests may
not declare proxy route groups. Hysteria `verge` is the first direct
application and defaults to `worker-4`; its Cloudflare record must remain
DNS-only because UDP/443 is served by the follower. Follower Caddy's optional
HTTP/3 listener is bound to loopback on the reviewed
`CADDY_HTTPS_UDP_FALLBACK_PORT` (8443 by default), so this behavior is shared by
future direct services rather than tied to a node name. Synchronization and
recovery reconcile this bind from the current node role, so moving a direct app
does not depend on rerunning bootstrap. A direct publication applies the host
firewall synchronously after its container smoke check; CI fails and queues the
systemd retry request if that firewall reconciliation cannot complete.
