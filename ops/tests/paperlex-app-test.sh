#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/paperlex"

grep -q '^APP_ID=paperlex$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=files$' "$app/manifest.env"
grep -q '^HEALTH_URL=/accounts/login/$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/paperlex.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/paperlex.policy"

# Verify Compose limits and constraints
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${PAPERLEX_MEMORY_LIMIT:-1280m}' "$app/compose.yml"
grep -Fq 'PAPERLESS_DBENGINE: sqlite' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'PAPERLESS_DB_TIMEOUT: ${PAPERLEX_DB_TIMEOUT:-60}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'PAPERLESS_OCR_MODE: ${PAPERLEX_OCR_MODE:-auto}' "$app/compose.yml"
[[ -x "$app/init-superuser.sh" ]]
grep -Fq 'init-superuser.sh:/custom-cont-init.d/01-ensure-superuser.sh:ro' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy paperlex:8000' "$app/route.follower.caddy"
grep -Fq 'health_uri /accounts/login/' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$PAPERLEX_UPSTREAM}' "$app/route.leader.caddy"

for node in leader worker-1 worker-2 worker-3 worker-4 worker-5; do
	prefix="${node/-/}"
	grep -q "^NODE_PAPERLEX_ORIGIN_HOST=${prefix}-paperlex-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

for workflow in \
	consumer-stage-paperlex-worker-2.yml \
	consumer-publish-paperlex.yml \
	consumer-finalize-paperlex-worker-2.yml \
	consumer-stop-paperlex-worker-1.yml \
	consumer-stop-paperlex-worker-3.yml \
	consumer-stop-paperlex-worker-4.yml \
	consumer-stop-paperlex-worker-5.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'Paperlex application tests passed\n'
