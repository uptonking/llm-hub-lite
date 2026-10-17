#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/openclouds"

grep -q '^APP_ID=openclouds$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=files$' "$app/manifest.env"
grep -q '^HEALTH_URL=/status.php$' "$app/manifest.env"
grep -q '^HEALTH_EXPECT=OpenCloud$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/openclouds.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/openclouds.policy"

# Verify Compose limits and constraints
grep -Fq 'user: "0:0"' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${OPENCLOUDS_MEMORY_LIMIT:-768m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${OPENCLOUDS_CPUS:-0.75}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${OPENCLOUDS_PIDS_LIMIT:-256}' "$app/compose.yml"
[[ -x "$app/entrypoint.sh" ]]

# Verify storage mounts
grep -Fq '/etc/opencloud' "$app/compose.yml"
grep -Fq '/var/lib/opencloud' "$app/compose.yml"

# Verify PosixFS and OIDC settings
grep -Fq 'STORAGE_USERS_DRIVER: "posix"' "$app/compose.yml"
grep -Fq 'OC_OIDC_ISSUER: "https://auther.aichorage.de"' "$app/compose.yml"
grep -Fq 'WEB_OIDC_SCOPE: "openid profile email groups"' "$app/compose.yml"
grep -Fq 'OC_EXCLUDE_RUN_SERVICES: "idp,search,activitylog,userlog,thumbnails,ocm"' "$app/compose.yml"
grep -Fq 'OC_ADD_RUN_SERVICES: "collaboration"' "$app/compose.yml"
grep -Fq 'COLLABORATION_APP_NAME: "CollaboraOnline"' "$app/compose.yml"
grep -Fq 'COLLABORATION_APP_PROOF_DISABLE: "true"' "$app/compose.yml"
grep -Fq 'https://collabora.aichorage.de/' "$app/csp.yaml"
grep -Fq 'FRONTEND_CHECK_FOR_UPDATES: "false"' "$app/compose.yml"

# Verify Auther OIDC client and CORS registration
grep -Fq 'client_id: openclouds' "$repo_root/apps/auther/clients.yml"
grep -Fq 'https://openclouds.aichorage.de/oidc-callback.html' "$repo_root/apps/auther/clients.yml"
grep -Fq 'allowed_origins_from_client_redirect_uris: true' "$repo_root/apps/auther/clients.yml"
grep -Fq 'https://openclouds.aichorage.de' "$repo_root/apps/auther/clients.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy openclouds:9200' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /status.php' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$OPENCLOUDS_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
	prefix="${node/-/}"
	grep -q "^NODE_OPENCLOUDS_ORIGIN_HOST=${prefix}-openclouds-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-openclouds-worker-2.yml \
	consumer-publish-openclouds.yml \
	consumer-finalize-openclouds-worker-2.yml \
	consumer-secrets-openclouds-worker-2.yml \
	consumer-stop-openclouds-worker-1.yml \
	consumer-stop-openclouds-worker-3.yml \
	consumer-stop-openclouds-worker-4.yml \
	consumer-stop-openclouds-worker-5.yml \
	consumer-stop-openclouds-worker-6.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'OpenClouds application tests passed\n'
