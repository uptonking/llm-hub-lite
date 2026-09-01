Node descriptor files are public topology metadata. Secrets and numeric public
addresses belong in root-only runtime files under `/etc/llm-hub-lite`, never in
this directory.

Each node must define `NODE_ID` and the origin host keys declared by the active
app manifests. The Leader uses those origin fields from every Follower
descriptor to render Caddy routes. LibreChat and legacy New API use
active-active health-checked upstreams. Aichorouter, CPAPI, Cursor API Proxy,
and Wapdf are enabled singleton services: each target is stored in its app policy,
and only that Follower is deployed. Pigeon retains a `worker-2` target but is disabled by
policy, so it has no runtime placement or workflow. Flowy (Activepieces) is an
enabled PGlite-backed singleton on the active `worker-3` by default. Singleton
local state is intentionally not replicated; its default DB file storage is
local, while R2 can be enabled explicitly for durable object storage. Wabase
(Grist) is enabled on active `worker-4`. That node has `BACKUP_ENABLED=false`,
so its Restic timers remain disabled. OpenObserve is a
Leader foundation service. Every node runs its read-only Docker socket proxy
and Vector shipper; each shipper forwards platform-labelled container logs to
the Leader's `observer-ingest` endpoint and keeps a bounded transient buffer
under `/opt/platform/observer/collector-buffer`. The buffer is excluded from
Restic. Keep origin names DNS-only and resolve them to the corresponding
Follower public IP; `observer-ingest` must resolve directly to the Leader.

`LEADER_NODE_ID` in `../policy.env` is the only role selector. A node whose
stable ID equals it is the Leader; every other node is a Follower. Do not add
`NODE_ROLE` to descriptors. Stable IDs must remain unchanged when public IPs
change. Bootstrap stores the private `LEADER_PUBLIC_IP` value in each node's
`/etc/llm-hub-lite/node.env`; Follower firewall reconciliation reads only that
runtime value.

Beszel agents keep `BESZEL_HUB_URL` set to the public status hostname so TLS
hostname verification and the public Caddy route remain unchanged. The agent
Compose project resolves that hostname locally to the private runtime
`LEADER_PUBLIC_IP` value. This avoids Cloudflare/IPv6 address selection when a
system is enrolled, so Beszel records the Leader's operational IPv4 address in
the system host field. Existing records should be updated through the Beszel
API after this routing change; do not delete and re-enroll systems because that
would discard their historical identity and monitoring data.

Create a Follower with
`DOMAIN_NAME=<base-domain> ops/configure-cluster-node.sh add <node-id>`. The
helper derives origin keys from each manifest's `PUBLIC_ENDPOINTS` and
`ROUTE_GROUPS`, applies manifest `NODE_DEFAULTS`, appends `NODE_IDS`, and
regenerates Woodpecker workflows. New nodes always start as `joining`, which
allows one-time foundation bootstrap but makes them ineligible for consumers.
After foundation health is verified, use
`ops/configure-cluster-node.sh state <node-id> active` and commit the generated
diff. Draining requires all app policies to be evacuated first; retirement is
allowed only from `draining`. Run the generated retirement workflow before
decommissioning the physical VPS.

Origin records in a Follower descriptor are DNS names, not physical identity.
They may be repointed when a VPS IP changes. Stop the old host before
bootstrapping its replacement with the same `NODE_ID`, so duplicate
Woodpecker/Beszel agents cannot run concurrently.

`NEW_API_NODE_TYPE` is deliberately node-local and is read only from this
descriptor, never from the shared `.env`. The policy's
`NEW_API_MIGRATION_NODE_ID` must point to exactly one follower whose descriptor
sets `NEW_API_NODE_TYPE=master`; all other followers use `slave` and skip
startup schema migrations. The pinned external image does not provide a
cross-process migration lock, so upgrade the migration node first and wait for
health before upgrading another replica. All replicas must use the same Neon
DSN, `SESSION_SECRET`, and `CRYPTO_SECRET`.

`NEW_API_BACKUP_NODE_ID` in `../policy.env` designates the one node that runs
the scheduled Neon `pg_dump`. Change it together with any manual Leader
promotion or backup ownership move.
