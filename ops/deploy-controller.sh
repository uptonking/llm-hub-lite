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

env_value() {
	local key="$1" file="${2:-$APP_ENV}"
	[[ -f "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
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
	local foundations disabled
	[[ "$1" == caddy ]] && return 0
	if [[ "$(runtime_node_role)" == leader ]]; then
		foundations="$(policy_value FOUNDATION_LEADER)"
	else
		foundations="$(policy_value FOUNDATION_FOLLOWER)"
	fi
	disabled="$(policy_value DISABLED_FOUNDATION)"
	csv_contains "$foundations" "$1" && ! csv_contains "$disabled" "$1"
}
app_enabled_for_image() {
	local id="$1"
	[[ "$(runtime_node_role)" == follower ]] || return 1
	! csv_contains "$(policy_value DISABLED_APPS)" "$id"
}
image_required() {
	case "$1" in
	CADDY_IMAGE) return 0 ;;
	WOODPECKER_SERVER_IMAGE) foundation_enabled woodpecker-controller ;;
	WOODPECKER_AGENT_IMAGE) foundation_enabled woodpecker-worker || foundation_enabled woodpecker-deployer ;;
	BESZEL_HUB_IMAGE) foundation_enabled beszel-controller ;;
	BESZEL_AGENT_IMAGE | BESZEL_SOCKET_PROXY_IMAGE) foundation_enabled beszel-worker ;;
	NEW_API_IMAGE) app_enabled_for_image newapi ;;
	CLIPROXY_IMAGE) app_enabled_for_image cliproxyapi ;;
	LIBRECHAT_API_IMAGE | LIBRECHAT_ADMIN_IMAGE | LIBRECHAT_CLIENT_IMAGE) app_enabled_for_image librechat ;;
	*) return 0 ;;
	esac
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
trap cleanup_github_https_auth EXIT

SOURCE_MIRROR="$CONTROL_ROOT/mirror.git"
RELEASES="$CONTROL_ROOT/releases"
CURRENT="$CONTROL_ROOT/current"
PREVIOUS="$CONTROL_ROOT/previous"
APP_CURRENT="$APP_ROOT/current"
APP_PREVIOUS="$APP_ROOT/previous"

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
	rm -f -- "$link"
	mv -- "$tmp" "$link"
}

mkdir -p "$APP_ROOT/shared/logs" "$RELEASES" "$(dirname "$PLATFORM_LOCK_FILE")"
exec > >(tee -a "$DEPLOY_LOG") 2>&1

ensure_mirror() {
	if [[ ! -d "$SOURCE_MIRROR" ]]; then git init --bare "$SOURCE_MIRROR" >/dev/null; fi
	if git -C "$SOURCE_MIRROR" remote get-url origin >/dev/null 2>&1; then
		git -C "$SOURCE_MIRROR" remote set-url origin "$(git_remote_url)"
	else
		git -C "$SOURCE_MIRROR" remote add origin "$(git_remote_url)"
	fi
}

fetch_main() {
	local attempt
	for attempt in 1 2 3 4 5; do
		if git -C "$SOURCE_MIRROR" fetch --prune origin "+refs/heads/$MAIN_BRANCH:refs/remotes/origin/$MAIN_BRANCH"; then return 0; fi
		log "git fetch retry $attempt"
		sleep 5
	done
	return 1
}

verify_target() {
	local sha="$1"
	git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'target is not in mirror'
	git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$sha" "refs/remotes/origin/$MAIN_BRANCH" || die 'target is not reachable from main'
}

verify_app_scope() {
	local old_release="$1" new_release="$2" mode="${3:-app}" old_sha new_sha path
	[[ -n "$old_release" ]] || return 0
	old_sha="$(basename "$old_release")"
	new_sha="$(basename "$new_release")"
	while IFS= read -r path; do
		case "$path" in
		apps/* | config/** | .woodpecker/** | README.md | LICENSE.md | ops/generate-woodpecker-workflows.sh) ;;
		ops/images.apps.prod.env) ;;
		*) die "application deployment contains foundation/control-plane change: $path; use the reviewed foundation workflow" ;;
		esac
		[[ "$path" != config/cluster/* ]] || die "cluster policy or inventory change requires the cluster-reconcile workflow: $path"
		if [[ "$path" == ops/images.apps.prod.env && "$mode" != app && "$mode" != app-upgrade ]]; then
			die "unsupported image manifest change in $mode deployment: $path"
		fi
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

prepare_release() {
	local sha="$1" release="$RELEASES/$sha"
	if [[ ! -e "$release" ]]; then git -C "$SOURCE_MIRROR" worktree add --detach "$release" "$sha" >/dev/null; fi
	printf '%s\n' "$release"
}

validate_release() {
	local release="$1" runtime foundation_validate control_validate image_apps image_foundation
	[[ -f "$release/ops/platformctl.sh" && -d "$release/apps" && -d "$release/config" ]] || die 'release is missing platform files'
	install -d -m 700 "$APP_ROOT/shared/runtime"
	runtime="$(mktemp -d "$APP_ROOT/shared/runtime/validate.XXXXXX")"
	foundation_validate="$(mktemp -d "$APP_ROOT/shared/runtime/foundation-validate.XXXXXX")"
	control_validate="$(mktemp -d "$APP_ROOT/shared/runtime/control-validate.XXXXXX")"
	image_apps="$control_validate/images.apps.env"
	image_foundation="$control_validate/images.foundation.env"
	ln -s "$release" "$control_validate/current"
	install -m 600 "$release/ops/images.apps.prod.env" "$image_apps"
	install -m 600 "$release/ops/images.foundation.prod.env" "$image_foundation"
	install -d -m 700 "$foundation_validate/env"
	cp -a "$FOUNDATION_ROOT/env/." "$foundation_validate/env/" 2>/dev/null || true
	install -d -m 700 "$control_validate/config/cluster/nodes"
	cp -a "$release/config/cluster/." "$control_validate/config/cluster/"
	install -m 600 "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" "$control_validate/node.env" 2>/dev/null || true
	install -m 600 "$release/compose/foundation/caddy.yml" "$foundation_validate/caddy.yml"
	for file in woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml; do
		install -m 600 "$release/compose/foundation/$file" "$foundation_validate/$file"
	done
	if ! CONTROL_ROOT="$control_validate" APPS_ROOT="$release/apps" RUNTIME_ROOT="$runtime" \
		APP_ENV="$APP_ENV" APP_IMAGE_ENV="$image_apps" FOUNDATION_IMAGE_ENV="$image_foundation" \
		FOUNDATION_ROOT="$foundation_validate" FOUNDATION_ENV_ROOT="$foundation_validate/env" NODE_CONFIG_FILE="$control_validate/node.env" CLUSTER_POLICY_FILE="$control_validate/config/cluster/policy.env" \
		PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
		"$release/ops/platformctl.sh" validate --check; then
		rm -rf -- "$runtime" "$foundation_validate" "$control_validate"
		return 1
	fi
	rm -rf -- "$runtime" "$foundation_validate" "$control_validate"
}

pull_image() {
	local image="$1" attempt
	for attempt in 1 2 3 4 5; do
		if docker pull "$image" >/dev/null; then
			return 0
		fi
		((attempt < 5)) || die "unable to pull image after $attempt attempts: $image"
		log "image pull failed; retrying in $((attempt * 5)) seconds (attempt $attempt/5): $image"
		sleep "$((attempt * 5))"
	done
}

backup() {
	[[ -x "$BACKUP_SCRIPT" ]] || die "backup script is not executable: $BACKUP_SCRIPT"
	log 'Creating verified pre-change snapshot'
	PLATFORM_LOCK_HELD=1 "$BACKUP_SCRIPT" snapshot "${1:-pre-deploy}" || die 'verified backup failed'
}

merge_new_app_image_keys() {
	local release="$1" key value
	[[ -f "$APP_IMAGE_ENV" ]] || : >"$APP_IMAGE_ENV"
	while IFS='=' read -r key value; do
		[[ -n "$key" && "$key" != \#* ]] || continue
		if ! grep -q "^${key}=" "$APP_IMAGE_ENV"; then
			printf '%s=%s\n' "$key" "$value" >>"$APP_IMAGE_ENV"
		fi
	done <"$release/ops/images.apps.prod.env"
	chmod 600 "$APP_IMAGE_ENV"
}

install_foundation_files() {
	local release="$1"
	install -d -m 700 "$FOUNDATION_ROOT/env"
	install -m 600 "$release/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
	for file in woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml; do
		install -m 600 "$release/compose/foundation/$file" "$FOUNDATION_ROOT/$file"
	done
}

refresh_descriptor_registry() {
	local release="$1" descriptor id registry="$CONTROL_ROOT/descriptors"
	install -d -m 700 "$registry"
	for descriptor in "$release"/apps/*; do
		[[ -f "$descriptor/manifest.env" ]] || continue
		id="$(basename "$descriptor")"
		install -d -m 700 "$registry/$id"
		install -m 600 "$descriptor/manifest.env" "$registry/$id/manifest.env"
	done
}

prefetch_images() {
	local mode="$1" file key image should_pull
	local -a files=()
	case "$mode" in
	app | app-upgrade) files=("$APP_IMAGE_ENV") ;;
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
			if [[ "$mode" == app-upgrade || "$mode" == foundation ]]; then
				should_pull=1
			elif ! docker image inspect "$image" >/dev/null 2>&1; then
				should_pull=1
			fi
			if ((should_pull == 1)); then pull_image "$image"; fi
		done <"$file"
	done
}

reconcile() {
	CONTROL_ROOT="$CONTROL_ROOT" APPS_ROOT="$CONTROL_ROOT/current/apps" FOUNDATION_ROOT="$FOUNDATION_ROOT" \
		APP_ENV="$APP_ENV" APP_IMAGE_ENV="$APP_IMAGE_ENV" FOUNDATION_IMAGE_ENV="$FOUNDATION_IMAGE_ENV" \
		FOUNDATION_ENV_ROOT="$FOUNDATION_ROOT/env" RUNTIME_ROOT="$APP_ROOT/shared/runtime" \
		NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" \
		CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}" \
		PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
		"$PLATFORMCTL_SCRIPT" sync "${DEPLOY_SYNC_SCOPE:-apps}"
}

smoke_apps() {
	local descriptor id placement disabled
	disabled="$(sed -n 's/^DISABLED_APPS=//p' "$CONTROL_ROOT/current/config/cluster/policy.env" | tail -n1)"
	for descriptor in "$CONTROL_ROOT/current"/apps/*; do
		[[ -f "$descriptor/manifest.env" ]] || continue
		id="$(basename "$descriptor")"
		placement="$(sed -n 's/^PLACEMENT=//p' "$descriptor/manifest.env" | tail -n1)"
		[[ "$placement" == follower ]] || continue
		[[ ",${disabled//[[:space:]]/}," == *",$id,"* ]] && continue
		APP_ENV="$APP_ENV" PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
			"$PLATFORMCTL_SCRIPT" smoke "app:$descriptor" || die "smoke failed: $id"
	done
}

cleanup() {
	local path stamp kept=0 current_target previous_target keep_file
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
			git -C "$SOURCE_MIRROR" worktree remove --force "$path" >/dev/null 2>&1 || true
		fi
	done < <(for path in "$RELEASES"/*; do
		[[ -d "$path" ]] || continue
		stamp="$(stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || printf 0)"
		printf '%s %s\n' "$stamp" "$path"
	done | sort -nr)
}

apply() {
	local sha="$1" mode="${2:-app}" release old_current old_previous old_app_previous tx sync_scope foundation_changed=0
	sha_valid "$sha"
	exec 9>"$PLATFORM_LOCK_FILE"
	flock -w 300 9 || die 'timed out waiting for deployment lock'
	ensure_mirror
	if [[ "$mode" == rollback ]]; then
		git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'rollback target is not retained in the local mirror'
	else
		fetch_main || die 'unable to fetch repository'
		verify_target "$sha"
	fi
	release="$(prepare_release "$sha")"
	validate_release "$release"
	old_current="$(readlink "$CURRENT" 2>/dev/null || true)"
	old_previous="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	old_app_previous="$(readlink "$APP_PREVIOUS" 2>/dev/null || true)"
	[[ "$mode" == app || "$mode" == app-upgrade ]] && verify_app_scope "$old_current" "$release" "$mode"
	backup "pre-$mode"
	tx="$(mktemp -d "$APP_ROOT/shared/runtime/transaction.XXXXXX")"
	cp -f "$APP_IMAGE_ENV" "$tx/images.apps" 2>/dev/null || true
	cp -f "$FOUNDATION_IMAGE_ENV" "$tx/images.foundation" 2>/dev/null || true
	for file in caddy.yml woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml; do cp -f "$FOUNDATION_ROOT/$file" "$tx/$file" 2>/dev/null || true; done
	[[ -d "$CONTROL_ROOT/descriptors" ]] && cp -a "$CONTROL_ROOT/descriptors" "$tx/descriptors"
	if [[ -n "$old_current" ]]; then
		atomic_link "$old_current" "$PREVIOUS"
		atomic_link "$old_current" "$APP_PREVIOUS"
	fi
	atomic_link "$release" "$CURRENT"
	atomic_link "$release" "$APP_CURRENT"
	refresh_descriptor_registry "$release"
	# Normal source deployments change application code/config only. Image
	# changes are explicit app-upgrade operations so a routine push cannot
	# silently move production to a new image set.
	if [[ "$mode" == app-upgrade ]]; then
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
	elif [[ "$mode" == app ]]; then
		merge_new_app_image_keys "$release"
	fi
	if [[ "$mode" == foundation || "$mode" == cluster-reconcile ]]; then
		foundation_changed=1
		install_foundation_files "$release"
		install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
	elif [[ "$mode" == rollback ]]; then
		# A rollback restores the complete release contract, including the
		# foundation files and both immutable image manifests.
		foundation_changed=1
		install_foundation_files "$release"
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
		install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
	fi
	sync_scope=apps
	[[ "$mode" == foundation ]] && sync_scope=foundation
	[[ "$mode" == cluster-reconcile || "$mode" == rollback ]] && sync_scope=all
	if prefetch_images "$mode" && DEPLOY_SYNC_SCOPE="$sync_scope" reconcile && smoke_apps; then
		cleanup
		rm -rf -- "$tx"
		log "deployment succeeded: $sha ($mode)"
		return 0
	fi
	log 'deployment failed; restoring previous complete bundle'
	[[ -n "$old_current" ]] && {
		atomic_link "$old_current" "$CURRENT"
		atomic_link "$old_current" "$APP_CURRENT"
	} || { rm -f -- "$CURRENT" "$APP_CURRENT"; }
	[[ -n "$old_previous" ]] && atomic_link "$old_previous" "$PREVIOUS" || rm -f -- "$PREVIOUS"
	[[ -n "$old_app_previous" ]] && atomic_link "$old_app_previous" "$APP_PREVIOUS" || rm -f -- "$APP_PREVIOUS"
	if [[ -f "$tx/images.apps" ]]; then install -m 600 "$tx/images.apps" "$APP_IMAGE_ENV"; else rm -f -- "$APP_IMAGE_ENV"; fi
	if [[ -f "$tx/images.foundation" ]]; then install -m 600 "$tx/images.foundation" "$FOUNDATION_IMAGE_ENV"; fi
	if ((foundation_changed)); then
		for file in caddy.yml woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml; do
			[[ -f "$tx/$file" ]] && install -m 600 "$tx/$file" "$FOUNDATION_ROOT/$file"
		done
	fi
	rm -rf -- "$CONTROL_ROOT/descriptors"
	[[ -d "$tx/descriptors" ]] && cp -a "$tx/descriptors" "$CONTROL_ROOT/descriptors"
	rm -rf -- "$tx"
	DEPLOY_SYNC_SCOPE=all reconcile || true
	return 1
}

rollback() {
	local target="${1:-previous}"
	[[ "$target" == previous ]] && target="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	[[ -n "$target" ]] || die 'no rollback target'
	apply "$(basename "$target")" rollback
}

case "${1:-}" in
deploy)
	[[ $# -eq 2 ]] || die 'usage: deploy <sha>'
	apply "$2" app
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
rollback) rollback "${2:-previous}" ;;
status) printf 'current=%s\nprevious=%s\n' "$(readlink "$CURRENT" 2>/dev/null || true)" "$(readlink "$PREVIOUS" 2>/dev/null || true)" ;;
*) die 'usage: deploy-controller {deploy|foundation-upgrade|cluster-reconcile|app-upgrade|rollback|status} <sha>' ;;
esac
