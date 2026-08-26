Node descriptor files are public topology metadata. Secrets and numeric public
addresses belong in root-only runtime files under `/etc/llm-hub-lite`, never in
this directory.

Each node must define `NODE_ID` and the origin host keys declared by the active
app manifests. The Leader uses those origin fields from every Follower
descriptor to render Caddy routes. LibreChat and legacy New API use
active-active health-checked upstreams. Aichorouter and CPAPI are singleton
services: each target is stored in its app policy, and only that Follower is
deployed. Their local state is intentionally not replicated. OpenObserve is a
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
