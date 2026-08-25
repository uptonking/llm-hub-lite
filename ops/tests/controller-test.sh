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
for manifest in "$repo_root"/apps/*/manifest.env; do grep -q '^MANIFEST_VERSION=3$' "$manifest"; done
grep -q '^LEADER_NODE_ID=leader$' "$repo_root/config/cluster/policy.env"
grep -q '^REPO_SLUG=uptonking/llm-hub-lite$' "$repo_root/config/cluster/policy.env"
grep -q '^PLACEMENT=follower$' "$repo_root/apps/newapi/manifest.env"
grep -q '^APP_ID=cpapi$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^PLACEMENT=single-follower$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^APP_ID=librechat$' "$repo_root/apps/librechat/manifest.env"
grep -q '^PLACEMENT=follower$' "$repo_root/apps/librechat/manifest.env"
grep -q '^NETWORK_ALIAS=librechat-client$' "$repo_root/apps/librechat/manifest.env"
grep -q '^LIBRECHAT_CLIENT_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^ENABLED=false$' "$repo_root/config/cluster/apps/newapi.policy"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/cpapi.policy"
grep -q '^APP_ID=aichorouter$' "$repo_root/apps/aichorouter/manifest.env"
grep -q '^PLACEMENT=single-follower$' "$repo_root/apps/aichorouter/manifest.env"
grep -q '^APP_ID=observer$' "$repo_root/apps/observer/manifest.env"
grep -q '^PLACEMENT=single-follower$' "$repo_root/apps/observer/manifest.env"
grep -q '^OBSERVER_TARGET_NODE_ID=worker-1$' "$repo_root/config/cluster/apps/observer.policy"
grep -q '^AICHOROUTER_TARGET_NODE_ID=worker-1$' "$repo_root/config/cluster/apps/aichorouter.policy"
grep -q '^AICHOROUTER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^CPAPI_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^HEALTH_PROBE_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^OBSERVER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^OBSERVER_LOG_PROXY_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^OBSERVER_LOG_SHIPPER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -Fq 'SQLITE_PATH: /data/aichorouter.db' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'SQL_MAX_OPEN_CONNS: ${AICHOROUTER_SQL_MAX_OPEN_CONNS:-4}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'mem_limit: ${AICHOROUTER_MEMORY_LIMIT:-768m}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'cpus: ${AICHOROUTER_CPUS:-0.9}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'GOMEMLIMIT: ${AICHOROUTER_GOMEMLIMIT:-500MiB}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'ZO_LOCAL_MODE: "true"' "$repo_root/apps/observer/compose.yml"
grep -Fq 'ZO_DATA_DIR: /data' "$repo_root/apps/observer/compose.yml"
grep -Fq 'ZO_COMPACT_DATA_RETENTION_DAYS: ${OBSERVER_DATA_RETENTION_DAYS:-30}' "$repo_root/apps/observer/compose.yml"
grep -Fq 'mem_limit: ${OBSERVER_MEMORY_LIMIT:-512m}' "$repo_root/apps/observer/compose.yml"
grep -Fq 'cpus: ${OBSERVER_CPUS:-0.50}' "$repo_root/apps/observer/compose.yml"
grep -Fq 'pids_limit: ${OBSERVER_PIDS_LIMIT:-256}' "$repo_root/apps/observer/compose.yml"
grep -Fq 'observer-log-proxy:' "$repo_root/apps/observer/compose.yml"
grep -Fq 'observer-log-shipper:' "$repo_root/apps/observer/compose.yml"
grep -Fq 'VECTOR_CONFIG: /etc/vector/vector.toml' "$repo_root/apps/observer/compose.yml"
grep -Fq 'test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8686/health >/dev/null"]' "$repo_root/apps/observer/compose.yml"
grep -Fq 'health-probe:' "$repo_root/apps/observer/compose.yml"
grep -Fq 'curl -fsS http://observer:5080/healthz' "$repo_root/apps/observer/compose.yml"
grep -Fq 'ALLOW_LOGS: "1"' "$repo_root/apps/observer/compose.yml"
grep -Fq 'POST: "0"' "$repo_root/apps/observer/compose.yml"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock:ro' "$repo_root/apps/observer/compose.yml"
grep -Fq 'observer/log-buffer:/var/lib/vector' "$repo_root/apps/observer/compose.yml"
grep -Fq 'max_size = ${OBSERVER_LOG_BUFFER_MAX_BYTES}' "$repo_root/apps/observer/vector.toml"
grep -Fq 'com.aichorage.observer.ignore-logs: "true"' "$repo_root/apps/observer/compose.yml"
grep -Fq "condition = '.label." "$repo_root/apps/observer/vector.toml"
if grep -Fq 'exclude_containers' "$repo_root/apps/observer/vector.toml"; then
	printf 'observer Vector config must not depend on exact Compose container names\n' >&2
	exit 1
fi
grep -Fq '[api]' "$repo_root/apps/observer/vector.toml"
grep -Fq 'OBSERVER_LOG_BUFFER_MAX_BYTES' "$repo_root/apps/observer/manifest.env"
grep -Fq 'docker_host = "http://observer-log-proxy:2375"' "$repo_root/apps/observer/vector.toml"
grep -Fq 'uri = "http://observer:5080/api/${OBSERVER_LOG_ORGANIZATION}/${OBSERVER_LOG_STREAM}/_json"' "$repo_root/apps/observer/vector.toml"
grep -Fq 'EPHEMERAL_DATA_REL=log-buffer' "$repo_root/apps/observer/manifest.env"
grep -q '^HEALTH_EXPECT=Server up and running$' "$repo_root/apps/observer/manifest.env"
if grep -Eq 'ports:' "$repo_root/apps/observer/compose.yml"; then
	printf 'OpenObserve must not publish a host port\n' >&2
	exit 1
fi
if grep -Eiq 'postgres|redis|nats' "$repo_root/apps/observer/compose.yml"; then
	printf 'OpenObserve singleton must not define external dependencies\n' >&2
	exit 1
fi
grep -Fq 'CPAPI_MANAGEMENT_KEY' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'CPAPI_API_KEY' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'config-seed.sha256' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'test: ["CMD-SHELL", "test -s /runtime/config.yaml && kill -0 1"]' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'curl -fsS http://cpapi:8317/healthz' "$repo_root/apps/cpapi/compose.yml"
if grep -Fq 'test: ["CMD", "bash"' "$repo_root/apps/cpapi/compose.yml"; then
	printf 'CPAPI must not require Bash for its healthcheck\n' >&2
	exit 1
fi
grep -Fq 'mem_limit: ${CPAPI_MEMORY_LIMIT:-256m}' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'cpus: ${CPAPI_CPUS:-0.25}' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'pids_limit: ${CPAPI_PIDS_LIMIT:-128}' "$repo_root/apps/cpapi/compose.yml"
if grep -Eq 'ports:' "$repo_root/apps/cpapi/compose.yml"; then
	printf 'CPAPI must not publish a host port\n' >&2
	exit 1
fi
if grep -Eiq 'REDIS_CONN_STRING|SQL_DSN|postgres|redis' "$repo_root/apps/aichorouter/compose.yml"; then
	printf 'aichorouter must not define Redis or PostgreSQL\n' >&2
	exit 1
fi
if grep -Eq 'mongodb:|meilisearch:|vectordb:|rag_api:' "$repo_root/apps/librechat/compose.yml"; then exit 1; fi
grep -q 'LIBRECHAT_MONGO_URI' "$repo_root/apps/librechat/compose.yml"
grep -q 'LIBRECHAT_REDIS_URI' "$repo_root/apps/librechat/compose.yml"
grep -q '/librechat/images:/app/client/public/images' "$repo_root/apps/librechat/compose.yml"
grep -q '/librechat/uploads:/app/uploads' "$repo_root/apps/librechat/compose.yml"
grep -q '^SMOKE_LOCAL=healthcheck$' "$repo_root/apps/newapi/manifest.env"
grep -q '^SMOKE_LOCAL=healthcheck$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$repo_root/apps/aichorouter/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$repo_root/apps/aichorouter/manifest.env"
grep -q '^HEALTH_URL=/healthz$' "$repo_root/apps/observer/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$repo_root/apps/observer/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$repo_root/apps/observer/manifest.env"
grep -q '^HEALTH_URL=/healthz$' "$repo_root/apps/cpapi/manifest.env"
grep -Fq 'health_uri /healthz' "$repo_root/apps/cpapi/route.leader.caddy"
if grep -Fq '127.0.0.1:5080/healthz' "$repo_root/apps/observer/compose.yml"; then
	printf 'OpenObserve Compose must not use a curl-based internal healthcheck\n' >&2
	exit 1
fi
grep -Fq 'singleton-transition-fail' "$repo_root/ops/platformctl.sh"
grep -Fq 'transition_begin' "$repo_root/ops/platformctl.sh"
if grep -Fq 'depends_on:' "$repo_root/.woodpecker/singleton-stage-cpapi.yml"; then
	printf 'singleton stage must not depend on an unrelated cluster workflow\n' >&2
	exit 1
fi
grep -q '^NEW_API_NODE_TYPE=master$' "$repo_root/config/cluster/nodes/worker-1.env"
grep -q '^NEW_API_NODE_TYPE=slave$' "$repo_root/config/cluster/nodes/worker-2.env"
grep -q '^NEW_API_BACKUP_NODE_ID=worker-2$' "$repo_root/config/cluster/policy.env"
grep -q '^NEW_API_MIGRATION_NODE_ID=worker-1$' "$repo_root/config/cluster/policy.env"
grep -Fq 'cluster-reconcile' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-stage' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-switch' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-stop' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-prepare' "$repo_root/ops/platformctl.sh"
grep -Fq 'app_in_reconcile_scope' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_FORCE_SINGLETON_ACTION' "$repo_root/ops/platformctl.sh"
grep -Fq 'singleton-origin-smoke' "$repo_root/ops/platformctl.sh"
grep -Fq 'Leader route and active containers reconciled' "$repo_root/ops/platformctl.sh"
grep -Fq 'app_policy_enabled "$(basename "$d")"' "$repo_root/ops/platformctl.sh"
grep -Fq 'record_singleton_transitions' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton_prepare_failed' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-origin-smoke' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'cluster app policy requires its dedicated reconciliation workflow' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'unsupported cluster configuration path in application deployment' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'application image manifest changes require the app-upgrade or singleton workflow' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-state' "$repo_root/ops/backup-platform.sh"
if grep -Fq 'rm -f -- "$runtime_env"' "$repo_root/ops/platformctl.sh"; then
	printf 'singleton stop must retain runtime secrets\n' >&2
	exit 1
fi
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
if find "$repo_root/apps/cliproxyapi" "$repo_root/config/cluster/apps/cliproxyapi.policy" -type f -print -quit 2>/dev/null | grep -q .; then
	exit 1
fi
if rg -n 'CLIPROXY|cliproxy|cpa\.aichorage\.de' "$repo_root" --hidden --glob '!.git/**' --glob '!ops/tests/**' --glob '!ops/images.apps.prod.env' >/dev/null 2>&1; then
	printf 'legacy CPA references remain in the repository\n' >&2
	exit 1
fi
printf 'controller topology tests passed\n'
