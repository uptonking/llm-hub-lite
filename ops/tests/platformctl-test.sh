#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034 # dynamically sourced fixture; values are read by sourced platformctl code
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/ops/tests/test-helpers.sh"
lock_key="${repo_root//[^A-Za-z0-9]/_}"
test_lock_dir="${TMPDIR:-/tmp}/llm-hub-lite-${lock_key}-platformctl-test.lock"
acquire_test_lock() {
	local owner
	if mkdir "$test_lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"$test_lock_dir/pid"
		return
	fi
	owner="$(cat "$test_lock_dir/pid" 2>/dev/null || true)"
	if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
		printf 'platformctl test is already running (pid %s); refusing a concurrent run\n' "$owner" >&2
		exit 2
	fi
	rm -f -- "$test_lock_dir/pid" 2>/dev/null || true
	rmdir "$test_lock_dir" 2>/dev/null || {
		printf 'unable to clear stale platformctl test lock: %s\n' "$test_lock_dir" >&2
		exit 2
	}
	mkdir "$test_lock_dir" || {
		printf 'unable to acquire platformctl test lock: %s\n' "$test_lock_dir" >&2
		exit 2
	}
	printf '%s\n' "$$" >"$test_lock_dir/pid"
}
release_test_lock() {
	rm -f -- "$test_lock_dir/pid" 2>/dev/null || true
	rmdir "$test_lock_dir" 2>/dev/null || true
}
acquire_test_lock
tmp="$(mktemp -d)"
cleanup() {
	rm -rf -- "$tmp"
	[[ -z "${DESCRIPTOR_CACHE_DIR:-}" ]] || rm -rf -- "$DESCRIPTOR_CACHE_DIR"
	release_test_lock
}
interrupted() {
	trap - EXIT HUP INT TERM
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
export PLATFORM_TEST_MODE=1
export PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1
# Keep Compose service discovery enabled for the initial strict validation;
# matrix cases switch this on only after that coverage has passed.
export PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0
mkdir -p "$tmp/control/releases/test" "$tmp/foundation/env" "$tmp/foundation/manifests" "$tmp/app/shared" "$tmp/config" "$tmp/bin" "$tmp/locks"
cp -a "$repo_root/apps" "$repo_root/config" "$tmp/control/releases/test/"
ln -s "$tmp/control/releases/test" "$tmp/control/current"
ln -s "$tmp/control/releases/test" "$tmp/app/current"
for f in "$repo_root"/compose/foundation/*.yml; do cp "$f" "$tmp/foundation/"; done
cp "$repo_root"/compose/foundation/manifests/*.env "$tmp/foundation/manifests/"
for source in "$repo_root"/ops/foundation/*.env.example; do
	cp "$source" "$tmp/foundation/env/$(basename "$source" .example)"
done
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
cat >"$tmp/config/aichor.env" <<'EOF'
AICHOR_PASSWORD=test-aichor-password-0123456789abcdef
EOF
cat >"$tmp/config/cursorapi.env" <<'EOF'
CURSORAPI_CURSOR_API_KEY=test-cursor-account-key
CURSORAPI_BRIDGE_API_KEY=test-cursor-bridge-key-0123456789abcdef
EOF
cat >"$tmp/config/pigeon.env" <<'EOF'
PIGEON_SECRET_KEY=0123456789abcdef0123456789abcdef
PIGEON_LOGIN_PASSWORD=test-pigeon-password
EOF
cat >"$tmp/config/verge.env" <<'EOF'
VERGE_AUTH_PASSWORD=0123456789abcdef0123456789abcdef
VERGE_CLOUDFLARE_API_TOKEN=test-cloudflare-token-0123456789
EOF
cat >"$tmp/config/node.env" <<EOF
NODE_ID=leader
LEADER_PUBLIC_IP=192.0.2.10
NODE_NEW_API_ORIGIN_HOST=worker2-newapi.example.invalid
NODE_CPAPI_ORIGIN_HOST=worker2-cpapi.example.invalid
NODE_LIBRECHAT_ORIGIN_HOST=worker2-chat.example.invalid
NODE_LIBRECHAT_ADMIN_ORIGIN_HOST=worker2-chat-admin.example.invalid
NODE_AICHOROUTER_ORIGIN_HOST=worker2-aichorouter.example.invalid
NODE_AICHOR_ORIGIN_HOST=worker2-aichor.example.invalid
NODE_CURSORAPI_ORIGIN_HOST=worker2-cursorapi.example.invalid
NODE_PIGEON_ORIGIN_HOST=worker2-pigeon.example.invalid
NODE_WAPDF_ORIGIN_HOST=worker2-wapdf.example.invalid
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in
  *" exec -T caddy wget "*) printf '%s\n' '{"status":"ok"}'; exit 0;;
  *"-p app-verge "*" ps --status running --services"*) printf 'verge\n'; exit 0;;
  *"-p app-verge "*" ps -q verge"*) printf 'verge-container\n'; exit 0;;
  *"-p app-verge "*" port --protocol udp verge 443"*) printf '%s\n' "${DIRECT_PORT_BIND:-0.0.0.0:443}"; exit 0;;
  *" ps --all -q observer-log-shipper"*) printf 'observer-log-shipper\n'; exit 0;;
  *" ps --all -q observer-controller"*) printf 'observer-controller\n'; exit 0;;
  *" ps --all -q beszel-socket-proxy"*) printf 'beszel-socket-proxy\n'; exit 0;;
  *" ps --all -q health-probe"*)
    case "$*" in
      *"-p app-aichor "*|*"-p app-aichorouter "*|*"-p app-cpapi "*|*"-p app-cursorapi "*|*"-p app-pigeon "*|*"-p app-wapdf "*)
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
  *app-aichor*) printf 'aichor\n';;
  *app-cursorapi*) printf 'cursorapi\nhealth-probe\n';;
  *app-pigeon*) printf 'pigeon\nhealth-probe\n';;
  *app-wapdf*) printf 'wapdf\nhealth-probe\n';;
  *app-verge*) printf 'verge\n';;
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
      printf '%s\n' '{"total":5,"hits":[{"node_id":"leader"},{"node_id":"worker-1"},{"node_id":"worker-2"},{"node_id":"worker-3"},{"node_id":"worker-4"}]}'
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
  *"inspect --format"*aichorouter*)
    [ "${CONSUMER_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
    ;;
  *"inspect --format"*observer-health-probe*)
    [ "${OBSERVER_CONTROLLER_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
    ;;
  *"inspect --format"*observer-log-shipper*)
    [ "${OBSERVER_COLLECTOR_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
    ;;
  *"inspect --format"*beszel-agent*)
    [ "${BESZEL_AGENT_UNHEALTHY:-0}" = 1 ] && printf 'running unhealthy\n' && exit 0
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
  *wapdf*/) printf 'BentoPDF - Free Online PDF Tools\n';;
  *) printf 'OK\n';;
esac
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation" FOUNDATION_MANIFEST_ROOT="$tmp/foundation/manifests" CONFIG_ROOT="$tmp/config" APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.prod.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.prod.env" NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
export COMPOSE_CALL_LOG="$tmp/compose.log" DOCKER_CALL_LOG="$tmp/docker.log" CURL_CALL_LOG="$tmp/curl.log"
install_test_node() {
	cp "$repo_root/config/cluster/nodes/$1.env" "$tmp/config/node.env"
	printf 'LEADER_PUBLIC_IP=192.0.2.10\n' >>"$tmp/config/node.env"
}
# Keep the singleton transition fixture independent of any operator or CI
# environment variable that may already be set when this test is launched.
export SINGLETON_STATE_ROOT="$tmp/config/singleton-state"
foundation_env_function="$(sed -n '/^env_value() {/,/^}/p; /^foundation_manifest_file() {/,/^}/p; /^foundation_manifest_value() {/,/^}/p; /^foundation_env() {/,/^}/p' "$repo_root/ops/platformctl.sh")"
foundation_env_result="$(FOUNDATION_ENV_FUNCTION="$foundation_env_function" FOUNDATION_ENV_ROOT=/foundation FOUNDATION_MANIFEST_ROOT="$tmp/foundation/manifests" bash -c '
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
[[ -s "$tmp/config/validation.stamp" ]] || {
	printf 'successful validation did not write a validation stamp\n' >&2
	exit 1
}
grep -q '^SCHEMA=1$' "$tmp/config/validation.stamp"
grep -q '^RELEASE_SHA=test$' "$tmp/config/validation.stamp"
grep -Fq 'trusted_proxies static 192.0.2.10 ' "$tmp/app/shared/runtime/config/Caddyfile"
grep -Fq 'header_up CF-Connecting-IP {client_ip}' "$tmp/app/shared/runtime/config/Caddyfile"
grep -Fq 'header_up X-Forwarded-For {client_ip}' "$tmp/app/shared/runtime/config/Caddyfile"
grep -Fq 'header_up X-Real-IP {client_ip}' "$tmp/app/shared/runtime/config/Caddyfile"
grep -Fq 'import forward_verified_client_ip' "$tmp/app/shared/runtime/config/routes.d/aichorouter.caddy"
cp "$tmp/config/node.env" "$tmp/node.env.valid"
sed 's/^LEADER_PUBLIC_IP=.*/LEADER_PUBLIC_IP=999.0.2.10/' "$tmp/node.env.valid" >"$tmp/config/node.env"
if invalid_output="$(PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1 PLATFORM_TEST_SKIP_RENDER=1 bash "$repo_root/ops/platformctl.sh" validate 2>&1)"; then
	printf 'platformctl accepted an invalid runtime Leader address\n' >&2
	exit 1
fi
grep -Fq 'runtime LEADER_PUBLIC_IP must be a valid IPv4 address' <<<"$invalid_output"
mv "$tmp/node.env.valid" "$tmp/config/node.env"
# All subsequent cases use the same fixture and mocked Compose implementation.
# Avoid repeating the per-app `config --services` subprocess while retaining
# the strict pass above as the contract test for descriptor/service wiring.
export PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=1
# Most matrix cases assert policy and lifecycle behavior, not regenerated
# routes. Keep route rendering enabled only for the focused route assertions
# below; this avoids repeatedly rebuilding the same Caddy candidate on macOS.
export PLATFORM_TEST_SKIP_RENDER=1
export PLATFORM_TEST_FAST_VALIDATE=1
export PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=1
# Load platformctl's functions once for the repeated Observer environment
# matrix. Each validation still runs in a subshell (so `die` cannot terminate
# this harness), but avoids reparsing a 2,000-line script for every value on
# macOS. The production entrypoint remains unchanged because this mode is
# explicitly library-only and never dispatches a command.
PLATFORMCTL_LIBRARY=1 source "$repo_root/ops/platformctl.sh"
unset PLATFORMCTL_LIBRARY
trap cleanup EXIT
trap interrupted HUP INT TERM

# A reboot recovery with unchanged inputs should use the stamp and skip the
# external Compose/Caddy validation phase. Test the exact reuse path directly;
# invoking a complete recovery here would repeat the expensive lifecycle
# matrix below and make the regression test needlessly slow on macOS.
if ! validation_stamp_matches; then
	printf 'validation stamp did not match unchanged fixture\n' >&2
	exit 1
fi
: >"$tmp/compose.log"
PLATFORM_RECOVERY_STAMP_MATCH=1 VALIDATE_SKIP_EXTERNAL=1 VALIDATE_STAGE_ONLY=1 \
	PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1 validate
if grep -Fq ' config --quiet' "$tmp/compose.log"; then
	printf 'matching validation stamp did not skip external Compose validation\n' >&2
	exit 1
fi

# Caddy's optional UDP listener is reconciled from the live node role on every
# sync/recovery, so a node moved between Leader and follower roles cannot retain
# a stale public bind from an earlier bootstrap.
reconcile_caddy_udp_policy
grep -qx 'CADDY_HTTPS_UDP_BIND=0.0.0.0' "$tmp/foundation/env/caddy.env"
grep -qx 'CADDY_HTTPS_UDP_HOST_PORT=443' "$tmp/foundation/env/caddy.env"
install_test_node worker-1
reconcile_caddy_udp_policy
grep -qx 'CADDY_HTTPS_UDP_BIND=127.0.0.1' "$tmp/foundation/env/caddy.env"
grep -qx 'CADDY_HTTPS_UDP_HOST_PORT=8443' "$tmp/foundation/env/caddy.env"
install_test_node leader
reconcile_caddy_udp_policy

# Validation-only matrix cases can share the controller functions loaded above.
# Keep an EXIT trap inside the subshell because a failed render would otherwise
# leave its private staging directory behind. Do not call platformctl's full
# cleanup_candidate here: it also removes the shared descriptor cache, while
# each command substitution intentionally has its own shell state.
cleanup_validation_candidate() {
	local candidate="${RUNTIME_CONFIG_CANDIDATE:-}"
	if [[ -n "$candidate" && "$candidate" == "$RUNTIME_ROOT"/.config.staging.* && -d "$candidate" ]]; then
		rm -rf -- "$candidate"
	fi
}
platform_validate_library() {
	local descriptor="$1" render="$2" external="$3" compose_inspect="$4" fast="$5" only_app="${6:-}" route_app
	route_app="${7-$descriptor}"
	# shellcheck disable=SC2030 # assignments are intentional within the subshell below
	(
		PLATFORM_TEST_ONLY_DESCRIPTOR="$descriptor"
		# Focused descriptor cases only assert that application's generated route.
		# The initial unscoped validation and the final route assertions cover the
		# complete consumer matrix; avoiding unrelated route rendering keeps this
		# Bash 3.2 fixture bounded on macOS without changing production behavior.
		if [[ "$route_app" == all ]]; then
			PLATFORM_ONLY_ROUTE_APP_ID=''
		else
			PLATFORM_ONLY_ROUTE_APP_ID="$route_app"
		fi
		PLATFORM_TEST_SKIP_RENDER="$render"
		PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION="$external"
		PLATFORM_TEST_SKIP_COMPOSE_INSPECTION="$compose_inspect"
		PLATFORM_TEST_FAST_VALIDATE="$fast"
		PLATFORM_ONLY_APP_ID="$only_app"
		# The helper is frequently called from an `if output=$(...)` assertion.
		# Bash suppresses inherited errexit in that context, including inside nested
		# command substitutions used by render_template. Re-enable it explicitly so
		# validation failures cannot be converted into a false success.
		set -Eeuo pipefail
		trap cleanup_validation_candidate EXIT
		validate
	)
}
# shellcheck disable=SC2031 # reads env set inside the subshell above; defaults keep it safe
platform_validate_fast() {
	platform_validate_library "${PLATFORM_TEST_ONLY_DESCRIPTOR:-}" 1 \
		"${PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION:-1}" \
		"${PLATFORM_TEST_SKIP_COMPOSE_INSPECTION:-1}" \
		"${PLATFORM_TEST_FAST_VALIDATE:-1}" "${PLATFORM_ONLY_APP_ID:-}"
}

# Keep the fixture setup and case matrix independently readable and below the
# repository's 700-line maintenance limit.
# shellcheck disable=SC1091
source "$repo_root/ops/tests/platformctl-cases.sh"
