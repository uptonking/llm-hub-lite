#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/collabora"

grep -q '^APP_ID=collabora$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=ephemeral$' "$app/manifest.env"
grep -q '^HEALTH_URL=/hosting/discovery$' "$app/manifest.env"
grep -q '^HEALTH_EXPECT=wopi-discovery$' "$app/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/collabora.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/collabora.policy"

# Verify Compose limits, capabilities, and options
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${COLLABORA_MEMORY_LIMIT:-1280m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${COLLABORA_CPUS:-1.0}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${COLLABORA_PIDS_LIMIT:-256}' "$app/compose.yml"
grep -Fq 'cap_add:' "$app/compose.yml"
grep -Fq -- '- SYS_ADMIN' "$app/compose.yml"
grep -Fq 'server_name: collabora.aichorage.de' "$app/compose.yml"
grep -Fq 'aliasgroup1: https://openclouds.aichorage.de,https://openclouds.aichorage.de:443' "$app/compose.yml"
grep -Fq 'content_security_policy: "frame-ancestors' "$app/compose.yml"
grep -Fq -e '--o:net.lok_allow.host[7]=openclouds.aichorage.de:443' "$app/compose.yml"
if grep -Fq -e '--o:net.frame_ancestors' "$app/compose.yml"; then exit 1; fi
grep -Fq -e '--o:ai.enabled=true' "$app/compose.yml"
grep -Fq -e '--o:ai.allow_user_settings=true' "$app/compose.yml"
# coolwsd does not implement ai.allowed_hosts, so the option must not come back:
# it would imply a host restriction that is never enforced. The egress profile is
# the control that keeps a user-chosen endpoint away from internal destinations.
if grep -Fq -e '--o:ai.allowed_hosts' "$app/compose.yml"; then
	printf 'collabora compose declares ai.allowed_hosts, which coolwsd does not implement\n' >&2
	exit 1
fi
grep -Fq -e '--o:zotero.enable=false' "$app/compose.yml"
grep -q '^EGRESS_PROFILE=llm-client$' "$repo_root/config/cluster/apps/collabora.policy"
grep -Fq -e '--o:per_document.max_concurrency=2' "$app/compose.yml"
grep -Fq -e '--o:per_document.idle_timeout_secs=1800' "$app/compose.yml"
grep -Fq -e '--o:languagetool.enabled=false' "$app/compose.yml"
grep -Fq -e '--o:deepl.enabled=false' "$app/compose.yml"
grep -Fq -e '--o:grammalecte.enabled=false' "$app/compose.yml"
grep -Fq -e '--o:duden.enabled=false' "$app/compose.yml"
grep -Fq -e '--o:num_prespawn_children=1' "$app/compose.yml"
grep -Fq 'test: ["CMD", "/usr/bin/coolwsd", "--probe", "--use-env-vars"]' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy collabora:9980' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'health_uri /hosting/discovery' "$app/route.leader.caddy"
# The embedded admin console is never published through the public edge.
grep -Fq '@admin_console path /browser/dist/admin* /cool/adminws*' "$app/route.leader.caddy"
grep -Fq 'respond @admin_console 403' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$COLLABORA_UPSTREAM}' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
	prefix="${node/-/}"
	grep -q "^NODE_COLLABORA_ORIGIN_HOST=${prefix}-collabora-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-collabora-worker-2.yml \
	consumer-publish-collabora.yml \
	consumer-finalize-collabora-worker-2.yml \
	consumer-secrets-collabora-worker-2.yml \
	consumer-stop-collabora-worker-1.yml \
	consumer-stop-collabora-worker-3.yml \
	consumer-stop-collabora-worker-4.yml \
	consumer-stop-collabora-worker-5.yml \
	consumer-stop-collabora-worker-6.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

printf 'Collabora application tests passed\n'
