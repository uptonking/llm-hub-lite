#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/onoffice"

grep -q '^APP_ID=onoffice$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=files$' "$app/manifest.env"
grep -q '^DATA_ROOT_REL=onoffice$' "$app/manifest.env"
grep -q '^HEALTH_URL=/healthcheck$' "$app/manifest.env"
grep -q '^HEALTH_EXPECT=true$' "$app/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/onoffice.policy"
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/onoffice.policy"

# Verify Compose limits, volumes, and options
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${ONOFFICE_MEMORY_LIMIT:-2048m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${ONOFFICE_CPUS:-1.5}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${ONOFFICE_PIDS_LIMIT:-512}' "$app/compose.yml"
grep -Fq 'WOPI_ENABLED: "true"' "$app/compose.yml"
grep -Fq 'GENERATE_FONTS: "true"' "$app/compose.yml"
grep -Fq 'EXAMPLE_ENABLED: "true"' "$app/compose.yml"
grep -Fq 'ADMINPANEL_ENABLED: "true"' "$app/compose.yml"
grep -Fq '/var/www/onlyoffice/Data' "$app/compose.yml"
grep -Fq '/var/lib/onlyoffice' "$app/compose.yml"
grep -Fq '/var/lib/postgresql' "$app/compose.yml"
grep -Fq '/var/lib/rabbitmq' "$app/compose.yml"
grep -Fq '/var/lib/redis' "$app/compose.yml"
grep -Fq 'test: ["CMD-SHELL", "curl -fsS --max-time 5 http://127.0.0.1:80/healthcheck | grep -Fq '\''true'\''"]' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy onoffice:80' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /healthcheck' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$ONOFFICE_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
	prefix="${node/-/}"
	grep -q "^NODE_ONOFFICE_ORIGIN_HOST=${prefix}-onoffice-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-onoffice-worker-1.yml \
	consumer-publish-onoffice.yml \
	consumer-finalize-onoffice-worker-1.yml \
	consumer-secrets-onoffice-worker-1.yml \
	consumer-stop-onoffice-worker-2.yml \
	consumer-stop-onoffice-worker-3.yml \
	consumer-stop-onoffice-worker-4.yml \
	consumer-stop-onoffice-worker-5.yml \
	consumer-stop-onoffice-worker-6.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'OnOffice application tests passed\n'
