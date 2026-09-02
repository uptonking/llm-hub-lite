#!/usr/bin/env bash
# shellcheck disable=SC2154 # tmp and repo_root are initialized by platformctl-test.sh

# Public endpoint declarations are the single source for both Caddy routes and
# Compose URL variables. Reject malformed, duplicate, missing, and unused
# mappings before a release can mutate runtime state.
aichorouter_manifest="$tmp/control/current/apps/aichorouter/manifest.env"
cp "$aichorouter_manifest" "$tmp/aichorouter.manifest.original"
assert_invalid_public_endpoints() {
	local replacement="$1" expected="$2" output
	sed "s#^PUBLIC_ENDPOINTS=.*#PUBLIC_ENDPOINTS=$replacement#" "$tmp/aichorouter.manifest.original" >"$aichorouter_manifest"
	if output="$(PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_library aichorouter 1 1 0 1 2>&1)"; then
		printf 'cluster validation accepted invalid public endpoints: %s\n' "$replacement" >&2
		exit 1
	fi
	grep -Fq "$expected" <<<"$output"
}
assert_invalid_public_endpoints 'bad_key|aichorouter' 'invalid PUBLIC_ENDPOINTS'
assert_invalid_public_endpoints 'AICHOROUTER_SITE|aichorouter-' 'invalid PUBLIC_ENDPOINTS'
assert_invalid_public_endpoints 'AICHOROUTER_SITE|aichorouter;OTHER_SITE|aichorouter' 'duplicate PUBLIC_ENDPOINTS host'
assert_invalid_public_endpoints 'OTHER_SITE|aichorouter' 'ROUTE_GROUPS public key is absent from PUBLIC_ENDPOINTS'
assert_invalid_public_endpoints 'AICHOROUTER_SITE|aichorouter;OTHER_SITE|other' 'PUBLIC_ENDPOINTS key is absent from ROUTE_GROUPS'
mv "$tmp/aichorouter.manifest.original" "$aichorouter_manifest"

# Origin records are DNS-only routing identities. Reject hand-edited IP
# literals and malformed/uppercase names before Caddy can publish them.
worker_node="$tmp/control/current/config/cluster/nodes/worker-1.env"
cp "$worker_node" "$tmp/worker-1.node.original"
assert_invalid_origin_host() {
	local replacement="$1" expected="$2" output
	sed "s#^NODE_AICHOROUTER_ORIGIN_HOST=.*#NODE_AICHOROUTER_ORIGIN_HOST=$replacement#" \
		"$tmp/worker-1.node.original" >"$worker_node"
	if output="$(PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_library aichorouter 1 1 0 1 2>&1)"; then
		printf 'cluster validation accepted invalid origin hostname: %s\n' "$replacement" >&2
		exit 1
	fi
	grep -Fq "$expected" <<<"$output"
}
assert_invalid_origin_host '192.0.2.1' 'invalid origin host NODE_AICHOROUTER_ORIGIN_HOST for worker-1'
assert_invalid_origin_host 'Worker1-aichorouter-origin.example.invalid' 'invalid origin host NODE_AICHOROUTER_ORIGIN_HOST for worker-1'
mv "$tmp/worker-1.node.original" "$worker_node"

# Restic backup is enabled by default, but a node may opt out explicitly. A
# malformed value must fail control validation before the node is reconciled.
cp "$worker_node" "$tmp/worker-1.backup-policy.original"
printf 'BACKUP_ENABLED=maybe\n' >>"$worker_node"
if output="$(PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_library aichorouter 1 1 0 1 2>&1)"; then
	printf 'cluster validation accepted invalid BACKUP_ENABLED\n' >&2
	exit 1
fi
grep -Fq 'BACKUP_ENABLED must be true or false: worker-1' <<<"$output"
mv "$tmp/worker-1.backup-policy.original" "$worker_node"

# Node-local defaults are explicit, single-line values and may not overwrite
# identity or role fields used by bootstrap and workflow routing.
newapi_manifest="$tmp/control/current/apps/newapi/manifest.env"
cp "$newapi_manifest" "$tmp/newapi.manifest.original"
assert_invalid_node_defaults() {
	local replacement="$1" expected="$2" output
	sed "s#^NODE_DEFAULTS=.*#NODE_DEFAULTS=$replacement#" "$tmp/newapi.manifest.original" >"$newapi_manifest"
	if output="$(platform_validate_library newapi 1 1 0 1 2>&1)"; then
		printf 'cluster validation accepted invalid NODE_DEFAULTS: %s\n' "$replacement" >&2
		exit 1
	fi
	grep -Fq "$expected" <<<"$output"
}
assert_invalid_node_defaults 'NODE_ID|newapi' 'NODE_DEFAULTS uses a reserved key'
assert_invalid_node_defaults 'NEW_API_NODE_TYPE|slave|unexpected' 'invalid NODE_DEFAULTS entry'
mv "$tmp/newapi.manifest.original" "$newapi_manifest"

# LibreChat backup ownership is committed alongside placement. Invalid booleans
# and owners outside NODES must fail validation before deployment mutates the
# running release.
librechat_policy="$tmp/control/current/config/cluster/apps/librechat.policy"
cp "$librechat_policy" "$tmp/librechat.policy.original"
assert_invalid_librechat_policy() {
	local expression="$1" expected="$2" output
	sed -E "$expression" "$tmp/librechat.policy.original" >"$librechat_policy"
	if output="$(platform_validate_library librechat 1 1 0 1 2>&1)"; then
		printf 'cluster validation accepted invalid LibreChat backup policy\n' >&2
		exit 1
	fi
	grep -Fq "$expected" <<<"$output"
}
assert_invalid_librechat_policy \
	's/^MONGO_BACKUP_ENABLED=.*/MONGO_BACKUP_ENABLED=perhaps/' \
	'LibreChat MONGO_BACKUP_ENABLED must be true or false'
assert_invalid_librechat_policy \
	's/^MONGO_BACKUP_NODE_ID=.*/MONGO_BACKUP_NODE_ID=leader/' \
	'LibreChat MONGO_BACKUP_NODE_ID is absent from NODES'
mv "$tmp/librechat.policy.original" "$librechat_policy"

# A draining follower can remain in inventory while work is evacuated, but the
# node that owns routing and the control plane must always be active.
cp "$tmp/control/current/config/cluster/nodes/leader.env" "$tmp/leader.env.original"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$tmp/leader.env.original" >"$tmp/control/current/config/cluster/nodes/leader.env"
if output="$(PLATFORM_TEST_FAST_VALIDATE=0 PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_fast 2>&1)"; then
	printf 'cluster validation accepted a draining Leader\n' >&2
	exit 1
fi
grep -Fq 'designated Leader node must be active: leader' <<<"$output"
mv "$tmp/leader.env.original" "$tmp/control/current/config/cluster/nodes/leader.env"

# The render shortcut is test-only and must never be accepted in production
# validation mode.
if output="$(PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=0 PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_SKIP_RENDER=1 bash "$repo_root/ops/platformctl.sh" validate 2>&1)"; then
	printf 'validation accepted PLATFORM_TEST_SKIP_RENDER without external-validation test mode\n' >&2
	exit 1
fi
grep -Fq 'PLATFORM_TEST_SKIP_RENDER requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1' <<<"$output"
if output="$(PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=0 PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_TEST_FAST_VALIDATE=1 bash "$repo_root/ops/platformctl.sh" validate 2>&1)"; then
	printf 'validation accepted PLATFORM_TEST_FAST_VALIDATE without external-validation test mode\n' >&2
	exit 1
fi
grep -Fq 'PLATFORM_TEST_FAST_VALIDATE requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1' <<<"$output"
if output="$(PLATFORMCTL_LIBRARY=1 PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=0 PLATFORM_TEST_SKIP_SYNC_VALIDATION=0 PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_TEST_FAST_VALIDATE=0 PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 bash "$repo_root/ops/platformctl.sh" status 2>&1)"; then
	printf 'platformctl library mode was accepted outside test validation mode\n' >&2
	exit 1
fi
grep -Fq 'PLATFORMCTL_LIBRARY requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1' <<<"$output"
if output="$(PLATFORM_TEST_MODE=0 PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1 PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 bash "$repo_root/ops/platformctl.sh" status 2>&1)"; then
	printf 'external validation skip was accepted outside explicit test mode\n' >&2
	exit 1
fi
grep -Fq 'test-only validation controls require PLATFORM_TEST_MODE=1' <<<"$output"

# Caddy is the mandatory ingress substrate on every node. Removing or
# weakening its manifest must invalidate the release instead of silently
# producing a platform with no ingress owner.
cp "$tmp/foundation/manifests/caddy.env" "$tmp/caddy.env.original"
sed 's/^MANDATORY=.*/MANDATORY=false/' "$tmp/caddy.env.original" >"$tmp/foundation/manifests/caddy.env"
if output="$(PLATFORM_TEST_FAST_VALIDATE=0 PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_fast 2>&1)"; then
	printf 'foundation validation accepted a non-mandatory Caddy manifest\n' >&2
	exit 1
fi
grep -Fq 'Caddy foundation manifest must declare MANDATORY=true' <<<"$output"
mv "$tmp/caddy.env.original" "$tmp/foundation/manifests/caddy.env"

: >"$tmp/compose.log"
PLATFORM_RECREATE_FOUNDATION=1 bash "$repo_root/ops/platformctl.sh" sync foundation >/dev/null
grep -Fq -- '--force-recreate --wait' "$tmp/compose.log"
# The first sync above proves the production path validates before mutation.
# Later sync cases exercise reconciliation branches against the same fixture;
# avoid repeating the complete validator for each mocked Compose call.
export PLATFORM_TEST_SKIP_SYNC_VALIDATION=1

observer_validation() {
	(validate_observer_env)
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
platform_validate_library observer 0 1 1 1
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
# The smoke implementation takes a short read lock for its local snapshot and
# releases it before network retries. This fixture already runs with the
# deployment lock logically held, so bypass the mocked flock binary here and
# exercise the query/heartbeat behavior itself.
smoke_success="$(PLATFORM_LOCK_HELD=1 FAIL_FLOCK=1 OBSERVER_SMOKE_ATTEMPTS=1 OBSERVER_SMOKE_RETRY_DELAY=0 bash "$repo_root/ops/platformctl.sh" observer-smoke 2>&1)"
grep -Fq 'attempts=1 timeout=120s' <<<"$smoke_success"
grep -Fq -- '--max-time 10' "$tmp/docker.log"
# Observer ingestion only expects heartbeats from nodes that are active and
# eligible for the collector component. Joining, draining, and retired nodes
# remain in inventory for lifecycle work, but must not make the smoke fail.
cp "$tmp/control/current/config/cluster/nodes/worker-1.env" "$tmp/worker-1.state-original"
cp "$tmp/control/current/config/cluster/nodes/worker-2.env" "$tmp/worker-2.state-original"
sed 's/^NODE_STATE=.*/NODE_STATE=joining/' "$tmp/worker-1.state-original" >"$tmp/control/current/config/cluster/nodes/worker-1.env"
sed 's/^NODE_STATE=.*/NODE_STATE=retired/' "$tmp/worker-2.state-original" >"$tmp/control/current/config/cluster/nodes/worker-2.env"
observer_filtered="$(PLATFORM_LOCK_HELD=1 FAIL_FLOCK=1 OBSERVER_SMOKE_ATTEMPTS=1 OBSERVER_SMOKE_RETRY_DELAY=0 bash "$repo_root/ops/platformctl.sh" observer-smoke 2>&1)"
grep -Fq 'expected_nodes=leader' <<<"$observer_filtered"
grep -Fq 'nodes=leader' <<<"$observer_filtered"
mv "$tmp/worker-1.state-original" "$tmp/control/current/config/cluster/nodes/worker-1.env"
mv "$tmp/worker-2.state-original" "$tmp/control/current/config/cluster/nodes/worker-2.env"
# Route validation must reject an inactive upstream instead of silently
# publishing an endpoint that points at a node being drained.
cp "$tmp/control/current/config/cluster/nodes/worker-2.env" "$tmp/worker-2.state-original"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$tmp/worker-2.state-original" >"$tmp/control/current/config/cluster/nodes/worker-2.env"
if output="$(platform_validate_fast 2>&1)"; then
	printf 'route validation accepted an inactive consumer upstream\n' >&2
	exit 1
fi
grep -Fq 'consumer app target is not active: worker-2' <<<"$output"
mv "$tmp/worker-2.state-original" "$tmp/control/current/config/cluster/nodes/worker-2.env"
# Leader-side origin smoke skips inactive origins, but must fail closed when no
# eligible active follower remains to check.
cp "$tmp/control/current/config/cluster/nodes/worker-1.env" "$tmp/worker-1.state-original"
cp "$tmp/control/current/config/cluster/nodes/worker-2.env" "$tmp/worker-2.state-original"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$tmp/worker-2.state-original" >"$tmp/control/current/config/cluster/nodes/worker-2.env"
consumer_partial="$(bash "$repo_root/ops/platformctl.sh" consumer-origin-smoke librechat 2>&1)"
grep -Fq 'skipping inactive or non-follower target librechat/worker-2' <<<"$consumer_partial"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$tmp/worker-1.state-original" >"$tmp/control/current/config/cluster/nodes/worker-1.env"
if output="$(bash "$repo_root/ops/platformctl.sh" consumer-origin-smoke librechat 2>&1)"; then
	printf 'origin smoke accepted a placement with no eligible active origins\n' >&2
	exit 1
fi
grep -Fq 'consumer has no origins to check: librechat' <<<"$output"
mv "$tmp/worker-1.state-original" "$tmp/control/current/config/cluster/nodes/worker-1.env"
mv "$tmp/worker-2.state-original" "$tmp/control/current/config/cluster/nodes/worker-2.env"
if observer_smoke_failure="$(OBSERVER_SMOKE_EMPTY=1 OBSERVER_SMOKE_ATTEMPTS=2 OBSERVER_SMOKE_RETRY_DELAY=0 \
	bash "$repo_root/ops/platformctl.sh" observer-smoke 2>&1)"; then
	printf 'Observer smoke check accepted a missing collector heartbeat\n' >&2
	exit 1
fi
grep -Fq 'attempt=1/2 reason=missing recent heartbeat nodes=leader,worker-1,worker-2,worker-3,worker-4 retry_in=0s' <<<"$observer_smoke_failure"
grep -Fq 'reason=missing recent heartbeat nodes=leader,worker-1,worker-2,worker-3,worker-4' <<<"$observer_smoke_failure"
if OBSERVER_CONTROLLER_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'Observer controller health sidecar failure was accepted\n' >&2
	exit 1
fi
if OBSERVER_COLLECTOR_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'Observer collector health sidecar failure was accepted\n' >&2
	exit 1
fi
# A fresh follower has no Beszel enrollment credentials yet. Its socket proxy
# is the only readiness target until the Leader provisions both files; an
# unhealthy agent must not block that bootstrap window. Once enrolled, the
# agent healthcheck is mandatory again.
cp "$tmp/config/node.env" "$tmp/node.env.before-beszel-enrollment"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
sed -e "s#^BESZEL_KEY_FILE=.*#BESZEL_KEY_FILE=$tmp/missing-beszel-key#" \
	-e "s#^BESZEL_TOKEN_FILE=.*#BESZEL_TOKEN_FILE=$tmp/missing-beszel-token#" \
	"$tmp/foundation/env/beszel.env" >"$tmp/foundation/env/beszel.env.tmp"
mv "$tmp/foundation/env/beszel.env.tmp" "$tmp/foundation/env/beszel.env"
if ! BESZEL_AGENT_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'unenrolled Beszel worker was blocked by agent health\n' >&2
	exit 1
fi
printf 'enrolled-key\n' >"$tmp/missing-beszel-key"
printf 'enrolled-token\n' >"$tmp/missing-beszel-token"
if BESZEL_AGENT_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" health >/dev/null 2>&1; then
	printf 'enrolled Beszel worker ignored agent health failure\n' >&2
	exit 1
fi
cp "$tmp/node.env.before-beszel-enrollment" "$tmp/config/node.env"
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
printf 'retired generated endpoint metadata\n' >"$tmp/app/shared/runtime/app-env/retired-app.env"
PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_ONLY_DESCRIPTOR=cpapi PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_ONLY_APP_ID=cpapi PLATFORM_ONLY_ROUTE_APP_ID=cpapi bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'app-cpapi' "$tmp/compose.log"
grep -Fxq 'CPAPI_SITE=http://cpapi.localhost' "$tmp/app/shared/runtime/app-env/cpapi.env"
grep -Fq -- "--env-file $tmp/app/shared/runtime/app-env/cpapi.env" "$tmp/compose.log"
[[ ! -e "$tmp/app/shared/runtime/app-env/retired-app.env" ]]
if grep -Fq 'app-librechat' "$tmp/compose.log"; then
	printf 'singleton app scope reconciled an unrelated consumer\n' >&2
	exit 1
fi

# A truly stateless singleton has neither a root-only runtime env file nor a
# persistent data directory, but its selected-node Compose project must still
# be fully evaluated and its move transaction must still be journaled.
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/config/node.env"
: >"$tmp/compose.log"
PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_ONLY_DESCRIPTOR=wapdf PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_ONLY_APP_ID=wapdf PLATFORM_ONLY_ROUTE_APP_ID=wapdf bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'app-wapdf' "$tmp/compose.log"
if grep -Fq "$tmp/config/wapdf.env" "$tmp/compose.log"; then
	printf 'stateless Wapdf Compose unexpectedly used a runtime env file\n' >&2
	exit 1
fi
[[ ! -e "$tmp/config/wapdf.env" ]]
rm -rf -- "$tmp/app/shared/data/prod/wapdf"
mkdir -p "$tmp/config/singleton-state"
printf 'worker-1\n' >"$tmp/config/singleton-state/wapdf.previous-target"
SINGLETON_RELEASE_SHA=wapdf-test bash "$repo_root/ops/platformctl.sh" singleton-prepare wapdf
grep -qx 'PHASE=prepared' "$tmp/config/singleton-state/wapdf.transition.env"
grep -qx 'ARCHIVE_PATH=' "$tmp/config/singleton-state/wapdf.transition.env"
[[ ! -e "$tmp/app/shared/data/prod/wapdf" ]]
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
stop_output="$(bash "$repo_root/ops/platformctl.sh" consumer-stop wapdf)"
grep -Fq 'stopped stateless singleton wapdf; no persistent data retained' <<<"$stop_output"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
# A reviewed foundation upgrade must preserve installed singleton routes while
# withholding a brand-new singleton. It must not require the new app's runtime
# secrets or an app-image key that is not installed until singleton staging.
cp "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy" "$tmp/cpapi-route.original"
rm -f "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" "$tmp/config/pigeon.env"
sed '/^PIGEON_IMAGE=/d' "$tmp/config/images.apps.prod.env" >"$tmp/config/images.apps.prod.env.tmp"
mv "$tmp/config/images.apps.prod.env.tmp" "$tmp/config/images.apps.prod.env"
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/config/node.env"
PLATFORM_SKIP_SINGLETONS=1 platform_validate_library cpapi 0 1 0 1
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
PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=0 PLATFORM_TEST_ONLY_DESCRIPTOR=pigeon PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_ONLY_APP_ID=pigeon PLATFORM_ONLY_ROUTE_APP_ID=pigeon bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'app-pigeon' "$tmp/compose.log"
grep -Fq 'reverse_proxy pigeon:5000' "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy"
cp "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy" "$tmp/pigeon-route.original"
PLATFORM_SKIP_SINGLETONS=1 platform_validate_library pigeon 0 1 0 1
cmp -s "$tmp/pigeon-route.original" "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy"
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
platform_validate_library cpapi 0 1 0 1 '' all
cp "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy" "$tmp/cpapi-route.before-disabled-reconcile"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/pigeon.policy" >"$tmp/control/current/config/cluster/apps/pigeon.policy.tmp"
mv "$tmp/control/current/config/cluster/apps/pigeon.policy.tmp" "$tmp/control/current/config/cluster/apps/pigeon.policy"
: >"$tmp/docker.log"
EMIT_PIGEON_CONTAINER=1 PLATFORM_SKIP_SINGLETONS=1 PLATFORM_RECONCILE_DISABLED_SINGLETONS=1 \
	PLATFORM_TEST_SKIP_RENDER=0 PLATFORM_TEST_SKIP_SYNC_VALIDATION=1 PLATFORM_TEST_SKIP_COMPOSE_INSPECTION=1 \
	bash "$repo_root/ops/platformctl.sh" sync apps
assert_file_absent "$tmp/app/shared/runtime/config/routes.d/pigeon.caddy"
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

# A stale singleton transition marker must fail closed. In particular, a
# previous target may not be the Leader (or any other inactive/non-follower),
# even when the committed singleton placement itself is valid.
mkdir -p "$tmp/config/singleton-state"
printf 'leader\n' >"$tmp/config/singleton-state/cpapi.previous-target"
if output="$(platform_validate_library cpapi 0 1 0 1 2>&1)"; then
	printf 'route validation accepted an invalid singleton previous target\n' >&2
	exit 1
fi
grep -Fq 'singleton previous target is not an active follower: leader' <<<"$output"
rm -f "$tmp/config/singleton-state/cpapi.previous-target"

# A singleton target switch is a route transaction. Keep the old route and the
# previous-target marker until both the new origin and public path return the
# manifest's expected health body.
cp "$tmp/control/current/config/cluster/apps/cpapi.policy" "$tmp/cpapi-policy.original"
cp "$tmp/app/shared/runtime/config/routes.d/librechat.caddy" "$tmp/librechat-route.before-switch"
sed 's/^NODES=.*/NODES=worker-2/' "$tmp/cpapi-policy.original" >"$tmp/control/current/config/cluster/apps/cpapi.policy"
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

# Publication completes the Leader's route transaction. The final generated job
# runs on the selected target and closes that target's matching local journal.
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/config/node.env"
cat >"$tmp/config/singleton-state/cpapi.transition.env" <<'EOF'
VERSION=1
APP_ID=cpapi
OLD_TARGET=worker-1
NEW_TARGET=worker-2
RELEASE_SHA=test
ARCHIVE_PATH=
PHASE=origin-healthy
EOF
SINGLETON_FINAL_STOP=1 SINGLETON_RELEASE_SHA=test bash "$repo_root/ops/platformctl.sh" consumer-stop cpapi
grep -qx 'PHASE=completed' "$tmp/config/singleton-state/cpapi.transition.env"
grep -Eq '^COMPLETED_UTC=[0-9]{4}-' "$tmp/config/singleton-state/cpapi.transition.env"
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"

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

# Generic publication failures after route synchronization must restore the
# prior route too. Public URLs are derived from PUBLIC_ENDPOINTS and DOMAIN_NAME,
# so fail the public smoke after the generated route has been installed.
cp "$tmp/app/shared/runtime/config/routes.d/librechat.caddy" "$tmp/librechat-route.before-public-failure"
if output="$(CURL_FAIL_URL=http://chat.localhost/health bash "$repo_root/ops/platformctl.sh" consumer-publish librechat 2>&1)"; then
	printf 'consumer publication accepted a failed public smoke\n' >&2
	exit 1
fi
grep -Fq 'consumer public smoke failed: http://chat.localhost/health' <<<"$output"
cmp -s "$tmp/librechat-route.before-public-failure" "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"

# A follower that is draining cannot claim a local consumer origin is healthy;
# direct smoke invocations must enforce the same lifecycle gate as reconcile.
cp "$tmp/control/current/config/cluster/nodes/worker-1.env" "$tmp/worker-1.state-original"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$tmp/worker-1.state-original" >"$tmp/control/current/config/cluster/nodes/worker-1.env"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
if output="$(bash "$repo_root/ops/platformctl.sh" consumer-origin-smoke librechat 2>&1)"; then
	printf 'draining follower origin smoke was incorrectly accepted\n' >&2
	exit 1
fi
grep -Fq 'consumer origin smoke requires an active follower: librechat/worker-1' <<<"$output"
mv "$tmp/worker-1.state-original" "$tmp/control/current/config/cluster/nodes/worker-1.env"
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"

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
# A staged application release must force-recreate its selected project.
# Compose can otherwise miss inline configs.content changes and report an old
# container as healthy without applying the new configuration.
: >"$tmp/compose.log"
PLATFORM_RECREATE_APPS=1 PLATFORM_ONLY_APP_ID=cpapi bash "$repo_root/ops/platformctl.sh" sync apps >/dev/null
grep -Fq 'app-cpapi' "$tmp/compose.log"
grep -Fq -- '--force-recreate --wait' "$tmp/compose.log"
for project in app-librechat app-aichorouter app-cursorapi; do
	if grep -Fq "$project" "$tmp/compose.log"; then
		printf 'focused application recreate touched unrelated project: %s\n' "$project" >&2
		exit 1
	fi
done
# A consumer that remains unhealthy after startup must make recovery fail so
# systemd's OnFailure retry path can run. Foundation startup remains complete.
if CONSUMER_UNHEALTHY=1 bash "$repo_root/ops/platformctl.sh" recover >/dev/null 2>&1; then
	printf 'consumer recovery failure was incorrectly reported as success\n' >&2
	exit 1
fi
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

# Direct/orphan smoke requires a public wildcard mapping, not merely the
# expected port number. Verify both the successful and loopback-only cases.
mkdir -p "$tmp/config/runtime/verge" "$tmp/app/current/apps/verge"
printf 'runtime: test\n' >"$tmp/config/runtime/verge/config.yaml"
cp "$repo_root/config/cluster/nodes/worker-4.env" "$tmp/config/node.env"
bash "$repo_root/ops/platformctl.sh" direct-smoke verge >/dev/null
if DIRECT_PORT_BIND='127.0.0.1:443' bash "$repo_root/ops/platformctl.sh" direct-smoke verge >/dev/null 2>&1; then
	printf 'direct smoke accepted a loopback-only listener\n' >&2
	exit 1
fi
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
# The final Leader render below covers both active-active upstreams. Avoid a
# duplicate render here; the preceding worker sync assertions already prove
# node-local placement and health behavior.

bash "$repo_root/ops/platformctl.sh" status --json | jq -e '.node == "leader" and .role == "leader"' >/dev/null
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
platform_validate_library newapi 0 1 0 1
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
if PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_fast >/dev/null 2>&1; then
	printf 'production LibreChat placeholder was accepted\n' >&2
	exit 1
fi
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
platform_validate_library librechat 0 1 0 1
grep -Fq 'librechat-client:80' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
bash "$repo_root/ops/platformctl.sh" smoke "app:$tmp/control/current/apps/librechat"
# Re-establish the Leader's installed route before simulating a target-policy
# change. Earlier checks intentionally reuse this fixture as a Follower and
# therefore replace its staged Caddy route with the Follower template.
cp "$repo_root/config/cluster/nodes/leader.env" "$tmp/config/node.env"
platform_validate_library librechat 0 1 0 1 '' all
grep -Fq 'worker1-chat-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'worker2-chat-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
cp "$tmp/control/current/config/cluster/apps/cpapi.policy" "$tmp/cpapi-policy.skip-test"
sed 's/^NODES=.*/NODES=worker-2/' "$tmp/cpapi-policy.skip-test" >"$tmp/control/current/config/cluster/apps/cpapi.policy"
mkdir -p "$tmp/config/singleton-state"
printf 'worker-1\n' >"$tmp/config/singleton-state/cpapi.previous-target"
PLATFORM_SKIP_SINGLETONS=1 platform_validate_library cpapi 0 1 0 1
grep -Fq 'reverse_proxy https://worker1-cpapi-origin.aichorage.de' "$tmp/app/shared/runtime/config/routes.d/cpapi.caddy"
cp "$tmp/cpapi-policy.skip-test" "$tmp/control/current/config/cluster/apps/cpapi.policy"
newapi_policy_backup="$tmp/newapi-policy.original"
cp "$tmp/control/current/config/cluster/apps/newapi.policy" "$newapi_policy_backup"
sed -E '/^(NEW_API_MIGRATION_NODE_ID|NEW_API_BACKUP_NODE_ID)=/d' "$newapi_policy_backup" \
	>"$tmp/control/current/config/cluster/apps/newapi.policy"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
sed 's/^ENABLED=.*/ENABLED=false/' "$tmp/control/current/config/cluster/apps/cpapi.policy" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/apps/cpapi.policy"
if ! validation_output="$(platform_validate_library '' 0 1 0 1 2>&1)"; then
	printf '%s\n' "$validation_output" >&2
	exit 1
fi
mv "$newapi_policy_backup" "$tmp/control/current/config/cluster/apps/newapi.policy"
awk -F= '{if ($1 == "NODE_ID") print "NODE_ID=rogue"; else print}' "$tmp/config/node.env" >"$tmp/node.tmp"
mv "$tmp/node.tmp" "$tmp/config/node.env"
if PLATFORM_TEST_SKIP_CLUSTER_VALIDATION=0 platform_validate_fast >/dev/null 2>&1; then
	printf 'runtime node identity mismatch was accepted\n' >&2
	exit 1
fi
printf 'platformctl tests passed\n'
