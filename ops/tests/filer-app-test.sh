#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/filer"

grep -q '^APP_ID=filer$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=sqlite$' "$app/manifest.env"
grep -q '^HEALTH_URL=/health$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/filer.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/filer.policy"

# Verify Compose limits and constraints
grep -Fq 'user: "0:0"' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${FILER_MEMORY_LIMIT:-256m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${FILER_CPUS:-0.5}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${FILER_PIDS_LIMIT:-128}' "$app/compose.yml"
[[ -x "$app/entrypoint.sh" ]]

# Verify storage mounts
grep -Fq '/srv/shared' "$app/compose.yml"
grep -Fq '/srv/personal' "$app/compose.yml"
grep -Fq 'data/database.sqlite' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy filer:80' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /health' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$FILER_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5; do
	prefix="${node/-/}"
	grep -q "^NODE_FILER_ORIGIN_HOST=${prefix}-filer-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-filer-worker-2.yml \
	consumer-publish-filer.yml \
	consumer-finalize-filer-worker-2.yml \
	consumer-secrets-filer-worker-2.yml \
	consumer-stop-filer-worker-1.yml \
	consumer-stop-filer-worker-3.yml \
	consumer-stop-filer-worker-4.yml \
	consumer-stop-filer-worker-5.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'Filer application tests passed\n'
