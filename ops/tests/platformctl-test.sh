#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/control/releases/test" "$tmp/foundation/env" "$tmp/app/shared" "$tmp/config" "$tmp/bin" "$tmp/locks"
cp -a "$repo_root/apps" "$repo_root/config" "$tmp/control/releases/test/"
ln -s "$tmp/control/releases/test" "$tmp/control/current"
for f in "$repo_root"/compose/foundation/*.yml; do cp "$f" "$tmp/foundation/"; done
cp "$repo_root"/ops/foundation/*.env.example "$tmp/foundation/env/"
cp "$repo_root/ops/foundation/observer.env.example" "$tmp/foundation/env/observer.env"
sed -e "s#^OBSERVER_DATA_ROOT=.*#OBSERVER_DATA_ROOT=$tmp/observer#" \
	-e 's#^OBSERVER_ROOT_USER_EMAIL=.*#OBSERVER_ROOT_USER_EMAIL=observer-admin@aichorage.test#' \
	-e 's#^OBSERVER_ROOT_USER_PASSWORD=.*#OBSERVER_ROOT_USER_PASSWORD=test-observer-password#' \
	-e 's#^OBSERVER_INGEST_TOKEN=.*#OBSERVER_INGEST_TOKEN=o2oi_00000000000000000000000000000000#' \
	"$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
cp "$repo_root"/ops/images.*.prod.env "$tmp/config/"
cat >"$tmp/config/cpapi.env" <<'EOF'
CPAPI_API_KEY=test-api-key
CPAPI_MANAGEMENT_KEY=test-management-key
EOF
cat >"$tmp/config/aichorouter.env" <<'EOF'
AICHOROUTER_SESSION_SECRET=test-session-secret
AICHOROUTER_CRYPTO_SECRET=test-crypto-secret
EOF
cat >"$tmp/config/pigeon.env" <<'EOF'
PIGEON_SECRET_KEY=0123456789abcdef0123456789abcdef
PIGEON_LOGIN_PASSWORD=test-pigeon-password
EOF
cat >"$tmp/config/node.env" <<EOF
NODE_ID=leader
NODE_NEW_API_ORIGIN_HOST=worker2-newapi.example.invalid
NODE_CPAPI_ORIGIN_HOST=worker2-cpapi.example.invalid
NODE_LIBRECHAT_ORIGIN_HOST=worker2-chat.example.invalid
NODE_LIBRECHAT_ADMIN_ORIGIN_HOST=worker2-chat-admin.example.invalid
NODE_AICHOROUTER_ORIGIN_HOST=worker2-aichorouter.example.invalid
NODE_PIGEON_ORIGIN_HOST=worker2-pigeon.example.invalid
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in
  *" ps --all -q observer-log-shipper"*) printf 'observer-log-shipper\n'; exit 0;;
  *" ps --all -q health-probe"*)
    case "$*" in
      *"-p app-aichorouter "*|*"-p app-cpapi "*|*"-p app-pigeon "*)
        printf 'health-probe\n'
        exit 0
        ;;
      *)
        printf 'health-probe queried through wrong Compose project: %s\n' "$*" >&2
        exit 1
        ;;
    esac
    ;;
  *" ps --all -q"*) :;;
esac
case "$*" in
  *app-librechat*) printf 'librechat-api\nlibrechat-admin-panel\nlibrechat-client\n';;
  *app-newapi*) printf 'newapi\n';;
  *app-cpapi*) printf 'cpapi\nhealth-probe\n';;
  *app-aichorouter*) printf 'aichorouter\nhealth-probe\n';;
  *app-pigeon*) printf 'pigeon\nhealth-probe\n';;
esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$1 $2" in "network inspect") exit 0;; "inspect --format") printf 'running healthy\n';; "run --rm") exit 0;; esac
case "$1 $2" in "logs --tail") printf 'WARN retry buffer token=o2oi_11111111111111111111111111111111 Authorization: Basic dGVzdDpzZWNyZXQ=\n';; esac
case "$*" in
  "ps -aq --filter label=com.docker.compose.project=app-pigeon")
    [ "${FAIL_DOCKER_PS:-0}" = 1 ] && exit 1
    [ "${EMIT_PIGEON_CONTAINER:-0}" = 1 ] && printf 'stale-pigeon\n'
    ;;
  "rm -f stale-pigeon")
    [ "${FAIL_DOCKER_RM:-0}" = 1 ] && exit 1
    ;;
esac
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation" CONFIG_ROOT="$tmp/config" APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.prod.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.prod.env" NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
export COMPOSE_CALL_LOG="$tmp/compose.log" DOCKER_CALL_LOG="$tmp/docker.log"
foundation_env_function="$(sed -n '/^foundation_env() {/,/^}/p' "$repo_root/ops/platformctl.sh")"
foundation_env_result="$(FOUNDATION_ENV_FUNCTION="$foundation_env_function" FOUNDATION_ENV_ROOT=/foundation bash -c '
	eval "$FOUNDATION_ENV_FUNCTION"
	die() { return 1; }
	foundation_env caddy
	foundation_env woodpecker-controller
	foundation_env beszel-worker
')"
[[ "$foundation_env_result" == $'/foundation/caddy.env\n/foundation/woodpecker.env\n/foundation/beszel.env' ]] || {
	printf 'foundation service resolved to an incorrect env file: %q\n' "$foundation_env_result" >&2
	exit 1
}
bash "$repo_root/ops/platformctl.sh" validate
for retention in 1 365; do
	sed "s/^OBSERVER_DATA_RETENTION_DAYS=.*/OBSERVER_DATA_RETENTION_DAYS=$retention/" "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
	mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
	bash "$repo_root/ops/platformctl.sh" validate
done
for retention in 0 -1 invalid 366; do
	sed "s/^OBSERVER_DATA_RETENTION_DAYS=.*/OBSERVER_DATA_RETENTION_DAYS=$retention/" "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
	mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
	if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
		printf 'invalid Observer retention was accepted: %s\n' "$retention" >&2
		exit 1
	fi
done
sed 's/^OBSERVER_DATA_RETENTION_DAYS=.*/OBSERVER_DATA_RETENTION_DAYS=30/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
for buffer in 1 268435487 8589934593 invalid; do
	sed "s/^OBSERVER_LOG_BUFFER_MAX_BYTES=.*/OBSERVER_LOG_BUFFER_MAX_BYTES=$buffer/" "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
	mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
	if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
		printf 'invalid Observer buffer size was accepted: %s\n' "$buffer" >&2
		exit 1
	fi
done
sed 's/^OBSERVER_LOG_BUFFER_MAX_BYTES=.*/OBSERVER_LOG_BUFFER_MAX_BYTES=536870912/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
for threads in 0 9 invalid; do
	sed "s/^OBSERVER_LOG_SHIPPER_THREADS=.*/OBSERVER_LOG_SHIPPER_THREADS=$threads/" "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
	mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
	if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
		printf 'invalid Observer collector thread count was accepted: %s\n' "$threads" >&2
		exit 1
	fi
done
sed 's/^OBSERVER_LOG_SHIPPER_THREADS=.*/OBSERVER_LOG_SHIPPER_THREADS=1/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
sed 's/^OBSERVER_DURABLE_WARN_BYTES=.*/OBSERVER_DURABLE_WARN_BYTES=0/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'zero Observer durable warning threshold was accepted\n' >&2
	exit 1
fi
sed 's/^OBSERVER_DURABLE_WARN_BYTES=.*/OBSERVER_DURABLE_WARN_BYTES=8589934592/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
sed 's/^OBSERVER_LOG_BUFFER_WARN_PERCENT=.*/OBSERVER_LOG_BUFFER_WARN_PERCENT=101/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'Observer buffer warning percentage above 100 was accepted\n' >&2
	exit 1
fi
sed 's/^OBSERVER_LOG_BUFFER_WARN_PERCENT=.*/OBSERVER_LOG_BUFFER_WARN_PERCENT=80/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
sed 's/^OBSERVER_INGEST_TOKEN=.*/OBSERVER_INGEST_TOKEN=bootstrap-pending/' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
PLATFORM_ALLOW_OBSERVER_BOOTSTRAP=1 bash "$repo_root/ops/platformctl.sh" validate
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'Observer bootstrap-pending token was accepted outside the bootstrap phase\n' >&2
	exit 1
fi
sed 's#^OBSERVER_INGEST_TOKEN=.*#OBSERVER_INGEST_TOKEN=o2oi_00000000000000000000000000000000#' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
sed 's#^OBSERVER_SITE=.*#OBSERVER_SITE=https://stale-app.example.invalid#; s#^OBSERVER_INGEST_SITE=.*#OBSERVER_INGEST_SITE=https://stale-ingest.example.invalid#' "$tmp/app/shared/.env.prod" >"$tmp/app/shared/.env.prod.tmp"
mv "$tmp/app/shared/.env.prod.tmp" "$tmp/app/shared/.env.prod"
sed 's#^OBSERVER_SITE=.*#OBSERVER_SITE=https://foundation.example.invalid#; s#^OBSERVER_INGEST_SITE=.*#OBSERVER_INGEST_SITE=https://foundation-ingest.example.invalid#; s#^OBSERVER_INGEST_URL=.*#OBSERVER_INGEST_URL=https://foundation-ingest.example.invalid#' "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
mkdir -p "$tmp/observer/data" "$tmp/observer/collector-buffer"
printf 'observer-data\n' >"$tmp/observer/data/log.txt"
printf 'collector-buffer\n' >"$tmp/observer/collector-buffer/buffer"
bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'foundation.example.invalid' "$tmp/app/shared/runtime/config/Caddyfile" "$tmp/app/shared/runtime/config/foundation-routes.d/observer.caddy"
grep -Fq 'foundation-ingest.example.invalid' "$tmp/app/shared/runtime/config/foundation-routes.d/observer.caddy"
if grep -Fq 'stale-app.example.invalid' "$tmp/app/shared/runtime/config/foundation-routes.d/observer.caddy"; then
	printf 'Observer Caddy route used stale shared application URL instead of foundation env\n' >&2
	exit 1
fi
PLATFORM_ONLY_APP_ID=cpapi bash "$repo_root/ops/platformctl.sh" diagnose app:cpapi >/dev/null
if bash "$repo_root/ops/platformctl.sh" diagnose app:not-an-app >/dev/null 2>&1; then
	printf 'diagnose accepted an unknown application\n' >&2
	exit 1
fi
leader_diagnose="$(bash "$repo_root/ops/platformctl.sh" diagnose foundation 2>&1)"
grep -Fq '[observer-storage]' <<<"$leader_diagnose"
grep -Fq '[observer-buffer]' <<<"$leader_diagnose"
grep -Fq '[observer-collector-recent]' <<<"$leader_diagnose"
grep -Fq '<redacted>' <<<"$leader_diagnose"
grep -Fq 'warn_bytes=8589934592' <<<"$leader_diagnose"
grep -Fq 'warn_percent=80' <<<"$leader_diagnose"
if grep -Fq 'test-observer-password' <<<"$leader_diagnose" || grep -Fq 'o2oi_' <<<"$leader_diagnose"; then
	printf 'Observer diagnostics exposed a credential\n' >&2
	exit 1
fi
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
worker_diagnose="$(bash "$repo_root/ops/platformctl.sh" diagnose foundation 2>&1)"
if grep -Fq '[observer-storage]' <<<"$worker_diagnose"; then
	printf 'follower diagnostics reported Leader-only Observer storage\n' >&2
	exit 1
fi
grep -Fq '[observer-buffer]' <<<"$worker_diagnose"
sed -e 's/^OBSERVER_DURABLE_WARN_BYTES=.*/OBSERVER_DURABLE_WARN_BYTES=1/' \
	-e 's/^OBSERVER_LOG_BUFFER_WARN_PERCENT=.*/OBSERVER_LOG_BUFFER_WARN_PERCENT=1/' \
	-e 's/^OBSERVER_LOG_BUFFER_MAX_BYTES=.*/OBSERVER_LOG_BUFFER_MAX_BYTES=268435488/' \
	"$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
dd if=/dev/zero of="$tmp/observer/collector-buffer/pressure" bs=1024 count=3072 >/dev/null 2>&1
warning_diagnose="$(bash "$repo_root/ops/platformctl.sh" diagnose foundation 2>&1)"
grep -Fq 'WARNING: Observer collector buffer' <<<"$warning_diagnose"
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
leader_warning_diagnose="$(bash "$repo_root/ops/platformctl.sh" diagnose foundation 2>&1)"
grep -Fq 'WARNING: Observer durable data' <<<"$leader_warning_diagnose"
cp "$tmp/compose.log" "$tmp/compose-all.log"
: >"$tmp/compose.log"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
PLATFORM_ONLY_APP_ID=cpapi bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'app-cpapi' "$tmp/compose.log"
if grep -Fq 'app-librechat' "$tmp/compose.log"; then
	printf 'singleton app scope reconciled an unrelated consumer\n' >&2
	exit 1
fi
# A reviewed foundation upgrade must preserve installed singleton routes while
# withholding a brand-new singleton. It must not require the new app's runtime
# secrets or an app-image key that is not installed until singleton staging.
cp "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy" "$tmp/cpapi-route.original"
rm -f "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" "$tmp/config/pigeon.env"
sed '/^PIGEON_IMAGE=/d' "$tmp/config/images.apps.prod.env" >"$tmp/config/images.apps.prod.env.tmp"
mv "$tmp/config/images.apps.prod.env.tmp" "$tmp/config/images.apps.prod.env"
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/config/node.env"
PLATFORM_SKIP_SINGLETONS=1 bash "$repo_root/ops/platformctl.sh" validate
cmp -s "$tmp/cpapi-route.original" "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" ]]
cp "$repo_root/ops/images.apps.prod.env" "$tmp/config/images.apps.prod.env"
cat >"$tmp/config/pigeon.env" <<'EOF'
PIGEON_SECRET_KEY=0123456789abcdef0123456789abcdef
PIGEON_LOGIN_PASSWORD=test-pigeon-password
EOF
: >"$tmp/compose.log"
sed 's/^ENABLED=.*/ENABLED=true/' "$tmp/control/current/config/cluster/apps/pigeon.policy" >"$tmp/control/current/config/cluster/apps/pigeon.policy.tmp"
mv "$tmp/control/current/config/cluster/apps/pigeon.policy.tmp" "$tmp/control/current/config/cluster/apps/pigeon.policy"
PLATFORM_ONLY_APP_ID=pigeon bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'app-pigeon' "$tmp/compose.log"
grep -Fq 'reverse_proxy pigeon:5000' "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy"
cp "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" "$tmp/pigeon-route.original"
PLATFORM_SKIP_SINGLETONS=1 bash "$repo_root/ops/platformctl.sh" validate
cmp -s "$tmp/pigeon-route.original" "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy"
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
bash "$repo_root/ops/platformctl.sh" validate
cp "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy" "$tmp/cpapi-route.before-disabled-reconcile"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/pigeon.policy" >"$tmp/control/current/config/cluster/apps/pigeon.policy.tmp"
mv "$tmp/control/current/config/cluster/apps/pigeon.policy.tmp" "$tmp/control/current/config/cluster/apps/pigeon.policy"
: >"$tmp/docker.log"
EMIT_PIGEON_CONTAINER=1 PLATFORM_SKIP_SINGLETONS=1 PLATFORM_RECONCILE_DISABLED_SINGLETONS=1 \
	bash "$repo_root/ops/platformctl.sh" sync apps
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" ]]
cmp -s "$tmp/cpapi-route.before-disabled-reconcile" "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
grep -Fq 'rm -f stale-pigeon' "$tmp/docker.log"
if EMIT_PIGEON_CONTAINER=1 FAIL_DOCKER_RM=1 PLATFORM_SKIP_SINGLETONS=1 PLATFORM_RECONCILE_DISABLED_SINGLETONS=1 \
	bash "$repo_root/ops/platformctl.sh" sync apps >/dev/null 2>&1; then
	printf 'inactive singleton cleanup failure did not fail reconciliation\n' >&2
	exit 1
fi
if FAIL_DOCKER_PS=1 PLATFORM_SKIP_SINGLETONS=1 PLATFORM_RECONCILE_DISABLED_SINGLETONS=1 \
	bash "$repo_root/ops/platformctl.sh" sync apps >/dev/null 2>&1; then
	printf 'inactive singleton discovery failure did not fail reconciliation\n' >&2
	exit 1
fi
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
grep -Fq 'Do not evaluate an inactive app' "$repo_root/ops/platformctl.sh"
grep -Fq -- '--force-recreate --wait' "$repo_root/ops/platformctl.sh"
grep -Fq 'Compose project state after failed health wait' "$repo_root/ops/platformctl.sh"
grep -Fq 'failed during recreate' "$repo_root/ops/platformctl.sh"
grep -Fq 'restart command failed' "$repo_root/ops/platformctl.sh"
grep -Fq 'app_in_reconcile_scope' "$repo_root/ops/platformctl.sh"
grep -Fq 'stopping retired Observer container' "$repo_root/ops/platformctl.sh"
grep -Fq 'singleton-origin-smoke' "$repo_root/ops/platformctl.sh"
grep -Fq 'oom={{.State.OOMKilled}}' "$repo_root/ops/platformctl.sh"
grep -Fq 'LibreChat Upstash Redis URI must use TLS (rediss://)' "$repo_root/ops/platformctl.sh"
[[ -f "$tmp/app/shared/runtime/config/Caddyfile" ]]
grep -Fq 'cpapi.localhost' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
grep -Fq 'lb_policy random_choose 2' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'header_up Host {http.reverse_proxy.upstream.hostport}' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'reverse_proxy https://worker1-aichorouter-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/aichorouter.caddy"
grep -Fq 'location = /health' "$repo_root/apps/librechat/client.nginx.conf"
grep -Fq 'mem_limit:' "$repo_root/apps/librechat/compose.yml"
grep -Fq 'MONGO_MAX_POOL_SIZE:' "$repo_root/apps/librechat/compose.yml"
for foundation_file in "$repo_root"/compose/foundation/*.yml; do
	grep -Fq 'mem_limit:' "$foundation_file"
	grep -Fq 'cpus:' "$foundation_file"
	grep -Fq 'pids_limit:' "$foundation_file"
done
awk '/^  librechat-api:/{in_api=1; next} /^  [a-z0-9-]+:/{in_api=0} in_api && /networks: \[librechat_private\]/{found=1} END{exit found ? 0 : 1}' "$repo_root/apps/librechat/compose.yml"
if awk '/^  librechat-api:/{in_api=1; next} /^  [a-z0-9-]+:/{in_api=0} in_api && /platform_edge/{found=1} END{exit found ? 0 : 1}' "$repo_root/apps/librechat/compose.yml"; then
	printf 'LibreChat API must not join the public edge network\n' >&2
	exit 1
fi
if grep -Fq 'header_up Host {http.request.host}' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"; then
	printf 'leader route overrides the origin Host header\n' >&2
	exit 1
fi
bash "$repo_root/ops/platformctl.sh" status --json | jq -e '.node == "leader" and .role == "leader"' >/dev/null
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
bash "$repo_root/ops/platformctl.sh" validate
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/newapi.caddy" ]]
sed 's/^ENABLED=.*/ENABLED=true/' "$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
sed -e 's/^DOMAIN_NAME=.*/DOMAIN_NAME=aichorage.de/' -e 's#^LIBRECHAT_AWS_ENDPOINT_URL=.*#LIBRECHAT_AWS_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com#' "$repo_root/.env.dev.example" >"$tmp/app/shared/.env.prod"
cat >"$tmp/config/aichorouter.env" <<'EOF'
AICHOROUTER_SESSION_SECRET=test-session
AICHOROUTER_CRYPTO_SECRET=test-crypto
AICHOROUTER_NODE_NAME=aichorouter-test
EOF
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'production LibreChat placeholder was accepted\n' >&2
	exit 1
fi
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'librechat-client:80' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
bash "$repo_root/ops/platformctl.sh" smoke "app:$tmp/control/current/apps/librechat"
# Re-establish the Leader's installed route before simulating a target-policy
# change. Earlier checks intentionally reuse this fixture as a Follower and
# therefore replace its staged Caddy route with the Follower template.
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
bash "$repo_root/ops/platformctl.sh" validate
cp "$tmp/control/current/config/cluster/apps/cpapi.policy" "$tmp/cpapi-policy.original"
sed 's/^CPAPI_TARGET_NODE_ID=.*/CPAPI_TARGET_NODE_ID=worker-2/' "$tmp/cpapi-policy.original" >"$tmp/control/current/config/cluster/apps/cpapi.policy"
mkdir -p "$tmp/config/singleton-state"
printf 'worker-1\n' >"$tmp/config/singleton-state/cpapi.previous-target"
PLATFORM_SKIP_SINGLETONS=1 bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'reverse_proxy https://worker1-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
cp "$tmp/cpapi-policy.original" "$tmp/control/current/config/cluster/apps/cpapi.policy"
policy_backup="$tmp/policy.original"
cp "$tmp/control/current/config/cluster/policy.env" "$policy_backup"
{
	sed -E '/^(NEW_API_MIGRATION_NODE_ID|NEW_API_BACKUP_NODE_ID)=/d' "$policy_backup"
} >"$tmp/control/current/config/cluster/policy.env"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/cpapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/cpapi.policy"
bash "$repo_root/ops/platformctl.sh" validate
mv "$policy_backup" "$tmp/control/current/config/cluster/policy.env"
awk -F= '{if ($1 == "NODE_ID") print "NODE_ID=rogue"; else print}' "$tmp/config/node.env" >"$tmp/node.tmp"
mv "$tmp/node.tmp" "$tmp/config/node.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'runtime node identity mismatch was accepted\n' >&2
	exit 1
fi
printf 'platformctl tests passed\n'
