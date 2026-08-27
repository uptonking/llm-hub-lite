#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
interrupted() {
	trap - EXIT HUP INT TERM
	pkill -TERM -P $$ 2>/dev/null || true
	cleanup
	exit 130
}
trap cleanup EXIT
trap interrupted HUP INT TERM
# Validation is fully mocked in this test. Do not spend three seconds between
# health polls when exercising the same command repeatedly.
export PLATFORM_WAIT_INTERVAL_SECONDS=0
# Compose and Caddy are covered by the initial validation and sync checks;
# route/policy matrix cases only need the local validator and renderer.
export PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1
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
cat >"$tmp/config/cursorapi.env" <<'EOF'
CURSORAPI_CURSOR_API_KEY=test-cursor-account-key
CURSORAPI_BRIDGE_API_KEY=test-cursor-bridge-key-0123456789abcdef
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
NODE_CURSORAPI_ORIGIN_HOST=worker2-cursorapi.example.invalid
NODE_PIGEON_ORIGIN_HOST=worker2-pigeon.example.invalid
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in
  *" ps --all -q observer-log-shipper"*) printf 'observer-log-shipper\n'; exit 0;;
  *" ps --all -q observer-controller"*) printf 'observer-controller\n'; exit 0;;
  *" ps --all -q health-probe"*)
    case "$*" in
      *"-p app-aichorouter "*|*"-p app-cpapi "*|*"-p app-cursorapi "*|*"-p app-pigeon "*)
        printf 'health-probe\n'
        exit 0
        ;;
      *)
        printf 'health-probe queried through wrong Compose project: %s\n' "$*" >&2
        exit 1
        ;;
    esac
    ;;
  *" ps --all -q"*)
    case "$*" in
      *"/caddy.yml"*) printf 'caddy\n';;
      *"/woodpecker-controller.yml"*) printf 'woodpecker-server\n';;
      *"/woodpecker-deployer.yml"*) printf 'woodpecker-deployer\n';;
      *"/woodpecker-worker.yml"*) printf 'woodpecker-agent\n';;
      *"/beszel-controller.yml"*) printf 'beszel-hub\n';;
      *"/beszel-worker.yml"*) printf 'beszel-socket-proxy\nbeszel-agent\n';;
      *"/observer-controller.yml"*) printf 'observer-controller\nobserver-health-probe\n';;
      *"/observer-collector.yml"*) printf 'observer-log-proxy\nobserver-log-shipper\nobserver-log-heartbeat\n';;
    esac
    ;;
esac
case "$*" in
  *app-librechat*) printf 'librechat-api\nlibrechat-admin-panel\nlibrechat-client\n';;
  *app-newapi*) printf 'newapi\n';;
  *app-cpapi*) printf 'cpapi\nhealth-probe\n';;
  *app-aichorouter*) printf 'aichorouter\nhealth-probe\n';;
  *app-cursorapi*) printf 'cursorapi\nhealth-probe\n';;
  *app-pigeon*) printf 'pigeon\nhealth-probe\n';;
esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$*" in
  *"/api/default/_search"*)
    if [ "${OBSERVER_SMOKE_EMPTY:-0}" = 1 ]; then
      printf '%s\n' '{"total":0,"hits":[]}'
    else
      printf '%s\n' '{"total":3,"hits":[{"node_id":"leader"},{"node_id":"worker-1"},{"node_id":"worker-2"}]}'
    fi
    exit 0
    ;;
  *"observer-log-shipper:8686/graphql"*)
    printf '%s\n' '{"data":{"components":{"nodes":[{"componentId":"docker_logs","componentType":"docker_logs","metrics":{"receivedEventsTotal":{"receivedEventsTotal":12},"sentEventsTotal":{"sentEventsTotal":12}}},{"componentId":"exclude_observer_sidecars","componentType":"filter","metrics":{"receivedEventsTotal":{"receivedEventsTotal":12},"sentEventsTotal":{"sentEventsTotal":10}}},{"componentId":"add_metadata","componentType":"remap","metrics":{"receivedEventsTotal":{"receivedEventsTotal":10},"sentEventsTotal":{"sentEventsTotal":10}}},{"componentId":"openobserve","componentType":"http","metrics":{"receivedEventsTotal":{"receivedEventsTotal":10},"sentEventsTotal":{"sentEventsTotal":8},"sentBytesTotal":{"sentBytesTotal":2048}}}]}}}'
    exit 0
    ;;
  *"observer-log-proxy:2375/_ping"*)
    [ "${OBSERVER_PROXY_UNAVAILABLE:-0}" = 1 ] && exit 1
    printf 'OK\n'
    exit 0
    ;;
esac
case "$*" in
  *"inspect --format"*observer-health-probe*)
    [ "${OBSERVER_CONTROLLER_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
    ;;
  *"inspect --format"*observer-log-shipper*)
    [ "${OBSERVER_COLLECTOR_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
    ;;
esac
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
[ "${FAIL_FLOCK:-0}" = 1 ] && exit 1
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
# Smoke tests should not contact real domains or exercise production retry
# backoff. Observer's in-container curl remains covered by the docker stub.
printf '%s\n' "$*" >>"${CURL_CALL_LOG:?}"
url=''
for argument in "$@"; do url="$argument"; done
if [ -n "${CURL_FAIL_URL:-}" ] && [ "$url" = "$CURL_FAIL_URL" ]; then
  exit 22
fi
if [ -n "${CURL_BAD_BODY_URL:-}" ] && [ "$url" = "$CURL_BAD_BODY_URL" ]; then
  printf 'unexpected body\n'
  exit 0
fi
case "$url" in
  *cpapi*/healthz) printf '{"status":"ok"}\n';;
  *cursorapi*/healthz) printf 'ok\n';;
  *aichorouter*/api/status) printf '{"success":true}\n';;
  *) printf 'OK\n';;
esac
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation" CONFIG_ROOT="$tmp/config" APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.prod.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.prod.env" NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
export COMPOSE_CALL_LOG="$tmp/compose.log" DOCKER_CALL_LOG="$tmp/docker.log" CURL_CALL_LOG="$tmp/curl.log"
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
PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=0 bash "$repo_root/ops/platformctl.sh" validate
: >"$tmp/compose.log"
PLATFORM_RECREATE_FOUNDATION=1 bash "$repo_root/ops/platformctl.sh" sync foundation >/dev/null
grep -Fq -- '--force-recreate --wait' "$tmp/compose.log"

observer_validation() {
	bash "$repo_root/ops/platformctl.sh" validate-observer
}
set_observer_value() {
	local key="$1" value="$2"
	sed "s#^${key}=.*#${key}=${value}#" "$tmp/foundation/env/observer.env" >"$tmp/foundation/env/observer.env.tmp"
	mv "$tmp/foundation/env/observer.env.tmp" "$tmp/foundation/env/observer.env"
}
expect_observer_invalid() {
	local key="$1" value="$2" message="$3"
	set_observer_value "$key" "$value"
	if observer_validation >/dev/null 2>&1; then
		printf '%s\n' "$message" >&2
		exit 1
	fi
}

for retention in 1 365; do
	set_observer_value OBSERVER_DATA_RETENTION_DAYS "$retention"
	observer_validation
done
for retention in 0 -1 invalid 366; do
	expect_observer_invalid OBSERVER_DATA_RETENTION_DAYS "$retention" "invalid Observer retention was accepted: $retention"
done
set_observer_value OBSERVER_DATA_RETENTION_DAYS 30
for buffer in 1 268435487 8589934593 invalid; do
	expect_observer_invalid OBSERVER_LOG_BUFFER_MAX_BYTES "$buffer" "invalid Observer buffer size was accepted: $buffer"
done
set_observer_value OBSERVER_LOG_BUFFER_MAX_BYTES 536870912
for threads in 0 9 invalid; do
	expect_observer_invalid OBSERVER_LOG_SHIPPER_THREADS "$threads" "invalid Observer collector thread count was accepted: $threads"
done
set_observer_value OBSERVER_LOG_SHIPPER_THREADS 1
for buffer_policy in invalid drop_oldest; do
	expect_observer_invalid OBSERVER_LOG_BUFFER_WHEN_FULL "$buffer_policy" "invalid Observer buffer policy was accepted: $buffer_policy"
done
set_observer_value OBSERVER_LOG_BUFFER_WHEN_FULL block
for buffer_policy in block drop_newest; do
	set_observer_value OBSERVER_LOG_BUFFER_WHEN_FULL "$buffer_policy"
	observer_validation
done
set_observer_value OBSERVER_LOG_BUFFER_WHEN_FULL block
for heartbeat_interval in 0 59 901 invalid; do
	expect_observer_invalid OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS "$heartbeat_interval" "invalid Observer heartbeat interval was accepted: $heartbeat_interval"
done
set_observer_value OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS 300
for stream_timeout in 3599s 59m 169h 8d 0h h1 1000000s invalid; do
	expect_observer_invalid OBSERVER_LOG_PROXY_STREAM_TIMEOUT "$stream_timeout" "invalid Observer Docker stream timeout was accepted: $stream_timeout"
done
set_observer_value OBSERVER_LOG_PROXY_STREAM_TIMEOUT 24h
expect_observer_invalid OBSERVER_DURABLE_WARN_BYTES 0 'zero Observer durable warning threshold was accepted'
set_observer_value OBSERVER_DURABLE_WARN_BYTES 8589934592
expect_observer_invalid OBSERVER_LOG_BUFFER_WARN_PERCENT 101 'Observer buffer warning percentage above 100 was accepted'
set_observer_value OBSERVER_LOG_BUFFER_WARN_PERCENT 80
set_observer_value OBSERVER_INGEST_TOKEN bootstrap-pending
PLATFORM_ALLOW_OBSERVER_BOOTSTRAP=1 observer_validation
expect_observer_invalid OBSERVER_INGEST_TOKEN bootstrap-pending 'Observer bootstrap-pending token was accepted outside the bootstrap phase'
set_observer_value OBSERVER_INGEST_TOKEN o2oi_00000000000000000000000000000000
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
grep -Fq '[observer-controller-recent]' <<<"$leader_diagnose"
grep -Fq '[observer-collector-recent]' <<<"$leader_diagnose"
grep -Fq '<redacted>' <<<"$leader_diagnose"
grep -Fq 'warn_bytes=8589934592' <<<"$leader_diagnose"
grep -Fq 'warn_percent=80' <<<"$leader_diagnose"
grep -Fq '[observer-collector-status]' <<<"$leader_diagnose"
grep -Fq 'state=backlog' <<<"$leader_diagnose"
grep -Fq 'pending_events=2' <<<"$leader_diagnose"
collector_status="$(bash "$repo_root/ops/platformctl.sh" observer-collector-status 2>&1)"
grep -Fq 'source_received=12 source_sent=12' <<<"$collector_status"
grep -Fq 'sink_received=10 sink_sent=8' <<<"$collector_status"
grep -Fq 'buffer_when_full=block' <<<"$collector_status"
if OBSERVER_PROXY_UNAVAILABLE=1 bash "$repo_root/ops/platformctl.sh" observer-collector-status >/dev/null 2>&1; then
	printf 'Observer collector status accepted an unavailable socket proxy\n' >&2
	exit 1
fi
if grep -Fq 'test-observer-password' <<<"$leader_diagnose" || grep -Fq 'o2oi_' <<<"$leader_diagnose"; then
	printf 'Observer diagnostics exposed a credential\n' >&2
	exit 1
fi
smoke_success="$(FAIL_FLOCK=1 OBSERVER_SMOKE_ATTEMPTS=1 OBSERVER_SMOKE_RETRY_DELAY=0 bash "$repo_root/ops/platformctl.sh" observer-smoke 2>&1)"
grep -Fq 'attempts=1 timeout=120s' <<<"$smoke_success"
grep -Fq -- '--max-time 10' "$tmp/docker.log"
if observer_smoke_failure="$(OBSERVER_SMOKE_EMPTY=1 OBSERVER_SMOKE_ATTEMPTS=2 OBSERVER_SMOKE_RETRY_DELAY=0 \
	bash "$repo_root/ops/platformctl.sh" observer-smoke 2>&1)"; then
	printf 'Observer smoke check accepted a missing collector heartbeat\n' >&2
	exit 1
fi
grep -Fq 'attempt=1/2 reason=missing recent heartbeat nodes=leader,worker-1,worker-2 retry_in=0s' <<<"$observer_smoke_failure"
grep -Fq 'reason=missing recent heartbeat nodes=leader,worker-1,worker-2' <<<"$observer_smoke_failure"
if OBSERVER_CONTROLLER_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'Observer controller health sidecar failure was accepted\n' >&2
	exit 1
fi
if OBSERVER_COLLECTOR_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'Observer collector health sidecar failure was accepted\n' >&2
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

# A singleton target switch is a route transaction. Keep the old route and the
# previous-target marker until both the new origin and public path return the
# manifest's expected health body.
cp "$tmp/control/current/config/cluster/apps/cpapi.policy" "$tmp/cpapi-policy.original"
cp "$tmp/app/shared/runtime/config/routes.d/librechat.caddy" "$tmp/librechat-route.before-switch"
sed 's/^CPAPI_TARGET_NODE_ID=.*/CPAPI_TARGET_NODE_ID=worker-2/' "$tmp/cpapi-policy.original" >"$tmp/control/current/config/cluster/apps/cpapi.policy"
mkdir -p "$tmp/config/singleton-state"
printf 'worker-1\n' >"$tmp/config/singleton-state/cpapi.previous-target"
if CURL_BAD_BODY_URL=http://cpapi.localhost/healthz \
	bash "$repo_root/ops/platformctl.sh" singleton-switch cpapi >"$tmp/switch-failure.log" 2>&1; then
	printf 'singleton switch accepted an invalid public health body\n' >&2
	exit 1
fi
grep -Fq 'response did not match HEALTH_EXPECT' "$tmp/switch-failure.log"
grep -Fq 'restored previous Leader route for singleton cpapi' "$tmp/switch-failure.log"
grep -Fq 'reverse_proxy https://worker1-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
cmp -s "$tmp/librechat-route.before-switch" "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
[[ -f "$tmp/config/singleton-state/cpapi.previous-target" ]]
grep -qx 'PHASE=failed' "$tmp/config/singleton-state/cpapi.transition.env"
[[ ! -e "$tmp/config/singleton-state/cpapi.route-backup.caddy" ]]
[[ ! -e "$tmp/config/singleton-state/cpapi.route-was-missing" ]]

# Reboot recovery must honor the incomplete transition marker instead of
# silently regenerating the unverified worker-2 route from committed policy.
bash "$repo_root/ops/platformctl.sh" recover >/dev/null
grep -Fq 'reverse_proxy https://worker1-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
[[ -f "$tmp/config/singleton-state/cpapi.previous-target" ]]

bash "$repo_root/ops/platformctl.sh" singleton-switch cpapi
grep -Fq 'reverse_proxy https://worker2-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
cmp -s "$tmp/librechat-route.before-switch" "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
[[ ! -e "$tmp/config/singleton-state/cpapi.previous-target" ]]
grep -qx 'PHASE=switched' "$tmp/config/singleton-state/cpapi.transition.env"

cp "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy" "$tmp/config/singleton-state/cpapi.route-backup.caddy"
if output="$(bash "$repo_root/ops/platformctl.sh" singleton-switch cpapi 2>&1)"; then
	printf 'singleton switch ignored unresolved rollback state\n' >&2
	exit 1
fi
grep -Fq 'unresolved singleton route rollback exists' <<<"$output"
rm -f "$tmp/config/singleton-state/cpapi.route-backup.caddy"

# On a first deployment there may be no old route. A failed public smoke must
# remove the candidate rather than leave an unverified endpoint published.
rm -f "$tmp/app/shared/runtime/config/routes.d/cursorapi.caddy" \
	"$tmp/config/singleton-state/cursorapi.route-backup.caddy" \
	"$tmp/config/singleton-state/cursorapi.route-was-missing" \
	"$tmp/config/singleton-state/cursorapi.transition.env"
if CURL_FAIL_URL=http://cursorapi.localhost/healthz \
	bash "$repo_root/ops/platformctl.sh" singleton-switch cursorapi >/dev/null 2>&1; then
	printf 'first singleton deployment accepted a failed public smoke\n' >&2
	exit 1
fi
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/cursorapi.caddy" ]]
grep -qx 'PHASE=failed' "$tmp/config/singleton-state/cursorapi.transition.env"
[[ ! -e "$tmp/config/singleton-state/cursorapi.route-backup.caddy" ]]
[[ ! -e "$tmp/config/singleton-state/cursorapi.route-was-missing" ]]

# Restore committed placement, then prove follower reconciliation preserves the
# active-active LibreChat project while selecting singletons only on their one
# configured follower.
cp "$tmp/cpapi-policy.original" "$tmp/control/current/config/cluster/apps/cpapi.policy"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
: >"$tmp/compose.log"
bash "$repo_root/ops/platformctl.sh" sync apps >/dev/null
for project in app-librechat app-aichorouter app-cpapi app-cursorapi; do
	grep -Fq "$project" "$tmp/compose.log"
done
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/config/node.env"
: >"$tmp/compose.log"
bash "$repo_root/ops/platformctl.sh" sync apps >/dev/null
grep -Fq 'app-librechat' "$tmp/compose.log"
for project in app-aichorouter app-cpapi app-cursorapi; do
	if grep -Fq "$project" "$tmp/compose.log"; then
		printf 'worker-2 reconciled worker-1 singleton project: %s\n' "$project" >&2
		exit 1
	fi
done
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'worker1-chat-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'worker2-chat-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"

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
cp "$tmp/control/current/config/cluster/apps/cpapi.policy" "$tmp/cpapi-policy.skip-test"
sed 's/^CPAPI_TARGET_NODE_ID=.*/CPAPI_TARGET_NODE_ID=worker-2/' "$tmp/cpapi-policy.skip-test" >"$tmp/control/current/config/cluster/apps/cpapi.policy"
mkdir -p "$tmp/config/singleton-state"
printf 'worker-1\n' >"$tmp/config/singleton-state/cpapi.previous-target"
PLATFORM_SKIP_SINGLETONS=1 bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'reverse_proxy https://worker1-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
cp "$tmp/cpapi-policy.skip-test" "$tmp/control/current/config/cluster/apps/cpapi.policy"
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
