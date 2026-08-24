#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns intentionally match literal '$var' text
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ ! -e "$repo_root/compose/foundation/woodpecker.yml" && ! -e "$repo_root/compose/foundation/beszel.yml" ]]
grep -Fq '${WOODPECKER_DATA_ROOT:-/opt/platform/woodpecker/data}:/var/lib/woodpecker' "$repo_root/compose/foundation/woodpecker-controller.yml"
if grep -Fq '${WOODPECKER_DATA_ROOT:-/opt/platform/woodpecker}/data:/var/lib/woodpecker' "$repo_root/compose/foundation/woodpecker-controller.yml"; then
	printf 'Woodpecker controller still appends a duplicate data directory\n' >&2
	exit 1
fi
grep -Fq '${BESZEL_DATA_ROOT:-/opt/platform/beszel/hub}:/beszel_data' "$repo_root/compose/foundation/beszel-controller.yml"
grep -Fq '${BESZEL_AGENT_DATA_ROOT:-/opt/platform/beszel/agent}:/var/lib/beszel-agent' "$repo_root/compose/foundation/beszel-worker.yml"
grep -Fq '${WOODPECKER_AGENT_CONFIG_ROOT:-/opt/platform/woodpecker/agent}:/etc/woodpecker' "$repo_root/compose/foundation/woodpecker-worker.yml"
grep -Fq '${WOODPECKER_DEPLOYER_CONFIG_ROOT:-/opt/platform/woodpecker/deployer}:/etc/woodpecker' "$repo_root/compose/foundation/woodpecker-deployer.yml"
for woodpecker_compose in "$repo_root"/compose/foundation/woodpecker-*.yml; do
	awk '
		/^  woodpecker_private:$/ { in_network=1; next }
		in_network && /^    external: true$/ { found=1 }
		in_network && /^  [a-zA-Z0-9_-]+:$/ { in_network=0 }
		END { exit found ? 0 : 1 }
	' "$woodpecker_compose" || {
		printf 'Woodpecker Compose file does not treat the shared private network as external: %s\n' "$woodpecker_compose" >&2
		exit 1
	}
done
for node in leader worker-1 worker-2; do grep -q "^NODE_ID=$node$" "$repo_root/config/cluster/nodes/$node.env"; done
if grep -R -q '^NODE_PUBLIC_IP=' "$repo_root/config/cluster/nodes"; then
	printf 'committed node inventory contains a public IP field\n' >&2
	exit 1
fi
if grep -E -q '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "$repo_root/README.md" "$repo_root/config/cluster/nodes"/*.env; then
	printf 'public documentation or node inventory contains an IPv4 literal\n' >&2
	exit 1
fi
grep -q '^FOUNDATION_LEADER=' "$repo_root/config/cluster/policy.env"
grep -q '^LEADER_NODE_ID=leader$' "$repo_root/config/cluster/policy.env"
grep -q '^REPO_SLUG=uptonking/llm-hub-lite$' "$repo_root/config/cluster/policy.env"
grep -q '^PLACEMENT=follower$' "$repo_root/apps/newapi/manifest.env"
grep -q '^PLACEMENT=follower$' "$repo_root/apps/cliproxyapi/manifest.env"
grep -q '^APP_ID=librechat$' "$repo_root/apps/librechat/manifest.env"
grep -q '^PLACEMENT=follower$' "$repo_root/apps/librechat/manifest.env"
grep -q '^NETWORK_ALIAS=librechat-client$' "$repo_root/apps/librechat/manifest.env"
grep -q '^LIBRECHAT_CLIENT_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^DISABLED_APPS=newapi,cliproxyapi$' "$repo_root/config/cluster/policy.env"
if grep -Eq 'mongodb:|meilisearch:|vectordb:|rag_api:' "$repo_root/apps/librechat/compose.yml"; then exit 1; fi
grep -q 'LIBRECHAT_MONGO_URI' "$repo_root/apps/librechat/compose.yml"
grep -q 'LIBRECHAT_REDIS_URI' "$repo_root/apps/librechat/compose.yml"
grep -q '/librechat/images:/app/client/public/images' "$repo_root/apps/librechat/compose.yml"
grep -q '/librechat/uploads:/app/uploads' "$repo_root/apps/librechat/compose.yml"
grep -q '^SMOKE_LOCAL=healthcheck$' "$repo_root/apps/newapi/manifest.env"
grep -q '^SMOKE_LOCAL=healthcheck$' "$repo_root/apps/cliproxyapi/manifest.env"
grep -q '^NEW_API_NODE_TYPE=master$' "$repo_root/config/cluster/nodes/worker-1.env"
grep -q '^NEW_API_NODE_TYPE=slave$' "$repo_root/config/cluster/nodes/worker-2.env"
grep -q '^NEW_API_BACKUP_NODE_ID=worker-2$' "$repo_root/config/cluster/policy.env"
grep -q '^CLIPROXY_PRIMARY_NODE_ID=worker-1$' "$repo_root/config/cluster/policy.env"
grep -q '^NEW_API_MIGRATION_NODE_ID=worker-1$' "$repo_root/config/cluster/policy.env"
grep -Fq 'cluster-reconcile' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'firewall-reconcile.request' "$repo_root/ops/platform-submit.sh"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$repo_root/.woodpecker/deploy-smoke.yml"
grep -Fq '/run/lock/llm-hub-lite:/run/lock/llm-hub-lite' "$repo_root/.woodpecker/deploy-smoke.yml"
for compose_file in "$repo_root"/compose/foundation/*.yml; do
	grep -Fq 'mem_limit:' "$compose_file"
	grep -Fq 'cpus:' "$compose_file"
	grep -Fq 'pids_limit:' "$compose_file"
done
grep -Fq 'LIBRECHAT_AWS_ACCESS_KEY_ID' "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'PathExists=/etc/llm-hub-lite/firewall-reconcile.request' "$repo_root/ops/systemd/platform-firewall.path"
grep -Fq 'deployment failed; restoring previous complete bundle' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_SYNC_SCOPE=all reconcile || true' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'git-auth.sh:/usr/local/bin/git-auth.sh:ro' "$repo_root/ops/platform-submit.sh"
grep -Fq 'RESTORE_IDENTITY' "$repo_root/ops/restore-platform.sh"
recover_body="$(sed -n '/^recover() {/,/^}/p' "$repo_root/ops/platformctl.sh")"
foundation_line="$(printf '%s\n' "$recover_body" | grep -n 'projects_foundation' | head -n1 | cut -d: -f1)"
consumer_line="$(printf '%s\n' "$recover_body" | grep -n 'projects_apps' | head -n1 | cut -d: -f1)"
[[ -n "$foundation_line" && -n "$consumer_line" && "$foundation_line" -lt "$consumer_line" ]]
if grep -q 'NEW_API_SITE' "$repo_root/apps/newapi/route.follower.caddy"; then
	exit 1
fi
if grep -q 'CLIPROXY_SITE' "$repo_root/apps/cliproxyapi/route.follower.caddy"; then
	exit 1
fi
printf 'controller topology tests passed\n'
