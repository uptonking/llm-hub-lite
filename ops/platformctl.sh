#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2155
set -Eeuo pipefail
umask 077

# Keep recursive platformctl operations pointed at this file even when the
# command is sourced by a test harness. In that case $0 belongs to the caller
# (for example ops/tests/platformctl-test.sh), and using it would recurse into
# the harness instead of dispatching the requested operation.
PLATFORMCTL_SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
APPS_ROOT="${APPS_ROOT:-$APP_ROOT/current/apps}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
FOUNDATION_MANIFEST_ROOT="${FOUNDATION_MANIFEST_ROOT:-$CONTROL_ROOT/current/compose/foundation/manifests}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
APP_IMAGE_ENV="${APP_IMAGE_ENV:-/etc/llm-hub-lite/images.apps.env}"
FOUNDATION_IMAGE_ENV="${FOUNDATION_IMAGE_ENV:-/etc/llm-hub-lite/images.foundation.env}"
FOUNDATION_ENV_ROOT="${FOUNDATION_ENV_ROOT:-$FOUNDATION_ROOT/env}"
RUNTIME_ROOT="${RUNTIME_ROOT:-$APP_ROOT/shared/runtime}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
SINGLETON_STATE_ROOT="${SINGLETON_STATE_ROOT:-$CONFIG_ROOT/singleton-state}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
VALIDATION_STAMP_FILE="${PLATFORM_VALIDATION_STAMP_FILE:-$CONFIG_ROOT/validation.stamp}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-180}"
PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION="${PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION:-0}"
PLATFORM_TEST_MODE="${PLATFORM_TEST_MODE:-0}"
# Test fixtures may explicitly validate a candidate once and then exercise
# repeated mocked sync paths. This switch only removes that duplicate validate
# call and is rejected unless all external validation is already test-disabled.
PLATFORM_TEST_SKIP_SYNC_VALIDATION="${PLATFORM_TEST_SKIP_SYNC_VALIDATION:-0}"
# Test fixtures can also skip repeated Compose service discovery after one
# production-like validation. This is deliberately restricted to the same
# external-validation test mode so production can never omit SERVICE_NAME and
# HEALTH_SERVICE checks.
PLATFORM_TEST_SKIP_COMPOSE_INSPECTION="${PLATFORM_TEST_SKIP_COMPOSE_INSPECTION:-0}"
# Negative test cases can validate policy and secrets without materializing a
# Caddy candidate. This is deliberately restricted to the mocked test mode so
# production commands can never skip route validation or commit behavior.
PLATFORM_TEST_SKIP_RENDER="${PLATFORM_TEST_SKIP_RENDER:-0}"
PLATFORM_TEST_ONLY_DESCRIPTOR="${PLATFORM_TEST_ONLY_DESCRIPTOR:-}"
PLATFORM_TEST_FAST_VALIDATE="${PLATFORM_TEST_FAST_VALIDATE:-0}"
PLATFORM_TEST_SKIP_CLUSTER_VALIDATION="${PLATFORM_TEST_SKIP_CLUSTER_VALIDATION:-0}"
PLATFORM_FORCE_SINGLETON_ROUTE="${PLATFORM_FORCE_SINGLETON_ROUTE:-0}"
PLATFORM_ONLY_ROUTE_APP_ID="${PLATFORM_ONLY_ROUTE_APP_ID:-}"
PLATFORM_PRESERVE_CONSUMER_ROUTES="${PLATFORM_PRESERVE_CONSUMER_ROUTES:-0}"
# Keep production polling conservative while allowing local test harnesses to
# disable the extra wait after an initial health check. A zero interval means
# "check once and return"; it never creates a busy loop.
PLATFORM_WAIT_INTERVAL_SECONDS="${PLATFORM_WAIT_INTERVAL_SECONDS:-3}"
# Internal transaction modes. These are set only after a successful full
# validation or a matching validation stamp; ordinary operators cannot use
# them to bypass validation accidentally.
VALIDATE_SKIP_EXTERNAL="${VALIDATE_SKIP_EXTERNAL:-0}"
PLATFORM_RECOVERY_STAMP_MATCH="${PLATFORM_RECOVERY_STAMP_MATCH:-0}"
PLATFORM_BOOTSTRAP_VALIDATION_REUSE="${PLATFORM_BOOTSTRAP_VALIDATION_REUSE:-0}"
# Descriptor discovery is used by many validation and reconciliation helpers,
# including from process substitutions. Keep it private to each invocation so
# concurrent platformctl processes cannot observe a partially-written cache.
DESCRIPTOR_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-hub-lite-descriptors.XXXXXX")"
DESCRIPTOR_CACHE_FILE="$DESCRIPTOR_CACHE_DIR/descriptors"
DESCRIPTOR_CACHE_LOADED=0
DESCRIPTOR_CACHE_CONTENT=''
# A pushed release can invoke this newer script through an older installed
# controller. Preserve the controller's explicit singleton-skip intent.
PLATFORM_SKIP_SINGLETONS="${PLATFORM_SKIP_SINGLETONS:-${DEPLOY_SKIP_SINGLETONS:-0}}"
die() {
	printf 'platformctl: %s\n' "$*" >&2
	exit 1
}
validate_test_flags() {
	[[ "$PLATFORM_TEST_MODE" == 0 || "$PLATFORM_TEST_MODE" == 1 ]] || die 'PLATFORM_TEST_MODE must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 || "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_SYNC_VALIDATION must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_SYNC_VALIDATION requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	[[ "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 0 || "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 1 ]] || die 'PLATFORM_TEST_SKIP_COMPOSE_INSPECTION must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_COMPOSE_INSPECTION requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	[[ "$PLATFORM_TEST_SKIP_RENDER" == 0 || "$PLATFORM_TEST_SKIP_RENDER" == 1 ]] || die 'PLATFORM_TEST_SKIP_RENDER must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_RENDER" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_RENDER requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	[[ -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" || "$PLATFORM_TEST_ONLY_DESCRIPTOR" =~ ^[a-z][a-z0-9-]*$ ]] || die 'PLATFORM_TEST_ONLY_DESCRIPTOR must be a valid application ID'
	[[ -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_ONLY_DESCRIPTOR requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	[[ "$PLATFORM_TEST_FAST_VALIDATE" == 0 || "$PLATFORM_TEST_FAST_VALIDATE" == 1 ]] || die 'PLATFORM_TEST_FAST_VALIDATE must be 0 or 1'
	[[ "$PLATFORM_TEST_FAST_VALIDATE" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_FAST_VALIDATE requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	[[ "$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" == 0 || "$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_SKIP_CLUSTER_VALIDATION must be 0 or 1'
	[[ "$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" == 0 || ("$PLATFORM_TEST_MODE" == 1 && "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 && "$PLATFORM_TEST_FAST_VALIDATE" == 1) ]] || die 'PLATFORM_TEST_SKIP_CLUSTER_VALIDATION requires fast explicit test mode'
	[[ "${PLATFORMCTL_LIBRARY:-0}" != 1 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORMCTL_LIBRARY requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
	if [[ "$PLATFORM_TEST_MODE" != 1 ]]; then
		[[ "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 0 && "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 && "$PLATFORM_TEST_SKIP_RENDER" == 0 && "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 0 && "$PLATFORM_TEST_FAST_VALIDATE" == 0 && -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" && "${PLATFORMCTL_LIBRARY:-0}" != 1 ]] || die 'test-only validation controls require PLATFORM_TEST_MODE=1'
	fi
}
cleanup_candidate() {
	local candidate="${RUNTIME_CONFIG_CANDIDATE:-}"
	# Only remove directories allocated by render_routes below this runtime root.
	# This guard keeps an interrupted validation from ever treating a malformed
	# environment value as a destructive path.
	if [[ -n "$candidate" && "$candidate" == "$RUNTIME_ROOT"/.config.staging.* && -d "$candidate" ]]; then
		rm -rf -- "$candidate"
	fi
	rm -rf -- "$DESCRIPTOR_CACHE_DIR"
}
cleanup_stale_candidates() {
	local candidate
	# A killed validation cannot run its EXIT trap. Remove only candidates older
	# than one hour, which is well beyond a normal render/commit transaction and
	# avoids touching a concurrently active candidate.
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		[[ "$candidate" == "${RUNTIME_CONFIG_CANDIDATE:-}" ]] && continue
		rm -rf -- "$candidate"
	done < <(find "$RUNTIME_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.config.staging.*' -mmin +60 -print 2>/dev/null)
}
trap cleanup_candidate EXIT
[[ "$PLATFORM_WAIT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die 'PLATFORM_WAIT_INTERVAL_SECONDS must be a non-negative integer'
validate_test_flags
[[ "$PLATFORM_FORCE_SINGLETON_ROUTE" == 0 || "$PLATFORM_FORCE_SINGLETON_ROUTE" == 1 ]] || die 'PLATFORM_FORCE_SINGLETON_ROUTE must be 0 or 1'
[[ "$PLATFORM_PRESERVE_CONSUMER_ROUTES" == 0 || "$PLATFORM_PRESERVE_CONSUMER_ROUTES" == 1 ]] || die 'PLATFORM_PRESERVE_CONSUMER_ROUTES must be 0 or 1'
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }
env_value() {
	local k="$1" f="${2:-$APP_ENV}" line value=''
	[[ -f "$f" ]] || return 0
	# Keep this lookup in-process. Validation and route rendering read the same
	# small env files many times; spawning sed/tail for every lookup makes local
	# macOS runs needlessly slow. The last matching assignment wins, matching the
	# previous sed | tail implementation.
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$k="* ]] || continue
		value="${line#*=}"
	done <"$f"
	printf '%s\n' "$value"
}
path_bytes() {
	local path="$1" bytes
	[[ -e "$path" || -L "$path" ]] || return 1
	bytes="$(LC_ALL=C du -sb "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"
	if [[ "$bytes" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$bytes"
		return 0
	fi
	bytes="$(LC_ALL=C du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1 * 1024}')"
	[[ "$bytes" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$bytes"
}
redact_observer_output() {
	sed -E 's/o2oi_[A-Za-z0-9]{32}/<redacted>/g; s/(Basic )[A-Za-z0-9+\/_=-]+/\1<redacted>/g; s/([Aa]uthorization:)[^,}]*/\1<redacted>/g'
}
policy_value() { env_value "$1" "$CLUSTER_POLICY_FILE"; }
node_value() { env_value "$1" "$NODE_CONFIG_FILE"; }
csv_has() {
	local c=",${1//[[:space:]]/},"
	[[ "$c" == *",$2,"* ]]
}
valid_dns_name() {
	local name="$1" label old_ifs
	local -a labels
	[[ -n "$name" && "${#name}" -le 253 && "$name" == *.* ]] || return 1
	[[ ! "$name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	old_ifs="$IFS"
	IFS=.
	read -r -a labels <<<"$name"
	IFS="$old_ifs"
	((${#labels[@]} >= 2)) || return 1
	for label in "${labels[@]}"; do
		[[ -n "$label" && "${#label}" -le 63 ]] || return 1
		[[ "$label" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ || "$label" =~ ^[a-z0-9]$ ]] || return 1
	done
}
placeholder_value() {
	case "$1" in
	'' | replace-with-* | *'<'* | *'>'* | *example.invalid* | *example.* | *your-upstash* | *account-id*) return 0 ;;
	*) return 1 ;;
	esac
}
valid_mongo_uri() {
	local uri="$1" scheme rest authority host entry host_name host_port
	case "$uri" in
	mongodb://*)
		scheme=mongodb
		rest="${uri#mongodb://}"
		;;
	mongodb+srv://*)
		scheme=mongodb+srv
		rest="${uri#mongodb+srv://}"
		;;
	*) return 1 ;;
	esac
	# A URI must be a single-line value with one scheme. This catches accidental
	# pastes such as mongodb+srv://clmongodb+srv://... before Mongo sees them.
	[[ -n "$rest" && "$rest" != *'://' && "$rest" != *$'\n'* && "$rest" != *$'\r'* ]] || return 1
	authority="${rest%%[/?#]*}"
	[[ -n "$authority" ]] || return 1
	host="${authority##*@}"
	[[ -n "$host" ]] || return 1
	if [[ "$scheme" == mongodb+srv ]]; then
		[[ "$host" != *:* && "$host" != *,* ]] || return 1
		[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$host" =~ ^[A-Za-z0-9]$ ]] || return 1
		return 0
	fi
	# Standard Mongo URIs may list host:port pairs for replica sets.
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || return 1
		host_name="${entry%%:*}"
		host_port="${entry#*:}"
		[[ "$host_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$host_name" =~ ^[A-Za-z0-9]$ ]] || return 1
		if [[ "$entry" == *:* ]]; then
			[[ "$host_port" =~ ^[0-9]{1,5}$ ]] || return 1
		fi
	done <<<"$(printf '%s' "$host" | tr ',' '\n')"
}
safe_relative() {
	local value="$1"
	[[ "$value" != /* && "$value" != *..* && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}
compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then compose_bin=("$PLATFORM_COMPOSE_BIN"); elif [[ -x /usr/local/bin/platform-compose ]]; then compose_bin=(/usr/local/bin/platform-compose); fi
acquire_lock() {
	[[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return
	install -d -m700 "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for platform lock'
	export PLATFORM_LOCK_HELD=1
}
acquire_read_lock() {
	[[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return 0
	install -d -m700 "$(dirname "$LOCK_FILE")"
	exec 8>"$LOCK_FILE"
	if [[ "${PLATFORM_HEALTH_NONBLOCKING:-0}" == 1 ]]; then
		flock -n 8 || {
			printf 'platformctl: deployment is active; read-only health check skipped\n' >&2
			return 2
		}
	else
		flock -w "${PLATFORM_READ_LOCK_WAIT:-30}" 8 || {
			printf 'platformctl: timed out waiting for an active deployment to finish\n' >&2
			return 1
		}
	fi
	PLATFORM_READ_LOCK_OWNED=1
	export PLATFORM_LOCK_HELD=1
}
release_read_lock() {
	[[ "${PLATFORM_READ_LOCK_OWNED:-0}" == 1 ]] || return 0
	flock -u 8 >/dev/null 2>&1 || true
	exec 8>&-
	unset PLATFORM_READ_LOCK_OWNED PLATFORM_LOCK_HELD
}
edge_network() { printf '%s\n' "$(env_value PLATFORM_EDGE_NETWORK)" | sed '/^$/s//platform_edge/'; }
ensure_network() {
	local n
	for n in "$(edge_network)" foundation-woodpecker_private foundation-observer_private; do docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null; done
}
node_id() { printf '%s\n' "${NODE_ID:-$(node_value NODE_ID)}" | sed '/^$/s//leader/'; }
leader_node_id() { printf '%s\n' "$(policy_value LEADER_NODE_ID)"; }
node_role() { [[ "$(node_id)" == "$(leader_node_id)" ]] && printf 'leader\n' || printf 'follower\n'; }
node_state() {
	local file="$CONTROL_ROOT/current/config/cluster/nodes/$(node_id).env"
	printf '%s\n' "$(env_value NODE_STATE "$file")"
}
node_descriptor_file() {
	printf '%s/config/cluster/nodes/%s.env\n' "$CONTROL_ROOT/current" "$1"
}
node_known() {
	local id="$1" file
	[[ -n "$id" && "$id" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
	csv_has "$(policy_value NODE_IDS)" "$id" || return 1
	file="$(node_descriptor_file "$id")"
	[[ -f "$file" && "$(env_value NODE_ID "$file")" == "$id" ]]
}
node_state_for() {
	env_value NODE_STATE "$(node_descriptor_file "$1")"
}
node_role_for() {
	[[ "$1" == "$(leader_node_id)" ]] && printf 'leader\n' || printf 'follower\n'
}
active_follower_node() {
	local id="$1"
	node_known "$id" || return 1
	[[ "$id" != "$(leader_node_id)" && "$(node_state_for "$id")" == active ]]
}
foundation_component_active_for_node() {
	local component="$1" id="$2" manifest roles
	manifest="$(foundation_manifest_file "$component")"
	[[ -f "$manifest" ]] || return 1
	node_known "$id" || return 1
	[[ "$(node_state_for "$id")" == active ]] || return 1
	roles="$(foundation_manifest_value "$component" ROLES)"
	csv_has "$roles" "$(node_role_for "$id")" || return 1
	foundation_policy_enabled "$component"
}
observer_collector_nodes() {
	local id
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		foundation_component_active_for_node observer-collector "$id" &&
			printf '%s\n' "$id"
	done <<<"$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')"
}
app_placement() { descriptor_value "$1" PLACEMENT; }
app_upstream_mode() { descriptor_value "$1" UPSTREAM_MODE; }
app_runtime_env_file() {
	local d="$1" rel
	rel="$(descriptor_value "$d" RUNTIME_ENV_FILE)"
	[[ -n "$rel" ]] || return 0
	printf '%s/%s\n' "$CONFIG_ROOT" "$rel"
}
app_config_file() { printf '%s/%s\n' "$1" "$(descriptor_value "$1" CONFIG_FILE)"; }
app_override_file_for_node() { printf '%s/config/cluster/overrides/%s/%s.env\n' "$CONTROL_ROOT/current" "$2" "$(basename "$1")"; }
app_override_file() { app_override_file_for_node "$1" "$(node_id)"; }
app_policy_file() {
	local d="$1" rel
	rel="$(descriptor_value "$d" POLICY_FILE)"
	[[ -n "$rel" ]] || return 0
	printf '%s/%s\n' "$CONTROL_ROOT/current/config" "$rel"
}
app_policy_value() {
	local d="$1" key="$2"
	env_value "$key" "$(app_policy_file "$d")"
}
app_nodes() { app_policy_value "$1" NODES; }
app_target_node() {
	local d="$1" nodes
	nodes="$(app_nodes "$d")"
	[[ "$(app_upstream_mode "$d")" == singleton && -n "$nodes" && "$nodes" != *,* ]] || return 1
	printf '%s\n' "$nodes"
}
app_value() {
	local d="$1" key="$2" value file
	file="$(app_runtime_env_file "$d")"
	value=''
	[[ -z "$file" ]] || value="$(env_value "$key" "$file")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$(app_override_file "$d")")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$(app_config_file "$d")")"
	[[ -n "$value" ]] || value="$(env_value "$key")"
	printf '%s\n' "$value"
}
foundation_manifest_file() { printf '%s/%s.env\n' "$FOUNDATION_MANIFEST_ROOT" "$1"; }
foundation_manifest_value() { env_value "$2" "$(foundation_manifest_file "$1")"; }
foundation_policy_file() { printf '%s/config/%s\n' "$CONTROL_ROOT/current" "$(foundation_manifest_value "$1" POLICY_FILE)"; }
foundation_policy_enabled() { [[ "$(env_value ENABLED "$(foundation_policy_file "$1")")" == true ]]; }
foundation_ids() {
	local manifest id order
	for manifest in "$FOUNDATION_MANIFEST_ROOT"/*.env; do
		[[ -f "$manifest" ]] || continue
		id="$(env_value COMPONENT_ID "$manifest")"
		order="$(env_value START_ORDER "$manifest")"
		[[ -n "$id" && "$order" =~ ^[0-9]+$ ]] && printf '%s\t%s\n' "$order" "$id"
	done | sort -n -k1,1 -k2,2 | cut -f2-
}
foundation_active() {
	local component="$1" manifest roles
	manifest="$(foundation_manifest_file "$component")"
	[[ -f "$manifest" ]] || return 1
	[[ "$(node_state)" != retired ]] || return 1
	roles="$(foundation_manifest_value "$component" ROLES)"
	csv_has "$roles" "$(node_role)" || return 1
	if [[ "$(foundation_manifest_value "$component" MANDATORY)" == true ]]; then
		foundation_policy_enabled "$component" || die "mandatory foundation service is disabled: $component"
		return 0
	fi
	foundation_policy_enabled "$component"
}
app_active() {
	local d="$1" id
	id="$(basename "$d")"
	app_policy_enabled "$id" || return 1
	[[ "$(app_placement "$d")" == consumer && "$(node_role)" == follower ]] || return 1
	[[ "$(node_state)" == active ]] || return 1
	csv_has "$(app_nodes "$d")" "$(node_id)"
}
app_in_reconcile_scope() {
	local d="$1"
	app_active "$d" || return 1
	[[ -z "${PLATFORM_ONLY_APP_ID:-}" || "$(basename "$d")" == "$PLATFORM_ONLY_APP_ID" ]] || return 1
	[[ "${PLATFORM_SKIP_SINGLETONS:-0}" != 1 || "$(app_upstream_mode "$d")" != singleton ]]
}
app_route_active() {
	local id="$(basename "$1")"
	[[ "$(app_placement "$1")" == consumer ]] || return 1
	if [[ "$(node_role)" != leader ]]; then
		app_active "$1" || return 1
	fi
	app_policy_enabled "$id"
}
foundation_file() { foundation_manifest_value "$1" COMPOSE_FILE; }
foundation_env() { printf '%s/%s\n' "$FOUNDATION_ENV_ROOT" "$(foundation_manifest_value "$1" ENV_FILE)"; }
# Some foundation projects expose a small sidecar health contract because the
# primary image does not provide a portable healthcheck command. Requiring the
# sidecar to be running and healthy prevents an Observer project from appearing
# ready while its local API or Vector shipper is still unavailable.
foundation_health_service() { foundation_manifest_value "$1" HEALTH_SERVICE; }
foundation_compose() { compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$(foundation_env "$1")" --env-file "$FOUNDATION_IMAGE_ENV" --env-file "$NODE_CONFIG_FILE" -f "$FOUNDATION_ROOT/$(foundation_file "$1")"); }
descriptor_ids() {
	if ((DESCRIPTOR_CACHE_LOADED == 0)); then
		if [[ ! -f "$DESCRIPTOR_CACHE_FILE" ]]; then
			# A failed discovery must not leave a partial cache that later calls trust.
			local tmp_cache="${DESCRIPTOR_CACHE_FILE}.tmp"
			if ! find -L "$APPS_ROOT" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; 2>/dev/null | sort >"$tmp_cache"; then
				rm -f -- "$tmp_cache"
				return 1
			fi
			mv -f -- "$tmp_cache" "$DESCRIPTOR_CACHE_FILE"
		fi
		DESCRIPTOR_CACHE_CONTENT="$(<"$DESCRIPTOR_CACHE_FILE")"
		DESCRIPTOR_CACHE_LOADED=1
	fi
	[[ -n "$DESCRIPTOR_CACHE_CONTENT" ]] && printf '%s\n' "$DESCRIPTOR_CACHE_CONTENT"
}
# Focused test validation still checks every inventory node, but can avoid
# repeatedly walking and parsing unrelated application manifests after the
# initial full validation. This is enabled only by the test-only fast mode,
# which itself requires external validation to be disabled.
cluster_validation_descriptor_ids() {
	if [[ "$PLATFORM_TEST_MODE" == 1 && "$PLATFORM_TEST_FAST_VALIDATE" == 1 && "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 && -n "$PLATFORM_TEST_ONLY_DESCRIPTOR" ]]; then
		printf '%s/%s\n' "$APPS_ROOT" "$PLATFORM_TEST_ONLY_DESCRIPTOR"
		return
	fi
	descriptor_ids
}
descriptor_value() {
	local value
	value="$(env_value "$2" "$1/manifest.env")"
	# Manifest values are env-style text; allow a single-quoted value to carry
	# JSON fragments such as HEALTH_EXPECT without leaking the delimiters into
	# HTTP smoke comparisons.
	if [[ "$value" == \'* ]]; then value="${value#\'}"; fi
	if [[ "$value" == *\' ]]; then value="${value%\'}"; fi
	printf '%s\n' "$value"
}
app_public_host() {
	local d="$1" wanted="$2" key host
	while IFS='|' read -r key host; do
		[[ "$key" == "$wanted" ]] || continue
		printf '%s\n' "$host"
		return 0
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')"
}
app_public_endpoint_env() {
	local d="$1" key host domain scheme file tmp
	domain="$(env_value DOMAIN_NAME)"
	[[ -n "$domain" ]] || die 'DOMAIN_NAME is required to derive application public endpoints'
	if [[ "$domain" == localhost ]]; then
		scheme=http
	else
		scheme=https
	fi
	file="$RUNTIME_ROOT/app-env/$(basename "$d").env"
	install -d -m 700 "$(dirname "$file")"
	tmp="$(mktemp "$file.tmp.XXXXXX")"
	: >"$tmp"
	while IFS='|' read -r key host; do
		[[ -n "$key" && -n "$host" ]] || continue
		printf '%s=%s://%s.%s\n' "$key" "$scheme" "$host" "$domain" >>"$tmp"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
	printf '%s\n' "$file"
}
descriptor_secret_min_length() {
	local d="$1" wanted="$2" rule key min_length
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		min_length="${rule#*:}"
		if [[ "$key" == "$wanted" ]]; then
			printf '%s\n' "$min_length"
			return 0
		fi
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" SECRET_MIN_LENGTHS)" | tr ',' '\n')"
	printf '1\n'
}
descriptor_secret_regex() {
	local d="$1" wanted="$2" rule key regex
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		regex="${rule#*:}"
		[[ "$key" == "$wanted" ]] && {
			printf '%s\n' "$regex"
			return 0
		}
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" SECRET_REGEXES)" | tr ',' '\n')"
	printf '\n'
}
descriptor_secret_keys() {
	local d="$1" keys
	keys="$(descriptor_value "$d" CLUSTER_SECRET_KEYS),$(descriptor_value "$d" NODE_SECRET_KEYS)"
	printf '%s\n' "$keys" | tr ',' '\n' | sed '/^$/d' | awk '!seen[$0]++'
}
app_declared() {
	local d
	# Use a here-string instead of a process substitution. These helpers are
	# called from descriptor iteration bodies; nested process substitutions leak
	# the outer pipe on Bash 3.2 and can wait forever for EOF.
	while IFS= read -r d; do [[ "$(basename "$d")" == "$1" ]] && return 0; done <<<"$(descriptor_ids)"
	return 1
}
app_policy_enabled() {
	local d
	while IFS= read -r d; do
		[[ "$(basename "$d")" == "$1" ]] || continue
		if [[ "$(app_policy_value "$d" ENABLED)" == true ]]; then
			return 0
		fi
		return 1
	done <<<"$(descriptor_ids)"
	return 1
}
app_compose() {
	local d="$1" runtime_env config_file override_file endpoint_env
	config_file="$(app_config_file "$d")"
	override_file="$(app_override_file "$d")"
	compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$NODE_CONFIG_FILE" --env-file "$APP_IMAGE_ENV" --env-file "$config_file")
	[[ ! -f "$override_file" ]] || compose_command+=(--env-file "$override_file")
	runtime_env="$(app_runtime_env_file "$d")"
	[[ -z "$runtime_env" || ! -f "$runtime_env" ]] || compose_command+=(--env-file "$runtime_env")
	endpoint_env="$(app_public_endpoint_env "$d")"
	compose_command+=(--env-file "$endpoint_env")
	compose_command+=(-p "$(descriptor_value "$d" COMPOSE_PROJECT)" -f "$d/$(descriptor_value "$d" COMPOSE_FILE)")
}
cluster_upstreams() {
	local d="$1" field="$2" node host output="" primary="${3:-}"
	if [[ -n "$primary" ]]; then
		csv_has "$(app_nodes "$d")" "$primary" || die "primary node is absent from application placement: $primary"
		active_follower_node "$primary" || die "upstream node is not an active follower: $primary"
		host="$(env_value "$field" "$(node_descriptor_file "$primary")")"
		[[ -n "$host" ]] || die "$field is missing from cluster inventory: $primary"
		output="https://$host"
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$(node_id)" ]] || continue
		[[ "$node" != "$primary" ]] || continue
		active_follower_node "$node" || die "upstream node is not an active follower: $node"
		host="$(env_value "$field" "$(node_descriptor_file "$node")")"
		[[ -n "$host" ]] || die "$field is missing from cluster inventory: $node"
		output="${output:+$output }https://$host"
	done <<<"$(printf '%s\n' "$(app_nodes "$d")" | tr ',' '\n' | sed '/^$/d')"
	[[ -n "$output" ]] || die "no follower upstreams are defined for $field"
	echo "$output"
}
effective_value() {
	local k="$1" v d target target_file mode groups public_key origin_key upstream_key primary_key primary public_host domain state_file previous_target
	d="${CURRENT_ROUTE_DESCRIPTOR:-}"
	# Foundation-owned route values must come from their foundation env file.
	# Keeping them in the shared application env is useful for bootstrap
	# compatibility, but allowing that copy to win would make a runtime edit to
	# observer.env (or another foundation env) silently leave Caddy on stale
	# hostnames until the application env is edited as well.
	case "$k" in
	OBSERVER_SITE | OBSERVER_INGEST_SITE)
		v="$(env_value "$k" "$FOUNDATION_ENV_ROOT/observer.env")"
		;;
	*)
		v=""
		;;
	esac
	[[ -n "$v" ]] || v="$(env_value "$k")"
	[[ -n "$v" ]] || v="$(node_value "$k")"
	if [[ -n "$d" ]]; then
		groups="$(descriptor_value "$d" ROUTE_GROUPS)"
		while IFS='|' read -r public_key origin_key upstream_key; do
			[[ -n "$public_key" ]] || continue
			if [[ "$k" == "$public_key" ]]; then
				v="$(app_value "$d" "$k")"
				if [[ -z "$v" ]]; then
					public_host="$(app_public_host "$d" "$public_key")"
					domain="$(env_value DOMAIN_NAME)"
					if [[ -n "$public_host" && -n "$domain" ]]; then
						if [[ "$domain" == localhost ]]; then v="http://${public_host}.localhost"; else v="https://${public_host}.${domain}"; fi
					fi
				fi
			elif [[ "$k" == "$origin_key" ]]; then
				v="$(node_value "$k")"
			elif [[ "$k" == "$upstream_key" && "$(node_role)" == leader ]]; then
				mode="$(descriptor_value "$d" UPSTREAM_MODE)"
				case "$mode" in
				singleton)
					target="$(app_target_node "$d")"
					# A singleton route may only point at a known active follower. The
					# configured target is always checked, even when a transition marker
					# temporarily keeps the previous target in service.
					active_follower_node "$target" || die "singleton target is not an active follower: $target"
					# A recorded previous target means a health-gated move has not
					# completed. Preserve it across normal deploys and reboot recovery;
					# only singleton-switch may render the candidate target.
					if [[ "$PLATFORM_FORCE_SINGLETON_ROUTE" != 1 && "$(node_role)" == leader ]]; then
						state_file="$(singleton_state_file "$d")"
						previous_target="$(sed -n '1p' "$state_file" 2>/dev/null || true)"
						if [[ -n "$previous_target" ]]; then
							active_follower_node "$previous_target" || die "singleton previous target is not an active follower: $previous_target"
							target="$previous_target"
						fi
					fi
					target_file="$(node_descriptor_file "$target")"
					v="https://$(env_value "$origin_key" "$target_file")"
					;;
				active-active) v="$(cluster_upstreams "$d" "$origin_key")" ;;
				active-passive)
					primary_key="$(descriptor_value "$d" PRIMARY_NODE_KEY)"
					primary="$(app_policy_value "$d" "$primary_key")"
					v="$(cluster_upstreams "$d" "$origin_key" "$primary")"
					;;
				*) die "unsupported upstream mode for $(basename "$d")" ;;
				esac
				[[ -n "$v" ]] || die "missing upstream for $(basename "$d")"
			fi
		done <<<"$(printf '%s\n' "$groups" | tr ';' '\n')"
	fi
	case "$k" in NODE_ID) v="$(node_id)" ;; NODE_ROLE) v="$(node_role)" ;; esac
	echo "$v"
}
render_template() {
	local f="$1" k v e descriptor="${2:-}" previous_descriptor="${CURRENT_ROUTE_DESCRIPTOR:-}" script tmp
	CURRENT_ROUTE_DESCRIPTOR="$descriptor"
	# Build one sed program per file instead of spawning sed once per
	# placeholder. Values are escaped for the delimiter, replacement markers,
	# and backslashes; this preserves the existing route rendering semantics.
	script="$(mktemp "${f}.sed.XXXXXX")"
	tmp=""
	while IFS= read -r k; do
		v="$(effective_value "$k")"
		e="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
		printf 's|{\\$%s}|%s|g\n' "$k" "$e" >>"$script"
	done <<<"$(grep -oE '\{\$[A-Z0-9_]+\}' "$f" | sed 's/[^A-Z0-9_]//g' | sort -u)"
	if [[ -s "$script" ]]; then
		tmp="$(mktemp "${f}.tmp.XXXXXX")"
		if ! sed -f "$script" "$f" >"$tmp"; then
			rm -f -- "$script" "$tmp"
			CURRENT_ROUTE_DESCRIPTOR="$previous_descriptor"
			return 1
		fi
		mv -f -- "$tmp" "$f"
	fi
	[[ -z "$tmp" || ! -e "$tmp" ]] || rm -f -- "$tmp"
	rm -f -- "$script"
	CURRENT_ROUTE_DESCRIPTOR="$previous_descriptor"
}
render_routes() {
	local s d a t o f current_route
	install -d -m700 "$RUNTIME_ROOT"
	# A caller may render more than once before committing (for example, a
	# staged validation followed by a scoped sync). Discard the superseded
	# candidate before allocating a new one so failed retries cannot accumulate
	# stale configuration trees.
	if [[ -n "${RUNTIME_CONFIG_CANDIDATE:-}" ]]; then
		cleanup_candidate
		unset RUNTIME_CONFIG_CANDIDATE
	fi
	cleanup_stale_candidates
	s="$(mktemp -d "$RUNTIME_ROOT/.config.staging.XXXXXX")"
	install -d -m700 "$s/routes.d"
	# Register the staging directory before any copy/render can fail so the EXIT
	# trap removes partial configurations instead of accumulating them across
	# repeated validations or interrupted reconciliations.
	RUNTIME_CONFIG_CANDIDATE="$s"
	cp -a "$CONTROL_ROOT/current/config/." "$s/"
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		render_template "$f"
	done <<<"$(find "$s" -type f -name '*.caddy' -print)"
	while IFS= read -r d; do
		[[ -n "$d" ]] || continue
		a="$(basename "$d")"
		current_route="$RUNTIME_ROOT/config/routes.d/$a.caddy"
		if [[ "$PLATFORM_PRESERVE_CONSUMER_ROUTES" == 1 || (-n "$PLATFORM_ONLY_ROUTE_APP_ID" && "$a" != "$PLATFORM_ONLY_ROUTE_APP_ID") ]]; then
			[[ -f "$current_route" ]] && cp "$current_route" "$s/routes.d/$a.caddy"
			continue
		fi
		if [[ "${PLATFORM_SKIP_SINGLETONS:-0}" == 1 && "$(app_upstream_mode "$d")" == singleton ]]; then
			if [[ "${PLATFORM_RECONCILE_DISABLED_SINGLETONS:-0}" == 1 ]] && ! app_policy_enabled "$a"; then
				continue
			fi
			[[ -f "$current_route" ]] && cp "$current_route" "$s/routes.d/$a.caddy"
			continue
		fi
		app_route_active "$d" || continue
		[[ "$(node_role)" == leader ]] && t="$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" || t="$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
		o="$s/routes.d/$a.caddy"
		cp "$d/$t" "$o"
		render_template "$o" "$d"
	done <<<"$(descriptor_ids)"
	foundation_active woodpecker-controller || rm -f "$s/foundation-routes.d/woodpecker.caddy" "$s/foundation-routes.d/woodpecker-grpc.caddy"
	foundation_active beszel-controller || rm -f "$s/foundation-routes.d/beszel.caddy"
	foundation_active observer-controller || rm -f "$s/foundation-routes.d/observer.caddy"
}
commit_routes() {
	local c="${RUNTIME_CONFIG_CANDIDATE:-}" d="$RUNTIME_ROOT/config" f r
	if [[ ! -d "$c" ]]; then
		# Fast test-mode sync/recovery intentionally skips route rendering. Never
		# silently accept a missing candidate in production.
		[[ "$PLATFORM_TEST_MODE" == 1 && "$PLATFORM_TEST_SKIP_RENDER" == 1 && "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] && return 0
		die 'missing staged Caddy configuration'
	fi
	install -d -m700 "$d"
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		r="${f#"$c/"}"
		install -d -m700 "$d/$(dirname "$r")"
		cp "$f" "$d/$r.tmp"
		mv "$d/$r.tmp" "$d/$r"
	done <<<"$(find "$c" -type f -print)"
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		# Another validation/reconcile process may be rendering its private
		# candidate under the same runtime root. Staging trees are transaction
		# state, not committed Caddy files, and must never be removed by the
		# stale-file sweep of a different commit.
		case "$f" in
		"$d"/.config.staging.* | "$d"/.config.staging.*/*) continue ;;
		esac
		r="${f#"$d/"}"
		[[ -e "$c/$r" ]] || rm -rf "$f"
	done <<<"$(find "$d" -mindepth 1 -print)"
	rm -rf "$c"
	unset RUNTIME_CONFIG_CANDIDATE
}
sha256_data() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}
sha256_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	else
		shasum -a 256 "$file" | awk '{print $1}'
	fi
}
sha256_files() {
	# Hash a batch in one process. Validation stamps are generated during every
	# successful reconcile; invoking a separate checksum process for each small
	# env/template file made recovery disproportionately expensive on macOS.
	(($# > 0)) || return 0
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@" | awk '{print $1}'
	else
		shasum -a 256 "$@" | awk '{print $1}'
	fi
}
validation_stamp_release() {
	local target
	target="$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)"
	[[ -n "$target" && -d "$target" ]] || return 1
	basename "$target"
}
validation_stamp_fingerprint() {
	local release="${1:-}" root file tool_identity tmp
	local -a fingerprint_files=()
	[[ -n "$release" && -d "$release" ]] || return 1
	tmp="$(mktemp "${TMPDIR:-/tmp}/llm-hub-lite-validation.XXXXXX")"
	append_fingerprint_files() {
		local append_root="$1" append_file
		while IFS= read -r append_file; do
			[[ -f "$append_file" ]] || continue
			fingerprint_files[${#fingerprint_files[@]}]="$append_file"
		done < <(find "$append_root" -type f -print | sort)
	}
	emit_fingerprint_files() {
		local kind="$1" base="$2" emit_file emit_relative emit_index=0 emit_digest
		((${#fingerprint_files[@]} > 0)) || return 0
		while IFS= read -r emit_digest; do
			emit_file="${fingerprint_files[$emit_index]}"
			[[ -n "$emit_file" ]] || return 1
			if [[ "$kind" == release ]]; then
				emit_relative="${emit_file#"$base/"}"
				printf 'release-file=%s:%s\n' "$emit_relative" "$emit_digest"
			else
				printf 'host-file=%s:%s\n' "$emit_file" "$emit_digest"
			fi
			emit_index=$((emit_index + 1))
		done < <(sha256_files "${fingerprint_files[@]}")
		((emit_index == ${#fingerprint_files[@]})) || return 1
	}
	{
		printf 'schema=1\nrelease=%s\n' "$(basename "$release")"
		for root in config apps compose ops; do
			[[ -d "$release/$root" ]] || continue
			fingerprint_files=()
			append_fingerprint_files "$release/$root"
			emit_fingerprint_files release "$release"
		done
		fingerprint_files=()
		for file in "$APP_ENV" "$APP_IMAGE_ENV" "$FOUNDATION_IMAGE_ENV" "$NODE_CONFIG_FILE" \
			"$CONFIG_ROOT/platform.env"; do
			if [[ -f "$file" ]]; then
				fingerprint_files[${#fingerprint_files[@]}]="$file"
			else
				printf 'host-file=%s:MISSING\n' "$file"
			fi
		done
		emit_fingerprint_files host ''
		for root in "$FOUNDATION_ENV_ROOT" "$RUNTIME_ROOT/app-env" "$SINGLETON_STATE_ROOT" \
			"$CONTROL_ROOT/current/config/cluster/overrides"; do
			[[ -d "$root" ]] || continue
			fingerprint_files=()
			append_fingerprint_files "$root"
			emit_fingerprint_files host ''
		done
		tool_identity="${compose_bin[*]}"
		printf 'compose-command=%s\n' "$tool_identity"
		if tool_identity="$("${compose_bin[@]}" version 2>/dev/null | head -n1)"; then
			printf 'compose-version=%s\n' "$tool_identity"
		else
			printf 'compose-version=unavailable\n'
		fi
		if command -v docker >/dev/null 2>&1; then
			printf 'docker-path=%s\n' "$(command -v docker)"
			printf 'docker-version=%s\n' "$(docker version --format '{{.Client.Version}}' 2>/dev/null || printf unavailable)"
		else
			printf 'docker-path=unavailable\n'
		fi
	} >"$tmp"
	sha256_file "$tmp"
	rm -f -- "$tmp"
}
validation_stamp_matches() {
	local current_release expected_release expected_fingerprint actual_fingerprint
	current_release="$(validation_stamp_release 2>/dev/null || true)"
	[[ -n "$current_release" && -f "$VALIDATION_STAMP_FILE" ]] || return 1
	expected_release="$(env_value RELEASE_SHA "$VALIDATION_STAMP_FILE")"
	[[ "$expected_release" == "$current_release" ]] || return 1
	expected_fingerprint="$(env_value FINGERPRINT "$VALIDATION_STAMP_FILE")"
	[[ -n "$expected_fingerprint" ]] || return 1
	actual_fingerprint="$(validation_stamp_fingerprint "$CONTROL_ROOT/current")"
	[[ "$actual_fingerprint" == "$expected_fingerprint" ]]
}
write_validation_stamp() {
	local release="${1:-$(validation_stamp_release 2>/dev/null || true)}" fingerprint tmp
	[[ -n "$release" ]] || return 0
	fingerprint="$(validation_stamp_fingerprint "$CONTROL_ROOT/current")" || return 1
	install -d -m700 "$(dirname "$VALIDATION_STAMP_FILE")"
	tmp="$(mktemp "${VALIDATION_STAMP_FILE}.tmp.XXXXXX")"
	printf 'SCHEMA=1\nRELEASE_SHA=%s\nFINGERPRINT=%s\nVALIDATED_UTC=%s\n' \
		"$release" "$fingerprint" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$VALIDATION_STAMP_FILE"
}
validate_cluster() {
	local node file state migration backup d groups public_key origin_key host node_count=0 master_count=0 origins='' newapi_enabled=0 newapi_descriptor
	need_file "$CLUSTER_POLICY_FILE"
	need_file "$NODE_CONFIG_FILE"
	[[ "$(policy_value CLUSTER_CONFIG_VERSION)" == 3 ]] || die 'unsupported cluster policy version'
	csv_has "$(policy_value NODE_IDS)" "$(node_id)" || die 'node is absent from cluster policy'
	[[ "$(node_id)" == "$(env_value NODE_ID "$NODE_CONFIG_FILE")" ]] || die 'runtime node identity disagrees with node inventory'
	[[ "$(node_role)" == leader || "$(node_role)" == follower ]] || die 'invalid derived node role'
	while IFS= read -r node; do
		[[ -n "$node" ]] || continue
		node_count=$((node_count + 1))
		file="$CONTROL_ROOT/current/config/cluster/nodes/$node.env"
		need_file "$file"
		[[ "$(env_value NODE_ID "$file")" == "$node" ]] || die "inventory NODE_ID mismatch: $node"
		[[ "$node" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid stable node ID: $node"
		state="$(env_value NODE_STATE "$file")"
		case "$state" in joining | active | draining | retired) ;; *) die "NODE_STATE must be joining, active, draining, or retired: $node" ;; esac
		if [[ "$node" == "$(leader_node_id)" && "$state" != active ]]; then
			die "designated Leader node must be active: $node"
		fi
		if [[ "$node" != "$(leader_node_id)" ]]; then
			while IFS= read -r d; do
				app_policy_enabled "$(basename "$d")" || continue
				[[ "$(app_placement "$d")" == consumer ]] || continue
				csv_has "$(app_nodes "$d")" "$node" || continue
				groups="$(descriptor_value "$d" ROUTE_GROUPS)"
				while IFS='|' read -r public_key origin_key _; do
					[[ -n "$public_key" ]] || continue
					host="$(env_value "$origin_key" "$file")"
					valid_dns_name "$host" || die "invalid origin host $origin_key for $node"
					csv_has "$origins" "$host" && die "duplicate consumer origin host: $host"
					origins="${origins:+$origins,}$host"
				done <<<"$(printf '%s\n' "$groups" | tr ';' '\n')"
			done <<<"$(cluster_validation_descriptor_ids)"
		fi
	done <<<"$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')"
	[[ "$node_count" -eq "$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" ]] || die 'NODE_IDS contains duplicate entries'
	csv_has "$(policy_value NODE_IDS)" "$(leader_node_id)" || die 'LEADER_NODE_ID is absent from NODE_IDS'
	app_policy_enabled newapi && newapi_enabled=1
	newapi_descriptor="$APPS_ROOT/newapi"
	if ((newapi_enabled == 1)); then
		backup="$(app_policy_value "$newapi_descriptor" NEW_API_BACKUP_NODE_ID)"
		csv_has "$(app_nodes "$newapi_descriptor")" "$backup" || die 'NEW_API_BACKUP_NODE_ID is absent from New API NODES'
	fi
	if ((newapi_enabled == 1)); then
		migration="$(app_policy_value "$newapi_descriptor" NEW_API_MIGRATION_NODE_ID)"
		csv_has "$(app_nodes "$newapi_descriptor")" "$migration" || die 'NEW_API_MIGRATION_NODE_ID is absent from New API NODES'
		[[ "$migration" != "$(leader_node_id)" ]] || die 'NEW_API_MIGRATION_NODE_ID must be a follower'
		[[ "$(env_value NEW_API_NODE_TYPE "$CONTROL_ROOT/current/config/cluster/nodes/$migration.env")" == master ]] || die 'migration node must use NEW_API_NODE_TYPE=master'
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$(leader_node_id)" && "$newapi_enabled" -eq 1 ]] || continue
		csv_has "$(app_nodes "$newapi_descriptor")" "$node" || continue
		case "$(env_value NEW_API_NODE_TYPE "$CONTROL_ROOT/current/config/cluster/nodes/$node.env")" in
		master) master_count=$((master_count + 1)) ;;
		slave) ;;
		*) die "invalid NEW_API_NODE_TYPE for $node" ;;
		esac
	done <<<"$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')"
	((newapi_enabled == 0 || master_count == 1)) || die 'exactly one follower must use NEW_API_NODE_TYPE=master'
}
validate_descriptor() {
	local d="$1" k v rel alias services health_service compose_file yaml_file nginx_file rule secret_key min_length value mode nodes node node_count=0 seen_nodes='' primary_key primary enabled all_secret_keys generated_keys endpoint_key endpoint_host endpoint_keys='' endpoint_hosts='' route_public_keys='' default_key default_value default_extra node_default_keys='' conditional_rule conditional_value conditional_keys conditional_key conditional_seen='' regex bytes
	for k in MANIFEST_VERSION APP_ID PLACEMENT UPSTREAM_MODE POLICY_FILE CONFIG_FILE PUBLIC_ENDPOINTS ROUTE_GROUPS COMPOSE_FILE COMPOSE_PROJECT SERVICE_NAME NETWORK_ALIAS IMAGE_KEYS DATA_ROOT_REL HEALTH_URL SMOKE_URL_KEY SMOKE_LOCAL HEALTH_MODE ROUTE_TEMPLATE_LEADER ROUTE_TEMPLATE_FOLLOWER; do
		v="$(descriptor_value "$d" "$k")"
		[[ -n "$v" ]] || die "$k is required in $d/manifest.env"
	done
	case "$(descriptor_value "$d" SMOKE_LOCAL)" in public | healthcheck) ;; *) die "SMOKE_LOCAL must be public or healthcheck in $d/manifest.env" ;; esac
	case "$(descriptor_value "$d" HEALTH_MODE)" in healthcheck | process) ;; *) die "HEALTH_MODE must be healthcheck or process in $d/manifest.env" ;; esac
	[[ "$(descriptor_value "$d" MANIFEST_VERSION)" == 5 ]] || die 'unsupported app manifest version'
	[[ "$(descriptor_value "$d" PLACEMENT)" == consumer ]] || die "app PLACEMENT must be consumer: $d"
	enabled="$(app_policy_value "$d" ENABLED)"
	case "$enabled" in true | false) ;; *) die "app policy ENABLED must be true or false: $d" ;; esac
	nodes="$(app_nodes "$d")"
	[[ -n "$nodes" ]] || die "app policy NODES must not be empty: $d"
	while IFS= read -r node; do
		[[ -n "$node" ]] || die "app policy NODES contains an empty entry: $d"
		csv_has "$(policy_value NODE_IDS)" "$node" || die "app node is absent from inventory: $node ($d)"
		[[ "$node" != "$(leader_node_id)" ]] || die "consumer app cannot target the Leader: $d"
		csv_has "$seen_nodes" "$node" && die "app policy NODES contains a duplicate: $node ($d)"
		# Disabled applications may reserve a joining follower for a future
		# rollout. Enabled applications still require an active target.
		if [[ "$enabled" == true ]]; then
			[[ "$(env_value NODE_STATE "$CONTROL_ROOT/current/config/cluster/nodes/$node.env")" == active ]] || die "consumer app target is not active: $node ($d)"
		fi
		seen_nodes="${seen_nodes:+$seen_nodes,}$node"
		node_count=$((node_count + 1))
	done <<<"$(printf '%s\n' "$nodes" | tr ',' '\n')"
	mode="$(app_upstream_mode "$d")"
	case "$mode" in
	active-active)
		((node_count >= 1)) || die "active-active app requires at least one follower: $d"
		;;
	active-passive)
		((node_count >= 1)) || die "active-passive app requires at least one follower: $d"
		primary_key="$(descriptor_value "$d" PRIMARY_NODE_KEY)"
		[[ -n "$primary_key" ]] || die "PRIMARY_NODE_KEY is required for active-passive app: $d"
		primary="$(app_policy_value "$d" "$primary_key")"
		csv_has "$nodes" "$primary" || die "active-passive primary is absent from app NODES: $d"
		;;
	singleton)
		for k in RUNTIME_ENV_FILE NODE_SECRET_KEYS MOVE_MODE; do
			[[ -n "$(descriptor_value "$d" "$k")" ]] || die "$k is required for singleton app $d/manifest.env"
		done
		((node_count == 1)) || die "singleton app must target exactly one follower: $d"
		if app_in_reconcile_scope "$d"; then
			[[ -f "$(app_runtime_env_file "$d")" ]] || die "missing runtime env file for active singleton app: $d"
		fi
		;;
	*) die "unsupported UPSTREAM_MODE in $d/manifest.env" ;;
	esac
	[[ "$(descriptor_value "$d" APP_ID)" == "$(basename "$d")" && "$(descriptor_value "$d" APP_ID)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid APP_ID in $d/manifest.env"
	while IFS= read -r k; do
		[[ -z "$k" || "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid ENV_KEYS entry in $d/manifest.env: $k"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" ENV_KEYS)" | tr ',' '\n')"
	while IFS='|' read -r default_key default_value default_extra; do
		[[ -z "$default_key" && -z "$default_value" ]] && continue
		[[ "$default_key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$default_value" && -z "$default_extra" ]] || die "invalid NODE_DEFAULTS entry in $d/manifest.env"
		case "$default_key" in
		NODE_ID | NODE_STATE | WOODPECKER_AGENT_LABELS | BESZEL_SYSTEM_NAME) die "NODE_DEFAULTS uses a reserved key in $d/manifest.env: $default_key" ;;
		esac
		! csv_has "$node_default_keys" "$default_key" || die "duplicate NODE_DEFAULTS key in $d/manifest.env: $default_key"
		printf '%s' "$default_value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1 && die "NODE_DEFAULTS contains control characters in $d/manifest.env: $default_key"
		node_default_keys="${node_default_keys:+$node_default_keys,}$default_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" NODE_DEFAULTS)" | tr ';' '\n')"
	all_secret_keys="$(descriptor_value "$d" CLUSTER_SECRET_KEYS),$(descriptor_value "$d" NODE_SECRET_KEYS)"
	while IFS= read -r secret_key; do
		[[ -n "$secret_key" ]] || continue
		[[ "$secret_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid application secret key in $d/manifest.env: $secret_key"
		! csv_has "$(descriptor_value "$d" ENV_KEYS)" "$secret_key" || die "secret key is also declared as non-secret configuration: $secret_key"
	done <<<"$(printf '%s\n' "$all_secret_keys" | tr ',' '\n')"
	generated_keys="$(descriptor_value "$d" GENERATED_SECRET_KEYS)"
	while IFS= read -r secret_key; do
		[[ -n "$secret_key" ]] || continue
		csv_has "$all_secret_keys" "$secret_key" || die "GENERATED_SECRET_KEYS references undeclared secret in $d/manifest.env: $secret_key"
	done <<<"$(printf '%s\n' "$generated_keys" | tr ',' '\n')"
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		secret_key="${rule%%:*}"
		bytes="${rule#*:}"
		[[ "$secret_key" =~ ^[A-Z][A-Z0-9_]*$ && "$bytes" =~ ^[1-9][0-9]*$ ]] || die "invalid GENERATED_SECRET_BYTES entry in $d/manifest.env: $rule"
		csv_has "$generated_keys" "$secret_key" || die "GENERATED_SECRET_BYTES references undeclared generated secret in $d/manifest.env: $secret_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" GENERATED_SECRET_BYTES)" | tr ',' '\n')"
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		secret_key="${rule%%:*}"
		min_length="${rule#*:}"
		[[ "$secret_key" =~ ^[A-Z][A-Z0-9_]*$ && "$min_length" =~ ^[1-9][0-9]*$ ]] || die "invalid SECRET_MIN_LENGTHS entry in $d/manifest.env: $rule"
		csv_has "$all_secret_keys" "$secret_key" || die "SECRET_MIN_LENGTHS references undeclared secret in $d/manifest.env: $secret_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" SECRET_MIN_LENGTHS)" | tr ',' '\n')"
	while IFS= read -r conditional_rule; do
		[[ -n "$conditional_rule" ]] || continue
		selector_key="${conditional_rule%%=*}"
		conditional_value="${conditional_rule#*=}"
		conditional_value="${conditional_value%%|*}"
		conditional_keys="${conditional_rule#*|}"
		[[ "$selector_key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$conditional_value" && "$conditional_rule" == *'|'* ]] || die "invalid CONDITIONAL_SECRET_KEYS entry in $d/manifest.env: $conditional_rule"
		csv_has "$(descriptor_value "$d" ENV_KEYS)" "$selector_key" || die "conditional selector is not declared in ENV_KEYS: $selector_key"
		while IFS= read -r conditional_key; do
			[[ -n "$conditional_key" ]] || continue
			[[ "$conditional_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid conditional secret key in $d/manifest.env: $conditional_key"
			csv_has "$all_secret_keys" "$conditional_key" && die "conditional secret must not also be unconditional: $conditional_key"
			! csv_has "$conditional_seen" "$conditional_key" || die "duplicate conditional secret key: $conditional_key"
			conditional_seen="${conditional_seen}${conditional_seen:+,}$conditional_key"
			all_secret_keys="${all_secret_keys}${all_secret_keys:+,}$conditional_key"
		done < <(printf '%s\n' "$conditional_keys" | tr ',' '\n')
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" CONDITIONAL_SECRET_KEYS)" | tr ';' '\n')"
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		secret_key="${rule%%:*}"
		regex="${rule#*:}"
		[[ "$secret_key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$regex" ]] || die "invalid SECRET_REGEXES entry in $d/manifest.env: $rule"
		csv_has "$all_secret_keys" "$secret_key" || die "SECRET_REGEXES references undeclared secret in $d/manifest.env: $secret_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" SECRET_REGEXES)" | tr ',' '\n')"
	[[ "$(descriptor_value "$d" COMPOSE_PROJECT)" == "app-$(basename "$d")" ]] || die "COMPOSE_PROJECT must equal app-APP_ID in $d/manifest.env"
	alias="$(descriptor_value "$d" NETWORK_ALIAS)"
	[[ "$alias" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid NETWORK_ALIAS in $d/manifest.env"
	for rel in "$(descriptor_value "$d" DATA_ROOT_REL)" "$(descriptor_value "$d" EPHEMERAL_DATA_REL)" "$(descriptor_value "$d" COMPOSE_FILE)" "$(descriptor_value "$d" CONFIG_FILE)" "$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" "$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)" "$(descriptor_value "$d" RUNTIME_ENV_FILE)" "$(descriptor_value "$d" POLICY_FILE)"; do
		[[ -z "$rel" ]] || safe_relative "$rel" || die "unsafe descriptor path in $d/manifest.env"
	done
	need_file "$CONTROL_ROOT/current/config/$(descriptor_value "$d" POLICY_FILE)"
	need_file "$(app_config_file "$d")"
	validate_app_config_file "$d" "$(app_config_file "$d")"
	while IFS='|' read -r endpoint_key endpoint_host; do
		[[ "$endpoint_key" =~ ^[A-Z][A-Z0-9_]*$ && "$endpoint_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid PUBLIC_ENDPOINTS in $d/manifest.env"
		csv_has "$endpoint_keys" "$endpoint_key" && die "duplicate PUBLIC_ENDPOINTS key in $d/manifest.env: $endpoint_key"
		csv_has "$endpoint_hosts" "$endpoint_host" && die "duplicate PUBLIC_ENDPOINTS host in $d/manifest.env: $endpoint_host"
		endpoint_keys="${endpoint_keys:+$endpoint_keys,}$endpoint_key"
		endpoint_hosts="${endpoint_hosts:+$endpoint_hosts,}$endpoint_host"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')"
	while IFS='|' read -r public_key origin_key upstream_key; do
		[[ "$public_key" =~ ^[A-Z][A-Z0-9_]*$ && "$origin_key" =~ ^[A-Z][A-Z0-9_]*$ && "$upstream_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid ROUTE_GROUPS in $d/manifest.env"
		csv_has "$endpoint_keys" "$public_key" || die "ROUTE_GROUPS public key is absent from PUBLIC_ENDPOINTS in $d/manifest.env: $public_key"
		route_public_keys="${route_public_keys:+$route_public_keys,}$public_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" ROUTE_GROUPS)" | tr ';' '\n')"
	while IFS='|' read -r endpoint_key _; do
		csv_has "$route_public_keys" "$endpoint_key" || die "PUBLIC_ENDPOINTS key is absent from ROUTE_GROUPS in $d/manifest.env: $endpoint_key"
	done <<<"$(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')"
	need_file "$d/$(descriptor_value "$d" COMPOSE_FILE)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
	grep -Fq "$alias" "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)" || die "follower route does not target NETWORK_ALIAS in $d/manifest.env"
	for k in $(descriptor_value "$d" IMAGE_KEYS); do
		[[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid IMAGE_KEYS entry in $d/manifest.env: $k"
		# Candidate validation always uses the committed image manifest. A runtime
		# foundation sync may retain the installed app image manifest while it
		# deliberately skips all singleton actions.
		if [[ "${VALIDATE_CHECK:-0}" == 1 ]] || app_in_reconcile_scope "$d"; then
			[[ -n "$(env_value "$k" "$APP_IMAGE_ENV")" ]] || die "$k missing from image manifest"
		fi
	done
	if app_in_reconcile_scope "$d" && [[ "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 0 ]]; then
		app_compose "$d"
		services="$("${compose_command[@]}" config --services 2>/dev/null || true)"
		[[ -n "$services" ]] || die "unable to evaluate active Compose project: $d"
		printf '%s\n' "$services" | grep -Fxq "$(descriptor_value "$d" SERVICE_NAME)" || die "SERVICE_NAME is absent from Compose project: $d"
		health_service="$(descriptor_value "$d" HEALTH_SERVICE)"
		[[ -z "$health_service" || "$(printf '%s\n' "$services" | grep -Fx "$health_service" || true)" == "$health_service" ]] || die "HEALTH_SERVICE is absent from Compose project: $d"
	fi
	if [[ "$(basename "$d")" == newapi ]] && app_in_reconcile_scope "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		[[ "$(env_value NEW_API_SQL_DSN)" =~ ^postgres(ql)?:// ]] || die 'production New API requires a postgres:// or postgresql:// DSN'
		[[ "$(env_value NEW_API_SQL_DSN)" != *replace-with* && "$(env_value NEW_API_SESSION_SECRET)" != *replace-with* && "$(env_value NEW_API_CRYPTO_SECRET)" != *replace-with* ]] || die 'production New API secrets and DSN must be configured'
	fi
	if [[ "$(basename "$d")" == librechat ]] && app_in_reconcile_scope "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			[[ -n "$(env_value "$k")" && "$(env_value "$k")" != replace-with-* ]] || die "production LibreChat requires $k"
		done
		valid_mongo_uri "$(env_value LIBRECHAT_MONGO_URI)" || die 'LibreChat Mongo URI is malformed; use one mongodb:// or mongodb+srv:// URI with a valid host'
		[[ "$(env_value LIBRECHAT_REDIS_URI)" =~ ^rediss:// ]] || die 'LibreChat Upstash Redis URI must use TLS (rediss://)'
		[[ "$(env_value LIBRECHAT_AWS_ENDPOINT_URL)" =~ ^https:// ]] || die 'LibreChat R2 endpoint must use https://'
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			! placeholder_value "$(env_value "$k")" || die "production LibreChat placeholder is not allowed: $k"
		done
	fi
	if [[ "$(basename "$d")" == librechat ]]; then
		case "$(app_policy_value "$d" MONGO_BACKUP_ENABLED)" in true | false) ;; *) die 'LibreChat MONGO_BACKUP_ENABLED must be true or false' ;; esac
		primary="$(app_policy_value "$d" MONGO_BACKUP_NODE_ID)"
		csv_has "$nodes" "$primary" || die 'LibreChat MONGO_BACKUP_NODE_ID is absent from NODES'
	fi
	case "$(descriptor_value "$d" STATE_MODE)" in
	sqlite)
		[[ -n "$(descriptor_value "$d" SQLITE_PATHS)" ]] || die "SQLite app is missing SQLITE_PATHS: $d"
		! grep -Eiq 'REDIS_CONN_STRING|SQL_DSN|postgres|redis' "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "SQLite app must not define Redis or PostgreSQL: $d"
		while IFS= read -r k; do
			[[ -n "$k" ]] || continue
			grep -Fq "$k" "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "SQLite path is absent from Compose: $k"
		done <<<"$(printf '%s\n' "$(descriptor_value "$d" SQLITE_PATHS)" | tr ',' '\n')"
		if app_in_reconcile_scope "$d"; then
			while IFS= read -r k; do
				[[ -n "$k" ]] || continue
				[[ -n "$(app_value "$d" "$k")" ]] || die "production SQLite app requires $k"
				! placeholder_value "$(app_value "$d" "$k")" || die "production SQLite app placeholder is not allowed: $k"
			done <<<"$(descriptor_secret_keys "$d")"
		fi
		;;
	pglite)
		local pglite_rel
		pglite_rel="$(descriptor_value "$d" PGLITE_PATH_REL)"
		[[ -n "$pglite_rel" ]] || die "PGlite app is missing PGLITE_PATH_REL: $d"
		safe_relative "$pglite_rel" || die "unsafe PGLITE_PATH_REL in $d"
		! grep -Eiq '^[[:space:]]{2}(postgres|redis):|AP_QUEUE_MODE|AP_DEV_PIECES' "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "PGlite app must not define PostgreSQL, Redis services, AP_QUEUE_MODE, or AP_DEV_PIECES: $d"
		grep -Fq 'AP_DB_TYPE:' "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "PGlite app must declare AP_DB_TYPE: $d"
		grep -Fq 'AP_CONFIG_PATH:' "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "PGlite app must declare AP_CONFIG_PATH: $d"
		if [[ "$(app_in_reconcile_scope "$d" && printf true || printf false)" == true ]]; then
			[[ -z "$(app_value "$d" AP_QUEUE_MODE)" && -z "$(app_value "$d" AP_DEV_PIECES)" ]] || die "PGlite production must not set legacy AP_QUEUE_MODE or AP_DEV_PIECES: $d"
			storage="$(app_value "$d" FLOWY_FILE_STORAGE_LOCATION)"
			case "$storage" in
			DB) ;;
			S3)
				for k in FLOWY_S3_ENDPOINT FLOWY_S3_BUCKET FLOWY_S3_REGION FLOWY_S3_ACCESS_KEY_ID FLOWY_S3_SECRET_ACCESS_KEY; do
					value="$(app_value "$d" "$k")"
					[[ -n "$value" && "$value" != replace-with-* ]] || die "production PGlite S3 storage requires $k"
					! placeholder_value "$value" || die "production PGlite S3 placeholder is not allowed: $k"
				done
				[[ "$(app_value "$d" FLOWY_S3_ENDPOINT)" =~ ^https:// ]] || die 'production Flowy S3 endpoint must use https://'
				;;
			*) die "PGlite file storage must be DB or S3: $d" ;;
			esac
		fi
		;;
	'' | files | ephemeral) ;;
	*) die "unsupported STATE_MODE in $d/manifest.env" ;;
	esac
	if [[ "$(app_upstream_mode "$d")" == singleton && "$(app_in_reconcile_scope "$d" && printf true || printf false)" == true ]]; then
		while IFS= read -r k; do
			[[ -n "$k" ]] || continue
			value="$(app_value "$d" "$k")"
			[[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "active singleton requires a non-empty single-line secret: $k"
			min_length="$(descriptor_secret_min_length "$d" "$k")"
			((${#value} >= min_length)) || die "active singleton secret $k must contain at least $min_length characters"
			regex="$(descriptor_secret_regex "$d" "$k")"
			[[ -z "$regex" || "$value" =~ $regex ]] || die "active singleton secret $k does not match its configured format"
			! placeholder_value "$value" || die "active singleton secret placeholder is not allowed: $k"
		done <<<"$(descriptor_secret_keys "$d")"
	fi
	if [[ "$(basename "$d")" == librechat ]]; then
		compose_file="$d/$(descriptor_value "$d" COMPOSE_FILE)"
		yaml_file="$d/librechat.yaml"
		nginx_file="$d/client.nginx.conf"
		need_file "$yaml_file"
		need_file "$nginx_file"
		# This profile deliberately keeps the follower footprint to API, admin, and Nginx.
		for forbidden in mongodb redis meilisearch vectordb rag_api pgvector; do
			! grep -Eiq "^[[:space:]]{2}${forbidden}:" "$compose_file" || die "LibreChat must not define local service: $forbidden"
		done
		! grep -Eiq 'MEILI_HOST|RAG_API_URL|RAG_PORT|LIBRECHAT_CODE_BASEURL|LIBRECHAT_CODE_API_KEY' "$compose_file" || die 'LibreChat has a forbidden local search, RAG, or code endpoint'
		! grep -Eiq '^[[:space:]]*(mcpServers:|[^#].*type:[[:space:]]*stdio)' "$yaml_file" || die 'LibreChat production YAML must not configure process-backed MCP'
		! grep -Eiq 'execute_code|file_search|web_search|stateful_code_sessions|programmatic_tools|run_in_background|tool_intents' "$yaml_file" || die 'LibreChat YAML enables a forbidden capability'
		grep -Fq 'location = /health' "$nginx_file" || die 'LibreChat Nginx must define an explicit /health endpoint'
		grep -Fq 'return 200 "OK\n"' "$nginx_file" || die 'LibreChat Nginx health endpoint must return OK'
		grep -Fq 'mem_limit:' "$compose_file" || die 'LibreChat Compose must define memory limits'
		grep -Fq 'pids_limit:' "$compose_file" || die 'LibreChat Compose must define PID limits'
		grep -Fq 'NODE_OPTIONS:' "$compose_file" || die 'LibreChat Compose must define Node heap limits'
	fi
}
validate_app_config_file() {
	local d="$1" file="$2" line key
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*) key="${line%%=*}" ;;
		*) die "invalid assignment in committed app configuration: $file" ;;
		esac
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid app configuration key in $file: $key"
		csv_has "$(descriptor_value "$d" ENV_KEYS)" "$key" || die "undeclared app configuration key in $file: $key"
		! csv_has "$(descriptor_value "$d" CLUSTER_SECRET_KEYS),$(descriptor_value "$d" NODE_SECRET_KEYS)" "$key" || die "secret key is forbidden in committed app configuration: $key"
	done <"$file"
}
validate_committed_overrides() {
	local root="$CONTROL_ROOT/current/config/cluster/overrides" file rel node name app d
	[[ -d "$root" ]] || return 0
	while IFS= read -r file; do
		rel="${file#"$root/"}"
		[[ "$rel" == */*.env && "$rel" != */*/* ]] || die "invalid app override path: $file"
		node="${rel%%/*}"
		name="${rel#*/}"
		app="${name%.env}"
		[[ "$name" == "$app.env" && "$app" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid app override filename: $file"
		csv_has "$(policy_value NODE_IDS)" "$node" || die "app override references unknown node: $file"
		app_declared "$app" || die "app override references unknown app: $file"
		d="$APPS_ROOT/$app"
		validate_app_config_file "$d" "$file"
	done <<<"$(find "$root" -mindepth 2 -maxdepth 2 -type f -print | sort)"
	while IFS= read -r file; do
		[[ "$file" == *.env ]] || die "unsupported file in app override tree: $file"
	done <<<"$(find "$root" -mindepth 1 -type f -print | sort)"
}
validate_observer_env() {
	local buffer retention ingest_url ingest_site ingest_url_base ingest_user ingest_token organization stream observer_site observer_api_url observer_data_root root_user root_password durable_warn buffer_warn_percent shipper_threads heartbeat_interval buffer_when_full stream_timeout stream_timeout_value stream_timeout_unit stream_timeout_seconds env_file
	observer_ingest_user_valid() {
		local value="$1"
		[[ -n "$value" && "${#value}" -le 256 ]] || return 1
		case "$value" in *[!A-Za-z0-9_-]*) return 1 ;; esac
	}
	observer_ingest_token_valid() {
		local value="$1" suffix
		case "$value" in o2oi_*) suffix="${value#o2oi_}" ;; *) return 1 ;; esac
		[[ "${#suffix}" -eq 32 ]] || return 1
		case "$suffix" in *[!A-Za-z0-9]*) return 1 ;; esac
	}
	if foundation_active observer-collector; then
		env_file="$(foundation_env observer-collector)"
		observer_data_root="$(env_value OBSERVER_DATA_ROOT "$env_file")"
		observer_data_root="${observer_data_root:-$PLATFORM_ROOT/observer}"
		case "$observer_data_root" in
		"$PLATFORM_ROOT"/*) [[ "$observer_data_root" != "$PLATFORM_ROOT/" && "$observer_data_root" != *..* && "$observer_data_root" != *$'\n'* && "$observer_data_root" != *$'\r'* ]] || die 'Observer data root must be a non-root path below PLATFORM_ROOT' ;;
		*) die 'Observer data root must be below PLATFORM_ROOT' ;;
		esac
		buffer="$(env_value OBSERVER_LOG_BUFFER_MAX_BYTES "$env_file")"
		[[ -n "$buffer" ]] || buffer=536870912
		[[ "$buffer" =~ ^[0-9]+$ ]] || die 'Observer collector buffer size must be an integer number of bytes'
		((buffer >= 268435488 && buffer <= 8589934592)) || die 'Observer collector buffer size must be between 268435488 bytes (Vector disk-buffer minimum) and 8 GiB'
		buffer_when_full="$(env_value OBSERVER_LOG_BUFFER_WHEN_FULL "$env_file")"
		buffer_when_full="${buffer_when_full:-block}"
		case "$buffer_when_full" in
		block | drop_newest) ;;
		*) die 'Observer collector buffer policy must be block or drop_newest' ;;
		esac
		durable_warn="$(env_value OBSERVER_DURABLE_WARN_BYTES "$env_file")"
		durable_warn="${durable_warn:-8589934592}"
		[[ "$durable_warn" =~ ^[0-9]+$ ]] && ((durable_warn > 0)) || die 'Observer durable-data warning threshold must be a positive integer number of bytes'
		buffer_warn_percent="$(env_value OBSERVER_LOG_BUFFER_WARN_PERCENT "$env_file")"
		buffer_warn_percent="${buffer_warn_percent:-80}"
		[[ "$buffer_warn_percent" =~ ^[0-9]+$ ]] && ((buffer_warn_percent >= 1 && buffer_warn_percent <= 100)) || die 'Observer collector buffer warning percentage must be between 1 and 100'
		shipper_threads="$(env_value OBSERVER_LOG_SHIPPER_THREADS "$env_file")"
		shipper_threads="${shipper_threads:-1}"
		[[ "$shipper_threads" =~ ^[0-9]+$ ]] && ((shipper_threads >= 1 && shipper_threads <= 8)) || die 'Observer collector thread count must be between 1 and 8'
		heartbeat_interval="$(env_value OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS "$env_file")"
		heartbeat_interval="${heartbeat_interval:-300}"
		[[ "$heartbeat_interval" =~ ^[0-9]+$ ]] && ((heartbeat_interval >= 60 && heartbeat_interval <= 900)) || die 'Observer heartbeat interval must be between 60 and 900 seconds'
		stream_timeout="$(env_value OBSERVER_LOG_PROXY_STREAM_TIMEOUT "$env_file")"
		stream_timeout="${stream_timeout:-24h}"
		[[ "$stream_timeout" =~ ^([1-9][0-9]{0,5})(s|m|h|d)$ ]] || die 'Observer Docker stream timeout must be a positive integer followed by s, m, h, or d'
		stream_timeout_value="${BASH_REMATCH[1]}"
		stream_timeout_unit="${BASH_REMATCH[2]}"
		case "$stream_timeout_unit" in s) stream_timeout_seconds="$stream_timeout_value" ;; m) stream_timeout_seconds=$((stream_timeout_value * 60)) ;; h) stream_timeout_seconds=$((stream_timeout_value * 3600)) ;; d) stream_timeout_seconds=$((stream_timeout_value * 86400)) ;; esac
		((stream_timeout_seconds >= 3600 && stream_timeout_seconds <= 604800)) || die 'Observer Docker stream timeout must be between 1 hour and 7 days'
		ingest_user="$(env_value OBSERVER_INGEST_USER "$env_file")"
		observer_ingest_user_valid "$ingest_user" || die 'Observer ingestion username must contain only letters, numbers, hyphens, or underscores'
		ingest_token="$(env_value OBSERVER_INGEST_TOKEN "$env_file")"
		if [[ "$ingest_token" == bootstrap-pending ]]; then
			[[ "$(node_role)" == leader && "${PLATFORM_ALLOW_OBSERVER_BOOTSTRAP:-0}" == 1 ]] || die 'Observer ingestion token is still bootstrap-pending; provision it on the Leader before normal recovery'
		else
			observer_ingest_token_valid "$ingest_token" || die 'Observer ingestion token must use the OpenObserve o2oi_<32 characters> format'
		fi
		ingest_site="$(env_value OBSERVER_INGEST_SITE "$env_file")"
		[[ "$ingest_site" =~ ^https?://[^[:space:]/]+$ ]] || die 'Observer ingestion site must use http:// or https:// and contain no path'
		ingest_url="$(env_value OBSERVER_INGEST_URL "$env_file")"
		[[ "$ingest_url" =~ ^https?://[^[:space:]/]+$ ]] || die 'Observer collector ingestion URL must use http:// or https:// and contain no path'
		[[ "$ingest_url" == "$ingest_site" ]] || die 'Observer ingestion URL and site must match exactly'
		ingest_url_base="$(env_value OBSERVER_API_URL "$env_file")"
		[[ -z "$ingest_url_base" || "$ingest_url_base" =~ ^https?://[^[:space:]/]+$ ]] || die 'Observer API URL must use http:// or https:// and contain no path'
		organization="$(env_value OBSERVER_LOG_ORGANIZATION "$env_file")"
		stream="$(env_value OBSERVER_LOG_STREAM "$env_file")"
		organization="${organization:-default}"
		stream="${stream:-docker}"
		[[ "$organization" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Observer log organization contains invalid path characters'
		[[ "$stream" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Observer log stream contains invalid path characters'
	fi
	if foundation_active observer-controller; then
		env_file="$(foundation_env observer-controller)"
		observer_site="$(env_value OBSERVER_SITE "$env_file")"
		[[ "$observer_site" =~ ^https?://[^[:space:]/]+$ ]] || die 'Observer site URL must use http:// or https:// and contain no path'
		observer_api_url="$(env_value OBSERVER_API_URL "$env_file")"
		[[ -z "$observer_api_url" || "$observer_api_url" =~ ^https?://[^[:space:]/]+$ ]] || die 'Observer API URL must use http:// or https:// and contain no path'
		root_user="$(env_value OBSERVER_ROOT_USER_EMAIL "$env_file")"
		[[ "$root_user" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Observer root email is invalid'
		root_password="$(env_value OBSERVER_ROOT_USER_PASSWORD "$env_file")"
		[[ -n "$root_password" && "$root_password" != *$'\n'* && "$root_password" != *$'\r'* ]] || die 'Observer root password must be a non-empty single-line value'
		! placeholder_value "$root_user" || die 'Observer root email is still a placeholder'
		! placeholder_value "$root_password" || die 'Observer root password is still a placeholder'
		retention="$(env_value OBSERVER_DATA_RETENTION_DAYS "$env_file")"
		retention="${retention:-30}"
		[[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1 && retention <= 365)) || die 'Observer retention days must be between 1 and 365'
		durable_warn="$(env_value OBSERVER_DURABLE_WARN_BYTES "$env_file")"
		durable_warn="${durable_warn:-8589934592}"
		[[ "$durable_warn" =~ ^[0-9]+$ ]] && ((durable_warn > 0)) || die 'Observer durable-data warning threshold must be a positive integer number of bytes'
	fi
}
validate_images() {
	local f="$1" k v
	while IFS='=' read -r k v; do
		[[ -z "$k" || "$k" == \#* ]] && continue
		[[ "$v" =~ @sha256:[0-9a-f]{64}$ ]] || die "$k must be digest-pinned"
	done <"$f"
}
validate_foundations() {
	local component manifest key value policy service roles role compose_file env_file ids='' caddy_manifest caddy_policy
	for manifest in "$FOUNDATION_MANIFEST_ROOT"/*.env; do
		[[ -f "$manifest" ]] || continue
		component="$(env_value COMPONENT_ID "$manifest")"
		for key in MANIFEST_VERSION COMPONENT_ID START_ORDER SERVICE_ID MANDATORY ROLES POLICY_FILE COMPOSE_FILE ENV_FILE IMAGE_KEYS; do
			value="$(env_value "$key" "$manifest")"
			[[ -n "$value" ]] || die "$key is required in foundation manifest: $manifest"
		done
		[[ "$(env_value MANIFEST_VERSION "$manifest")" == 1 ]] || die "unsupported foundation manifest version: $manifest"
		[[ "$(env_value START_ORDER "$manifest")" =~ ^[0-9]+$ ]] || die "invalid foundation START_ORDER: $manifest"
		[[ "$(basename "$manifest" .env)" == "$component" && "$component" =~ ^[a-z][a-z0-9-]*$ ]] || die "foundation manifest filename and COMPONENT_ID disagree: $manifest"
		csv_has "$ids" "$component" && die "duplicate foundation component ID: $component"
		ids="${ids:+$ids,}$component"
		service="$(env_value SERVICE_ID "$manifest")"
		[[ "$service" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid foundation service ID: $manifest"
		case "$(env_value MANDATORY "$manifest")" in true | false) ;; *) die "foundation MANDATORY must be true or false: $manifest" ;; esac
		roles="$(env_value ROLES "$manifest")"
		while IFS= read -r role; do case "$role" in leader | follower) ;; *) die "invalid foundation role $role: $manifest" ;; esac done <<<"$(printf '%s\n' "$roles" | tr ',' '\n')"
		for key in POLICY_FILE COMPOSE_FILE ENV_FILE; do safe_relative "$(env_value "$key" "$manifest")" || die "unsafe foundation path in $manifest: $key"; done
		policy="$CONTROL_ROOT/current/config/$(env_value POLICY_FILE "$manifest")"
		need_file "$policy"
		case "$(env_value ENABLED "$policy")" in true | false) ;; *) die "foundation policy ENABLED must be true or false: $policy" ;; esac
		if [[ "$(env_value MANDATORY "$manifest")" == true && "$(env_value ENABLED "$policy")" != true ]]; then
			die "mandatory foundation service cannot be disabled: $service"
		fi
		compose_file="$(env_value COMPOSE_FILE "$manifest")"
		env_file="$FOUNDATION_ENV_ROOT/$(env_value ENV_FILE "$manifest")"
		need_file "$FOUNDATION_ROOT/$compose_file"
		need_file "$env_file"
		for key in $(env_value IMAGE_KEYS "$manifest"); do
			[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid foundation IMAGE_KEYS entry: $manifest"
			[[ -n "$(env_value "$key" "$FOUNDATION_IMAGE_ENV")" ]] || die "$key missing from foundation image manifest"
		done
	done
	[[ -n "$ids" ]] || die 'no foundation manifests were discovered'
	caddy_manifest="$FOUNDATION_MANIFEST_ROOT/caddy.env"
	need_file "$caddy_manifest"
	[[ "$(env_value COMPONENT_ID "$caddy_manifest")" == caddy ]] || die 'Caddy foundation manifest must declare COMPONENT_ID=caddy'
	[[ "$(env_value SERVICE_ID "$caddy_manifest")" == caddy ]] || die 'Caddy foundation manifest must declare SERVICE_ID=caddy'
	[[ "$(env_value MANDATORY "$caddy_manifest")" == true ]] || die 'Caddy foundation manifest must declare MANDATORY=true'
	[[ "$(env_value ROLES "$caddy_manifest")" == leader,follower ]] || die 'Caddy foundation manifest must declare ROLES=leader,follower'
	caddy_policy="$CONTROL_ROOT/current/config/$(env_value POLICY_FILE "$caddy_manifest")"
	need_file "$caddy_policy"
	[[ "$(env_value ENABLED "$caddy_policy")" == true ]] || die 'Caddy foundation policy must declare ENABLED=true'
}
projects_foundation() {
	local component
	# START_ORDER keeps controllers ahead of collectors and Caddy first without
	# maintaining a second role-to-component map.
	foundation_active caddy && printf 'caddy\n'
	while IFS= read -r component; do
		[[ -n "$component" ]] || continue
		[[ "$component" == caddy ]] && continue
		foundation_active "$component" && printf '%s\n' "$component"
	done <<<"$(foundation_ids)"
}
projects_apps() {
	local d
	while IFS= read -r d; do
		[[ -n "$d" ]] || continue
		app_in_reconcile_scope "$d" && printf 'app:%s\n' "$d"
	done <<<"$(descriptor_ids)"
}
all_projects() {
	foundation_ids
	while IFS= read -r d; do
		[[ -n "$d" ]] || continue
		printf 'app:%s\n' "$d"
	done <<<"$(descriptor_ids)"
}
validate() {
	local d id project alias n ids='' projects='' aliases=''
	if [[ "$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" != 1 ]]; then
		validate_cluster
	fi
	need_file "$APP_ENV"
	if [[ "$PLATFORM_TEST_FAST_VALIDATE" == 0 ]]; then
		validate_images "$APP_IMAGE_ENV"
		validate_images "$FOUNDATION_IMAGE_ENV"
		validate_foundations
		validate_observer_env
	fi
	need_file "$CONTROL_ROOT/current/config/Caddyfile"
	need_file "$FOUNDATION_ROOT/caddy.yml"
	while IFS= read -r d; do
		[[ -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" || "$(basename "$d")" == "$PLATFORM_TEST_ONLY_DESCRIPTOR" ]] || continue
		validate_descriptor "$d"
		id="$(descriptor_value "$d" APP_ID)"
		project="$(descriptor_value "$d" COMPOSE_PROJECT)"
		alias="$(descriptor_value "$d" NETWORK_ALIAS)"
		csv_has "$ids" "$id" && die "duplicate app ID: $id"
		csv_has "$projects" "$project" && die "duplicate Compose project: $project"
		csv_has "$aliases" "$alias" && die "duplicate network alias: $alias"
		ids="${ids:+$ids,}$id"
		projects="${projects:+$projects,}$project"
		aliases="${aliases:+$aliases,}$alias"
	done <<<"$(descriptor_ids)"
	validate_committed_overrides
	if [[ "$PLATFORM_TEST_SKIP_RENDER" == 1 ]]; then
		# This branch is only for fast negative tests. All structural and secret
		# validation above still runs; no runtime files are changed.
		return 0
	fi
	render_routes
	if [[ "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 0 && "${VALIDATE_SKIP_EXTERNAL:-0}" == 0 ]]; then
		[[ "${VALIDATE_CHECK:-0}" == 1 ]] || ensure_network
		while IFS= read -r n; do
			[[ -n "$n" ]] || continue
			foundation_active "$n" || continue
			foundation_compose "$n"
			"${compose_command[@]}" config --quiet
		done <<<"$(projects_foundation)"
		while IFS= read -r d; do
			[[ -n "$d" ]] || continue
			app_compose "${d#app:}"
			"${compose_command[@]}" config --quiet
		done <<<"$(projects_apps)"
		docker run --rm --pull=never --env-file "$APP_ENV" --env-file "$NODE_CONFIG_FILE" -v "${RUNTIME_CONFIG_CANDIDATE:-$RUNTIME_ROOT/config}:/etc/caddy:ro" "$(env_value CADDY_IMAGE "$FOUNDATION_IMAGE_ENV")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	elif [[ "${VALIDATE_SKIP_EXTERNAL:-0}" == 1 ]]; then
		[[ "${PLATFORM_RECOVERY_STAMP_MATCH:-0}" == 1 || "${PLATFORM_BOOTSTRAP_VALIDATION_REUSE:-0}" == 1 ]] ||
			die 'internal validation reuse was not authorized by a successful full validation or matching stamp'
	fi
	[[ "${VALIDATE_CHECK:-0}" == 1 ]] && {
		cleanup_candidate
		unset RUNTIME_CONFIG_CANDIDATE
	} || [[ "${VALIDATE_STAGE_ONLY:-0}" == 1 ]] || {
		commit_routes
		write_validation_stamp "$(validation_stamp_release 2>/dev/null || true)"
	}
}
project_enabled() {
	[[ "$1" == caddy ]] && {
		foundation_active caddy
		return
	}
	if [[ "$1" == app:* ]]; then
		# Normal application reconciliation deliberately skips singleton start and
		# stop operations. Explicit singleton-stop sets the force flag below.
		if [[ "${PLATFORM_SKIP_SINGLETONS:-0}" == 1 && "${PLATFORM_FORCE_SINGLETON_ACTION:-0}" != 1 && "$(app_upstream_mode "${1#app:}")" == singleton ]]; then
			if [[ "${PLATFORM_RECONCILE_DISABLED_SINGLETONS:-0}" == 1 ]] && ! app_policy_enabled "$(basename "${1#app:}")"; then
				return 1
			fi
			return 0
		fi
		app_active "${1#app:}"
	else
		foundation_active "$1"
	fi
}
beszel_enrollment_pending() {
	[[ "$1" == beszel-worker && (! -s "$(env_value BESZEL_KEY_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" || ! -s "$(env_value BESZEL_TOKEN_FILE "$FOUNDATION_ENV_ROOT/beszel.env")") ]]
}
project_ids() {
	if beszel_enrollment_pending "$1"; then
		"${compose_command[@]}" ps --all -q beszel-socket-proxy
		return
	fi
	"${compose_command[@]}" ps --all -q
}
project_is_healthy() {
	local ids id state health_mode=process health_service health_ids health_id
	project_enabled "$1" || return 0
	if [[ "$1" == app:* ]]; then
		app_compose "${1#app:}"
		health_mode="$(descriptor_value "${1#app:}" HEALTH_MODE)"
		health_service="$(descriptor_value "${1#app:}" HEALTH_SERVICE)"
	else
		foundation_compose "$1"
		health_service="$(foundation_health_service "$1")"
	fi
	# A new Beszel worker cannot start its agent until the Leader provisions the
	# enrollment key and token.  During that bootstrap window start_project only
	# brings up the socket proxy, so requiring beszel-agent here would make the
	# worker appear unhealthy and prevent recovery from completing.  Once both
	# credentials exist, project_ids includes the agent again and its healthcheck
	# is enforced by the normal path below.
	if beszel_enrollment_pending "$1"; then
		health_service=''
	fi
	ids="$(project_ids "$1")"
	[[ -n "$ids" ]] || return 1
	if [[ -n "$health_service" ]]; then
		health_ids="$("${compose_command[@]}" ps --all -q "$health_service")"
		[[ -n "$health_ids" ]] || return 1
		while IFS= read -r health_id; do
			[[ -n "$health_id" ]] || continue
			state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$health_id")"
			[[ "$state" == 'running healthy' ]] || return 1
		done <<<"$health_ids"
	fi
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
		if [[ "$health_mode" == healthcheck ]]; then
			[[ "$state" == 'running healthy' ]] || return 1
		else
			[[ "$state" == 'running healthy' || "$state" == 'running none' ]] || return 1
		fi
	done <<<"$ids"
}
inspect_container_state() {
	docker inspect --format 'container={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} health={{with (index .State "Health")}}{{.Status}}{{else}}none{{end}}{{with (index .State "Health")}}{{range .Log}}{{printf "\n  health exit=%v output=%q" .ExitCode .Output}}{{end}}{{end}}' "$1"
}
report_compose_failure() {
	local id
	printf 'platformctl: Compose project state after failed health wait:\n' >&2
	"${compose_command[@]}" ps --all >&2 || true
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		inspect_container_state "$id" >&2 || true
	done <<<"$("${compose_command[@]}" ps --all -q 2>/dev/null || true)"
}
woodpecker_agent_component() {
	case "$1" in
	woodpecker-worker | foundation-woodpecker-worker) printf 'woodpecker-worker\n' ;;
	woodpecker-deployer | foundation-woodpecker-deployer) printf 'woodpecker-deployer\n' ;;
	*) return 1 ;;
	esac
}
woodpecker_agent_config_file() {
	local p="$1" component env_file config_root
	component="$(woodpecker_agent_component "$p")" || return 1
	env_file="$(foundation_env "$component")"
	case "$component" in
	woodpecker-worker) config_root="$(env_value WOODPECKER_AGENT_CONFIG_ROOT "$env_file")" ;;
	woodpecker-deployer) config_root="$(env_value WOODPECKER_DEPLOYER_CONFIG_ROOT "$env_file")" ;;
	*) return 1 ;;
	esac
	[[ -n "$config_root" ]] || return 1
	printf '%s/agent.conf\n' "$config_root"
}
woodpecker_agent_auth_failed() {
	local p="$1" id logs
	woodpecker_agent_component "$p" >/dev/null || return 1
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		logs="$(docker logs --tail 100 "$id" 2>&1 || true)"
		[[ "$logs" == *'agent could not auth: AgentID not found in database'* ]] && return 0
	done <<<"$("${compose_command[@]}" ps --all -q 2>/dev/null || true)"
	return 1
}
quarantine_woodpecker_agent_identity() {
	local p="$1" config_file orphan_dir orphan_stamp
	config_file="$(woodpecker_agent_config_file "$p")" || return 1
	[[ -s "$config_file" ]] || return 1
	orphan_dir="$(dirname "$config_file")/orphaned"
	install -d -m 700 "$orphan_dir"
	orphan_stamp="$(date -u '+%Y%m%dT%H%M%SZ').$$"
	mv -f -- "$config_file" "$orphan_dir/agent.conf.$orphan_stamp"
	printf 'platformctl: quarantined stale Woodpecker agent identity: %s\n' "$orphan_dir/agent.conf.$orphan_stamp" >&2
}
repair_woodpecker_agent_identity() {
	local p="$1"
	woodpecker_agent_auth_failed "$p" || return 1
	quarantine_woodpecker_agent_identity "$p"
}
compose_up_wait() {
	if "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
		return 0
	fi
	report_compose_failure
	if [[ -n "${PLATFORM_COMPOSE_PROJECT:-}" ]] && repair_woodpecker_agent_identity "$PLATFORM_COMPOSE_PROJECT"; then
		printf 'platformctl: stale Woodpecker agent identity detected; registering a new identity\n' >&2
		if ! "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
			report_compose_failure
			return 1
		fi
		return 0
	fi
	printf 'platformctl: project did not become healthy; recreating it once\n' >&2
	if ! "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
		report_compose_failure
		return 1
	fi
}
start_project() {
	local p="$1"
	project_enabled "$p" || return
	ensure_network
	PLATFORM_COMPOSE_PROJECT="$p"
	if beszel_enrollment_pending "$p"; then
		foundation_compose "$p"
		if ! compose_up_wait beszel-socket-proxy; then
			unset PLATFORM_COMPOSE_PROJECT
			return 1
		fi
		unset PLATFORM_COMPOSE_PROJECT
		return
	fi
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	if ! compose_up_wait; then
		unset PLATFORM_COMPOSE_PROJECT
		return 1
	fi
	unset PLATFORM_COMPOSE_PROJECT
}
stop_project() {
	local p="$1" project ids
	if ! project_enabled "$p"; then
		# Do not evaluate an inactive app's Compose file: disabled services may
		# intentionally have empty required secrets. Remove only its containers;
		# named volumes and bind-mounted data remain untouched.
		if [[ "$p" == app:* ]]; then
			project="$(descriptor_value "${p#app:}" COMPOSE_PROJECT)"
		else
			[[ -f "$(foundation_manifest_file "$p")" ]] || return 0
			project="foundation-$p"
		fi
		if ! ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"; then
			printf 'platformctl: unable to list containers for inactive project: %s\n' "$project" >&2
			return 1
		fi
		while IFS= read -r id; do
			[[ -n "$id" ]] || continue
			docker rm -f "$id" >/dev/null || return 1
		done <<<"$ids"
		return 0
	fi
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	"${compose_command[@]}" down --remove-orphans
}
stop_inactive() {
	local p failed=0 ids
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		if ! project_enabled "$p" && ! stop_project "$p"; then
			printf 'platformctl: unable to stop inactive project: %s\n' "$p" >&2
			failed=1
		fi
	done <<<"$(all_projects)"
	# Observer used to be a singleton consumer. Its manifest is gone, so it is
	# not discoverable through all_projects. Retire only the old containers;
	# leave its data in place for explicit operator cleanup after verification.
	local id ownership project
	project='app-observer'
	if ! ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then
		printf 'platformctl: unable to list retired Observer containers\n' >&2
		return 1
	fi
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		ownership="$(docker inspect --format '{{ index .Config.Labels "com.aichorage.platform" }}' "$id" 2>/dev/null || true)"
		[[ "$ownership" == llm-hub-lite ]] || continue
		printf 'platformctl: stopping retired Observer container %s\n' "$id" >&2
		if ! docker rm -f "$id" >/dev/null 2>&1; then
			printf 'platformctl: unable to stop retired Observer container %s\n' "$id" >&2
			failed=1
		fi
	done <<<"$ids"
	return "$failed"
}
health_scope() {
	local scope="$1" failed=0 p
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		project_is_healthy "$p" || {
			printf '%s: unhealthy\n' "$p" >&2
			failed=1
		}
	done <<<"$([[ "$scope" == foundation ]] && projects_foundation || projects_apps)"
	return "$failed"
}
health() {
	local failed=0
	health_scope foundation || failed=1
	health_scope consumers || failed=1
	return "$failed"
}
wait_project() {
	local p="$1" elapsed=0 interval="$PLATFORM_WAIT_INTERVAL_SECONDS"
	while ((elapsed < COMPOSE_WAIT_TIMEOUT)); do
		project_is_healthy "$p" && return
		((interval > 0)) || return 1
		sleep "$interval"
		elapsed=$((elapsed + interval))
	done
	return 1
}
reload_caddy() {
	foundation_compose caddy
	if ! "${compose_command[@]}" exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
		return 1
	fi
	"${compose_command[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}
recover() {
	local recover_mode="${1:-}" recover_full=0
	case "$recover_mode" in
	'' | --quiet) ;;
	--full) recover_full=1 ;;
	*) die 'usage: platformctl recover [--quiet|--full]' ;;
	esac
	if [[ "$(node_state)" == retired ]]; then
		retire_node
		return 0
	fi
	if ((recover_full == 1)); then
		VALIDATE_STAGE_ONLY=1 validate
	elif validation_stamp_matches; then
		printf 'platformctl: validation stamp matches; using structural recovery validation\n'
		VALIDATE_SKIP_EXTERNAL=1 PLATFORM_RECOVERY_STAMP_MATCH=1 VALIDATE_STAGE_ONLY=1 validate
	elif [[ "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 ]]; then
		printf 'platformctl: validation stamp is missing or stale; running full recovery validation\n'
		VALIDATE_STAGE_ONLY=1 validate
	elif [[ "$PLATFORM_TEST_SKIP_RENDER" == 0 || "$PLATFORM_FORCE_SINGLETON_ROUTE" == 1 ]]; then
		# Test fixtures may validate the candidate once before exercising repeated
		# reboot/recovery branches. Keep route generation available when a test
		# explicitly requests it, but do not rebuild an unused candidate each time.
		render_routes
	fi
	local p failed=0
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		start_project "$p"
	done <<<"$(projects_foundation)"
	health_scope foundation || die 'foundation recovery failed'
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		if ! start_project "$p"; then
			printf 'platformctl: consumer start failed: %s\n' "$p" >&2
			failed=1
		fi
	done <<<"$(projects_apps)"
	if ! stop_inactive; then
		printf 'platformctl: one or more inactive projects could not be stopped; recovery will retry\n' >&2
		failed=1
	fi
	if ! health_scope consumers; then
		printf 'platformctl: consumer recovery is incomplete; foundation remains healthy and recovery will retry\n' >&2
		failed=1
	fi
	commit_routes
	reload_caddy
	if ((failed == 0)); then
		write_validation_stamp "$(validation_stamp_release 2>/dev/null || true)"
	fi
	return "$failed"
}
retire_node() {
	local marker="$CONFIG_ROOT/retired" p
	[[ "$(node_state)" == retired ]] || die 'retire-node requires NODE_STATE=retired'
	install -d -m 700 "$CONFIG_ROOT"
	printf 'node=%s\nretired_utc=%s\n' "$(node_id)" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$marker"
	chmod 600 "$marker"
	# Stop consumers first and Caddy last. Containers and bind-mounted state are
	# removed independently, so a missing secret cannot prevent retirement.
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		PLATFORM_FORCE_SINGLETON_ACTION=1 stop_project "$p" || die "unable to retire project: $p"
	done <<<"$(all_projects | awk '{ item[NR]=$0 } END { for (i=NR; i>0; i--) print item[i] }')"
	printf 'retired node %s; persistent application and foundation data were retained\n' "$(node_id)"
}
sync() {
	local scope="${1:-all}" p
	[[ "$scope" == apps || "$scope" == foundation || "$scope" == all ]] || die 'sync scope must be apps, foundation, or all'
	[[ "${PLATFORM_RECREATE_FOUNDATION:-0}" == 0 || "${PLATFORM_RECREATE_FOUNDATION:-0}" == 1 ]] || die 'PLATFORM_RECREATE_FOUNDATION must be 0 or 1'
	if [[ "${PLATFORM_BOOTSTRAP_VALIDATION_REUSE:-0}" == 1 ]]; then
		VALIDATE_SKIP_EXTERNAL=1 PLATFORM_BOOTSTRAP_VALIDATION_REUSE=1 VALIDATE_STAGE_ONLY=1 validate
	elif [[ "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 ]]; then
		VALIDATE_STAGE_ONLY=1 validate
	elif [[ "$PLATFORM_TEST_SKIP_RENDER" == 0 || "$PLATFORM_FORCE_SINGLETON_ROUTE" == 1 ]]; then
		# The test fixture was validated explicitly. Render only when the caller
		# needs to exercise route commit/reload behavior; mocked sync cases can
		# avoid this filesystem-heavy step.
		render_routes
	fi
	if [[ "$scope" == foundation || "$scope" == all ]]; then
		while IFS= read -r p; do
			[[ -n "$p" ]] || continue
			if [[ "${PLATFORM_RECREATE_FOUNDATION:-0}" == 1 ]]; then
				printf 'Recreating foundation project to apply installed configuration: %s\n' "$p"
				recreate_project "$p"
			else
				start_project "$p"
			fi
		done <<<"$(projects_foundation)"
		health_scope foundation || die 'foundation synchronization failed'
	fi
	if [[ "$scope" == apps || "$scope" == all ]]; then
		while IFS= read -r p; do
			[[ -n "$p" ]] || continue
			start_project "$p"
		done <<<"$(projects_apps)"
		stop_inactive || die 'inactive project cleanup failed'
		health_scope consumers
	fi
	commit_routes
	reload_caddy
	write_validation_stamp "$(validation_stamp_release 2>/dev/null || true)"
}
diagnose_projects() {
	case "$1" in
	foundation)
		projects_foundation
		;;
	consumers)
		projects_apps
		;;
	all)
		projects_foundation
		projects_apps
		;;
	app:*)
		local id="${1#app:}" d
		while IFS= read -r d; do
			[[ "$(basename "$d")" == "$id" ]] || continue
			printf 'app:%s\n' "$d"
			return 0
		done <<<"$(descriptor_ids)"
		;;
	*)
		return 1
		;;
	esac
}
diagnose() {
	local scope="${1:-all}" p id
	case "$scope" in
	foundation | consumers | all) ;;
	app:*) app_declared "${scope#app:}" || die "unknown application: ${scope#app:}" ;;
	*) die 'diagnose scope must be foundation, consumers, all, or app:<id>' ;;
	esac
	printf 'platformctl diagnose: node=%s role=%s scope=%s\n' "$(node_id)" "$(node_role)" "$scope"
	printf 'control_current=%s\ncontrol_previous=%s\nservice_current=%s\nservice_previous=%s\nmaintenance=%s\n' \
		"$(readlink "$CONTROL_ROOT/current" 2>/dev/null || printf '<missing>')" \
		"$(readlink "$CONTROL_ROOT/previous" 2>/dev/null || printf '<missing>')" \
		"$(readlink "$APP_ROOT/current" 2>/dev/null || printf '<missing>')" \
		"$(readlink "$APP_ROOT/previous" 2>/dev/null || printf '<missing>')" \
		"$(maintenance status 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
	if [[ "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)" != "$(readlink "$APP_ROOT/current" 2>/dev/null || true)" ]]; then
		printf 'release_divergence=control_and_service_differ\n'
	fi
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		printf '\n[%s]\n' "$p"
		if [[ "$p" == app:* ]]; then
			app_compose "${p#app:}"
		else
			foundation_compose "$p"
		fi
		"${compose_command[@]}" ps --all 2>&1 | sed -n '1,80p' || true
		while IFS= read -r id; do
			[[ -n "$id" ]] || continue
			inspect_container_state "$id" 2>&1 | sed -n '1,24p' || true
		done <<<"$("${compose_command[@]}" ps --all -q 2>/dev/null || true)"
	done <<<"$(diagnose_projects "$scope")"
	if [[ "$scope" == foundation || "$scope" == all ]]; then
		local observer_env observer_root observer_data observer_buffer observer_bytes buffer_bytes buffer_max durable_warn buffer_warn_percent utilization observer_shipper_id observer_controller_id observer_recent observer_controller_recent
		observer_env="$(foundation_env observer-collector)"
		if [[ -r "$observer_env" ]]; then
			observer_root="$(env_value OBSERVER_DATA_ROOT "$observer_env")"
			observer_root="${observer_root:-$PLATFORM_ROOT/observer}"
			buffer_max="$(env_value OBSERVER_LOG_BUFFER_MAX_BYTES "$observer_env")"
			buffer_max="${buffer_max:-536870912}"
			durable_warn="$(env_value OBSERVER_DURABLE_WARN_BYTES "$observer_env")"
			durable_warn="${durable_warn:-8589934592}"
			buffer_warn_percent="$(env_value OBSERVER_LOG_BUFFER_WARN_PERCENT "$observer_env")"
			buffer_warn_percent="${buffer_warn_percent:-80}"
			if foundation_active observer-controller; then
				observer_data="$observer_root/data"
				if observer_bytes="$(path_bytes "$observer_data")"; then
					printf '\n[observer-storage]\npath=%s bytes=%s warn_bytes=%s retention_days=%s\n' \
						"$observer_data" "$observer_bytes" "$durable_warn" "$(env_value OBSERVER_DATA_RETENTION_DAYS "$observer_env" | sed '/^$/s//30/')"
					if ((observer_bytes >= durable_warn)); then
						printf 'WARNING: Observer durable data is at or above its %s-byte warning threshold; retention remains time-based and no data was deleted.\n' "$durable_warn" >&2
					fi
				else
					printf '\n[observer-storage]\npath=%s state=missing warn_bytes=%s retention_days=%s\n' \
						"$observer_data" "$durable_warn" "$(env_value OBSERVER_DATA_RETENTION_DAYS "$observer_env" | sed '/^$/s//30/')"
				fi
				foundation_compose observer-controller
				observer_controller_id="$("${compose_command[@]}" ps --all -q observer-controller 2>/dev/null | head -n1 || true)"
				if [[ -n "$observer_controller_id" ]]; then
					observer_controller_recent="$(docker logs --tail 120 "$observer_controller_id" 2>&1 | grep -Ei 'error|warn|failed|flatten' | tail -n 20 | redact_observer_output || true)"
					printf '\n[observer-controller-recent]\n'
					[[ -n "$observer_controller_recent" ]] && printf '%s\n' "$observer_controller_recent" || printf 'state=no-recent-warnings-or-errors\n'
				else
					printf '\n[observer-controller-recent]\nstate=container-missing\n'
				fi
			fi
			if foundation_active observer-collector; then
				observer_buffer="$observer_root/collector-buffer"
				if buffer_bytes="$(path_bytes "$observer_buffer")"; then
					utilization="$(awk -v bytes="$buffer_bytes" -v maximum="$buffer_max" 'BEGIN { if (maximum > 0) printf "%.1f", (bytes * 100) / maximum; else print "0.0" }')"
					printf '\n[observer-buffer]\npath=%s bytes=%s max_bytes=%s utilization_percent=%s warn_percent=%s\n' \
						"$observer_buffer" "$buffer_bytes" "$buffer_max" "$utilization" "$buffer_warn_percent"
					if awk -v bytes="$buffer_bytes" -v maximum="$buffer_max" -v threshold="$buffer_warn_percent" 'BEGIN { exit !(maximum > 0 && bytes * 100 >= maximum * threshold) }'; then
						printf 'WARNING: Observer collector buffer is at or above %s%%; delivery may be dropping newest records if it reaches max_bytes.\n' "$buffer_warn_percent" >&2
					fi
				else
					printf '\n[observer-buffer]\npath=%s state=missing max_bytes=%s warn_percent=%s\n' \
						"$observer_buffer" "$buffer_max" "$buffer_warn_percent"
				fi
				foundation_compose observer-collector
				observer_shipper_id="$("${compose_command[@]}" ps --all -q observer-log-shipper 2>/dev/null | head -n1 || true)"
				if [[ -n "$observer_shipper_id" ]]; then
					observer_recent="$(docker logs --tail 80 "$observer_shipper_id" 2>&1 | grep -Ei 'error|warn|failed|retry|buffer' | tail -n 20 | redact_observer_output || true)"
					printf '\n[observer-collector-recent]\n'
					[[ -n "$observer_recent" ]] && printf '%s\n' "$observer_recent" || printf 'state=no-recent-warnings-or-errors\n'
				else
					printf '\n[observer-collector-recent]\nstate=container-missing\n'
				fi
				printf '\n'
				observer_collector_status || true
			fi
		fi
	fi
}
restart_project() {
	local p="$1"
	project_enabled "$p" || {
		stop_project "$p" || true
		return
	}
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	if ! "${compose_command[@]}" restart; then
		report_compose_failure
		die "$p restart command failed"
	fi
	if ! wait_project "$p"; then
		report_compose_failure
		die "$p failed after restart"
	fi
}
recreate_project() {
	local p="$1"
	project_enabled "$p" || {
		stop_project "$p" || true
		return
	}
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	PLATFORM_COMPOSE_PROJECT="$p"
	if ! "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"; then
		report_compose_failure
		if repair_woodpecker_agent_identity "$p"; then
			printf 'platformctl: stale Woodpecker agent identity detected; registering a new identity\n' >&2
			if ! "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"; then
				report_compose_failure
				unset PLATFORM_COMPOSE_PROJECT
				die "$p failed during recreate"
			fi
		else
			unset PLATFORM_COMPOSE_PROJECT
			die "$p failed during recreate"
		fi
	fi
	unset PLATFORM_COMPOSE_PROJECT
}
smoke_project() {
	local d="$1" u path expected smoke_local
	smoke_local="$(descriptor_value "$d" SMOKE_LOCAL)"
	if [[ "$(node_role)" == follower && "$smoke_local" == healthcheck ]]; then
		project_is_healthy "app:$d"
		return
	fi
	u="$(env_value "$(descriptor_value "$d" SMOKE_URL_KEY)")"
	path="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	[[ -n "$u" ]] || return
	curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${u%/}$path" | { [[ -z "$expected" ]] || grep -q "$expected"; }
}
observer_smoke() {
	local env_file organization stream root_user root_password api_url probe_image interval lookback now start_micros end_micros sql payload response attempt attempts delay expected_node missing_nodes query_error query_detail expected_nodes smoke_timeout request_timeout deadline remaining request_seconds retry_delay read_lock_owned=0 read_lock_status
	[[ "$(node_role)" == leader ]] || return 0
	foundation_active observer-controller && foundation_active observer-collector || return 0
	if [[ "${PLATFORM_LOCK_HELD:-0}" != 1 ]]; then
		if acquire_read_lock; then
			read_lock_owned=1
		else
			read_lock_status=$?
			[[ "$read_lock_status" == 2 ]] && return 0
			return "$read_lock_status"
		fi
	fi
	command -v jq >/dev/null 2>&1 || die 'jq is required for the Observer ingestion smoke check'
	env_file="$(foundation_env observer-controller)"
	organization="$(env_value OBSERVER_LOG_ORGANIZATION "$env_file")"
	organization="${organization:-default}"
	stream="$(env_value OBSERVER_LOG_STREAM "$env_file")"
	stream="${stream:-docker}"
	root_user="$(env_value OBSERVER_ROOT_USER_EMAIL "$env_file")"
	root_password="$(env_value OBSERVER_ROOT_USER_PASSWORD "$env_file")"
	api_url="$(env_value OBSERVER_API_URL "$env_file")"
	api_url="${api_url:-http://observer-controller:5080}"
	probe_image="$(env_value OBSERVER_HEALTH_PROBE_IMAGE "$FOUNDATION_IMAGE_ENV")"
	interval="$(env_value OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS "$env_file")"
	interval="${interval:-300}"
	# Keep the periodic health timer bounded. Operators can increase these values
	# for a slow or freshly restored Observer, but every request and the complete
	# retry loop still have an explicit upper bound.
	attempts="${OBSERVER_SMOKE_ATTEMPTS:-6}"
	delay="${OBSERVER_SMOKE_RETRY_DELAY:-5}"
	smoke_timeout="${OBSERVER_SMOKE_TIMEOUT_SECONDS:-120}"
	request_timeout="${OBSERVER_SMOKE_REQUEST_TIMEOUT_SECONDS:-10}"
	[[ "$attempts" =~ ^[0-9]+$ ]] && ((attempts >= 1 && attempts <= 60)) || die 'OBSERVER_SMOKE_ATTEMPTS must be between 1 and 60'
	[[ "$delay" =~ ^[0-9]+$ ]] && ((delay <= 60)) || die 'OBSERVER_SMOKE_RETRY_DELAY must be between 0 and 60 seconds'
	[[ "$smoke_timeout" =~ ^[0-9]+$ ]] && ((smoke_timeout >= 1 && smoke_timeout <= 3600)) || die 'OBSERVER_SMOKE_TIMEOUT_SECONDS must be between 1 and 3600 seconds'
	[[ "$request_timeout" =~ ^[0-9]+$ ]] && ((request_timeout >= 1 && request_timeout <= 120)) || die 'OBSERVER_SMOKE_REQUEST_TIMEOUT_SECONDS must be between 1 and 120 seconds'
	[[ -n "$root_user" && -n "$root_password" && -n "$probe_image" ]] || die 'Observer smoke-check credentials or probe image are missing'
	lookback=$((interval * 3 + 120))
	now="$(date +%s)"
	deadline=$((now + smoke_timeout))
	start_micros=$(((now - lookback) * 1000000))
	end_micros=$(((now + 60) * 1000000))
	sql="SELECT node_id, MAX(_timestamp) AS latest FROM \"$stream\" WHERE component = 'foundation-observer-heartbeat' GROUP BY node_id"
	payload="$(jq -nc --arg sql "$sql" --argjson start "$start_micros" --argjson end "$end_micros" '{query:{sql:$sql,start_time:$start,end_time:$end}}')"
	expected_nodes=''
	while IFS= read -r expected_node; do
		[[ -n "$expected_node" ]] || continue
		expected_nodes="${expected_nodes:+$expected_nodes,}$expected_node"
	done <<<"$(observer_collector_nodes)"
	[[ -n "$expected_nodes" ]] || die 'Observer smoke-check has no eligible active collector nodes'
	if ((read_lock_owned == 1)); then
		# The query retries can legitimately take up to two minutes. Release the
		# deployment lock before network I/O so a transient Observer outage cannot
		# block a concurrent recovery transaction.
		release_read_lock
	fi
	printf 'Observer ingestion smoke: organization=%s stream=%s expected_nodes=%s attempts=%s timeout=%ss\n' \
		"$organization" "$stream" "$expected_nodes" "$attempts" "$smoke_timeout"
	for ((attempt = 1; attempt <= attempts; attempt++)); do
		now="$(date +%s)"
		remaining=$((deadline - now))
		if ((remaining <= 0)); then
			query_error='overall timeout elapsed'
			break
		fi
		request_seconds="$request_timeout"
		if ((request_seconds > remaining)); then request_seconds="$remaining"; fi
		missing_nodes=''
		query_error=''
		if response="$(docker run --rm --pull=never --network foundation-observer_private "$probe_image" \
			-fsS --max-time "$request_seconds" -u "$root_user:$root_password" -H 'Content-Type: application/json' \
			--data "$payload" "${api_url%/}/api/${organization}/_search" 2>&1)"; then
			if ! printf '%s' "$response" | jq -e 'type == "object" and (.hits | type == "array")' >/dev/null 2>&1; then
				query_error='OpenObserve returned an invalid search response'
			else
				while IFS= read -r expected_node; do
					[[ -n "$expected_node" ]] || continue
					if ! printf '%s' "$response" | jq -e --arg node "$expected_node" 'any(.hits[]?; .node_id == $node)' >/dev/null 2>&1; then
						missing_nodes="${missing_nodes:+$missing_nodes,}$expected_node"
					fi
				done <<<"$(printf '%s' "$expected_nodes" | tr ',' '\n')"
				if [[ -z "$missing_nodes" ]]; then
					printf 'Observer ingestion smoke passed: organization=%s stream=%s nodes=%s\n' "$organization" "$stream" "$expected_nodes"
					return 0
				fi
				query_error="missing recent heartbeat nodes=$missing_nodes"
			fi
		else
			query_detail="$(printf '%s' "$response" | tail -n 1 | tr '\r\n' ' ' | cut -c1-240)"
			query_error="OpenObserve query failed${query_detail:+: $query_detail}"
		fi
		if ((attempt < attempts)); then
			now="$(date +%s)"
			remaining=$((deadline - now))
			if ((remaining <= 0)); then
				query_error='overall timeout elapsed'
				break
			fi
			retry_delay="$delay"
			if ((retry_delay > remaining)); then retry_delay="$remaining"; fi
			printf 'Observer ingestion smoke waiting: attempt=%s/%s reason=%s retry_in=%ss\n' "$attempt" "$attempts" "$query_error" "$retry_delay" >&2
			if ((retry_delay > 0)); then sleep "$retry_delay"; fi
		fi
	done
	printf 'platformctl: Observer ingestion smoke failed: organization=%s stream=%s reason=%s; run platformctl diagnose foundation on the Leader and affected nodes\n' \
		"$organization" "$stream" "${query_error:-unknown}" >&2
	return 1
}
observer_collector_status() {
	local env_file probe_image query payload response proxy_response observer_root observer_buffer buffer_bytes buffer_max utilization
	local source_received source_sent transform_received transform_sent metadata_received metadata_sent sink_received sink_sent sink_bytes pending state metrics failed=0
	printf '[observer-collector-status]\nnode_id=%s\n' "$(node_id)"
	foundation_active observer-collector || {
		printf 'state=disabled\n'
		return 0
	}
	env_file="$(foundation_env observer-collector)"
	probe_image="$(env_value OBSERVER_HEALTH_PROBE_IMAGE "$FOUNDATION_IMAGE_ENV")"
	if [[ -z "$probe_image" ]]; then
		printf 'state=unavailable\nreason=missing_probe_image\n'
		return 1
	fi
	if proxy_response="$(docker run --rm --pull=never --network foundation-observer_private "$probe_image" \
		-fsS --max-time 10 http://observer-log-proxy:2375/_ping 2>&1)" && [[ "$proxy_response" == OK* ]]; then
		printf 'socket_proxy=healthy\n'
	else
		printf 'socket_proxy=unavailable\n'
		failed=1
	fi
	query='{components(first:50){nodes{componentId componentType ... on Source {metrics {receivedEventsTotal {receivedEventsTotal} sentEventsTotal {sentEventsTotal}}} ... on Transform {metrics {receivedEventsTotal {receivedEventsTotal} sentEventsTotal {sentEventsTotal}}} ... on Sink {metrics {receivedEventsTotal {receivedEventsTotal} sentEventsTotal {sentEventsTotal} sentBytesTotal {sentBytesTotal}}}}}}'
	payload="$(jq -nc --arg query "$query" '{query:$query}')"
	if ! response="$(docker run --rm --pull=never --network foundation-observer_private "$probe_image" \
		-fsS --max-time 10 -H 'Content-Type: application/json' --data "$payload" \
		http://observer-log-shipper:8686/graphql 2>&1)"; then
		printf 'state=unavailable\nreason=vector_api_unreachable detail=%s\n' "$(printf '%s' "$response" | tail -n1 | tr '\r\n' ' ' | cut -c1-200)"
		return 1
	fi
	if ! printf '%s' "$response" | jq -e '(.data.components.nodes | type == "array") and ((.errors // []) | length == 0)' >/dev/null 2>&1; then
		printf 'state=unavailable\nreason=vector_api_invalid_response\n'
		return 1
	fi
	# Read the stable component IDs from the committed Vector topology. Null or
	# absent metrics are rendered as zero so a fresh collector has a useful state.
	# Extract all counters in one jq process. This command is used by diagnose;
	# one parser keeps routine health checks cheap on small VPS hosts.
	metrics="$(printf '%s' "$response" | jq -r '
		def metric($id; $name): (([.data.components.nodes[] | select(.componentId == $id) | .metrics[$name][$name] // 0][0]) // 0) | floor;
		[metric("docker_logs"; "receivedEventsTotal"), metric("docker_logs"; "sentEventsTotal"),
		 metric("exclude_observer_sidecars"; "receivedEventsTotal"), metric("exclude_observer_sidecars"; "sentEventsTotal"),
		 metric("add_metadata"; "receivedEventsTotal"), metric("add_metadata"; "sentEventsTotal"),
		 metric("openobserve"; "receivedEventsTotal"), metric("openobserve"; "sentEventsTotal"), metric("openobserve"; "sentBytesTotal")] | @tsv')"
	IFS=$'\t' read -r source_received source_sent transform_received transform_sent metadata_received metadata_sent sink_received sink_sent sink_bytes <<<"$metrics"
	pending="$(awk -v received="$sink_received" -v sent="$sink_sent" 'BEGIN { pending = received - sent; if (pending < 0) pending = 0; printf "%d", pending }')"
	observer_root="$(env_value OBSERVER_DATA_ROOT "$env_file")"
	observer_root="${observer_root:-$PLATFORM_ROOT/observer}"
	observer_buffer="$observer_root/collector-buffer"
	buffer_max="$(env_value OBSERVER_LOG_BUFFER_MAX_BYTES "$env_file")"
	buffer_max="${buffer_max:-536870912}"
	if buffer_bytes="$(path_bytes "$observer_buffer")"; then
		utilization="$(awk -v bytes="$buffer_bytes" -v maximum="$buffer_max" 'BEGIN { if (maximum > 0) printf "%.1f", (bytes * 100) / maximum; else print "0.0" }')"
	else
		buffer_bytes=0
		utilization=0.0
	fi
	if ((pending > 0)); then
		state=backlog
	elif ((buffer_bytes > 0)); then
		state=buffered
	elif ((sink_sent > 0)); then
		state=drained
	else
		state=idle
	fi
	printf 'state=%s\nsource_received=%s source_sent=%s\nfilter_received=%s filter_sent=%s\nmetadata_received=%s metadata_sent=%s\nsink_received=%s sink_sent=%s sink_bytes_sent=%s pending_events=%s\nbuffer_bytes=%s buffer_max_bytes=%s buffer_utilization_percent=%s buffer_when_full=%s\n' \
		"$state" "$source_received" "$source_sent" "$transform_received" "$transform_sent" \
		"$metadata_received" "$metadata_sent" "$sink_received" "$sink_sent" "$sink_bytes" "$pending" \
		"$buffer_bytes" "$buffer_max" "$utilization" "$(env_value OBSERVER_LOG_BUFFER_WHEN_FULL "$env_file" | sed '/^$/s//block/')"
	return "$failed"
}
smoke_all() {
	local d
	observer_smoke
	while IFS= read -r d; do
		app_route_active "$d" && smoke_project "$d"
	done <<<"$(descriptor_ids)"
}
maintenance() { case "${1:-status}" in begin)
	install -d -m700 "$(dirname "$MAINTENANCE_FILE")"
	printf 'started_utc=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${2:-manual}" >"$MAINTENANCE_FILE"
	echo enabled
	;;
end)
	rm -f "$MAINTENANCE_FILE"
	echo disabled
	;;
status) [[ -f "$MAINTENANCE_FILE" ]] && cat "$MAINTENANCE_FILE" || echo inactive ;; *) die 'maintenance expects begin, end, or status' ;; esac }
data_root() {
	local v
	v="$(env_value DATA_ROOT)"
	printf '%s\n' "${v:-$APP_ROOT/shared/data/prod}"
}
singleton_descriptor() {
	local wanted="$1" d
	while IFS= read -r d; do
		[[ "$(basename "$d")" == "$wanted" ]] || continue
		[[ "$(app_upstream_mode "$d")" == singleton ]] || die "app is not singleton: $wanted"
		printf '%s\n' "$d"
		return 0
	done <<<"$(descriptor_ids)"
	die "unknown singleton app: $wanted"
}
singleton_state_file() { printf '%s/%s.previous-target\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
singleton_transition_file() { printf '%s/%s.transition.env\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
singleton_route_backup_file() { printf '%s/%s.route-backup.caddy\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
singleton_route_missing_file() { printf '%s/%s.route-was-missing\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
transition_value() {
	local key="$1" file="$2"
	[[ -r "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
transition_set() {
	local file="$1" key="$2" value="$3" tmp
	install -d -m 700 "$SINGLETON_STATE_ROOT"
	tmp="$(mktemp "$file.XXXXXX")"
	if [[ -f "$file" ]]; then sed "/^${key}=/d" "$file" >"$tmp"; fi
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
transition_begin() {
	local file="$1" app="$2" old_target="$3" new_target="$4" release="$5" archive="$6" tmp
	install -d -m 700 "$SINGLETON_STATE_ROOT"
	tmp="$(mktemp "$file.XXXXXX")"
	{
		printf 'VERSION=1\nAPP_ID=%s\nOLD_TARGET=%s\nNEW_TARGET=%s\nRELEASE_SHA=%s\nPHASE=archiving\n' "$app" "$old_target" "$new_target" "$release"
		printf 'ARCHIVE_PATH=%s\nSTARTED_UTC=%s\nUPDATED_UTC=%s\n' "$archive" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	} >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
singleton_route_keys() {
	local d="$1" groups
	groups="$(descriptor_value "$d" ROUTE_GROUPS)"
	printf '%s\n' "$groups" | tr ';' '\n' | head -n1
}
singleton_prepare() {
	local d="$1" previous="${SINGLETON_PREVIOUS_TARGET:-}" target base rel root ephemeral_rel ephemeral_root archive state_file journal release phase journal_target journal_release
	[[ "$(node_role)" == follower ]] || die 'singleton prepare must run on a follower'
	d="$(singleton_descriptor "$d")"
	state_file="$(singleton_state_file "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ -n "$previous" ]] || previous="$(cat "$state_file" 2>/dev/null || true)"
	target="$(app_target_node "$d")"
	[[ "$(node_id)" == "$target" ]] || die 'singleton prepare must run on the configured target'
	if [[ "$(descriptor_value "$d" MOVE_MODE)" != fresh || -z "$previous" || "$previous" == "$target" ]]; then
		rm -f -- "$state_file"
		return 0
	fi
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	base="$(data_root)"
	rel="$(descriptor_value "$d" DATA_ROOT_REL)"
	safe_relative "$rel" || die "unsafe singleton data path: $rel"
	root="$base/$rel"
	case "$root" in "$base"/*) ;; *) die 'refusing to operate outside DATA_ROOT' ;; esac
	ephemeral_rel="$(descriptor_value "$d" EPHEMERAL_DATA_REL)"
	if [[ -n "$ephemeral_rel" ]]; then
		safe_relative "$ephemeral_rel" || die "unsafe singleton ephemeral data path: $ephemeral_rel"
		ephemeral_root="$root/$ephemeral_rel"
	fi
	journal_target="$(transition_value NEW_TARGET "$journal")"
	journal_release="$(transition_value RELEASE_SHA "$journal")"
	phase="$(transition_value PHASE "$journal")"
	if [[ "$journal_target" == "$target" && "$journal_release" == "$release" && "$phase" != failed && "$phase" != completed ]]; then
		archive="$(transition_value ARCHIVE_PATH "$journal")"
		if [[ -n "$archive" && -e "$archive" && ! -e "$root" ]]; then install -d -m 700 "$root"; fi
		if [[ "$phase" == prepared || "$phase" == origin-healthy ]]; then
			rm -f -- "$state_file"
			return 0
		fi
	fi
	if [[ ! -d "$root" ]]; then
		archive="$root.retained.$(date -u '+%Y%m%dT%H%M%SZ')"
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" "$archive"
		install -d -m 700 "$root"
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		return 0
	fi
	if ! find "$root" -mindepth 1 -print -quit | grep -q .; then
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		return 0
	fi
	stop_project "app:$d" || die "unable to stop existing singleton before fresh prepare"
	if [[ -n "$ephemeral_root" && (-e "$ephemeral_root" || -L "$ephemeral_root") ]]; then
		rm -rf -- "$ephemeral_root"
		printf 'discarded ephemeral singleton data at %s\n' "$ephemeral_root"
	fi
	if ! find "$root" -mindepth 1 -print -quit | grep -q .; then
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		printf 'discarded ephemeral singleton data and created fresh path %s\n' "$root"
		return 0
	fi
	archive="$root.retained.$(date -u '+%Y%m%dT%H%M%SZ')"
	transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" "$archive"
	mv -- "$root" "$archive"
	install -d -m 700 "$root"
	transition_set "$journal" PHASE prepared
	rm -f -- "$state_file"
	printf 'archived previous singleton data at %s and created fresh path %s\n' "$archive" "$root"
}
singleton_origin_smoke() {
	local d="$1" target origin_key origin health expected response journal release
	[[ "$(node_role)" == follower ]] || die 'singleton origin smoke must run on a follower'
	d="$(singleton_descriptor "$d")"
	target="$(app_target_node "$d")"
	[[ "$(node_id)" == "$target" ]] || die 'singleton origin smoke must run on the configured target'
	IFS='|' read -r _ origin_key _ <<EOF
$(singleton_route_keys "$d")
EOF
	origin="$(node_value "$origin_key")"
	health="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	[[ -n "$origin" && -n "$health" ]] || die "singleton origin smoke is missing origin or health path: $(basename "$d")"
	response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://$origin${health}" 2>/dev/null)" || die "singleton origin is unhealthy: $origin"
	[[ -z "$expected" || "$response" == *"$expected"* ]] || die "singleton origin response did not match HEALTH_EXPECT: $(basename "$d")"
	journal="$(singleton_transition_file "$d")"
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	if [[ "$(transition_value RELEASE_SHA "$journal")" == "$release" ]]; then transition_set "$journal" PHASE origin-healthy; fi
}
singleton_transition_fail() {
	local d="$1" journal
	[[ "$(node_role)" == follower ]] || die 'singleton transition failure must run on a follower'
	d="$(singleton_descriptor "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ -f "$journal" ]] || return 0
	transition_set "$journal" PHASE failed
	transition_set "$journal" FAILED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf 'singleton transition marked failed; retained journal at %s\n' "$journal" >&2
}
singleton_restore_route() {
	local d="$1" route="$2" backup="$3" missing="$4" tmp
	if [[ -f "$backup" ]]; then
		install -d -m 700 "$(dirname "$route")"
		tmp="$(mktemp "$route.rollback.XXXXXX")"
		if ! cp "$backup" "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$route"; then
			rm -f -- "$tmp"
			printf 'platformctl: unable to restore the previous singleton route from %s\n' "$backup" >&2
			return 1
		fi
	elif [[ -f "$missing" ]]; then
		rm -f -- "$route"
	else
		printf 'platformctl: singleton route rollback state is incomplete for %s\n' "$(basename "$d")" >&2
		return 1
	fi
	if ! reload_caddy; then
		printf 'platformctl: previous singleton route was restored on disk, but Caddy reload failed; rollback state remains in %s\n' "$SINGLETON_STATE_ROOT" >&2
		return 1
	fi
	rm -f -- "$backup" "$missing"
	printf 'restored previous Leader route for singleton %s\n' "$(basename "$d")" >&2
}
singleton_switch() {
	local d="$1" target origin_key origin public_key public_url enabled public_host domain journal release previous state_file health expected response route backup missing backup_tmp switch_failed=0
	[[ "$(node_role)" == leader ]] || die 'singleton switch must run on the Leader'
	d="$(singleton_descriptor "$d")"
	target="$(app_target_node "$d")"
	# Fail before probing or publishing an origin that is no longer eligible.
	# Validation also enforces this invariant, but singleton-switch is an
	# explicit operational entry point and must remain safe when inventory state
	# changes between validations.
	active_follower_node "$target" || die "singleton target is not an active follower: $target"
	enabled="$(app_policy_enabled "$(basename "$d")" && printf true || printf false)"
	if [[ "$enabled" != true ]]; then
		PLATFORM_SKIP_SINGLETONS=0 sync apps
		printf 'singleton %s is disabled; Leader route and active containers reconciled\n' "$(basename "$d")"
		return 0
	fi
	IFS='|' read -r public_key origin_key _ <<EOF
$(singleton_route_keys "$d")
EOF
	origin="$(env_value "$origin_key" "$CONTROL_ROOT/current/config/cluster/nodes/$target.env")"
	health="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	[[ -n "$origin" && -n "$health" ]] || die "singleton switch is missing origin or health path: $(basename "$d")"
	response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://$origin${health}" 2>/dev/null)" || die "singleton origin is unhealthy: $origin"
	[[ -z "$expected" || "$response" == *"$expected"* ]] || die "singleton origin response did not match HEALTH_EXPECT: $(basename "$d")"

	install -d -m 700 "$SINGLETON_STATE_ROOT"
	route="$RUNTIME_ROOT/config/routes.d/$(basename "$d").caddy"
	backup="$(singleton_route_backup_file "$d")"
	missing="$(singleton_route_missing_file "$d")"
	[[ ! -e "$backup" && ! -e "$missing" ]] || die "unresolved singleton route rollback exists for $(basename "$d") in $SINGLETON_STATE_ROOT"
	if [[ -f "$route" ]]; then
		backup_tmp="$(mktemp "$backup.XXXXXX")"
		if ! cp "$route" "$backup_tmp" || ! chmod 600 "$backup_tmp" || ! mv -f -- "$backup_tmp" "$backup"; then
			rm -f -- "$backup_tmp"
			die "unable to snapshot the existing singleton route: $route"
		fi
	else
		: >"$missing"
		chmod 600 "$missing"
	fi

	journal="$(singleton_transition_file "$d")"
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	state_file="$(singleton_state_file "$d")"
	previous="$(cat "$state_file" 2>/dev/null || true)"
	if [[ "$(transition_value NEW_TARGET "$journal")" != "$target" || "$(transition_value RELEASE_SHA "$journal")" != "$release" ]]; then
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""
	fi
	transition_set "$journal" PHASE switching
	# Run synchronization through a child platformctl process. Validation uses
	# explicit fatal exits, so a function call in an `if` condition could exit this
	# transaction before its rollback handler gets control.
	if ! PLATFORM_LOCK_HELD=1 PLATFORM_SKIP_SINGLETONS=0 PLATFORM_FORCE_SINGLETON_ROUTE=1 PLATFORM_ONLY_ROUTE_APP_ID="$(basename "$d")" "$PLATFORMCTL_SCRIPT_PATH" sync apps; then
		transition_set "$journal" PHASE route-publish-failed
		switch_failed=1
	fi
	public_url="$(app_value "$d" "$public_key")"
	if [[ -z "$public_url" ]]; then
		public_host="$(app_public_host "$d" "$public_key")"
		domain="$(env_value DOMAIN_NAME)"
		if [[ -n "$public_host" && -n "$domain" ]]; then
			if [[ "$domain" == localhost ]]; then public_url="http://${public_host}.localhost"; else public_url="https://${public_host}.${domain}"; fi
		fi
	fi
	if ((switch_failed == 0)) && [[ -z "$public_url" ]]; then
		printf 'platformctl: singleton public URL is missing: %s\n' "$(basename "$d")" >&2
		transition_set "$journal" PHASE public-smoke-failed
		switch_failed=1
	fi
	if ((switch_failed == 0)); then
		if ! response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${public_url%/}${health}" 2>/dev/null)"; then
			printf 'platformctl: singleton public smoke failed: %s\n' "${public_url%/}${health}" >&2
			transition_set "$journal" PHASE public-smoke-failed
			switch_failed=1
		elif [[ -n "$expected" && "$response" != *"$expected"* ]]; then
			printf 'platformctl: singleton public response did not match HEALTH_EXPECT: %s\n' "$(basename "$d")" >&2
			transition_set "$journal" PHASE public-smoke-failed
			switch_failed=1
		fi
	fi
	if ((switch_failed != 0)); then
		if ! singleton_restore_route "$d" "$route" "$backup" "$missing"; then
			transition_set "$journal" PHASE route-rollback-failed
		else
			transition_set "$journal" PHASE failed
		fi
		transition_set "$journal" FAILED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		return 1
	fi
	rm -f -- "$backup" "$missing"
	transition_set "$journal" RELEASE_SHA "$release"
	transition_set "$journal" PHASE switched
	transition_set "$journal" SWITCHED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	rm -f -- "$state_file"
}
singleton_stop() {
	local d="$1" rel root base runtime_env state_file journal release journal_release phase
	[[ "$(node_role)" == follower ]] || die 'singleton stop must run on a follower'
	d="$(singleton_descriptor "$d")"
	state_file="$(singleton_state_file "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ "$(node_id)" == "$(app_target_node "$d")" && "$(app_policy_enabled "$(basename "$d")" && printf true || printf false)" == true ]] && {
		printf 'retained active singleton %s on configured target %s\n' "$(basename "$d")" "$(node_id)"
		if [[ "${SINGLETON_FINAL_STOP:-0}" == 1 && -f "$journal" ]]; then
			release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
			journal_release="$(transition_value RELEASE_SHA "$journal")"
			phase="$(transition_value PHASE "$journal")"
			if [[ "$journal_release" == "$release" ]]; then
				case "$phase" in
				origin-healthy | completed)
					transition_set "$journal" PHASE completed
					transition_set "$journal" COMPLETED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
					;;
				*) die "singleton transition cannot be finalized from phase ${phase:-missing}: $(basename "$d")" ;;
				esac
			else
				printf 'no singleton transition journal for release %s on %s\n' "$release" "$(node_id)"
			fi
		fi
		return 0
	}
	app_active "$d" && return 0
	PLATFORM_FORCE_SINGLETON_ACTION=1 stop_project "app:$d" || die "unable to stop singleton containers for $(basename "$d")"
	rm -f -- "$state_file"
	base="$(data_root)"
	rel="$(descriptor_value "$d" DATA_ROOT_REL)"
	safe_relative "$rel" || die "unsafe singleton data path: $rel"
	root="$base/$rel"
	case "$root" in "$base"/*) ;; *) die 'refusing to report data outside DATA_ROOT' ;; esac
	runtime_env="$(app_runtime_env_file "$d")"
	printf 'stopped singleton %s; retained data at %s%s\n' "$(basename "$d")" "$root" "${runtime_env:+ and runtime secrets at $runtime_env}"
}
consumer_descriptor() {
	local app="$1" d
	[[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid consumer app ID: $app"
	d="$APPS_ROOT/$app"
	[[ -f "$d/manifest.env" ]] || die "unknown consumer app: $app"
	[[ "$(app_placement "$d")" == consumer ]] || die "application is not a consumer: $app"
	printf '%s\n' "$d"
}
consumer_origin_smoke_generic() {
	local d="$1" id node groups public_key origin_key upstream_key origin health expected response checked=0
	id="$(basename "$d")"
	app_policy_enabled "$id" || {
		printf 'consumer %s is disabled; origin smoke skipped\n' "$id"
		return 0
	}
	health="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	groups="$(descriptor_value "$d" ROUTE_GROUPS)"
	IFS='|' read -r public_key origin_key upstream_key <<EOF
${groups%%;*}
EOF
	[[ -n "$origin_key" && -n "$health" ]] || die "consumer is missing origin or health configuration: $id"
	if [[ "$(node_role)" == leader ]]; then
		while IFS= read -r node; do
			[[ -n "$node" ]] || continue
			if ! active_follower_node "$node"; then
				printf 'consumer origin smoke: skipping inactive or non-follower target %s/%s\n' "$id" "$node" >&2
				continue
			fi
			origin="$(env_value "$origin_key" "$(node_descriptor_file "$node")")"
			[[ -n "$origin" ]] || die "consumer origin is missing for $id on $node"
			response="$(curl -fsS --retry 4 --retry-delay 3 --retry-all-errors --max-time 20 "https://$origin${health}" 2>/dev/null)" || die "consumer origin is unhealthy: $id/$node ($origin)"
			[[ -z "$expected" || "$response" == *"$expected"* ]] || die "consumer origin response did not match HEALTH_EXPECT: $id/$node"
			checked=$((checked + 1))
		done <<<"$(printf '%s\n' "$(app_nodes "$d")" | tr ',' '\n' | sed '/^$/d')"
	else
		# A node being drained must not report a successful local smoke while its
		# containers are being evacuated. This also protects direct operational
		# invocations that bypass the normal reconciliation path.
		[[ "$(node_state)" == active ]] || die "consumer origin smoke requires an active follower: $id/$(node_id)"
		csv_has "$(app_nodes "$d")" "$(node_id)" || die "consumer is not assigned to this node: $id/$(node_id)"
		origin="$(node_value "$origin_key")"
		[[ -n "$origin" ]] || die "consumer origin is missing for $id on $(node_id)"
		response="$(curl -fsS --retry 4 --retry-delay 3 --retry-all-errors --max-time 20 "https://$origin${health}" 2>/dev/null)" || die "consumer origin is unhealthy: $id/$(node_id) ($origin)"
		[[ -z "$expected" || "$response" == *"$expected"* ]] || die "consumer origin response did not match HEALTH_EXPECT: $id/$(node_id)"
		checked=1
	fi
	((checked > 0)) || die "consumer has no origins to check: $id"
}
consumer_origin_smoke() {
	local d
	d="$(consumer_descriptor "$1")"
	if [[ "$(app_upstream_mode "$d")" == singleton ]]; then
		singleton_origin_smoke "$(basename "$d")"
	else
		consumer_origin_smoke_generic "$d"
	fi
}
consumer_public_url() {
	local d="$1" key value host domain
	key="$(descriptor_value "$d" SMOKE_URL_KEY)"
	value="$(app_value "$d" "$key")"
	if [[ -z "$value" ]]; then
		host="$(app_public_host "$d" "$key")"
		domain="$(env_value DOMAIN_NAME)"
		if [[ -n "$host" && -n "$domain" ]]; then
			if [[ "$domain" == localhost ]]; then value="http://${host}.localhost"; else value="https://${host}.${domain}"; fi
		fi
	fi
	printf '%s\n' "$value"
}
consumer_publish_generic() {
	local d="$1" id route backup missing=0 public_url health expected response failed=0
	[[ "$(node_role)" == leader ]] || die 'consumer publication must run on the Leader'
	id="$(basename "$d")"
	app_policy_enabled "$id" && consumer_origin_smoke_generic "$d"
	install -d -m 700 "$RUNTIME_ROOT/config/routes.d"
	route="$RUNTIME_ROOT/config/routes.d/$id.caddy"
	backup="$(mktemp "$RUNTIME_ROOT/.${id}.route.XXXXXX")"
	if [[ -f "$route" ]]; then
		cp "$route" "$backup"
	else
		missing=1
	fi
	if ! PLATFORM_LOCK_HELD=1 PLATFORM_ONLY_ROUTE_APP_ID="$id" PLATFORM_FORCE_SINGLETON_ROUTE=1 "$PLATFORMCTL_SCRIPT_PATH" sync apps; then
		failed=1
	fi
	if ((failed == 0)) && app_policy_enabled "$id"; then
		public_url="$(consumer_public_url "$d")"
		health="$(descriptor_value "$d" HEALTH_URL)"
		expected="$(descriptor_value "$d" HEALTH_EXPECT)"
		if [[ -z "$public_url" ]]; then
			printf 'platformctl: consumer public URL is missing: %s\n' "$id" >&2
			failed=1
		elif ! response="$(curl -fsS --retry 4 --retry-delay 3 --retry-all-errors --max-time 20 "${public_url%/}${health}" 2>/dev/null)"; then
			printf 'platformctl: consumer public smoke failed: %s\n' "${public_url%/}${health}" >&2
			failed=1
		elif [[ -n "$expected" && "$response" != *"$expected"* ]]; then
			printf 'platformctl: consumer public response did not match HEALTH_EXPECT: %s\n' "$id" >&2
			failed=1
		fi
	fi
	if ((failed != 0)); then
		if ((missing == 1)); then rm -f -- "$route"; else cp "$backup" "$route"; fi
		rm -f -- "$backup"
		reload_caddy || die "consumer route rollback reload failed: $id"
		return 1
	fi
	rm -f -- "$backup"
	printf 'published consumer route: %s\n' "$id"
}
consumer_publish() {
	local d
	d="$(consumer_descriptor "$1")"
	if [[ "$(app_upstream_mode "$d")" == singleton && "$(app_policy_enabled "$(basename "$d")" && printf true || printf false)" == true ]]; then
		singleton_switch "$(basename "$d")"
	else
		consumer_publish_generic "$d"
	fi
}
consumer_stop() {
	local d
	[[ "$(node_role)" == follower ]] || die 'consumer stop must run on a follower'
	d="$(consumer_descriptor "$1")"
	if [[ "$(app_upstream_mode "$d")" == singleton ]]; then
		singleton_stop "$(basename "$d")"
		return
	fi
	if app_active "$d"; then
		printf 'retained active consumer %s on configured node %s\n' "$(basename "$d")" "$(node_id)"
		return 0
	fi
	PLATFORM_FORCE_SINGLETON_ACTION=1 stop_project "app:$d" || die "unable to stop consumer containers for $(basename "$d")"
	printf 'stopped inactive consumer %s on node %s\n' "$(basename "$d")" "$(node_id)"
}
start_all_projects() {
	local p
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		start_project "$p"
	done <<<"$(
		projects_foundation
		projects_apps
	)"
}
stop_all_projects() {
	local p
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		stop_project "$p"
	done <<<"$(all_projects)"
}
reconcile_all_projects() {
	local p
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		if [[ "$1" == restart ]]; then
			restart_project "$p"
		else
			recreate_project "$p"
		fi
	done <<<"$(
		projects_foundation
		projects_apps
	)"
}
if [[ "${PLATFORMCTL_LIBRARY:-0}" != 1 ]]; then
	op="${1:-status}"
	read_only_lock=0
	case "$op" in
	status | health | diagnose | observer-collector-status)
		if acquire_read_lock; then
			read_only_lock=1
		else
			read_only_status=$?
			[[ "$read_only_status" == 2 ]] && exit 0
			exit "$read_only_status"
		fi
		;;
	validate)
		# `validate` commits the rendered runtime configuration and validation
		# stamp. Serialize it with deployments; only `validate --check` is a
		# read-only candidate check and may share the read lock.
		if [[ "${2:-}" == --check ]]; then
			if acquire_read_lock; then
				read_only_lock=1
			else
				read_only_status=$?
				[[ "$read_only_status" == 2 ]] && exit 0
				exit "$read_only_status"
			fi
		else
			acquire_lock
		fi
		;;
	validate-observer | observer-smoke) ;;
	*) acquire_lock ;;
	esac
	case "$op" in validate) [[ "${2:-}" == --check ]] && VALIDATE_CHECK=1 validate || validate ;; status) [[ "${2:-}" == --json ]] && printf '{"node":"%s","role":"%s","state":"%s"}\n' "$(node_id)" "$(node_role)" "$(node_state)" || {
		printf 'node=%s role=%s state=%s\n' "$(node_id)" "$(node_role)" "$(node_state)"
		health
	} ;; health) health ;; recover) recover "${2:-}" ;; retire-node) retire_node ;; ensure-network) ensure_network ;; start) [[ "${2:-all}" == all ]] && start_all_projects || start_project "$2" ;; sync) sync "${2:-all}" ;; stop) [[ "${2:-all}" == all ]] && stop_all_projects || stop_project "$2" ;; restart | recreate) if [[ "${2:-all}" == all ]]; then reconcile_all_projects "$op"; else [[ "$op" == restart ]] && restart_project "$2" || recreate_project "$2"; fi ;; singleton-switch)
		[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-switch <app-id>'
		singleton_switch "$2"
		;;
	singleton-stop)
		[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-stop <app-id>'
		singleton_stop "$2"
		;;
	singleton-prepare)
		[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-prepare <app-id>'
		singleton_prepare "$2"
		;;
	singleton-origin-smoke)
		[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-origin-smoke <app-id>'
		singleton_origin_smoke "$2"
		;;
	singleton-transition-fail)
		[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-transition-fail <app-id>'
		singleton_transition_fail "$2"
		;;
	consumer-origin-smoke)
		[[ -n "${2:-}" ]] || die 'usage: platformctl consumer-origin-smoke <app-id>'
		consumer_origin_smoke "$2"
		;;
	consumer-publish)
		[[ -n "${2:-}" ]] || die 'usage: platformctl consumer-publish <app-id>'
		consumer_publish "$2"
		;;
	consumer-stop)
		[[ -n "${2:-}" ]] || die 'usage: platformctl consumer-stop <app-id>'
		consumer_stop "$2"
		;;
	smoke)
		if [[ "${2:-}" == all ]]; then
			smoke_all
		else
			[[ "${2:-}" == app:* ]] || die 'usage: platformctl smoke {all|app:<descriptor>}'
			smoke_project "${2#app:}"
		fi
		;;
	validate-observer) validate_observer_env ;;
	observer-smoke) observer_smoke ;;
	observer-collector-status) observer_collector_status ;;
	diagnose) diagnose "${2:-all}" ;; maintenance) maintenance "${2:-status}" "${3:-}" ;; reload) reload_caddy ;; backup) exec "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;; restore) exec "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;; *) die 'usage: platformctl {validate|validate-observer|status|health|diagnose|recover|retire-node|ensure-network|start|sync|restart|recreate|stop|consumer-origin-smoke|consumer-publish|consumer-stop|singleton-prepare|singleton-origin-smoke|singleton-switch|singleton-stop|smoke|observer-smoke|observer-collector-status|maintenance|reload|backup|restore}' ;; esac
	if ((read_only_lock == 1)); then release_read_lock; fi
fi
