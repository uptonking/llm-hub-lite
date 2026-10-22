#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/mailer"

grep -q '^APP_ID=mailer$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^INGRESS_MODE=direct-and-proxy$' "$app/manifest.env"
grep -q '^STATE_MODE=files$' "$app/manifest.env"
grep -q '^HEALTH_URL=/healthz/live$' "$app/manifest.env"
grep -q '^HEALTH_PORT=8080$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/mailer.policy"
grep -q '^NODES=worker-3$' "$repo_root/config/cluster/apps/mailer.policy"

# Verify direct listeners
grep -q '^DIRECT_LISTENERS=tcp:25:25,tcp:465:465,tcp:587:587,tcp:993:993,tcp:4190:4190$' "$app/manifest.env"

# Verify Compose limits and constraints
grep -Fq 'user: "0:0"' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${MAILER_MEMORY_LIMIT:-512m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${MAILER_CPUS:-1.0}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${MAILER_PIDS_LIMIT:-256}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq '${CADDY_CERTIFICATES_ROOT:-/opt/platform/caddy/data/caddy/certificates}:/etc/caddy-certificates:ro' "$app/compose.yml"
[[ -x "$app/entrypoint.sh" ]]
grep -Fq 'sync_certs' "$app/entrypoint.sh"
grep -Fq 'x:Domain/set' "$app/entrypoint.sh"
grep -Fq 'x:Certificate/set' "$app/entrypoint.sh"
grep -Fq 'x:NetworkListener/set' "$app/entrypoint.sh"

# Verify RocksDB template
grep -Fq '"@type": "RocksDb"' "$app/config.json.tmpl"
grep -Fq '"path": "/var/lib/stalwart/data"' "$app/config.json.tmpl"

# Verify published ports
grep -Fq '"25:25/tcp"' "$app/compose.yml"
grep -Fq '"465:465/tcp"' "$app/compose.yml"
grep -Fq '"587:587/tcp"' "$app/compose.yml"
grep -Fq '"993:993/tcp"' "$app/compose.yml"
grep -Fq '"4190:4190/tcp"' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy mailer:8080' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /healthz/live' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$MAILER_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5; do
	prefix="${node/-/}"
	grep -q "^NODE_MAILER_ORIGIN_HOST=${prefix}-mail-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-mailer-worker-3.yml \
	consumer-publish-mailer.yml \
	consumer-finalize-mailer-worker-3.yml \
	consumer-secrets-mailer-worker-3.yml \
	consumer-stop-mailer-worker-1.yml \
	consumer-stop-mailer-worker-2.yml \
	consumer-stop-mailer-worker-4.yml \
	consumer-stop-mailer-worker-5.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'Mailer application tests passed\n'
