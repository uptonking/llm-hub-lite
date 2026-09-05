#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2097,SC2098,SC2318
set -Eeuo pipefail

umask 077
log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() {
	log "ERROR: $*" >&2
	exit 1
}
config_file="${DEPLOY_CONFIG_FILE:-/etc/llm-hub-lite/platform.env}"
[[ -r "$config_file" ]] || {
	printf 'missing platform configuration: %s\n' "$config_file" >&2
	exit 1
}
# shellcheck disable=SC1090
source "$config_file"

: "${APP_ROOT:=/opt/apps/llm-hub-lite}"
: "${CONFIG_ROOT:=/etc/llm-hub-lite}"
: "${PLATFORM_ROOT:=/opt/platform}"
: "${CONTROL_ROOT:=$PLATFORM_ROOT/control}"
: "${APP_RELEASE_ROOT:=$APP_ROOT/current}"
: "${FOUNDATION_ROOT:=$PLATFORM_ROOT/foundation}"
: "${REPO_URL:?REPO_URL must be set}"
: "${MAIN_BRANCH:=main}"
: "${APP_ENV:=$APP_ROOT/shared/.env.prod}"
: "${APP_IMAGE_ENV:=/etc/llm-hub-lite/images.apps.env}"
: "${FOUNDATION_IMAGE_ENV:=/etc/llm-hub-lite/images.foundation.env}"
: "${DEPLOY_LOG:=$APP_ROOT/shared/logs/deploy.log}"
: "${PLATFORM_LOCK_FILE:=/run/lock/llm-hub-lite/platform.lock}"
: "${RETAIN_RELEASES:=5}"
: "${PLATFORMCTL_SCRIPT:=/usr/local/bin/platformctl}"
: "${BACKUP_SCRIPT:=/usr/local/bin/backup-platform}"
: "${GIT_DEPLOY_KEY_FILE:=$CONFIG_ROOT/deploy-key}"
: "${GIT_KNOWN_HOSTS_FILE:=$CONFIG_ROOT/known_hosts}"
: "${GITHUB_TOKEN_FILE:=$CONFIG_ROOT/github-token}"
: "${SINGLETON_STATE_ROOT:=$CONFIG_ROOT/singleton-state}"
: "${CONTROL_SYNC_STATE_FILE:=$CONFIG_ROOT/control-sync.state}"
: "${CONTROL_ATTESTATION_FILE:=$CONTROL_ROOT/attestation.env}"
: "${VALIDATION_CACHE_ROOT:=$CONTROL_ROOT/validation-cache}"
# Production defaults retain the existing retry backoff. Tests and operators
# may set these to zero to avoid waiting after a mocked/transient failure.
: "${DEPLOY_FETCH_RETRY_DELAY_SECONDS:=5}"
: "${DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS:=5}"
# These switches are intentionally test-only controls consumed by the
# candidate platformctl process. They default to strict production behavior
# and are forwarded explicitly so a child release cannot accidentally inherit
# a partially configured test environment.
: "${PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION:=0}"
: "${PLATFORM_TEST_MODE:=0}"
: "${PLATFORM_TEST_SKIP_SYNC_VALIDATION:=0}"
: "${PLATFORM_TEST_SKIP_RENDER:=0}"
: "${PLATFORM_TEST_SKIP_COMPOSE_INSPECTION:=0}"
: "${PLATFORM_TEST_FAST_VALIDATE:=0}"
: "${PLATFORM_TEST_SKIP_CLUSTER_VALIDATION:=0}"
: "${PLATFORM_TEST_ONLY_DESCRIPTOR:=}"
# Test fixtures that fully mock platformctl may skip the candidate validation
# tree; production deployments always validate releases before mutation.
: "${DEPLOY_TEST_SKIP_RELEASE_VALIDATION:=0}"
: "${DEPLOY_DEBUG_LEVEL:=off}"
if [[ -z "${CONSUMER_APP_ID:-}" && -n "${DIRECT_APP_ID:-}" ]]; then
	CONSUMER_APP_ID="$DIRECT_APP_ID"
	export CONSUMER_APP_ID
fi

env_value() {
	local key="$1" file="${2:-$APP_ENV}" line value=''
	[[ -f "$file" ]] || return 0
	# Keep lookups in-process. Deployment paths read the same small env files
	# repeatedly; spawning sed and tail for every lookup adds measurable CPU and
	# latency on small VPS hosts and in the rollback test harness.
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$key="* ]] || continue
		value="${line#*=}"
	done <"$file"
	printf '%s\n' "$value"
}
[[ "$DEPLOY_FETCH_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die 'DEPLOY_FETCH_RETRY_DELAY_SECONDS must be a non-negative integer'
[[ "$DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die 'DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS must be a non-negative integer'
[[ "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 0 || "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 1 ]] || die 'DEPLOY_TEST_SKIP_RELEASE_VALIDATION must be 0 or 1'
[[ "$PLATFORM_TEST_MODE" == 0 || "$PLATFORM_TEST_MODE" == 1 ]] || die 'PLATFORM_TEST_MODE must be 0 or 1'
[[ "$PLATFORM_TEST_MODE" == 1 || ("$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 0 && "$PLATFORM_TEST_SKIP_SYNC_VALIDATION" == 0 && "$PLATFORM_TEST_SKIP_RENDER" == 0 && "$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" == 0 && "$PLATFORM_TEST_FAST_VALIDATE" == 0 && -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" && "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 0) ]] || die 'test-only deployment controls require PLATFORM_TEST_MODE=1'
[[ "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'DEPLOY_TEST_SKIP_RELEASE_VALIDATION requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
case "$DEPLOY_DEBUG_LEVEL" in off | debug | warn) ;; *) die 'DEPLOY_DEBUG_LEVEL must be off, debug, or warn' ;; esac
debug_log() {
	[[ "$DEPLOY_DEBUG_LEVEL" == debug ]] || return 0
	log "DEBUG: $*"
}
[[ "$PLATFORM_TEST_FAST_VALIDATE" == 0 || "$PLATFORM_TEST_FAST_VALIDATE" == 1 ]] || die 'PLATFORM_TEST_FAST_VALIDATE must be 0 or 1'
[[ -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" || "$PLATFORM_TEST_ONLY_DESCRIPTOR" =~ ^[a-z][a-z0-9-]*$ ]] || die 'PLATFORM_TEST_ONLY_DESCRIPTOR must be a valid application ID'
[[ "$PLATFORM_TEST_FAST_VALIDATE" == 0 || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_FAST_VALIDATE requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
[[ "$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" == 0 || ("$PLATFORM_TEST_MODE" == 1 && "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 && "$PLATFORM_TEST_FAST_VALIDATE" == 1) ]] || die 'PLATFORM_TEST_SKIP_CLUSTER_VALIDATION requires fast explicit test mode'
[[ -z "$PLATFORM_TEST_ONLY_DESCRIPTOR" || "$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" == 1 ]] || die 'PLATFORM_TEST_ONLY_DESCRIPTOR requires PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1'
policy_value() { env_value "$1" "$CONTROL_ROOT/current/config/cluster/policy.env"; }
node_value() { env_value "$1" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"; }
csv_contains() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
runtime_node_role() {
	[[ "$(node_value NODE_ID)" == "$(policy_value LEADER_NODE_ID)" ]] && printf 'leader\n' || printf 'follower\n'
}
foundation_enabled() {
	local component="$1" manifest roles policy_rel enabled mandatory
	manifest="$CONTROL_ROOT/current/compose/foundation/manifests/$component.env"
	[[ -f "$manifest" ]] || return 1
	roles="$(env_value ROLES "$manifest")"
	csv_contains "$roles" "$(runtime_node_role)" || return 1
	policy_rel="$(env_value POLICY_FILE "$manifest")"
	enabled="$(env_value ENABLED "$CONTROL_ROOT/current/config/$policy_rel")"
	mandatory="$(env_value MANDATORY "$manifest")"
	[[ "$mandatory" != true || "$enabled" == true ]] || die "mandatory foundation service is disabled: $component"
	[[ "$enabled" == true ]]
}
app_enabled_for_image() {
	local id="$1" d policy_rel nodes
	[[ "$(runtime_node_role)" == follower ]] || return 1
	d="$APP_RELEASE_ROOT/apps/$id"
	[[ -f "$d/manifest.env" ]] || return 1
	policy_rel="$(env_value POLICY_FILE "$d/manifest.env")"
	[[ "$(env_value ENABLED "$APP_RELEASE_ROOT/config/$policy_rel")" == true ]] || return 1
	nodes="$(env_value NODES "$APP_RELEASE_ROOT/config/$policy_rel")"
	csv_contains "$nodes" "$(node_value NODE_ID)"
}
image_required() {
	local key="$1" descriptor image_key app_id manifest component matched=0
	for manifest in "$CONTROL_ROOT"/current/compose/foundation/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		component="$(env_value COMPONENT_ID "$manifest")"
		for image_key in $(env_value IMAGE_KEYS "$manifest"); do
			[[ "$image_key" == "$key" ]] || continue
			matched=1
			foundation_enabled "$component" && return 0
		done
	done
	while IFS= read -r descriptor; do
		while IFS= read -r image_key; do
			[[ "$image_key" == "$key" ]] || continue
			matched=1
			app_id="$(env_value APP_ID "$descriptor")"
			app_enabled_for_image "$app_id" && return 0
		done < <(env_value IMAGE_KEYS "$descriptor" | tr ' ' '\n')
	done < <(find "$APP_RELEASE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
	((matched == 0)) && die "image key is not declared by a manifest: $key"
	return 1
}
image_key_declared() {
	local key="$1" manifest image_key
	for manifest in "$CONTROL_ROOT"/current/compose/foundation/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		for image_key in $(env_value IMAGE_KEYS "$manifest"); do
			[[ "$image_key" == "$key" ]] && return 0
		done
	done
	while IFS= read -r manifest; do
		while IFS= read -r image_key; do
			[[ "$image_key" == "$key" ]] && return 0
		done < <(env_value IMAGE_KEYS "$manifest" | tr ' ' '\n')
	done < <(find "$APP_RELEASE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
	return 1
}
prune_stale_image_keys() {
	local target="$1" tmp line key
	[[ -f "$target" ]] || return 0
	tmp="$(mktemp "${target}.tmp.XXXXXX")"
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		'' | \#*)
			printf '%s\n' "$line" >>"$tmp"
			;;
		*=*)
			key="${line%%=*}"
			if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && ! image_key_declared "$key"; then
				log "removing stale image key from $target: $key"
				continue
			fi
			printf '%s\n' "$line" >>"$tmp"
			;;
		*)
			printf '%s\n' "$line" >>"$tmp"
			;;
		esac
	done <"$target"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$target"
}

git_auth_helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-auth.sh"
if [[ ! -r "$git_auth_helper" && -r /usr/local/bin/git-auth.sh ]]; then
	git_auth_helper=/usr/local/bin/git-auth.sh
fi
[[ -r "$git_auth_helper" ]] || die "missing Git authentication helper: $git_auth_helper"
# Daily reconciliation is deliberately HTTPS-only. SSH may be used by the
# operator to bootstrap a host, but a Woodpecker deployment must not depend on
# an SSH key or an SSH connection to any VPS.
# shellcheck disable=SC1090
source "$git_auth_helper"
setup_github_https_auth || die 'unable to configure GitHub HTTPS authentication'
CONTROL_SYNC_ACTIVE=0
CONTROL_SYNC_SHA=''
CONTROL_SYNC_PREVIOUS_SHA=''
controller_exit() {
	local status=$?
	trap - EXIT
	if [[ "$CONTROL_SYNC_ACTIVE" == 1 && "$status" -ne 0 ]]; then
		write_control_sync_state failed "$CONTROL_SYNC_SHA" "$CONTROL_SYNC_PREVIOUS_SHA" 'control sync aborted before completion' || true
	fi
	cleanup_github_https_auth
	exit "$status"
}
trap controller_exit EXIT

SOURCE_MIRROR="$CONTROL_ROOT/mirror.git"
RELEASES="$CONTROL_ROOT/releases"
CURRENT="$CONTROL_ROOT/current"
PREVIOUS="$CONTROL_ROOT/previous"
APP_CURRENT="$APP_ROOT/current"
APP_PREVIOUS="$APP_ROOT/previous"

write_control_sync_state() {
	local state="$1" sha="$2" previous="$3" error="${4:-}" tmp
	install -d -m 700 "$(dirname "$CONTROL_SYNC_STATE_FILE")"
	tmp="$(mktemp "${CONTROL_SYNC_STATE_FILE}.tmp.XXXXXX")"
	printf 'node=%s\ntarget_sha=%s\nprevious_sha=%s\nstate=%s\nupdated_utc=%s\n' \
		"$(node_value NODE_ID)" "$sha" "${previous:-}" "$state" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
	if [[ -n "$error" ]]; then
		error="$(printf '%s' "$error" | tr '\n\r' '  ' | cut -c1-240)"
		printf 'error=%s\n' "$error" >>"$tmp"
	fi
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$CONTROL_SYNC_STATE_FILE"
}

apply_control_sync() {
	local sha="$1" release old_current old_sha='' stage
	CONTROL_SYNC_ACTIVE=1
	CONTROL_SYNC_SHA="$sha"
	if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
		write_control_sync_state failed "$sha" '' 'expected a full 40-character commit SHA' || true
		die 'expected a full 40-character commit SHA'
	fi
	exec 9>"$PLATFORM_LOCK_FILE"
	if ! flock -w 300 9; then
		write_control_sync_state failed "$sha" '' 'timed out waiting for deployment lock' || true
		die 'timed out waiting for deployment lock'
	fi
	log "control sync start: node=$(node_value NODE_ID) sha=$sha"
	debug_log "control pointer=$(readlink "$CURRENT" 2>/dev/null || printf '<missing>') service pointer=$(readlink "$APP_CURRENT" 2>/dev/null || printf '<missing>')"
	old_current="$(readlink "$CURRENT" 2>/dev/null || true)"
	old_sha="${old_current##*/}"
	if ! ensure_mirror; then
		write_control_sync_state failed "$sha" "$old_sha" 'unable to initialize repository mirror' || true
		die 'unable to initialize repository mirror'
	fi
	fetch_main || {
		write_control_sync_state failed "$sha" "$old_sha" 'unable to fetch repository' || true
		die 'unable to fetch repository'
	}
	if ! git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}"; then
		write_control_sync_state failed "$sha" "$old_sha" 'target is not in mirror'
		die 'target is not in mirror'
	fi
	if ! git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$sha" "refs/remotes/origin/$MAIN_BRANCH"; then
		write_control_sync_state failed "$sha" "$old_sha" 'target is not reachable from main'
		die 'target is not reachable from main'
	fi
	if is_superseded "$sha"; then
		log "superseded control sync skipped without mutation: sha=$sha latest=$(git -C "$SOURCE_MIRROR" rev-parse "refs/remotes/origin/$MAIN_BRANCH")"
		CONTROL_SYNC_ACTIVE=0
		return 78
	fi
	if [[ -n "$old_current" ]] && ! git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$old_sha" "$sha"; then
		write_control_sync_state failed "$sha" "$old_sha" 'target commit is older than installed control release'
		die 'target commit is older than the installed control release'
	fi
	if ! release="$(prepare_release "$sha")"; then
		write_control_sync_state failed "$sha" "$old_sha" 'unable to prepare control release' || true
		die 'unable to prepare control release'
	fi
	debug_log "prepared release=$release"
	if [[ "${CONTROL_VERIFY_ONLY:-0}" == 1 ]]; then
		verify_release_contract "$release" || {
			write_control_sync_state failed "$sha" "$old_sha" 'candidate contract verification failed'
			die 'candidate control contract verification failed'
		}
		validate_release "$release" 1 || {
			write_control_sync_state failed "$sha" "$old_sha" 'node-local candidate validation failed'
			die 'node-local candidate validation failed'
		}
	else
		if ! validate_release_cached "$release"; then
			write_control_sync_state failed "$sha" "$old_sha" 'candidate validation failed'
			die 'candidate control release validation failed'
		fi
	fi
	stage="$(mktemp -d "$CONTROL_ROOT/.control-sync.XXXXXX")"
	if ! sync_node_config "$release" "$stage/node.env"; then
		rm -rf -- "$stage"
		write_control_sync_state failed "$sha" "$old_sha" 'unable to stage node configuration' || true
		die 'unable to stage node configuration'
	fi
	if ! refresh_descriptor_registry "$release" "$stage/descriptors"; then
		rm -rf -- "$stage"
		write_control_sync_state failed "$sha" "$old_sha" 'unable to stage application descriptors' || true
		die 'unable to stage application descriptors'
	fi
	if ! install_control_sync_metadata "$stage"; then
		rm -rf -- "$stage"
		write_control_sync_state failed "$sha" "$old_sha" 'unable to install control metadata' || true
		die 'unable to install control metadata'
	fi
	if [[ "$old_current" != "$release" ]]; then
		if [[ -n "$old_current" ]] && ! atomic_link "$old_current" "$PREVIOUS"; then
			rollback_control_sync_metadata "$stage"
			rm -rf -- "$stage"
			write_control_sync_state failed "$sha" "$old_sha" 'unable to update previous control pointer' || true
			die 'unable to update previous control pointer'
		fi
		if ! atomic_link "$release" "$CURRENT"; then
			rollback_control_sync_metadata "$stage"
			rm -rf -- "$stage"
			write_control_sync_state failed "$sha" "$old_sha" 'unable to update current control pointer' || true
			die 'unable to update current control pointer'
		fi
	fi
	# This controller was loaded from the previously installed release; the
	# command below becomes available to a newly installed controller next sync.
	if ! PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" prune-app-endpoints; then
		if [[ -n "$old_current" ]]; then
			atomic_link "$old_current" "$CURRENT" || die 'endpoint metadata cleanup failed and the previous control pointer could not be restored'
		else
			rm -f -- "$CURRENT"
		fi
		rollback_control_sync_metadata "$stage"
		rm -rf -- "$stage"
		write_control_sync_state failed "$sha" "$old_sha" 'unable to prune retired app endpoint metadata' || true
		die 'unable to prune retired app endpoint metadata'
	fi
	rm -rf -- "$stage"
	write_release_attestation "$release"
	write_control_sync_state succeeded "$sha" "$old_sha"
	CONTROL_SYNC_ACTIVE=0
	log "control sync succeeded: $sha"
}

apply_control_verify() {
	CONTROL_VERIFY_ONLY=1 apply_control_sync "$1"
}

git_remote_url() {
	[[ "$REPO_URL" == https://github.com/* ]] || die 'REPO_URL must use HTTPS GitHub transport for daily deployment'
	printf '%s\n' "$REPO_URL"
}

sha_valid() { [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die 'expected a full 40-character commit SHA'; }

atomic_link() {
	local target="$1" link="$2" directory tmp
	directory="$(dirname "$link")"
	install -d -m 700 "$directory"
	tmp="$directory/.$(basename "$link").tmp.$$"
	rm -f -- "$tmp"
	ln -s "$target" "$tmp"
	# GNU mv needs -T to replace a symlink-to-directory; BSD mv uses -h
	# for the same no-follow behavior. Both preserve the old link until the
	# rename, avoiding a window where readers see no current release.
	if ! mv -fT "$tmp" "$link" 2>/dev/null; then
		mv -fh "$tmp" "$link"
	fi
}
sync_node_config() {
	local release="$1" destination="$2" runtime_source id source tmp value
	runtime_source="${3:-${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}}"
	id="$(env_value NODE_ID "$runtime_source")"
	[[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'runtime node ID is invalid'
	source="$release/config/cluster/nodes/$id.env"
	[[ -f "$source" ]] || die "release is missing node inventory: $id"
	install -d -m 700 "$(dirname "$destination")"
	tmp="$(mktemp "${destination}.tmp.XXXXXX")"
	cp "$source" "$tmp"
	# node.env is committed inventory plus this one private, host-local field.
	# Do not preserve arbitrary keys: that would let stale inventory or secrets
	# become an undocumented second source of truth.
	value="$(env_value LEADER_PUBLIC_IP "$runtime_source")"
	[[ -n "$value" ]] && printf 'LEADER_PUBLIC_IP=%s\n' "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$destination"
}

mkdir -p "$APP_ROOT/shared/logs" "$APP_ROOT/shared/runtime" "$RELEASES" "$(dirname "$PLATFORM_LOCK_FILE")"
# Older installations used only the control pointer.  Migrate the application
# pointer lazily and non-destructively so the first scoped deployment has a
# stable service baseline.
if [[ ! -e "$APP_CURRENT" && ! -L "$APP_CURRENT" && -L "$CURRENT" ]]; then
	atomic_link "$(readlink "$CURRENT")" "$APP_CURRENT"
fi
# The normal controller keeps an append-only deployment log. Test harnesses
# can set DEPLOY_LOG=/dev/null (or DEPLOY_LOG_TEE=0) to avoid creating a
# process-substitution tee for every mocked deployment; this also makes
# interruption cleanup deterministic.
if [[ "$DEPLOY_LOG" != /dev/null && "${DEPLOY_LOG_TEE:-1}" != 0 ]]; then
	exec > >(tee -a "$DEPLOY_LOG") 2>&1
fi

ensure_mirror() {
	if [[ ! -d "$SOURCE_MIRROR" ]]; then git init --bare "$SOURCE_MIRROR" >/dev/null; fi
	if git -C "$SOURCE_MIRROR" remote get-url origin >/dev/null 2>&1; then
		git -C "$SOURCE_MIRROR" remote set-url origin "$(git_remote_url)"
	else
		git -C "$SOURCE_MIRROR" remote add origin "$(git_remote_url)"
	fi
}

fetch_main() {
	local attempt delay
	for attempt in 1 2 3 4 5; do
		if git -C "$SOURCE_MIRROR" fetch --prune origin "+refs/heads/$MAIN_BRANCH:refs/remotes/origin/$MAIN_BRANCH"; then return 0; fi
		log "git fetch retry $attempt"
		delay="$DEPLOY_FETCH_RETRY_DELAY_SECONDS"
		if ((delay > 0)); then sleep "$delay"; fi
	done
	return 1
}

verify_target() {
	local sha="$1"
	git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'target is not in mirror'
	git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$sha" "refs/remotes/origin/$MAIN_BRANCH" || die 'target is not reachable from main'
}

sha256_file_safe() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	else
		shasum -a 256 "$file" | awk '{print $1}'
	fi
}

release_attestation_fingerprint() {
	local release="$1" tree policy images foundation controller ctl sha
	sha="$(basename "$release")"
	tree="$(git -C "$SOURCE_MIRROR" rev-parse "$sha^{tree}")"
	policy="$(sha256_file_safe "$release/config/cluster/policy.env")"
	images="$(sha256_file_safe "$release/ops/images.apps.prod.env")"
	foundation="$(sha256_file_safe "$release/ops/images.foundation.prod.env")"
	controller="$(sha256_file_safe "$release/ops/deploy-controller.sh")"
	ctl="$(sha256_file_safe "$release/ops/platformctl.sh")"
	printf 'schema=1\nsha=%s\ntree=%s\npolicy=%s\napps_images=%s\nfoundation_images=%s\ndeploy_controller=%s\nplatformctl=%s\n' "$sha" "$tree" "$policy" "$images" "$foundation" "$controller" "$ctl"
}

write_release_attestation() {
	local release="$1" tmp
	install -d -m 700 "$(dirname "$CONTROL_ATTESTATION_FILE")"
	tmp="$(mktemp "${CONTROL_ATTESTATION_FILE}.tmp.XXXXXX")"
	release_attestation_fingerprint "$release" >"$tmp"
	printf 'validated_utc=%s\nnode=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(node_value NODE_ID)" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$CONTROL_ATTESTATION_FILE"
}

is_superseded() {
	local sha="$1" latest
	latest="$(git -C "$SOURCE_MIRROR" rev-parse "refs/remotes/origin/$MAIN_BRANCH" 2>/dev/null || true)"
	[[ -n "$latest" && "$latest" != "$sha" ]] || return 1
	git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$sha" "$latest"
}

verify_release_contract() {
	local release="$1" node
	[[ -f "$release/config/cluster/policy.env" && -f "$release/ops/platformctl.sh" ]] || die 'release contract is incomplete'
	validate_application_image_locks "$release"
	node="$(node_value NODE_ID)"
	[[ "$(env_value NODE_ID "$release/config/cluster/nodes/$node.env")" == "$node" ]] || die "release node inventory does not contain runtime node: $node"
}

control_sync_matches_sha() {
	local sha="$1" state_sha state_status current_sha
	[[ -f "$CONTROL_SYNC_STATE_FILE" ]] || return 1
	state_status="$(sed -n 's/^state=//p' "$CONTROL_SYNC_STATE_FILE" | tail -n1)"
	state_sha="$(sed -n 's/^target_sha=//p' "$CONTROL_SYNC_STATE_FILE" | tail -n1)"
	current_sha="$(basename "$(readlink "$CURRENT" 2>/dev/null || true)")"
	[[ "$state_status" == succeeded && "$state_sha" == "$sha" && "$current_sha" == "$sha" ]]
}

verify_fast_forward() {
	local old_release="$1" sha="$2" mode="$3" old_sha
	[[ "$mode" == rollback || -z "$old_release" ]] && return 0
	old_sha="$(basename "$old_release")"
	if ! git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$old_sha" "$sha"; then
		log "deployment ordering guard: current=$old_sha target=$sha mode=$mode"
		die 'target commit is older than the installed release; retry the newest Woodpecker build (or use the explicit rollback workflow)'
	fi
}

scope_failure() {
	local old_sha="$1" new_sha="$2" mode="$3" path
	log "deployment scope rejected: mode=$mode old=$old_sha new=$new_sha"
	while IFS= read -r path; do
		[[ -n "$path" ]] && log "changed path: $path"
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

verify_app_scope() {
	local old_release="$1" new_release="$2" mode="${3:-app}" old_sha new_sha path
	[[ -n "$old_release" ]] || return 0
	old_sha="$(basename "$old_release")"
	new_sha="$(basename "$new_release")"
	while IFS= read -r path; do
		case "$path" in
		compose/foundation/** | config/Caddyfile | config/foundation-routes.d/** | config/cluster/foundation/** | ops/images.foundation.prod.env | ops/foundation/** | ops/systemd/** | ops/*.sh | ops/deploy-runner/** | ops/tests/**)
			[[ "$mode" == foundation || "$mode" == cluster-reconcile || "$mode" == rollback ]] || {
				scope_failure "$old_sha" "$new_sha" "$mode"
				die "foundation/control-plane change requires the reviewed foundation workflow: $path"
			}
			continue
			;;
		esac
		case "$path" in
		apps/* | config/** | .woodpecker/** | README.md | LICENSE.md | .env.prod.example | .env.dev.example | ops/generate-woodpecker-workflows.sh) ;;
		ops/images.apps.prod.env) ;;
		*)
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "application deployment contains foundation/control-plane change: $path; use the reviewed foundation workflow"
			;;
		esac
		case "$path" in
		config/cluster/policy.env | config/cluster/nodes/* | config/cluster/foundation/*.policy)
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "cluster policy or inventory change requires a consumer or cluster reconciliation workflow: $path"
			;;
		config/cluster/apps/*)
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "cluster app policy requires its consumer reconciliation workflow: $path"
			;;
		config/cluster/*)
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "unsupported cluster configuration path in application deployment: $path"
			;;
		esac
		if [[ "$path" == ops/images.apps.prod.env && "$mode" != app-upgrade ]]; then
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "application image manifest changes require the reviewed consumer workflow: $path"
		fi
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

verify_cluster_scope() {
	local old_release="$1" new_release="$2" old_sha new_sha path app manifest policy old_leader new_leader
	[[ -n "$old_release" ]] || return 0
	old_sha="$(basename "$old_release")"
	new_sha="$(basename "$new_release")"
	old_leader="$(sed -n 's/^LEADER_NODE_ID=//p' "$old_release/config/cluster/policy.env" | tail -n1)"
	new_leader="$(sed -n 's/^LEADER_NODE_ID=//p' "$new_release/config/cluster/policy.env" | tail -n1)"
	[[ "$old_leader" == "$new_leader" ]] || {
		scope_failure "$old_sha" "$new_sha" cluster-reconcile
		die 'cluster reconciliation cannot change LEADER_NODE_ID; use explicit repair promotion'
	}
	while IFS= read -r path; do
		case "$path" in
		config/cluster/apps/*.policy)
			app="$(basename "$path" .policy)"
			manifest="$new_release/apps/$app/manifest.env"
			policy="$new_release/$path"
			if [[ ! -f "$manifest" || ! -f "$policy" || "$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)" != "${path#config/}" ]]; then
				scope_failure "$old_sha" "$new_sha" cluster-reconcile
				die "cluster reconciliation contains an undeclared application policy: $path"
			fi
			if [[ "$(sed -n 's/^UPSTREAM_MODE=//p' "$manifest" | tail -n1)" == singleton && "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" == true ]]; then
				scope_failure "$old_sha" "$new_sha" cluster-reconcile
				die "cluster reconciliation cannot own an enabled singleton policy: $path; use its dedicated stage/switch/stop workflow"
			fi
			;;
		config/cluster/policy.env | config/cluster/nodes/* | config/cluster/foundation/*.policy | .woodpecker/** | README.md | AGENTS.md) ;;
		*)
			scope_failure "$old_sha" "$new_sha" cluster-reconcile
			die "cluster reconciliation contains a non-cluster change: $path; run the reviewed foundation workflow first"
			;;
		esac
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

verify_woodpecker_self_disable() {
	local old_release="$1" new_release="$2" old_policy new_policy old_enabled new_enabled
	[[ "$(runtime_node_role)" == leader && -n "$old_release" ]] || return 0
	old_policy="$old_release/config/cluster/foundation/woodpecker.policy"
	new_policy="$new_release/config/cluster/foundation/woodpecker.policy"
	[[ -f "$old_policy" && -f "$new_policy" ]] || return 0
	old_enabled="$(env_value ENABLED "$old_policy")"
	new_enabled="$(env_value ENABLED "$new_policy")"
	if [[ "$old_enabled" == true && "$new_enabled" == false && "${ALLOW_WOODPECKER_SELF_DISABLE:-0}" != 1 ]]; then
		die 'refusing to disable Woodpecker from its own deployment control plane; run an explicit recovery deployment with ALLOW_WOODPECKER_SELF_DISABLE=1'
	fi
}

verify_consumer_scope() {
	# Control sync runs before every consumer workflow. A commit may therefore
	# coordinate an application change with foundation, policy, or controller
	# changes; those changes are installed by their own optional workflows while
	# this job reconciles only the selected application. Non-runtime paths such as
	# ops/tests/** | docs/** remain harmless to include in the same commit.
	local old_release="$1" new_release="$2" mode="$3" app="${CONSUMER_APP_ID:-}" manifest
	[[ "$mode" == consumer-stage || "$mode" == consumer-publish || "$mode" == consumer-stop || "$mode" == direct-publish ]] || return 0
	[[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || die 'consumer deployment is missing a valid CONSUMER_APP_ID'
	manifest="$new_release/apps/$app/manifest.env"
	[[ -f "$manifest" && "$(env_value APP_ID "$manifest")" == "$app" ]] || die "consumer application is not present in target release: $app"
	[[ "$(env_value PLACEMENT "$manifest")" == consumer ]] || die "application is not a consumer: $app"
}
singleton_previous_target() {
	local release="$1" app="$2" state_file
	state_file="$SINGLETON_STATE_ROOT/$app.previous-target"
	if [[ -s "$state_file" ]]; then
		sed -n '1p' "$state_file"
		return 0
	fi
	singleton_release_target "$release" "$app"
}
singleton_release_target() {
	local release="$1" app="$2" manifest policy_rel
	[[ -n "$release" && -f "$release/apps/$app/manifest.env" ]] || return 0
	manifest="$release/apps/$app/manifest.env"
	policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"
	sed -n 's/^NODES=//p' "$release/config/$policy_rel" 2>/dev/null | tail -n1
}
record_singleton_transitions() {
	local old_release="$1" new_release="$2" manifest app old_target new_target state_file tmp
	[[ -n "$old_release" && -d "$new_release/apps" ]] || return 0
	while IFS= read -r manifest; do
		[[ "$(sed -n 's/^UPSTREAM_MODE=//p' "$manifest" | tail -n1)" == singleton ]] || continue
		app="$(basename "$(dirname "$manifest")")"
		old_target="$(singleton_release_target "$old_release" "$app")"
		new_target="$(singleton_release_target "$new_release" "$app")"
		[[ -n "$old_target" && -n "$new_target" && "$old_target" != "$new_target" ]] || continue
		install -d -m 700 "$SINGLETON_STATE_ROOT"
		state_file="$SINGLETON_STATE_ROOT/$app.previous-target"
		tmp="$(mktemp "$state_file.XXXXXX")"
		printf '%s\n' "$old_target" >"$tmp"
		chmod 600 "$tmp"
		mv -f -- "$tmp" "$state_file"
	done < <(find "$new_release/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}
remove_compose_project_containers() {
	local project="$1" description="$2" ids id
	if ! ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then
		log "ERROR: unable to enumerate containers for $description: $project" >&2
		return 1
	fi
	[[ -n "$ids" ]] || return 0
	log "stopping $description project $project"
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		if ! docker rm -f "$id" >/dev/null 2>&1; then
			log "ERROR: unable to stop $description project: $project" >&2
			return 1
		fi
	done <<<"$ids"
}

stop_removed_projects() {
	local old_release="$1" new_release="$2" manifest app project
	[[ -n "$old_release" && -d "$old_release/apps" ]] || return 0
	while IFS= read -r manifest; do
		app="$(basename "$(dirname "$manifest")")"
		[[ -f "$new_release/apps/$app/manifest.env" ]] && continue
		[[ "$app" =~ ^[a-z][a-z0-9-]*$ && "$(env_value APP_ID "$manifest")" == "$app" ]] || die "invalid removed application manifest: $manifest"
		project="$(sed -n 's/^COMPOSE_PROJECT=//p' "$manifest" | tail -n1)"
		[[ "$project" == "app-$app" ]] || die "invalid Compose project in removed application manifest: $manifest"
		remove_compose_project_containers "$project" 'removed application' || return 1
	done < <(find "$old_release/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}

stop_removed_foundation_projects() {
	local old_release="$1" new_release="$2" manifest component project
	[[ -n "$old_release" && -d "$old_release/compose/foundation/manifests" ]] || return 0
	while IFS= read -r manifest; do
		component="$(basename "$manifest" .env)"
		[[ -f "$new_release/compose/foundation/manifests/$component.env" ]] && continue
		[[ "$component" =~ ^[a-z][a-z0-9-]*$ && "$(env_value COMPONENT_ID "$manifest")" == "$component" ]] || die "invalid removed foundation manifest: $manifest"
		project="foundation-$component"
		remove_compose_project_containers "$project" 'removed foundation component' || return 1
	done < <(find "$old_release/compose/foundation/manifests" -mindepth 1 -maxdepth 1 -type f -name '*.env' -print | sort)
}

prepare_release() {
	local sha="$1" release="$RELEASES/$sha"
	if [[ ! -e "$release" ]]; then git -C "$SOURCE_MIRROR" worktree add --detach "$release" "$sha" >/dev/null; fi
	printf '%s\n' "$release"
}

validate_application_image_locks() {
	local release="$1" manifest app lock key image lock_image line lock_key
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app="$(env_value APP_ID "$manifest")"
		lock="$release/apps/$app/images.lock.env"
		[[ -f "$lock" ]] || die "application image lock is missing: $app"
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			image="$(env_value "$key" "$release/ops/images.apps.prod.env")"
			lock_image="$(env_value "$key" "$lock")"
			[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || die "canonical application image is not digest-pinned: $app/$key"
			[[ "$lock_image" == "$image" ]] || die "application image lock differs from the canonical manifest: $app/$key"
		done < <(env_value IMAGE_KEYS "$manifest" | tr ' ' '\n')
		while IFS= read -r line || [[ -n "$line" ]]; do
			case "$line" in '' | \#*) continue ;; *=*) lock_key="${line%%=*}" ;; *) die "invalid application image lock entry: $lock" ;; esac
			csv_contains "$(env_value IMAGE_KEYS "$manifest" | tr ' ' ',')" "$lock_key" || die "undeclared image key in application lock: $app/$lock_key"
		done <"$lock"
	done < <(find "$release/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}

stage_validation_runtime_config() {
	local release="$1" destination="$2" manifest runtime_rel source_rel source_prefix target_prefix source target tmp
	install -d -m 700 "$destination"
	if [[ -f "$CONFIG_ROOT/platform.env" && ! -L "$CONFIG_ROOT/platform.env" ]]; then
		install -m 600 "$CONFIG_ROOT/platform.env" "$destination/platform.env"
	fi
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		runtime_rel="$(env_value RUNTIME_ENV_FILE "$manifest")"
		[[ -n "$runtime_rel" ]] || continue
		[[ "$runtime_rel" != /* && "$runtime_rel" != *..* && "$runtime_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "unsafe RUNTIME_ENV_FILE in candidate release: $manifest"
		target="$destination/$runtime_rel"
		install -d -m 700 "$(dirname "$target")"
		if [[ -f "$CONFIG_ROOT/$runtime_rel" && ! -L "$CONFIG_ROOT/$runtime_rel" ]]; then
			install -m 600 "$CONFIG_ROOT/$runtime_rel" "$target"
			continue
		fi
		[[ -n "$(env_value IDENTITY_MIGRATION_FROM_APP_ID "$manifest")" ]] || continue
		source_rel="$(env_value IDENTITY_MIGRATION_FROM_RUNTIME_ENV_FILE "$manifest")"
		source_prefix="$(env_value IDENTITY_MIGRATION_FROM_ENV_PREFIX "$manifest")"
		target_prefix="$(env_value IDENTITY_MIGRATION_TO_ENV_PREFIX "$manifest")"
		[[ "$source_rel" != /* && "$source_rel" != *..* && "$source_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "unsafe identity migration runtime env in candidate release: $manifest"
		[[ "$source_prefix" =~ ^[A-Z][A-Z0-9_]*$ && "$target_prefix" =~ ^[A-Z][A-Z0-9_]*$ && "$source_prefix" != "$target_prefix" ]] || die "invalid identity migration prefixes in candidate release: $manifest"
		source="$CONFIG_ROOT/$source_rel"
		[[ -f "$source" && ! -L "$source" ]] || continue
		tmp="$(mktemp "$target.XXXXXX")"
		sed "s/^${source_prefix}_/${target_prefix}_/" "$source" >"$tmp"
		chmod 600 "$tmp"
		mv -f -- "$tmp" "$target"
	done < <(find "$release/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}

validate_release() {
	local release="$1" local_scope="${2:-0}" runtime foundation_validate control_validate validation_config image_apps image_foundation
	[[ -f "$release/ops/platformctl.sh" && -d "$release/apps" && -d "$release/config" ]] || die 'release is missing platform files'
	validate_application_image_locks "$release"
	install -d -m 700 "$APP_ROOT/shared/runtime"
	runtime="$(mktemp -d "$APP_ROOT/shared/runtime/validate.XXXXXX")"
	foundation_validate="$(mktemp -d "$APP_ROOT/shared/runtime/foundation-validate.XXXXXX")"
	control_validate="$(mktemp -d "$APP_ROOT/shared/runtime/control-validate.XXXXXX")"
	validation_config="$control_validate/runtime-config"
	image_apps="$control_validate/images.apps.env"
	image_foundation="$control_validate/images.foundation.env"
	ln -s "$release" "$control_validate/current"
	install -m 600 "$release/ops/images.apps.prod.env" "$image_apps"
	install -m 600 "$release/ops/images.foundation.prod.env" "$image_foundation"
	install -d -m 700 "$foundation_validate/env"
	cp -a "$FOUNDATION_ROOT/env/." "$foundation_validate/env/" 2>/dev/null || true
	install -d -m 700 "$control_validate/config/cluster/nodes"
	stage_validation_runtime_config "$release" "$validation_config"
	cp -a "$release/config/cluster/." "$control_validate/config/cluster/"
	sync_node_config "$release" "$control_validate/node.env"
	copy_foundation_payload "$release" "$foundation_validate"
	if ! PLATFORM_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" CONTROL_ROOT="$control_validate" CONFIG_ROOT="$validation_config" APPS_ROOT="$release/apps" RUNTIME_ROOT="$runtime" \
		APP_ENV="$APP_ENV" APP_IMAGE_ENV="$image_apps" FOUNDATION_IMAGE_ENV="$image_foundation" \
		FOUNDATION_ROOT="$foundation_validate" FOUNDATION_ENV_ROOT="$foundation_validate/env" NODE_CONFIG_FILE="$control_validate/node.env" CLUSTER_POLICY_FILE="$control_validate/config/cluster/policy.env" \
		PLATFORM_VALIDATE_LOCAL="$local_scope" PLATFORM_TEST_MODE="$PLATFORM_TEST_MODE" PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION="$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" PLATFORM_TEST_SKIP_SYNC_VALIDATION="$PLATFORM_TEST_SKIP_SYNC_VALIDATION" PLATFORM_TEST_SKIP_RENDER="$PLATFORM_TEST_SKIP_RENDER" PLATFORM_TEST_SKIP_COMPOSE_INSPECTION="$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" PLATFORM_TEST_FAST_VALIDATE="$PLATFORM_TEST_FAST_VALIDATE" PLATFORM_TEST_ONLY_DESCRIPTOR="$PLATFORM_TEST_ONLY_DESCRIPTOR" PLATFORM_TEST_SKIP_CLUSTER_VALIDATION="$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" \
		PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" PLATFORM_LOCK_HELD=1 \
		"$release/ops/platformctl.sh" validate --check; then
		rm -rf -- "$runtime" "$foundation_validate" "$control_validate"
		return 1
	fi
	rm -rf -- "$runtime" "$foundation_validate" "$control_validate"
}

validation_cache_key() {
	local release="$1" file fingerprint
	fingerprint="$({
		printf 'schema=2\nrelease=%s\n' "$(basename "$release")"
		for file in "${BASH_SOURCE[0]}" "$release/ops/platformctl.sh" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" "$APP_ENV" "$APP_IMAGE_ENV" "$FOUNDATION_IMAGE_ENV" "$CONFIG_ROOT/platform.env"; do
			if [[ -f "$file" ]]; then cksum "$file"; else printf 'missing %s\n' "$file"; fi
		done
		for file in "$FOUNDATION_ROOT"/env/* "$APP_ROOT/shared/runtime/app-env"/*; do
			[[ -f "$file" ]] && cksum "$file"
		done
		printf 'compose=%s\n' "$("${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" version 2>/dev/null | head -n1 || printf unavailable)"
		printf 'docker=%s\n' "$(docker version --format '{{.Client.Version}}' 2>/dev/null || printf unavailable)"
	} | cksum | awk '{print $1}')"
	printf '%s.%s' "$(basename "$release")" "$fingerprint"
}
validate_release_cached() {
	local release="$1" cache key
	[[ "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 1 ]] && return 0
	key="$(validation_cache_key "$release")"
	cache="$VALIDATION_CACHE_ROOT/$key.ok"
	if [[ -f "$cache" ]] && grep -Fxq "sha=$(basename "$release")" "$cache"; then
		debug_log "reusing validated release: $(basename "$release")"
		return 0
	fi
	validate_release "$release" || return 1
	install -d -m 700 "$VALIDATION_CACHE_ROOT"
	printf 'schema=2\nsha=%s\nvalidated_utc=%s\n' "$(basename "$release")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$cache"
	chmod 600 "$cache"
}

copy_foundation_payload() {
	local release="$1" destination="$2" file mode
	install -d -m 700 "$destination"
	for file in "$release"/compose/foundation/*; do
		[[ -f "$file" ]] || continue
		mode=600
		[[ "$file" == *.sh ]] && mode=700
		install -m "$mode" "$file" "$destination/$(basename "$file")"
	done
}

append_csv_unique() {
	local list="$1" item="$2"
	case ",$list," in *",$item,"*) printf '%s\n' "$list" ;; *) printf '%s%s\n' "${list}${list:+,}" "$item" ;; esac
}
changed_foundation_projects() {
	local release="$1" force_all="${2:-0}" component manifest compose payload key candidate_image installed_image projects=''
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		component="$(basename "$manifest" .env)"
		compose="$(env_value COMPOSE_FILE "$manifest")"
		if [[ "$force_all" == 1 ]] || ! cmp -s "$manifest" "$FOUNDATION_ROOT/manifests/$component.env" || ! cmp -s "$release/compose/foundation/$compose" "$FOUNDATION_ROOT/$compose"; then
			projects="$(append_csv_unique "$projects" "$component")"
		fi
		while IFS= read -r payload; do
			payload="${payload#./}"
			payload="${payload%:}"
			[[ "$payload" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe relative foundation payload in $compose: $payload"
			cmp -s "$release/compose/foundation/$payload" "$FOUNDATION_ROOT/$payload" || projects="$(append_csv_unique "$projects" "$component")"
		done < <(grep -oE '\./[A-Za-z0-9._-]+:' "$release/compose/foundation/$compose" 2>/dev/null | sort -u || true)
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			candidate_image="$(env_value "$key" "$release/ops/images.foundation.prod.env")"
			installed_image="$(env_value "$key" "$FOUNDATION_IMAGE_ENV")"
			[[ "$candidate_image" == "$installed_image" ]] || projects="$(append_csv_unique "$projects" "$component")"
		done < <(env_value IMAGE_KEYS "$manifest" | tr ' ' '\n')
	done < <(find "$release/compose/foundation/manifests" -mindepth 1 -maxdepth 1 -type f -name '*.env' -print | sort)
	# Keep removed components in the transaction list. They are stopped before
	# installation; if a later step fails, rollback restores their manifests and
	# this list ensures their containers are recreated from the restored payload.
	for manifest in "$FOUNDATION_ROOT"/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		component="$(basename "$manifest" .env)"
		[[ -f "$release/compose/foundation/manifests/$component.env" ]] || projects="$(append_csv_unique "$projects" "$component")"
	done
	printf '%s\n' "$projects"
}

verify_foundation_self_recreate() {
	local projects=",$1," component
	[[ "${DEPLOY_WORKFLOW:-unknown}" != unknown ]] || return 0
	if [[ "$(runtime_node_role)" == leader ]]; then
		for component in caddy woodpecker-controller woodpecker-deployer; do
			[[ "$projects" == *",$component,"* ]] || continue
			die "refusing to recreate $component from the Woodpecker control plane; run this committed foundation upgrade locally on the Leader"
		done
	elif [[ "$projects" == *',woodpecker-worker,'* ]]; then
		die 'refusing to recreate woodpecker-worker from its own agent; run this committed foundation upgrade locally on the Follower'
	fi
}

pull_image() {
	local image="$1" attempt delay
	for attempt in 1 2 3 4 5; do
		if docker pull "$image" >/dev/null; then
			return 0
		fi
		((attempt < 5)) || die "unable to pull image after $attempt attempts: $image"
		delay=$((attempt * DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS))
		log "image pull failed; retrying in ${delay} seconds (attempt $attempt/5): $image"
		if ((delay > 0)); then sleep "$delay"; fi
	done
}

backup() {
	local reason="${1:-pre-deploy}" pipeline="${DEPLOY_PIPELINE:-}" marker_root marker_key marker tmp node
	[[ -x "$BACKUP_SCRIPT" ]] || die "backup script is not executable: $BACKUP_SCRIPT"
	# A pipeline can stage several applications on the same host. The host lock
	# serializes those stages, so one verified snapshot is sufficient for the
	# whole pipeline. Unknown/manual invocations intentionally retain the old
	# per-operation behavior.
	if [[ "${DEPLOY_FORCE_BACKUP:-0}" != 1 && -n "$pipeline" && "$pipeline" != unknown && "$pipeline" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
		node="$(node_value NODE_ID)"
		marker_root="${DEPLOY_BACKUP_MARKER_ROOT:-$PLATFORM_ROOT/deployment-backups}"
		marker_key="${node}.${pipeline}.${sha:-unknown}"
		marker_key="$(printf '%s' "$marker_key" | tr -c 'A-Za-z0-9_.-' '_')"
		marker="$marker_root/$marker_key.env"
		if [[ -f "$marker" && "$(sed -n 's/^SCHEMA=//p' "$marker" | tail -n1)" == 1 && "$(sed -n 's/^NODE_ID=//p' "$marker" | tail -n1)" == "$node" && "$(sed -n 's/^PIPELINE=//p' "$marker" | tail -n1)" == "$pipeline" && "$(sed -n 's/^SHA=//p' "$marker" | tail -n1)" == "$sha" ]]; then
			log "verified backup already exists for node=$node pipeline=$pipeline sha=$sha"
			return 0
		fi
	fi
	log "Creating verified pre-change snapshot: $reason"
	PLATFORM_LOCK_HELD=1 "$BACKUP_SCRIPT" snapshot "$reason" || die 'verified backup failed'
	if [[ -n "${marker:-}" ]]; then
		install -d -m 700 "$marker_root"
		tmp="$(mktemp "$marker.tmp.XXXXXX")"
		printf 'SCHEMA=1\nNODE_ID=%s\nPIPELINE=%s\nSHA=%s\nREASON=%s\nCREATED_UTC=%s\n' \
			"$node" "$pipeline" "$sha" "$reason" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
		chmod 600 "$tmp"
		mv -f -- "$tmp" "$marker"
	fi
}

install_foundation_files() {
	local release="$1" file
	install -d -m 700 "$FOUNDATION_ROOT/env" "$FOUNDATION_ROOT/manifests"
	find "$FOUNDATION_ROOT" -mindepth 1 -maxdepth 1 -type f -delete
	rm -rf -- "$FOUNDATION_ROOT/manifests"
	install -d -m 700 "$FOUNDATION_ROOT/manifests"
	copy_foundation_payload "$release" "$FOUNDATION_ROOT"
	for file in "$release"/compose/foundation/manifests/*.env; do
		[[ -f "$file" ]] || continue
		install -m 600 "$file" "$FOUNDATION_ROOT/manifests/$(basename "$file")"
	done
}

refresh_descriptor_registry() {
	local release="$1" descriptor id registry="${2:-$CONTROL_ROOT/descriptors}" old
	install -d -m 700 "$registry"
	if [[ "$registry" == "$CONTROL_ROOT/descriptors" ]]; then
		rm -rf -- "${registry:?}"/*
	fi
	for descriptor in "$release"/apps/*; do
		[[ -f "$descriptor/manifest.env" ]] || continue
		id="$(basename "$descriptor")"
		install -d -m 700 "$registry/$id"
		install -m 600 "$descriptor/manifest.env" "$registry/$id/manifest.env"
	done
	for old in "$registry"/*; do
		[[ -f "$old/manifest.env" ]] || continue
		id="${old##*/}"
		[[ -f "$release/apps/$id/manifest.env" ]] || rm -rf -- "$old"
	done
}

install_control_sync_metadata() {
	local stage="$1" destination="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" registry="$CONTROL_ROOT/descriptors"
	local backup="$stage/old-descriptors" old_node="$stage/old-node.env"
	[[ -f "$stage/node.env" && -d "$stage/descriptors" ]] || return 1
	if [[ -e "$destination" || -L "$destination" ]]; then
		cp -p "$destination" "$old_node" || return 1
	fi
	if [[ -e "$registry" || -L "$registry" ]]; then
		mv -- "$registry" "$backup" || return 1
	fi
	if ! mv -- "$stage/descriptors" "$registry"; then
		[[ -e "$backup" ]] && mv -- "$backup" "$registry"
		return 1
	fi
	if ! mv -f -- "$stage/node.env" "$destination"; then
		rm -rf -- "$registry"
		[[ -e "$backup" ]] && mv -- "$backup" "$registry"
		[[ -e "$old_node" ]] && mv -f -- "$old_node" "$destination"
		return 1
	fi
}

rollback_control_sync_metadata() {
	local stage="$1" destination="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" registry="$CONTROL_ROOT/descriptors"
	rm -rf -- "$registry"
	if [[ -e "$stage/old-descriptors" ]]; then
		mv -- "$stage/old-descriptors" "$registry"
	else
		install -d -m 700 "$registry"
	fi
	if [[ -e "$stage/old-node.env" ]]; then
		mv -f -- "$stage/old-node.env" "$destination"
	else
		rm -f -- "$destination"
	fi
}

install_application_image_lock() {
	local release="$1" app="$2" manifest lock key image tmp next
	manifest="$release/apps/$app/manifest.env"
	lock="$release/apps/$app/images.lock.env"
	[[ -f "$manifest" && -f "$lock" ]] || die "missing application manifest or image lock: $app"
	install -d -m 700 "$(dirname "$APP_IMAGE_ENV")"
	tmp="$(mktemp "${APP_IMAGE_ENV}.tmp.XXXXXX")"
	[[ -f "$APP_IMAGE_ENV" ]] && cp "$APP_IMAGE_ENV" "$tmp"
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		image="$(env_value "$key" "$lock")"
		[[ -n "$image" ]] || die "application image lock is missing $key: $app"
		next="$(mktemp "${APP_IMAGE_ENV}.key.XXXXXX")"
		sed "/^${key}=/d" "$tmp" >"$next"
		printf '%s=%s\n' "$key" "$image" >>"$next"
		mv -f -- "$next" "$tmp"
	done < <(env_value IMAGE_KEYS "$manifest" | tr ' ' '\n')
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$APP_IMAGE_ENV"
}

prefetch_images() {
	local mode="$1" file key image should_pull
	local -a files=()
	case "$mode" in
	app | app-upgrade | consumer-publish | direct-publish | consumer-stop) files=("$APP_IMAGE_ENV") ;;
	consumer-stage) files=("$APP_RELEASE_ROOT/apps/${CONSUMER_APP_ID:?missing CONSUMER_APP_ID}/images.lock.env") ;;
	foundation) files=("$FOUNDATION_IMAGE_ENV") ;;
	cluster-reconcile | rollback) files=("$APP_IMAGE_ENV" "$FOUNDATION_IMAGE_ENV") ;;
	*) die "unknown image prefetch mode: $mode" ;;
	esac
	for file in "${files[@]}"; do
		[[ -f "$file" ]] || continue
		while IFS='=' read -r key image; do
			[[ -n "$key" && "$key" != \#* && -n "$image" ]] || continue
			image_required "$key" || {
				log "skipping image for disabled or inactive service: $key"
				continue
			}
			should_pull=0
			# Digest-pinned image references make presence a sufficient reuse
			# decision. A changed lock points at a different digest and therefore
			# naturally misses this inspection, while unchanged images are never
			# needlessly pulled during foundation or application upgrades.
			if ! docker image inspect "$image" >/dev/null 2>&1; then
				should_pull=1
			fi
			if ((should_pull == 1)); then pull_image "$image"; fi
		done <"$file"
	done
}

reconcile() {
	PLATFORM_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" CONTROL_ROOT="$CONTROL_ROOT" APPS_ROOT="$APP_RELEASE_ROOT/apps" FOUNDATION_ROOT="$FOUNDATION_ROOT" \
		APP_ENV="$APP_ENV" APP_IMAGE_ENV="$APP_IMAGE_ENV" FOUNDATION_IMAGE_ENV="$FOUNDATION_IMAGE_ENV" \
		FOUNDATION_ENV_ROOT="$FOUNDATION_ROOT/env" RUNTIME_ROOT="$APP_ROOT/shared/runtime" \
		NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" \
		CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}" \
		PLATFORM_ONLY_APP_ID="${PLATFORM_ONLY_APP_ID:-}" \
		PLATFORM_ONLY_ROUTE_APP_ID="${PLATFORM_ONLY_ROUTE_APP_ID:-}" \
		PLATFORM_PRESERVE_CONSUMER_ROUTES="${PLATFORM_PRESERVE_CONSUMER_ROUTES:-0}" \
		PLATFORM_RECONCILE_DISABLED_SINGLETONS="${PLATFORM_RECONCILE_DISABLED_SINGLETONS:-0}" \
		PLATFORM_TEST_MODE="$PLATFORM_TEST_MODE" \
		PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION="$PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION" \
		PLATFORM_TEST_SKIP_SYNC_VALIDATION="$PLATFORM_TEST_SKIP_SYNC_VALIDATION" \
		PLATFORM_TEST_SKIP_RENDER="$PLATFORM_TEST_SKIP_RENDER" \
		PLATFORM_TEST_SKIP_COMPOSE_INSPECTION="$PLATFORM_TEST_SKIP_COMPOSE_INSPECTION" \
		PLATFORM_TEST_FAST_VALIDATE="$PLATFORM_TEST_FAST_VALIDATE" PLATFORM_TEST_ONLY_DESCRIPTOR="$PLATFORM_TEST_ONLY_DESCRIPTOR" PLATFORM_TEST_SKIP_CLUSTER_VALIDATION="$PLATFORM_TEST_SKIP_CLUSTER_VALIDATION" \
		PLATFORM_RECREATE_FOUNDATION="${DEPLOY_RECREATE_FOUNDATION:-0}" \
		PLATFORM_RECREATE_FOUNDATION_PROJECTS="${DEPLOY_RECREATE_FOUNDATION_PROJECTS:-}" \
		PLATFORM_RECREATE_APPS="${DEPLOY_RECREATE_APPS:-0}" \
		PLATFORM_DEPLOYMENT_VALIDATED="${DEPLOYMENT_VALIDATED:-0}" \
		PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
		PLATFORM_LOCK_HELD=1 \
		"$PLATFORMCTL_SCRIPT" sync "${DEPLOY_SYNC_SCOPE:-apps}"
}

smoke_apps() {
	local descriptor id mode policy_file nodes
	for descriptor in "$APP_RELEASE_ROOT"/apps/*; do
		[[ -f "$descriptor/manifest.env" ]] || continue
		id="$(basename "$descriptor")"
		[[ "$(sed -n 's/^PLACEMENT=//p' "$descriptor/manifest.env" | tail -n1)" == consumer ]] || continue
		mode="$(sed -n 's/^UPSTREAM_MODE=//p' "$descriptor/manifest.env" | tail -n1)"
		[[ -z "${PLATFORM_ONLY_APP_ID:-}" || "$id" == "$PLATFORM_ONLY_APP_ID" ]] || continue
		[[ "${DEPLOY_SKIP_SINGLETONS:-0}" != 1 || "$mode" != singleton ]] || continue
		policy_file="$(sed -n 's/^POLICY_FILE=//p' "$descriptor/manifest.env" | tail -n1)"
		[[ "$(sed -n 's/^ENABLED=//p' "$APP_RELEASE_ROOT/config/$policy_file" | tail -n1)" == true ]] || continue
		nodes="$(sed -n 's/^NODES=//p' "$APP_RELEASE_ROOT/config/$policy_file" | tail -n1)"
		csv_contains "$nodes" "$(node_value NODE_ID)" || continue
		APP_ENV="$APP_ENV" PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" PLATFORM_LOCK_HELD=1 \
			"$PLATFORMCTL_SCRIPT" smoke "app:$descriptor" || die "smoke failed: $id"
	done
}

cleanup() {
	local path stamp kept=0 current_target previous_target keep_file old_sha cache
	current_target="$(readlink "$CURRENT" 2>/dev/null || true)"
	previous_target="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	keep_file="${RETAIN_RELEASES_FILE:-$CONTROL_ROOT/retain-releases}"
	# Keep newest releases by filesystem mtime (not by SHA lexical order), and
	# honor explicit pins used by operators while an incident is investigated.
	while IFS= read -r path; do
		stamp="${path%% *}"
		path="${path#* }"
		[[ -d "$path" && "$path" != "$current_target" && "$path" != "$previous_target" ]] || continue
		if [[ -f "$keep_file" ]] && grep -Fxq "$(basename "$path")" "$keep_file"; then continue; fi
		kept=$((kept + 1))
		if ((kept > RETAIN_RELEASES)); then
			old_sha="$(basename "$path")"
			git -C "$SOURCE_MIRROR" worktree remove --force "$path" >/dev/null 2>&1 || true
			for cache in "$VALIDATION_CACHE_ROOT/${old_sha}."*.ok; do
				[[ -f "$cache" ]] || continue
				rm -f -- "$cache"
			done
		fi
	done < <(for path in "$RELEASES"/*; do
		[[ -d "$path" ]] || continue
		stamp="$(stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || printf 0)"
		printf '%s %s\n' "$stamp" "$path"
	done | sort -nr)
}

apply() {
	local sha="$1" mode="${2:-app}" release old_current old_control_current old_previous old_app_previous tx sync_scope foundation_changed=0 foundation_recreate_projects='' cleanup_failed=0 previous_singleton_target singleton_prepare_failed=0
	# Foundation upgrades install shared control logic but never start, stop, or
	# publish singleton consumers. Their dedicated workflow owns that change.
	[[ "$mode" == foundation ]] && DEPLOY_SKIP_SINGLETONS=1
	# Cluster reconciliation owns placement and enablement policy only. It
	# preserves enabled singletons while retiring apps disabled by target policy.
	if [[ "$mode" == cluster-reconcile ]]; then
		DEPLOY_SKIP_SINGLETONS=1
		PLATFORM_RECONCILE_DISABLED_SINGLETONS=1
	fi
	if [[ "$mode" == consumer-stage || "$mode" == consumer-publish || "$mode" == consumer-stop || "$mode" == direct-publish ]]; then
		[[ "${CONSUMER_APP_ID:-}" =~ ^[a-z][a-z0-9-]*$ ]] || die 'consumer workflow requires CONSUMER_APP_ID'
		PLATFORM_ONLY_APP_ID="$CONSUMER_APP_ID"
		if [[ "$mode" == consumer-stage ]]; then
			DEPLOY_SKIP_SINGLETONS=0
			# Compose does not reliably detect changes to inline configs.content.
			# Recreate only the staged app so its committed config is applied.
			DEPLOY_RECREATE_APPS=1
			PLATFORM_ONLY_ROUTE_APP_ID="$CONSUMER_APP_ID"
			DEPLOY_SYNC_SCOPE="app:$CONSUMER_APP_ID"
		else
			DEPLOY_SKIP_SINGLETONS=1
			PLATFORM_PRESERVE_CONSUMER_ROUTES=1
			DEPLOY_SYNC_SCOPE="route:$CONSUMER_APP_ID"
		fi
	fi
	sha_valid "$sha"
	exec 9>"$PLATFORM_LOCK_FILE"
	flock -w 300 9 || die 'timed out waiting for deployment lock'
	log "deployment start: node=$(node_value NODE_ID) role=$(runtime_node_role) mode=$mode sha=$sha workflow=${DEPLOY_WORKFLOW:-unknown} pipeline=${DEPLOY_PIPELINE:-unknown} build=${DEPLOY_BUILD:-unknown}"
	ensure_mirror
	if [[ "$mode" == rollback ]]; then
		git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'rollback target is not retained in the local mirror'
	else
		if [[ "$mode" == consumer-stage || "$mode" == consumer-publish || "$mode" == consumer-stop || "$mode" == direct-publish ]] && control_sync_matches_sha "$sha"; then
			log "reusing control-sync mirror for $sha"
			# Refresh origin even when the immutable control release is already
			# installed so a newer push can supersede this queued stage safely.
			fetch_main || die 'unable to refresh repository for supersession check'
		else
			fetch_main || die 'unable to fetch repository'
		fi
		verify_target "$sha"
	fi
	release="$(prepare_release "$sha")"
	old_control_current="$(readlink "$CURRENT" 2>/dev/null || true)"
	old_current="$(readlink "$APP_CURRENT" 2>/dev/null || true)"
	[[ -z "$old_current" && -n "$old_control_current" ]] && old_current="$old_control_current"
	verify_fast_forward "$old_current" "$sha" "$mode"
	[[ "$mode" == cluster-reconcile ]] && verify_cluster_scope "$old_control_current" "$release"
	if [[ "$mode" != rollback && "$mode" != control-sync && "$mode" != control-verify ]]; then
		if is_superseded "$sha"; then
			log "superseded deployment skipped before mutation: mode=$mode sha=$sha latest=$(git -C "$SOURCE_MIRROR" rev-parse "refs/remotes/origin/$MAIN_BRANCH")"
			return 78
		fi
	fi
	if [[ "$DEPLOY_TEST_SKIP_RELEASE_VALIDATION" == 1 ]]; then
		log 'test mode: skipping candidate release validation (platformctl is mocked)'
	elif [[ "$mode" == consumer-stage || "$mode" == consumer-publish || "$mode" == consumer-stop || "$mode" == direct-publish ]] && control_sync_matches_sha "$sha"; then
		log "reusing Leader-gated control validation for $sha"
	else
		validate_release_cached "$release"
		# The candidate was fully validated before any pointers or containers are
		# changed. Child platformctl sync calls can reuse that attestation and only
		# perform the scoped reconciliation work.
		DEPLOYMENT_VALIDATED=1
	fi
	verify_woodpecker_self_disable "$old_control_current" "$release"
	if [[ "$mode" == foundation ]]; then
		foundation_changed=1
		foundation_recreate_projects="$(changed_foundation_projects "$release")"
		verify_foundation_self_recreate "$foundation_recreate_projects"
	elif [[ "$mode" == rollback ]]; then
		foundation_changed=1
		foundation_recreate_projects="$(changed_foundation_projects "$release" 1)"
	fi
	old_previous="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	old_app_previous="$(readlink "$APP_PREVIOUS" 2>/dev/null || true)"
	[[ "$mode" == app || "$mode" == app-upgrade ]] && verify_app_scope "$old_current" "$release" "$mode"
	verify_consumer_scope "$old_current" "$release" "$mode"
	record_singleton_transitions "$old_current" "$release"
	if [[ "$mode" == consumer-stage && -n "${CONSUMER_APP_ID:-}" && "$(env_value UPSTREAM_MODE "$release/apps/$CONSUMER_APP_ID/manifest.env")" == singleton ]]; then
		previous_singleton_target="$(singleton_previous_target "$old_current" "$CONSUMER_APP_ID")"
	fi
	case "$mode" in
	consumer-publish | consumer-stop | direct-publish)
		# These operations publish/withdraw routes or stop stale containers; they
		# do not mutate persistent release data and therefore do not need a backup.
		log "skipping backup for route/stop-only operation: $mode"
		;;
	*) backup "pre-$mode" ;;
	esac
	if [[ "$mode" != consumer-stage && "$mode" != consumer-publish && "$mode" != consumer-stop && "$mode" != direct-publish ]]; then
		if ! stop_removed_projects "$old_current" "$release"; then
			cleanup_failed=1
		elif [[ "$mode" == foundation || "$mode" == rollback ]] && ! stop_removed_foundation_projects "$old_current" "$release"; then
			cleanup_failed=1
		fi
		if ((cleanup_failed == 1)); then
			log 'removed-project cleanup failed; reconciling the current release'
			DEPLOY_SYNC_SCOPE=all reconcile || true
			return 1
		fi
	fi
	tx="$(mktemp -d "$APP_ROOT/shared/runtime/transaction.XXXXXX")"
	cp -f "$APP_IMAGE_ENV" "$tx/images.apps" 2>/dev/null || true
	cp -f "$FOUNDATION_IMAGE_ENV" "$tx/images.foundation" 2>/dev/null || true
	cp -f "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" "$tx/node.env" 2>/dev/null || true
	[[ -d "$FOUNDATION_ROOT" ]] && cp -a "$FOUNDATION_ROOT" "$tx/foundation"
	[[ -d "$CONTROL_ROOT/descriptors" ]] && cp -a "$CONTROL_ROOT/descriptors" "$tx/descriptors"
	if [[ "$mode" != consumer-stage && "$mode" != consumer-publish && "$mode" != consumer-stop && "$mode" != direct-publish ]]; then
		if [[ "$old_control_current" != "$release" ]]; then
			if [[ -n "$old_control_current" ]]; then atomic_link "$old_control_current" "$PREVIOUS"; fi
			atomic_link "$release" "$CURRENT"
		fi
		sync_node_config "$release" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
		refresh_descriptor_registry "$release"
	fi
	if [[ "$mode" != foundation && "$mode" != consumer-stop && "$old_current" != "$release" ]]; then
		if [[ -n "$old_current" ]]; then atomic_link "$old_current" "$APP_PREVIOUS"; fi
		atomic_link "$release" "$APP_CURRENT"
	fi
	# A newly introduced singleton needs its candidate image keys before
	# singleton-prepare evaluates the Compose project to stop/archive it.
	if [[ "$mode" == app-upgrade ]]; then
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
	elif [[ "$mode" == consumer-stage ]]; then
		install_application_image_lock "$release" "$CONSUMER_APP_ID"
	elif [[ "$mode" == cluster-reconcile ]]; then
		# Reconciliation is also the repair path after an app-scoped operation
		# may have pruned image keys. Restore the complete immutable manifests
		# before prefetching or validating any project.
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
		install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
	fi
	if [[ "$mode" == consumer-stage && "$(env_value UPSTREAM_MODE "$release/apps/$CONSUMER_APP_ID/manifest.env")" == singleton ]]; then
		if ! SINGLETON_PREVIOUS_TARGET="$previous_singleton_target" SINGLETON_RELEASE_SHA="$sha" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-prepare "$CONSUMER_APP_ID"; then
			singleton_prepare_failed=1
		fi
	fi
	# Normal source deployments change application code/config only. Image
	# changes are explicit app-upgrade operations so a routine push cannot
	# silently move production to a new image set.
	if [[ "$mode" == foundation ]]; then
		install_foundation_files "$release"
		install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
	elif [[ "$mode" == rollback ]]; then
		# A rollback restores the complete release contract, including the
		# foundation files and both immutable image manifests.
		install_foundation_files "$release"
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
		install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
	fi
	# Image keys are declarative. Remove entries from an older release (for
	# example a key renamed during an app migration) before prefetching, while
	# retaining all keys still declared by the candidate release.
	prune_stale_image_keys "$APP_IMAGE_ENV"
	prune_stale_image_keys "$FOUNDATION_IMAGE_ENV"
	sync_scope=apps
	[[ "$mode" == foundation ]] && sync_scope=foundation
	[[ "$mode" == cluster-reconcile || "$mode" == rollback ]] && sync_scope=all
	if ((singleton_prepare_failed == 0)) && prefetch_images "$mode" && DEPLOY_RECREATE_FOUNDATION=0 DEPLOY_RECREATE_FOUNDATION_PROJECTS="$foundation_recreate_projects" DEPLOY_SYNC_SCOPE="$sync_scope" reconcile && smoke_apps && {
		[[ "$mode" != consumer-stage ]] ||
			SINGLETON_RELEASE_SHA="$sha" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" consumer-origin-smoke "$CONSUMER_APP_ID"
	}; then
		cleanup
		rm -rf -- "$tx"
		log "deployment succeeded: $sha ($mode)"
		return 0
	fi
	log 'deployment failed; restoring previous complete bundle'
	[[ -n "$old_control_current" ]] && atomic_link "$old_control_current" "$CURRENT" || rm -f -- "$CURRENT"
	[[ -n "$old_current" ]] && atomic_link "$old_current" "$APP_CURRENT" || rm -f -- "$APP_CURRENT"
	[[ -n "$old_previous" ]] && atomic_link "$old_previous" "$PREVIOUS" || rm -f -- "$PREVIOUS"
	[[ -n "$old_app_previous" ]] && atomic_link "$old_app_previous" "$APP_PREVIOUS" || rm -f -- "$APP_PREVIOUS"
	if [[ -f "$tx/images.apps" ]]; then install -m 600 "$tx/images.apps" "$APP_IMAGE_ENV"; else rm -f -- "$APP_IMAGE_ENV"; fi
	if [[ -f "$tx/images.foundation" ]]; then install -m 600 "$tx/images.foundation" "$FOUNDATION_IMAGE_ENV"; fi
	if [[ -f "$tx/node.env" ]]; then install -m 600 "$tx/node.env" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"; else rm -f -- "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"; fi
	if ((foundation_changed)); then
		rm -rf -- "$FOUNDATION_ROOT"
		if [[ -d "$tx/foundation" ]]; then cp -a "$tx/foundation" "$FOUNDATION_ROOT"; else install -d -m 700 "$FOUNDATION_ROOT"; fi
	fi
	rm -rf -- "$CONTROL_ROOT/descriptors"
	[[ -d "$tx/descriptors" ]] && cp -a "$tx/descriptors" "$CONTROL_ROOT/descriptors"
	rm -rf -- "$tx"
	if [[ "$mode" == cluster-reconcile ]]; then
		DEPLOY_SKIP_SINGLETONS=0
		PLATFORM_RECONCILE_DISABLED_SINGLETONS=0
	fi
	DEPLOY_RECREATE_FOUNDATION=0 DEPLOY_RECREATE_FOUNDATION_PROJECTS="$foundation_recreate_projects" DEPLOY_SYNC_SCOPE=all reconcile || true
	if [[ "$mode" == consumer-stage && -n "${CONSUMER_APP_ID:-}" && "$(env_value UPSTREAM_MODE "$release/apps/$CONSUMER_APP_ID/manifest.env")" == singleton ]]; then
		SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-transition-fail "$CONSUMER_APP_ID" || true
	fi
	return 1
}

rollback() {
	local target="${1:-previous}"
	[[ "$target" == previous ]] && target="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	[[ -n "$target" ]] || die 'no rollback target'
	apply "$(basename "$target")" rollback
}

retire_node_release() {
	local sha="$1" release node descriptor_state old_current
	sha_valid "$sha"
	exec 9>"$PLATFORM_LOCK_FILE"
	flock -w 300 9 || die 'timed out waiting for deployment lock'
	node="$(node_value NODE_ID)"
	[[ "$node" != "$(policy_value LEADER_NODE_ID)" ]] || die 'the designated Leader cannot be retired in place'
	log "node retirement start: node=$node sha=$sha"
	ensure_mirror
	fetch_main || die 'unable to fetch repository'
	verify_target "$sha"
	release="$(prepare_release "$sha")"
	descriptor_state="$(env_value NODE_STATE "$release/config/cluster/nodes/$node.env")"
	[[ "$descriptor_state" == retired ]] || die "target release does not mark this node retired: $node/$descriptor_state"
	old_current="$(readlink "$CURRENT" 2>/dev/null || true)"
	verify_fast_forward "$old_current" "$sha" node-retire
	validate_release_cached "$release"
	backup pre-node-retire
	if [[ -n "$old_current" ]]; then
		atomic_link "$old_current" "$PREVIOUS"
		atomic_link "$old_current" "$APP_PREVIOUS"
	fi
	atomic_link "$release" "$CURRENT"
	atomic_link "$release" "$APP_CURRENT"
	sync_node_config "$release" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
	refresh_descriptor_registry "$release"
	log "node retirement release installed: node=$node sha=$sha; deferred shutdown may proceed"
}

case "${1:-}" in
deploy)
	[[ $# -eq 2 ]] || die 'usage: deploy <sha>'
	apply "$2" app
	;;
consumer-stage)
	[[ $# -eq 2 && -n "${CONSUMER_APP_ID:-}" ]] || die 'usage: CONSUMER_APP_ID=<id> deploy-controller consumer-stage <sha>'
	apply "$2" consumer-stage
	;;
consumer-publish)
	[[ $# -eq 2 && -n "${CONSUMER_APP_ID:-}" ]] || die 'usage: CONSUMER_APP_ID=<id> deploy-controller consumer-publish <sha>'
	apply "$2" consumer-publish
	SINGLETON_RELEASE_SHA="$2" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" SINGLETON_ORIGIN_PRECHECKED=1 PLATFORM_DEPLOYMENT_VALIDATED=1 PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" consumer-publish "$CONSUMER_APP_ID"
	;;
direct-publish)
	[[ $# -eq 2 && -n "${CONSUMER_APP_ID:-}" ]] || die 'usage: DIRECT_APP_ID=<id> deploy-controller direct-publish <sha>'
	apply "$2" direct-publish
	[[ "$(env_value ENABLED "$CONTROL_ROOT/current/config/cluster/apps/$CONSUMER_APP_ID.policy")" == true ]] || die "direct publication is disabled by policy: $CONSUMER_APP_ID"
	[[ "$(env_value INGRESS_MODE "$CONTROL_ROOT/current/apps/$CONSUMER_APP_ID/manifest.env")" == direct ]] || die "application is not a direct service: $CONSUMER_APP_ID"
	PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" direct-smoke "$CONSUMER_APP_ID"
	;;
consumer-stop)
	[[ $# -eq 2 && -n "${CONSUMER_APP_ID:-}" ]] || die 'usage: CONSUMER_APP_ID=<id> deploy-controller consumer-stop <sha>'
	apply "$2" consumer-stop
	SINGLETON_RELEASE_SHA="$2" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_DEPLOYMENT_VALIDATED=1 PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" consumer-stop "$CONSUMER_APP_ID"
	;;
foundation-upgrade)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller foundation-upgrade <sha>'
	apply "$2" foundation
	;;
cluster-reconcile)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller cluster-reconcile <sha>'
	apply "$2" cluster-reconcile
	;;
app-upgrade)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller app-upgrade <sha>'
	apply "$2" app-upgrade
	;;
node-retire)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller node-retire <sha>'
	retire_node_release "$2"
	;;
control-sync)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller control-sync <sha>'
	apply_control_sync "$2"
	;;
control-verify)
	[[ $# -eq 2 ]] || die 'usage: deploy-controller control-verify <sha>'
	apply_control_verify "$2"
	;;
rollback) rollback "${2:-previous}" ;;
status) printf 'control_current=%s\ncontrol_previous=%s\nservice_current=%s\nservice_previous=%s\ncontrol_sync_state=%s\n' "$(readlink "$CURRENT" 2>/dev/null || true)" "$(readlink "$PREVIOUS" 2>/dev/null || true)" "$(readlink "$APP_CURRENT" 2>/dev/null || true)" "$(readlink "$APP_PREVIOUS" 2>/dev/null || true)" "$(tr '\n' ' ' <"$CONTROL_SYNC_STATE_FILE" 2>/dev/null | cut -c1-240)" ;;
*) die 'usage: deploy-controller {deploy|control-sync|consumer-stage|consumer-publish|consumer-stop|foundation-upgrade|cluster-reconcile|app-upgrade|node-retire|rollback|status} <sha>' ;;
esac
