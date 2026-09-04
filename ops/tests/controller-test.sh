#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns intentionally match literal '$var' text
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/ops/tests/run-all.sh"
bash -n "$runner"
grep -Fq 'TEST_PARALLELISM must be an integer between 1 and 16' "$runner"
if TEST_PARALLELISM=0 bash "$runner" fast >/dev/null 2>&1; then
	printf 'test runner accepted invalid parallelism\n' >&2
	exit 1
fi
[[ ! -e "$repo_root/compose/foundation/woodpecker.yml" && ! -e "$repo_root/compose/foundation/beszel.yml" ]]
grep -Fq '${WOODPECKER_DATA_ROOT:-/opt/platform/woodpecker/data}:/var/lib/woodpecker' "$repo_root/compose/foundation/woodpecker-controller.yml"
if grep -Fq '${WOODPECKER_DATA_ROOT:-/opt/platform/woodpecker}/data:/var/lib/woodpecker' "$repo_root/compose/foundation/woodpecker-controller.yml"; then
	printf 'Woodpecker controller still appends a duplicate data directory\n' >&2
	exit 1
fi
grep -Fq '${BESZEL_DATA_ROOT:-/opt/platform/beszel/hub}:/beszel_data' "$repo_root/compose/foundation/beszel-controller.yml"
grep -Fq '${BESZEL_AGENT_DATA_ROOT:-/opt/platform/beszel/agent}:/var/lib/beszel-agent' "$repo_root/compose/foundation/beszel-worker.yml"
grep -Fq 'status.${DOMAIN_NAME:-aichorage.de}:${LEADER_PUBLIC_IP:-127.0.0.1}' "$repo_root/compose/foundation/beszel-worker.yml"
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
for node in leader worker-1 worker-2 worker-3 worker-4; do grep -q "^NODE_ID=$node$" "$repo_root/config/cluster/nodes/$node.env"; done
if grep -R -q '^NODE_PUBLIC_IP=' "$repo_root/config/cluster/nodes"; then
	printf 'committed node inventory contains a public IP field\n' >&2
	exit 1
fi
if grep -E -q '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "$repo_root/README.md" "$repo_root/config/cluster/nodes"/*.env; then
	printf 'public documentation or node inventory contains an IPv4 literal\n' >&2
	exit 1
fi
grep -q '^CLUSTER_CONFIG_VERSION=3$' "$repo_root/config/cluster/policy.env"
if grep -q '^FOUNDATION_' "$repo_root/config/cluster/policy.env"; then
	printf 'global cluster policy still owns foundation component placement\n' >&2
	exit 1
fi
for manifest in "$repo_root"/apps/*/manifest.env; do
	grep -q '^MANIFEST_VERSION=5$' "$manifest"
	grep -q '^PLACEMENT=consumer$' "$manifest"
	grep -q '^PUBLIC_ENDPOINTS=' "$manifest"
	if grep -Eq '^(PUBLIC_URL_KEY|PUBLIC_HOST|SECRET_KEYS)=' "$manifest"; then
		printf 'application manifest uses a retired manifest field: %s\n' "$manifest" >&2
		exit 1
	fi
	app="$(basename "$(dirname "$manifest")")"
	[[ -f "$repo_root/apps/$app/images.lock.env" ]]
done
grep -Fq 'valid_mongo_uri()' "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'valid_mongo_uri()' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'write_secrets "$conditional_keys" "$runtime_file"' "$repo_root/ops/configure-app-secrets.sh"
grep -q '^LEADER_NODE_ID=leader$' "$repo_root/config/cluster/policy.env"
grep -q '^NODE_IDS=leader,worker-1,worker-2,worker-3,worker-4$' "$repo_root/config/cluster/policy.env"
grep -q '^REPO_SLUG=uptonking/llm-hub-lite$' "$repo_root/config/cluster/policy.env"
grep -q '^APP_ID=cpapi$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^GENERATED_SECRET_BYTES=FLOWY_ENCRYPTION_KEY:16,FLOWY_JWT_SECRET:32$' "$repo_root/apps/flowy/manifest.env"
grep -Fq 'SECRET_REGEXES=FLOWY_ENCRYPTION_KEY:^[A-Fa-f0-9]{32}$' "$repo_root/apps/flowy/manifest.env"
grep -q '^APP_ID=librechat$' "$repo_root/apps/librechat/manifest.env"
grep -q '^NETWORK_ALIAS=librechat-client$' "$repo_root/apps/librechat/manifest.env"
grep -Fq 'LIBRECHAT_OPENROUTER_KEY' "$repo_root/apps/librechat/manifest.env"
grep -Fq 'LIBRECHAT_OPENROUTER_KEY:24' "$repo_root/apps/librechat/manifest.env"
grep -Fq 'OPENROUTER_KEY: ${LIBRECHAT_OPENROUTER_KEY:?LIBRECHAT_OPENROUTER_KEY must be set}' "$repo_root/apps/librechat/compose.yml"
grep -q '^LIBRECHAT_ALLOW_REGISTRATION=false$' "$repo_root/apps/librechat/config.env"
grep -q '^LIBRECHAT_APP_TITLE=aichorchat$' "$repo_root/apps/librechat/config.env"
grep -q '^LIBRECHAT_HELP_AND_FAQ_URL=https://www.librechat.ai/docs/features$' "$repo_root/apps/librechat/config.env"
grep -Fq 'APP_TITLE: ${LIBRECHAT_APP_TITLE:-LibreChat}' "$repo_root/apps/librechat/compose.yml"
grep -Fq 'HELP_AND_FAQ_URL: ${LIBRECHAT_HELP_AND_FAQ_URL:-https://librechat.ai}' "$repo_root/apps/librechat/compose.yml"
grep -Fq 'baseURL: "https://openrouter.ai/api/v1"' "$repo_root/apps/librechat/librechat.yaml"
grep -Fq 'default: ["openrouter/free"]' "$repo_root/apps/librechat/librechat.yaml"
grep -Fq 'fetch: false' "$repo_root/apps/librechat/librechat.yaml"
grep -q '^LIBRECHAT_CLIENT_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^ENABLED=false$' "$repo_root/config/cluster/apps/newapi.policy"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/cpapi.policy"
grep -q '^APP_ID=aichorouter$' "$repo_root/apps/aichorouter/manifest.env"
grep -Fq 'header_up X-Forwarded-For {client_ip}' "$repo_root/apps/aichorouter/route.leader.caddy"
grep -Fq 'header_up X-Forwarded-For {http.request.header.X-Forwarded-For}' "$repo_root/apps/aichorouter/route.follower.caddy"
grep -Fq 'client_ip_headers CF-Connecting-IP' "$repo_root/config/Caddyfile"
grep -Fq 'trusted_proxies_strict' "$repo_root/config/Caddyfile"
grep -q '^APP_ID=cursorapi$' "$repo_root/apps/cursorapi/manifest.env"
grep -q '^SECRET_MIN_LENGTHS=CURSORAPI_CURSOR_API_KEY:16,CURSORAPI_BRIDGE_API_KEY:32$' "$repo_root/apps/cursorapi/manifest.env"
grep -q '^STATE_MODE=ephemeral$' "$repo_root/apps/cursorapi/manifest.env"
grep -q '^MOVE_MODE=fresh$' "$repo_root/apps/cursorapi/manifest.env"
grep -q '^APP_ID=pigeon$' "$repo_root/apps/pigeon/manifest.env"
grep -q '^SECRET_MIN_LENGTHS=PIGEON_SECRET_KEY:32,PIGEON_LOGIN_PASSWORD:12$' "$repo_root/apps/pigeon/manifest.env"
grep -q '^ENABLED=false$' "$repo_root/config/cluster/apps/pigeon.policy"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/cursorapi.policy"
grep -q '^APP_ID=flowy$' "$repo_root/apps/flowy/manifest.env"
grep -q '^STATE_MODE=pglite$' "$repo_root/apps/flowy/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/flowy.policy"
grep -q '^NODES=worker-3$' "$repo_root/config/cluster/apps/flowy.policy"
grep -q '^NODE_STATE=active$' "$repo_root/config/cluster/nodes/worker-3.env"
grep -q '^FLOWY_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^APP_ID=wabase$' "$repo_root/apps/wabase/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$repo_root/apps/wabase/manifest.env"
grep -q '^STATE_MODE=sqlite$' "$repo_root/apps/wabase/manifest.env"
grep -Fq 'SQLITE_GLOBS=docs/*.grist' "$repo_root/apps/wabase/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/wabase.policy"
grep -q '^NODES=worker-4$' "$repo_root/config/cluster/apps/wabase.policy"
grep -q '^NODE_STATE=active$' "$repo_root/config/cluster/nodes/worker-4.env"
grep -q '^BACKUP_ENABLED=false$' "$repo_root/config/cluster/nodes/worker-4.env"
grep -q '^WABASE_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -Fq 'mem_limit: ${WABASE_MEMORY_LIMIT:-1500m}' "$repo_root/apps/wabase/compose.yml"
grep -Fq 'cpus: ${WABASE_CPUS:-0.9}' "$repo_root/apps/wabase/compose.yml"
grep -Fq 'GRIST_SQLITE_MODE: ${WABASE_SQLITE_MODE:-wal}' "$repo_root/apps/wabase/compose.yml"
grep -Fq "status?ready=1&db=1" "$repo_root/apps/wabase/compose.yml"
grep -Fq 'header_up Host {$WABASE_SITE_HOST}' "$repo_root/apps/wabase/route.follower.caddy"
grep -Fq 'header_up X-Forwarded-Host {$WABASE_SITE_HOST}' "$repo_root/apps/wabase/route.follower.caddy"
grep -q '^APP_ID=wapdf$' "$repo_root/apps/wapdf/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$repo_root/apps/wapdf/manifest.env"
grep -q '^STATE_MODE=ephemeral$' "$repo_root/apps/wapdf/manifest.env"
grep -q '^DATA_ROOT_REL=$' "$repo_root/apps/wapdf/manifest.env"
grep -q '^RUNTIME_ENV_FILE=$' "$repo_root/apps/wapdf/manifest.env"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/wapdf.policy"
grep -q '^WAPDF_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -Fq 'mem_limit: ${WAPDF_MEMORY_LIMIT:-900m}' "$repo_root/apps/wapdf/compose.yml"
grep -Fq 'cpus: ${WAPDF_CPUS:-0.60}' "$repo_root/apps/wapdf/compose.yml"
grep -Fq 'pids_limit: ${WAPDF_PIDS_LIMIT:-64}' "$repo_root/apps/wapdf/compose.yml"
grep -Fq 'read_only: true' "$repo_root/apps/wapdf/compose.yml"
grep -Fq 'cap_drop: [ALL]' "$repo_root/apps/wapdf/compose.yml"
grep -Fq "security_opt: ['no-new-privileges:true']" "$repo_root/apps/wapdf/compose.yml"
grep -Fq 'reverse_proxy wapdf:8080' "$repo_root/apps/wapdf/route.follower.caddy"
grep -Fq 'health_uri /' "$repo_root/apps/wapdf/route.leader.caddy"
grep -q '^NODE_WAPDF_ORIGIN_HOST=worker2-wapdf-origin.aichorage.de$' "$repo_root/config/cluster/nodes/worker-2.env"
if grep -Eiq 'ports:|/var/run/docker.sock|postgres|redis' "$repo_root/apps/wapdf/compose.yml"; then
	printf 'Wapdf must not publish ports or depend on databases or the Docker socket\n' >&2
	exit 1
fi
if grep -Eq '^[[:space:]]+volumes:' "$repo_root/apps/wapdf/compose.yml"; then
	printf 'Wapdf must remain stateless and must not mount persistent volumes\n' >&2
	exit 1
fi
grep -Fq 'stage_validation_runtime_config "$release" "$validation_config"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'CONFIG_ROOT="$validation_config" APPS_ROOT="$release/apps"' "$repo_root/ops/deploy-controller.sh"
grep -q '^CONDITIONAL_SECRET_KEYS=FLOWY_FILE_STORAGE_LOCATION=S3|FLOWY_S3_ENDPOINT,FLOWY_S3_BUCKET,FLOWY_S3_ACCESS_KEY_ID,FLOWY_S3_SECRET_ACCESS_KEY$' "$repo_root/apps/flowy/manifest.env"
grep -q '^WOODPECKER_SECRET_NAMES=FLOWY_S3_ENDPOINT:FLOWY_S3_ENDPOINT,FLOWY_S3_BUCKET:FLOWY_S3_BUCKET,FLOWY_S3_ACCESS_KEY_ID:FLOWY_S3_ACCESS_KEY_ID,FLOWY_S3_SECRET_ACCESS_KEY:FLOWY_S3_SECRET_ACCESS_KEY$' "$repo_root/apps/flowy/manifest.env"
grep -Fq 'reverse_proxy flowy:80' "$repo_root/apps/flowy/route.follower.caddy"
grep -Fq '127.0.0.1:80/api/v1/health' "$repo_root/apps/flowy/compose.yml"
grep -Fq 'curl -fsS --max-time 5 http://127.0.0.1:80/api/v1/health' "$repo_root/apps/flowy/compose.yml"
grep -Fq 'mem_limit: ${FLOWY_MEMORY_LIMIT:-1500m}' "$repo_root/apps/flowy/compose.yml"
grep -Fq 'AP_TELEMETRY_ENABLED: ${FLOWY_TELEMETRY_ENABLED:-false}' "$repo_root/apps/flowy/compose.yml"
grep -Fq 'AP_FILE_STORAGE_LOCATION: ${FLOWY_FILE_STORAGE_LOCATION:-S3}' "$repo_root/apps/flowy/compose.yml"
if grep -Fq 'wget -q -O - http://127.0.0.1:80/api/v1/health' "$repo_root/apps/flowy/compose.yml"; then
	printf 'Flowy healthcheck must use an image-provided HTTP client\n' >&2
	exit 1
fi
grep -q '^FLOWY_MEMORY_LIMIT=1500m$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_CPUS=0.95$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_LOG_LEVEL=warn$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_REUSE_SANDBOX=false$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_NODE_OPTIONS=--max-old-space-size=768$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_FILE_STORAGE_LOCATION=S3$' "$repo_root/apps/flowy/config.env"
grep -q '^FLOWY_TELEMETRY_ENABLED=false$' "$repo_root/apps/flowy/config.env"
if grep -Fq 'fail_duration 30s' "$repo_root/apps/flowy/route.leader.caddy"; then
	printf 'Flowy singleton route must not quarantine the origin for 30 seconds after one failed request\n' >&2
	exit 1
fi
grep -Fq 'health_timeout 10s' "$repo_root/apps/flowy/route.leader.caddy"
grep -Fq 'health_fails 3' "$repo_root/apps/flowy/route.leader.caddy"
grep -Fq 'health_passes 1' "$repo_root/apps/flowy/route.leader.caddy"
for app in aichorouter cpapi cursorapi pigeon; do
	grep -q '^UPSTREAM_MODE=singleton$' "$repo_root/apps/$app/manifest.env"
	nodes="$(sed -n 's/^NODES=//p' "$repo_root/config/cluster/apps/$app.policy")"
	[[ -n "$nodes" && "$nodes" != *,* ]]
done
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/aichorouter.policy"
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/cpapi.policy"
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/cursorapi.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/pigeon.policy"
grep -q '^UPSTREAM_MODE=active-active$' "$repo_root/apps/librechat/manifest.env"
grep -q '^NODES=worker-1,worker-2$' "$repo_root/config/cluster/apps/librechat.policy"
grep -q '^UPSTREAM_MODE=active-active$' "$repo_root/apps/newapi/manifest.env"
grep -q '^NODES=worker-1,worker-2$' "$repo_root/config/cluster/apps/newapi.policy"
for component in caddy beszel-controller beszel-worker woodpecker-controller woodpecker-deployer woodpecker-worker observer-controller observer-collector; do
	grep -q "^COMPONENT_ID=$component$" "$repo_root/compose/foundation/manifests/$component.env"
done
grep -q '^MANDATORY=true$' "$repo_root/compose/foundation/manifests/caddy.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/foundation/caddy.policy"
grep -q '^ROLES=leader$' "$repo_root/compose/foundation/manifests/observer-controller.env"
grep -q '^ROLES=leader,follower$' "$repo_root/compose/foundation/manifests/observer-collector.env"
grep -q '^AICHOROUTER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^CPAPI_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^CURSORAPI_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^CURSORAPI_SOURCE_COMMIT=[0-9a-f]\{40\}$' "$repo_root/images/cursorapi/release.env"
grep -q '^CURSOR_AGENT_LINUX_AMD64_SHA256=[0-9a-f]\{64\}$' "$repo_root/images/cursorapi/release.env"
grep -Fq 'npm test -- --maxWorkers=2' "$repo_root/images/cursorapi/Dockerfile"
if grep -Fq -- '--passWithNoTests' "$repo_root/images/cursorapi/Dockerfile"; then
	printf 'Cursorapi release build must execute the upstream tests\n' >&2
	exit 1
fi
grep -Fq 'git -C "$source_dir" archive "$CURSORAPI_SOURCE_COMMIT"' "$repo_root/ops/publish-cursorapi-image.sh"
grep -Fq 'rm -f "$build_context/.dockerignore"' "$repo_root/ops/publish-cursorapi-image.sh"
grep -Fq 'GHCR package manifest is not anonymously readable' "$repo_root/ops/publish-cursorapi-image.sh"
if grep -Fq 'api.github.com/user/packages' "$repo_root/ops/publish-cursorapi-image.sh"; then
	printf 'Cursorapi publisher must not mutate GHCR package visibility\n' >&2
	exit 1
fi
grep -q '^PIGEON_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^HEALTH_PROBE_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.apps.prod.env"
grep -q '^OBSERVER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.foundation.prod.env"
grep -q '^OBSERVER_LOG_PROXY_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.foundation.prod.env"
grep -q '^OBSERVER_LOG_SHIPPER_IMAGE=.*@sha256:[0-9a-f]\{64\}$' "$repo_root/ops/images.foundation.prod.env"
grep -Fq 'SQLITE_PATH: /data/aichorouter.db' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'SQL_MAX_OPEN_CONNS: ${AICHOROUTER_SQL_MAX_OPEN_CONNS:-4}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'mem_limit: ${AICHOROUTER_MEMORY_LIMIT:-768m}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'cpus: ${AICHOROUTER_CPUS:-0.9}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'GOMEMLIMIT: ${AICHOROUTER_GOMEMLIMIT:-500MiB}' "$repo_root/apps/aichorouter/compose.yml"
grep -Fq 'ZO_LOCAL_MODE: "true"' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'ZO_COOKIE_SECURE_ONLY: ${OBSERVER_COOKIE_SECURE_ONLY:-true}' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'ZO_DATA_DIR: /data' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'ZO_COMPACT_DATA_RETENTION_DAYS: ${OBSERVER_DATA_RETENTION_DAYS:-30}' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'mem_limit: ${OBSERVER_MEMORY_LIMIT:-512m}' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'cpus: ${OBSERVER_CPUS:-0.50}' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'pids_limit: ${OBSERVER_PIDS_LIMIT:-256}' "$repo_root/compose/foundation/observer-controller.yml"
grep -q '^OBSERVER_DURABLE_WARN_BYTES=8589934592$' "$repo_root/ops/foundation/observer.env.example"
grep -q '^OBSERVER_LOG_BUFFER_WARN_PERCENT=80$' "$repo_root/ops/foundation/observer.env.example"
grep -Fq 'observer-log-proxy:' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'observer-log-shipper:' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'observer-log-heartbeat:' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'com.aichorage.component: foundation-observer-heartbeat' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'max-size: 1m' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'VECTOR_CONFIG: /etc/vector/vector.toml' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8686/health >/dev/null"]' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'observer-health-probe:' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'com.aichorage.observer.ignore-logs: "true"' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'curl -fsS http://observer-controller:5080/healthz' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'ALLOW_LOGS: "1"' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'POST: "0"' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock:ro' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'OBSERVER_LOG_PROXY_STREAM_TIMEOUT: ${OBSERVER_LOG_PROXY_STREAM_TIMEOUT:-24h}' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq './observer-log-proxy-entrypoint.sh:/observer-log-proxy-entrypoint.sh:ro' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'entrypoint: ["/bin/sh", "/observer-log-proxy-entrypoint.sh"]' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq "client_timeouts=\"\$(grep -c '^    timeout client 10m$'" "$repo_root/compose/foundation/observer-log-proxy-entrypoint.sh"
grep -Fq "server_timeouts=\"\$(grep -c '^    timeout server 10m$'" "$repo_root/compose/foundation/observer-log-proxy-entrypoint.sh"
grep -q '^OBSERVER_LOG_PROXY_STREAM_TIMEOUT=24h$' "$repo_root/ops/foundation/observer.env.example"
grep -Fq 'collector-buffer:/var/lib/vector' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'max_size = ${OBSERVER_LOG_BUFFER_MAX_BYTES}' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'com.aichorage.observer.ignore-logs: "true"' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq "condition = '.label." "$repo_root/compose/foundation/observer-vector.toml"
if grep -Fq 'exclude_containers' "$repo_root/compose/foundation/observer-vector.toml"; then
	printf 'observer Vector config must not depend on exact Compose container names\n' >&2
	exit 1
fi
grep -Fq '[api]' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'OBSERVER_LOG_BUFFER_MAX_BYTES' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'OBSERVER_LOG_BUFFER_WHEN_FULL' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq 'when_full = "${OBSERVER_LOG_BUFFER_WHEN_FULL}"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'validate_observer_env()' "$repo_root/ops/platformctl.sh"
grep -Fq 'foundation_health_service()' "$repo_root/ops/platformctl.sh"
grep -q '^HEALTH_SERVICE=observer-health-probe$' "$repo_root/compose/foundation/manifests/observer-controller.env"
grep -q '^HEALTH_SERVICE=observer-log-shipper$' "$repo_root/compose/foundation/manifests/observer-collector.env"
grep -Fq 'OBSERVER_SMOKE_TIMEOUT_SECONDS:-120' "$repo_root/ops/platformctl.sh"
grep -Fq 'OBSERVER_SMOKE_REQUEST_TIMEOUT_SECONDS:-10' "$repo_root/ops/platformctl.sh"
grep -Fq 'Observer collector buffer policy must be block or drop_newest' "$repo_root/ops/platformctl.sh"
grep -Fq 'observer_collector_status()' "$repo_root/ops/platformctl.sh"
grep -Fq 'observer-collector-status' "$repo_root/ops/platformctl.sh"
grep -Fq 'Observer collector buffer size must be between 268435488 bytes (Vector disk-buffer minimum) and 8 GiB' "$repo_root/ops/platformctl.sh"
grep -Fq 'Observer ingestion site must use http:// or https:// and contain no path' "$repo_root/ops/platformctl.sh"
grep -Fq 'Observer log organization contains invalid path characters' "$repo_root/ops/platformctl.sh"
grep -Fq 'DEPLOY_FETCH_RETRY_DELAY_SECONDS:=5' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS:=5' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_TEST_SKIP_RELEASE_VALIDATION:=0' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_TEST_SKIP_RELEASE_VALIDATION requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_WAIT_INTERVAL_SECONDS:-3' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION:-0' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_MODE:-0' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_MODE:=0' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'test-only validation controls require PLATFORM_TEST_MODE=1' "$repo_root/ops/platformctl.sh"
grep -Fq 'test-only deployment controls require PLATFORM_TEST_MODE=1' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_SKIP_COMPOSE_INSPECTION:-0' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_SKIP_COMPOSE_INSPECTION requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_ONLY_DESCRIPTOR' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_FAST_VALIDATE' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_TEST_FAST_VALIDATE:=0' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_ONLY_DESCRIPTOR="$PLATFORM_TEST_ONLY_DESCRIPTOR"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_FAST_VALIDATE="$PLATFORM_TEST_FAST_VALIDATE" PLATFORM_TEST_ONLY_DESCRIPTOR="$PLATFORM_TEST_ONLY_DESCRIPTOR"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_SKIP_COMPOSE_INSPECTION="$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION="$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_SKIP_SYNC_VALIDATION="$PLATFORM_TEST_SKIP_SYNC_VALIDATION"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_TEST_SKIP_RENDER="$PLATFORM_TEST_SKIP_RENDER"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'docker_host = "http://observer-log-proxy:2375"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'uri = "${OBSERVER_INGEST_URL}/api/${OBSERVER_LOG_ORGANIZATION}/${OBSERVER_LOG_STREAM}/_json"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'path_regexp ^/api/[^/]+/[^/]+/_json$' "$repo_root/config/foundation-routes.d/observer.caddy"
grep -Fq 'method POST' "$repo_root/config/foundation-routes.d/observer.caddy"
grep -Fq 'max_size 10MB' "$repo_root/config/foundation-routes.d/observer.caddy"
grep -Fq 'batch.max_bytes = 5000000' "$repo_root/compose/foundation/observer-vector.toml"
if grep -Eq '^(framing\.|payload_prefix|payload_suffix)' "$repo_root/compose/foundation/observer-vector.toml"; then
	printf 'Observer Vector config must not wrap the JSON encoder batch in another array\n' >&2
	exit 1
fi
grep -Fq '[sinks.openobserve.healthcheck]' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'VECTOR_THREADS: ${OBSERVER_LOG_SHIPPER_THREADS:-1}' "$repo_root/compose/foundation/observer-collector.yml"
grep -Fq '.application = .label."com.aichorage.application"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq '.component = .label."com.aichorage.component"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq '.compose_project = .label."com.docker.compose.project"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq '.compose_service = .label."com.docker.compose.service"' "$repo_root/compose/foundation/observer-vector.toml"
grep -Fq 'ExecStart=/usr/local/bin/platformctl observer-smoke' "$repo_root/ops/systemd/platform-health.service"
grep -Fq 'site="$(env_value OBSERVER_SITE)"' "$repo_root/ops/configure-observer-ingest.sh"
grep -Fq 'api_base="$(env_value OBSERVER_API_URL)"' "$repo_root/ops/configure-observer-ingest.sh"
grep -Fq 'flock -w "${OBSERVER_INGEST_LOCK_WAIT:-300}"' "$repo_root/ops/configure-observer-ingest.sh"
grep -Fq 'OBSERVER_INGEST_URL and OBSERVER_INGEST_SITE must match exactly' "$repo_root/ops/configure-observer-ingest.sh"
grep -Fq 'docker run --rm --network "$OBSERVER_PRIVATE_NETWORK"' "$repo_root/ops/configure-observer-ingest.sh"
grep -Fq 'api="${api_base%/}/api/${organization}/ingestion-tokens"' "$repo_root/ops/configure-observer-ingest.sh"
if grep -Eq 'ports:' "$repo_root/compose/foundation/observer-controller.yml"; then
	printf 'OpenObserve must not publish a host port\n' >&2
	exit 1
fi
if grep -Eiq 'postgres|redis|nats' "$repo_root/compose/foundation/observer-controller.yml"; then
	printf 'OpenObserve foundation service must not define external dependencies\n' >&2
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
grep -Fq 'enabled: ${CPAPI_PLUGINS_ENABLED:-true}' "$repo_root/apps/cpapi/compose.yml"
grep -Fq 'CPAPI_PLUGINS_ENABLED' "$repo_root/apps/cpapi/manifest.env"
grep -Fq 'CPAPI_PLUGINS_ENABLED=true' "$repo_root/apps/cpapi/config.env"
if grep -Eq 'ports:' "$repo_root/apps/cpapi/compose.yml"; then
	printf 'CPAPI must not publish a host port\n' >&2
	exit 1
fi
grep -Fq 'CURSOR_API_KEY: ${CURSORAPI_CURSOR_API_KEY:?CURSORAPI_CURSOR_API_KEY must be set}' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'CURSOR_BRIDGE_API_KEY: ${CURSORAPI_BRIDGE_API_KEY:?CURSORAPI_BRIDGE_API_KEY must be set}' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'mem_limit: ${CURSORAPI_MEMORY_LIMIT:-512m}' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'cpus: ${CURSORAPI_CPUS:-0.50}' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'pids_limit: ${CURSORAPI_PIDS_LIMIT:-128}' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'read_only: true' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'cap_drop: [ALL]' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq "security_opt: ['no-new-privileges:true']" "$repo_root/apps/cursorapi/compose.yml"
grep -Fq "fetch('http://127.0.0.1:8765/healthz')" "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'curl -fsS http://cursorapi:8765/healthz' "$repo_root/apps/cursorapi/compose.yml"
grep -Fq 'com.aichorage.observer.ignore-logs: "true"' "$repo_root/apps/cursorapi/compose.yml"
grep -q '^HEALTH_URL=/healthz$' "$repo_root/apps/cursorapi/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$repo_root/apps/cursorapi/manifest.env"
grep -Fq '@cursorapi_api path /v1/* /healthz' "$repo_root/apps/cursorapi/route.leader.caddy"
grep -Fq 'health_uri /healthz' "$repo_root/apps/cursorapi/route.leader.caddy"
grep -Fq '@cursorapi_origin path /v1/* /healthz' "$repo_root/apps/cursorapi/route.follower.caddy"
grep -Fq 'reverse_proxy cursorapi:8765' "$repo_root/apps/cursorapi/route.follower.caddy"
if grep -Eiq 'ports:|/var/run/docker.sock|postgres|redis' "$repo_root/apps/cursorapi/compose.yml"; then
	printf 'Cursorapi must not publish ports or depend on databases or the Docker socket\n' >&2
	exit 1
fi
if grep -Eq '^[[:space:]]+volumes:' "$repo_root/apps/cursorapi/compose.yml"; then
	printf 'Cursorapi must remain ephemeral and must not mount persistent volumes\n' >&2
	exit 1
fi
grep -Fq 'DATABASE_PATH: /data/outlook_accounts.db' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'DOCKER_UPDATE_ENABLED: "false"' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:5000/login >/dev/null"]' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'curl -fsS http://pigeon:5000/login' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'mem_limit: ${PIGEON_MEMORY_LIMIT:-512m}' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'cpus: ${PIGEON_CPUS:-0.50}' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'pids_limit: ${PIGEON_PIDS_LIMIT:-128}' "$repo_root/apps/pigeon/compose.yml"
grep -q '^HEALTH_URL=/login$' "$repo_root/apps/pigeon/manifest.env"
grep -Fq 'health_uri /login' "$repo_root/apps/pigeon/route.leader.caddy"
grep -Fq 'reverse_proxy pigeon:5000' "$repo_root/apps/pigeon/route.follower.caddy"
grep -Fq 'read_only: true' "$repo_root/apps/pigeon/compose.yml"
grep -Fq 'cap_drop: [ALL]' "$repo_root/apps/pigeon/compose.yml"
grep -Fq '/root/.gunicorn:rw,noexec,nosuid,size=1m' "$repo_root/apps/pigeon/compose.yml"
if grep -Eq 'ports:' "$repo_root/apps/pigeon/compose.yml"; then
	printf 'Pigeon must not publish a host port\n' >&2
	exit 1
fi
if grep -Eiq 'postgres|redis|/var/run/docker.sock' "$repo_root/apps/pigeon/compose.yml"; then
	printf 'Pigeon must not define external databases or Docker socket access\n' >&2
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
grep -q '^HEALTH_URL=/healthz$' "$repo_root/apps/cpapi/manifest.env"
grep -q '^HEALTH_MODE=healthcheck$' "$repo_root/apps/pigeon/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$repo_root/apps/pigeon/manifest.env"
grep -Fq 'health_uri /healthz' "$repo_root/apps/cpapi/route.leader.caddy"
grep -Fq 'observer-health-probe:' "$repo_root/compose/foundation/observer-controller.yml"
grep -Fq 'singleton-transition-fail' "$repo_root/ops/platformctl.sh"
grep -Fq 'verify_cluster_scope "$old_control_current" "$release"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'cluster reconciliation contains a non-cluster change' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'ops/tests/** | docs/**' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'sync_node_config "$release" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'current_route="$RUNTIME_ROOT/config/routes.d/$a.caddy"' "$repo_root/ops/platformctl.sh"
grep -Fq 'stopping retired Observer container' "$repo_root/ops/platformctl.sh"
grep -Fq "stop_inactive || die 'inactive project cleanup failed'" "$repo_root/ops/platformctl.sh"
grep -Fq 'Observer retention days must be between 1 and 365' "$repo_root/ops/platformctl.sh"
grep -Fq '[observer-collector-recent]' "$repo_root/ops/platformctl.sh"
grep -Fq 'transition_begin' "$repo_root/ops/platformctl.sh"
grep -Fq 'CONSUMER_APP_ID=cpapi /usr/local/bin/platform-submit consumer-stage' "$repo_root/.woodpecker/consumer-stage-cpapi-worker-1.yml"
grep -Fq 'consumer-stage-cpapi-worker-1' "$repo_root/.woodpecker/consumer-publish-cpapi.yml"
for node in leader worker-1 worker-2 worker-3 worker-4; do
	[[ -f "$repo_root/.woodpecker/control-sync-$node.yml" ]]
done
grep -Fq 'platform-submit control-sync' "$repo_root/.woodpecker/control-sync-leader.yml"
for node in worker-1 worker-2 worker-3 worker-4; do
	grep -Fq 'platform-submit control-verify' "$repo_root/.woodpecker/control-sync-$node.yml"
done
grep -Fq 'control-sync-worker-1' "$repo_root/.woodpecker/consumer-stage-cpapi-worker-1.yml"
grep -Fq 'control-verify' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'CONTROL_ATTESTATION_FILE' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'consumer-publish-cpapi' "$repo_root/.woodpecker/consumer-stop-cpapi-worker-2.yml"
grep -Fq 'CONSUMER_APP_ID=wapdf /usr/local/bin/platform-submit consumer-stage' "$repo_root/.woodpecker/consumer-stage-wapdf-worker-2.yml"
grep -Fq 'consumer-stage-wapdf-worker-2' "$repo_root/.woodpecker/consumer-publish-wapdf.yml"
grep -Fq 'consumer-publish-wapdf' "$repo_root/.woodpecker/consumer-stop-wapdf-worker-1.yml"
[[ ! -e "$repo_root/.woodpecker/consumer-secrets-wapdf-worker-2.yml" ]]
if grep -Fq 'consumer-stage-librechat-worker-1' "$repo_root/.woodpecker/consumer-stage-librechat-worker-2.yml"; then
	printf 'active-active stages must be parallel\n' >&2
	exit 1
fi
grep -Fq 'consumer-stage-librechat-worker-1' "$repo_root/.woodpecker/consumer-publish-librechat.yml"
grep -Fq 'consumer-stage-librechat-worker-2' "$repo_root/.woodpecker/consumer-publish-librechat.yml"
grep -q '^NEW_API_NODE_TYPE=master$' "$repo_root/config/cluster/nodes/worker-1.env"
grep -q '^NEW_API_NODE_TYPE=slave$' "$repo_root/config/cluster/nodes/worker-2.env"
grep -q '^NEW_API_BACKUP_NODE_ID=worker-2$' "$repo_root/config/cluster/apps/newapi.policy"
grep -q '^NEW_API_MIGRATION_NODE_ID=worker-1$' "$repo_root/config/cluster/apps/newapi.policy"
grep -Fq 'cluster-reconcile' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'consumer-stage)' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_RECREATE_APPS=1' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_RECREATE_APPS="${DEPLOY_RECREATE_APPS:-0}"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'consumer-publish)' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'consumer-stop)' "$repo_root/ops/deploy-controller.sh"
if grep -Eq '^(singleton-stage|singleton-switch|singleton-stop)\)' "$repo_root/ops/deploy-controller.sh"; then
	printf 'deployment controller still exposes a retired singleton workflow mode\n' >&2
	exit 1
fi
if grep -Eq '\^\(.*singleton-(stage|switch|stop)' "$repo_root/ops/platform-submit.sh"; then
	printf 'platform submitter still accepts a retired singleton workflow mode\n' >&2
	exit 1
fi
grep -Fq 'singleton-prepare' "$repo_root/ops/platformctl.sh"
grep -Fq 'app_in_reconcile_scope' "$repo_root/ops/platformctl.sh"
grep -Fq 'PLATFORM_FORCE_SINGLETON_ACTION' "$repo_root/ops/platformctl.sh"
grep -Fq 'singleton-origin-smoke' "$repo_root/ops/platformctl.sh"
grep -Fq 'Leader route and active containers reconciled' "$repo_root/ops/platformctl.sh"
grep -Fq 'app_policy_enabled "$(basename "$d")"' "$repo_root/ops/platformctl.sh"
grep -Fq 'record_singleton_transitions' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton_prepare_failed' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'stop_removed_foundation_projects "$old_current" "$release"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'unable to enumerate containers for $description: $project' "$repo_root/ops/deploy-controller.sh"
if grep -Fq 'docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true' "$repo_root/ops/deploy-controller.sh"; then
	printf 'deployment cleanup still ignores Docker enumeration failures\n' >&2
	exit 1
fi
grep -Fq 'cluster app policy requires its consumer reconciliation workflow' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'unsupported cluster configuration path in application deployment' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'application image manifest changes require the reviewed consumer workflow' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'prune_stale_image_keys' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'removing stale image key' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'validate_release_cached' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'control_sync_matches_sha' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'ops/*.sh | ops/deploy-runner/** | ops/tests/**' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'PLATFORM_ONLY_APP_ID="${PLATFORM_ONLY_APP_ID:-}"' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'singleton-state' "$repo_root/ops/backup-platform.sh"
if grep -Fq 'rm -f -- "$runtime_env"' "$repo_root/ops/platformctl.sh"; then
	printf 'singleton stop must retain runtime secrets\n' >&2
	exit 1
fi
grep -Fq 'firewall-reconcile.request' "$repo_root/ops/platform-submit.sh"
grep -Fq 'direct publication requires firewall reconciler' "$repo_root/ops/platform-submit.sh"
grep -Fq 'reconcile_caddy_udp_policy' "$repo_root/ops/platformctl.sh"
grep -Fq 'port --protocol "$proto" "$service" "$container_port"' "$repo_root/ops/platformctl.sh"
for node in leader worker-1 worker-2 worker-3; do
	[[ -f "$repo_root/.woodpecker/cluster-reconcile-$node.yml" ]] || {
		printf 'missing generated cluster reconciliation workflow: %s\n' "$node" >&2
		exit 1
	}
done
grep -Fq 'config/cluster/foundation/**' "$repo_root/.woodpecker/cluster-reconcile-leader.yml"
if grep -Eq 'config/Caddyfile|compose/foundation|ops/\*\*' "$repo_root/.woodpecker/cluster-reconcile-leader.yml"; then
	printf 'cluster workflow overlaps ingress or foundation implementation paths\n' >&2
	exit 1
fi
grep -Fq 'config/Caddyfile' "$repo_root/.woodpecker/foundation-reconcile-leader.yml"
grep -Fq 'config/foundation-routes.d/**' "$repo_root/.woodpecker/foundation-reconcile-leader.yml"
if grep -Eq 'compose/foundation|ops/images\.foundation|ops/foundation|config/cluster/foundation' "$repo_root/.woodpecker/foundation-reconcile-leader.yml"; then
	printf 'automatic ingress workflow includes disruptive foundation paths\n' >&2
	exit 1
fi
grep -Fq $'depends_on:\n  - name: cluster-reconcile-leader\n    optional: true' "$repo_root/.woodpecker/cluster-reconcile-worker-1.yml"
for compose_file in "$repo_root"/compose/foundation/*.yml; do
	grep -Fq 'mem_limit:' "$compose_file"
	grep -Fq 'cpus:' "$compose_file"
	grep -Fq 'pids_limit:' "$compose_file"
done
validate_observer_labels() {
	awk '
		function finish_service() {
			if (service != "" && (!platform || !application || !component)) {
				printf "missing Observer enrollment metadata in %s service %s\n", FILENAME, service > "/dev/stderr"
				missing=1
			}
		}
		$0 == "services:" { in_services=1; next }
		in_services && /^[^[:space:]]/ { finish_service(); service=""; in_services=0 }
		in_services && /^  [A-Za-z0-9_-]+:$/ {
			finish_service()
			service=$1
			sub(/:$/, "", service)
			platform=application=component=0
			next
		}
		in_services && service != "" && /com\.aichorage\.platform: llm-hub-lite$/ { platform=1 }
		in_services && service != "" && /com\.aichorage\.application: [a-z0-9-]+$/ { application=1 }
		in_services && service != "" && /com\.aichorage\.component: [a-z0-9-]+$/ { component=1 }
		END { finish_service(); exit missing }
	' "$1"
}
for compose_file in "$repo_root"/compose/foundation/*.yml "$repo_root"/apps/*/compose.yml; do
	validate_observer_labels "$compose_file"
done
service_opts_out_of_observer() {
	awk -v wanted="$2" '
		/^  [A-Za-z0-9_-]+:$/ { current=$1; sub(/:$/, "", current) }
		current == wanted && /com\.aichorage\.observer\.ignore-logs: "true"$/ { found=1 }
		END { exit !found }
	' "$1"
}
while IFS='|' read -r compose_file service; do
	service_opts_out_of_observer "$repo_root/$compose_file" "$service" || {
		printf 'Observer sidecar must opt out of log collection: %s service %s\n' "$compose_file" "$service" >&2
		exit 1
	}
done <<'EOF'
apps/aichorouter/compose.yml|health-probe
apps/cpapi/compose.yml|health-probe
apps/wapdf/compose.yml|health-probe
apps/pigeon/compose.yml|health-probe
compose/foundation/beszel-worker.yml|beszel-socket-proxy
compose/foundation/observer-controller.yml|observer-controller
compose/foundation/observer-controller.yml|observer-health-probe
compose/foundation/observer-collector.yml|observer-log-proxy
compose/foundation/observer-collector.yml|observer-log-shipper
EOF
grep -Fq 'prepare_application_secrets()' "$repo_root/ops/bootstrap-vps.sh"
grep -Fq "s/^CLUSTER_SECRET_KEYS=//p" "$repo_root/ops/bootstrap-vps.sh"
grep -Fq "s/^NODE_SECRET_KEYS=//p" "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'PathExists=/etc/llm-hub-lite/firewall-reconcile.request' "$repo_root/ops/systemd/platform-firewall.path"
grep -Fq 'deployment failed; restoring previous complete bundle' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'DEPLOY_SYNC_SCOPE=all reconcile || true' "$repo_root/ops/deploy-controller.sh"
grep -Fq 'git-auth.sh:/usr/local/bin/git-auth.sh:ro' "$repo_root/ops/platform-submit.sh"
grep -Fq 'RESTORE_IDENTITY' "$repo_root/ops/restore-platform.sh"
recover_body="$(sed -n '/^recover() {/,/^}/p' "$repo_root/ops/platformctl.sh")"
foundation_line="$(printf '%s\n' "$recover_body" | grep -n 'projects_foundation' | head -n1 | cut -d: -f1)"
consumer_line="$(printf '%s\n' "$recover_body" | grep -n 'start_consumer_projects_parallel' | head -n1 | cut -d: -f1)"
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
