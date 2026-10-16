#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/outline"

grep -q '^APP_ID=outline$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=files$' "$app/manifest.env"
grep -q '^HEALTH_URL=/_health$' "$app/manifest.env"
grep -q '^HEALTH_PORT=3000$' "$app/manifest.env"
grep -q '^HEALTH_EXPECT=OK$' "$app/manifest.env"
grep -q '^RECOVERY_REQUIRED_PATHS=postgres/pgdata/PG_VERSION$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/outline.policy"
grep -q '^NODES=worker-4$' "$repo_root/config/cluster/apps/outline.policy"

# Verify Compose limits, services, and constraints
grep -Fq 'user: "0:0"' "$app/compose.yml"
grep -Fq -- '- ./build/server/index.js' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${OUTLINE_MEMORY_LIMIT:-768m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${OUTLINE_CPUS:-0.75}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${OUTLINE_PIDS_LIMIT:-256}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${OUTLINE_POSTGRES_MEMORY_LIMIT:-192m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${OUTLINE_REDIS_MEMORY_LIMIT:-64m}' "$app/compose.yml"

# Verify Outline storage, database and authentication config
grep -Fq 'FILE_STORAGE: local' "$app/compose.yml"
grep -Fq 'FILE_STORAGE_LOCAL_ROOT_DIR: /var/lib/outline/data' "$app/compose.yml"
grep -Fq '/outline/data:/var/lib/outline/data' "$app/compose.yml"
grep -Fq '/outline/postgres:/var/lib/postgresql/data' "$app/compose.yml"
grep -Fq 'WEB_CONCURRENCY: 1' "$app/compose.yml"
grep -Fq 'OIDC_CLIENT_ID: outline' "$app/compose.yml"
grep -Fq 'OIDC_AUTH_URI: https://auther.aichorage.de/api/oidc/authorization' "$app/compose.yml"
grep -Fq 'OIDC_TOKEN_URI: https://auther.aichorage.de/api/oidc/token' "$app/compose.yml"
grep -Fq 'OIDC_USERINFO_URI: https://auther.aichorage.de/api/oidc/userinfo' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy outline:3000' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /_health' "$app/route.leader.caddy"
grep -Fq 'flush_interval -1' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$OUTLINE_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
	prefix="${node/-/}"
	grep -q "^NODE_OUTLINE_ORIGIN_HOST=${prefix}-outline-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify Auther OIDC client registration
grep -Fq 'client_id: outline' "$repo_root/apps/auther/clients.yml"
grep -Fq 'https://outline.aichorage.de/auth/oidc.callback' "$repo_root/apps/auther/clients.yml"
grep -Fq 'AUTHER_OIDC_OUTLINE_CLIENT_SECRET' "$repo_root/apps/auther/manifest.env"
grep -Fq 'AUTHER_OIDC_OUTLINE_CLIENT_SECRET' "$repo_root/apps/auther/compose.yml"

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-outline-worker-4.yml \
	consumer-publish-outline.yml \
	consumer-finalize-outline-worker-4.yml \
	consumer-secrets-outline-worker-4.yml \
	consumer-stop-outline-worker-1.yml \
	consumer-stop-outline-worker-2.yml \
	consumer-stop-outline-worker-3.yml \
	consumer-stop-outline-worker-5.yml \
	consumer-stop-outline-worker-6.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'Outline application tests passed\n'
