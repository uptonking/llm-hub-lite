#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/relaichor1"

grep -q '^APP_ID=relaichor1$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=ephemeral$' "$app/manifest.env"
grep -q '^HEALTH_URL=/health$' "$app/manifest.env"
grep -q '^HEALTH_MODE=process$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/relaichor1.policy"
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/relaichor1.policy"
grep -q '^RELAICHOR1_MEMORY_LIMIT=256m$' "$app/config.env"
grep -q '^RELAICHOR1_CPUS=0.20$' "$app/config.env"
grep -q '^RELAICHOR1_MAX_BUFFER_FRAMES=64$' "$app/config.env"
grep -Fq 'read_only: true' "$app/compose.yml"
grep -Fq 'cap_drop: [ALL]' "$app/compose.yml"
grep -Fq 'reverse_proxy relaichor1:8411' "$app/route.follower.caddy"
grep -Fq 'health_uri /health' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$RELAICHOR1_UPSTREAM}' "$app/route.leader.caddy"
for node in leader worker-1 worker-2 worker-3 worker-4; do
	prefix="${node/-/}"
	grep -q "^NODE_RELAICHOR1_ORIGIN_HOST=${prefix}-relaichor1-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done
for workflow in \
	consumer-stage-relaichor1-worker-1.yml \
	consumer-publish-relaichor1.yml \
	consumer-finalize-relaichor1-worker-1.yml \
	consumer-stop-relaichor1-worker-2.yml \
	consumer-stop-relaichor1-worker-3.yml \
	consumer-stop-relaichor1-worker-4.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done
if find "$repo_root/.woodpecker" -maxdepth 1 -name 'consumer-stage-relaichor1-worker-*.yml' ! -name '*worker-1.yml' | grep -q .; then
	printf 'Relaichor1 generated a stage workflow outside its singleton target\n' >&2
	exit 1
fi
printf 'Relaichor1 application tests passed\n'
