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
: "${SINGLETON_STATE_ROOT:=$CONFIG_ROOT/singleton-state}"
# Production defaults retain the existing retry backoff. Tests and operators
# may set these to zero to avoid waiting after a mocked/transient failure.
: "${DEPLOY_FETCH_RETRY_DELAY_SECONDS:=5}"
: "${DEPLOY_PULL_RETRY_BASE_DELAY_SECONDS:=5}"

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
	local id="$1" d placement target_key target
	[[ "$(runtime_node_role)" == follower ]] || return 1
	d="$CONTROL_ROOT/current/apps/$id"
	[[ -f "$d/manifest.env" ]] || return 1
	[[ "$(sed -n 's/^ENABLED=//p' "$(sed -n 's/^POLICY_FILE=//p' "$d/manifest.env" | tail -n1 | sed "s#^#$CONTROL_ROOT/current/config/#")" | tail -n1)" != false ]] || return 1
	placement="$(sed -n 's/^PLACEMENT=//p' "$d/manifest.env" | tail -n1)"
	if [[ "$placement" == single-follower ]]; then
		target_key="$(sed -n 's/^TARGET_NODE_KEY=//p' "$d/manifest.env" | tail -n1)"
		target="$(sed -n "s/^$target_key=//p" "$(sed -n 's/^POLICY_FILE=//p' "$d/manifest.env" | tail -n1 | sed "s#^#$CONTROL_ROOT/current/config/#")" | tail -n1)"
		[[ "$target" == "$(node_value NODE_ID)" ]]
	fi
}
image_required() {
	local key="$1" descriptor image_key app_id
	case "$key" in
	CADDY_IMAGE) return 0 ;;
	WOODPECKER_SERVER_IMAGE) foundation_enabled woodpecker-controller ;;
	WOODPECKER_AGENT_IMAGE) foundation_enabled woodpecker-worker || foundation_enabled woodpecker-deployer ;;
	BESZEL_HUB_IMAGE) foundation_enabled beszel-controller ;;
	BESZEL_AGENT_IMAGE | BESZEL_SOCKET_PROXY_IMAGE) foundation_enabled beszel-worker ;;
	OBSERVER_IMAGE) foundation_enabled observer-controller ;;
	OBSERVER_HEALTH_PROBE_IMAGE) foundation_enabled observer-controller || foundation_enabled observer-collector ;;
	OBSERVER_LOG_PROXY_IMAGE | OBSERVER_LOG_SHIPPER_IMAGE) foundation_enabled observer-collector ;;
	NEW_API_IMAGE) app_enabled_for_image newapi ;;
	LIBRECHAT_API_IMAGE | LIBRECHAT_ADMIN_IMAGE | LIBRECHAT_CLIENT_IMAGE) app_enabled_for_image librechat ;;
	*)
		while IFS= read -r descriptor; do
			while IFS= read -r image_key; do
				[[ "$image_key" == "$key" ]] || continue
				app_id="$(sed -n 's/^APP_ID=//p' "$descriptor" | tail -n1)"
				app_enabled_for_image "$app_id"
				return
			done < <(sed -n 's/^IMAGE_KEYS=//p' "$descriptor" | tail -n1 | tr ' ' '\n')
		done < <(find "$CONTROL_ROOT/current/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
		return 1
		;;
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
sync_node_config() {
	local release="$1" destination="$2" runtime_source id source tmp key value
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
	for key in LEADER_PUBLIC_IP; do
		value="$(env_value "$key" "$runtime_source")"
		[[ -n "$value" ]] && printf '%s=%s\n' "$key" "$value" >>"$tmp"
	done
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$destination"
}

mkdir -p "$APP_ROOT/shared/logs" "$RELEASES" "$(dirname "$PLATFORM_LOCK_FILE")"
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
		compose/foundation/** | ops/images.foundation.prod.env | ops/foundation/** | ops/systemd/** | ops/*.sh | ops/deploy-runner/** | ops/tests/**)
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
		config/cluster/policy.env | config/cluster/nodes/*)
			[[ "$mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop ]] || {
				scope_failure "$old_sha" "$new_sha" "$mode"
				die "cluster policy or inventory change requires the cluster-reconcile workflow: $path"
			}
			;;
		config/cluster/apps/*)
			[[ "$mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop ]] || {
				scope_failure "$old_sha" "$new_sha" "$mode"
				die "cluster app policy requires its dedicated reconciliation workflow: $path"
			}
			;;
		config/cluster/*)
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "unsupported cluster configuration path in application deployment: $path"
			;;
		esac
		if [[ "$path" == ops/images.apps.prod.env && "$mode" != app-upgrade && "$mode" != singleton-stage && "$mode" != singleton-switch && "$mode" != singleton-stop ]]; then
			scope_failure "$old_sha" "$new_sha" "$mode"
			die "application image manifest changes require the app-upgrade or singleton workflow: $path"
		fi
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

verify_cluster_scope() {
	local old_release="$1" new_release="$2" old_sha new_sha path app manifest policy
	[[ -n "$old_release" ]] || return 0
	old_sha="$(basename "$old_release")"
	new_sha="$(basename "$new_release")"
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
			if [[ "$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)" == single-follower && "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" != false ]]; then
				scope_failure "$old_sha" "$new_sha" cluster-reconcile
				die "cluster reconciliation cannot own an enabled singleton policy: $path; use its dedicated stage/switch/stop workflow"
			fi
			;;
		config/cluster/policy.env | config/cluster/nodes/* | .woodpecker/** | README.md | AGENTS.md) ;;
		*)
			scope_failure "$old_sha" "$new_sha" cluster-reconcile
			die "cluster reconciliation contains a non-cluster change: $path; run the reviewed foundation workflow first"
			;;
		esac
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$old_sha" "$new_sha")
}

verify_singleton_scope() {
	local old_release="$1" new_release="$2" mode="$3" app="${SINGLETON_APP_ID:-}" path
	[[ "$mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop ]] || return 0
	[[ -n "$app" ]] || die 'singleton deployment is missing SINGLETON_APP_ID'
	[[ -f "$new_release/apps/$app/manifest.env" ]] || die "singleton application is not present in target release: $app"
	# There is no previous release to diff during the first deployment. The
	# target manifest check above is sufficient; every file is new by definition.
	[[ -n "$old_release" ]] || return 0
	while IFS= read -r path; do
		case "$path" in
		apps/$app/** | config/cluster/apps/$app.policy | ops/images.apps.prod.env | .env.prod.example | .env.dev.example | \
			.woodpecker/singleton-stage-$app.yml | .woodpecker/singleton-switch-$app.yml | .woodpecker/singleton-stop-$app-*.yml) ;;
		*)
			log "singleton scope rejected: app=$app mode=$mode path=$path"
			die "singleton workflow for $app cannot apply unrelated path: $path"
			;;
		esac
	done < <(git -C "$SOURCE_MIRROR" diff --name-only "$(basename "$old_release")" "$(basename "$new_release")")
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
	local release="$1" app="$2" manifest policy_rel target_key
	[[ -n "$release" && -f "$release/apps/$app/manifest.env" ]] || return 0
	manifest="$release/apps/$app/manifest.env"
	policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"
	target_key="$(sed -n 's/^TARGET_NODE_KEY=//p' "$manifest" | tail -n1)"
	sed -n "s/^$target_key=//p" "$release/config/$policy_rel" 2>/dev/null | tail -n1
}
record_singleton_transitions() {
	local old_release="$1" new_release="$2" manifest app old_target new_target state_file tmp
	[[ -n "$old_release" && -d "$new_release/apps" ]] || return 0
	while IFS= read -r manifest; do
		[[ "$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)" == single-follower ]] || continue
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
stop_removed_projects() {
	local old_release="$1" new_release="$2" manifest app project id
	[[ -n "$old_release" && -d "$old_release/apps" ]] || return 0
	while IFS= read -r manifest; do
		app="$(basename "$(dirname "$manifest")")"
		[[ -f "$new_release/apps/$app/manifest.env" ]] && continue
		project="$(sed -n 's/^COMPOSE_PROJECT=//p' "$manifest" | tail -n1)"
		[[ "$project" =~ ^app-[a-z0-9-]+$ ]] || continue
		while IFS= read -r id; do
			[[ -n "$id" ]] || continue
			log "stopping removed application project $project"
			docker rm -f "$id" >/dev/null 2>&1 || die "unable to stop removed application project: $project"
		done < <(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
	done < <(find "$old_release/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
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
	sync_node_config "$release" "$control_validate/node.env"
	install -m 600 "$release/compose/foundation/caddy.yml" "$foundation_validate/caddy.yml"
	for file in woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml observer-controller.yml observer-collector.yml observer-vector.toml observer-log-proxy-entrypoint.sh; do
		install -m 600 "$release/compose/foundation/$file" "$foundation_validate/$file"
	done
	if ! PLATFORM_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" CONTROL_ROOT="$control_validate" APPS_ROOT="$release/apps" RUNTIME_ROOT="$runtime" \
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
	[[ -x "$BACKUP_SCRIPT" ]] || die "backup script is not executable: $BACKUP_SCRIPT"
	log 'Creating verified pre-change snapshot'
	PLATFORM_LOCK_HELD=1 "$BACKUP_SCRIPT" snapshot "${1:-pre-deploy}" || die 'verified backup failed'
}

install_foundation_files() {
	local release="$1"
	install -d -m 700 "$FOUNDATION_ROOT/env"
	install -m 600 "$release/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
	for file in woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml observer-controller.yml observer-collector.yml observer-vector.toml observer-log-proxy-entrypoint.sh; do
		install -m 600 "$release/compose/foundation/$file" "$FOUNDATION_ROOT/$file"
	done
}

refresh_descriptor_registry() {
	local release="$1" descriptor id registry="$CONTROL_ROOT/descriptors" old
	install -d -m 700 "$registry"
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

prefetch_images() {
	local mode="$1" file key image should_pull
	local -a files=()
	case "$mode" in
	app | app-upgrade | singleton-stage | singleton-switch | singleton-stop) files=("$APP_IMAGE_ENV") ;;
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
	PLATFORM_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" CONTROL_ROOT="$CONTROL_ROOT" APPS_ROOT="$CONTROL_ROOT/current/apps" FOUNDATION_ROOT="$FOUNDATION_ROOT" \
		APP_ENV="$APP_ENV" APP_IMAGE_ENV="$APP_IMAGE_ENV" FOUNDATION_IMAGE_ENV="$FOUNDATION_IMAGE_ENV" \
		FOUNDATION_ENV_ROOT="$FOUNDATION_ROOT/env" RUNTIME_ROOT="$APP_ROOT/shared/runtime" \
		NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" \
		CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}" \
		PLATFORM_ONLY_APP_ID="${PLATFORM_ONLY_APP_ID:-}" \
		PLATFORM_RECONCILE_DISABLED_SINGLETONS="${PLATFORM_RECONCILE_DISABLED_SINGLETONS:-0}" \
		PLATFORM_RECREATE_FOUNDATION="${DEPLOY_RECREATE_FOUNDATION:-0}" \
		PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
		PLATFORM_LOCK_HELD=1 \
		"$PLATFORMCTL_SCRIPT" sync "${DEPLOY_SYNC_SCOPE:-apps}"
}

smoke_apps() {
	local descriptor id placement policy_file
	for descriptor in "$CONTROL_ROOT/current"/apps/*; do
		[[ -f "$descriptor/manifest.env" ]] || continue
		id="$(basename "$descriptor")"
		placement="$(sed -n 's/^PLACEMENT=//p' "$descriptor/manifest.env" | tail -n1)"
		[[ "$placement" == follower || "$placement" == single-follower ]] || continue
		[[ -z "${PLATFORM_ONLY_APP_ID:-}" || "$id" == "$PLATFORM_ONLY_APP_ID" ]] || continue
		[[ "${DEPLOY_SKIP_SINGLETONS:-0}" != 1 || "$placement" != single-follower ]] || continue
		policy_file="$(sed -n 's/^POLICY_FILE=//p' "$descriptor/manifest.env" | tail -n1)"
		[[ "$(sed -n 's/^ENABLED=//p' "$CONTROL_ROOT/current/config/$policy_file" | tail -n1)" != false ]] || continue
		APP_ENV="$APP_ENV" PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" PLATFORM_LOCK_HELD=1 \
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
	local sha="$1" mode="${2:-app}" release old_current old_previous old_app_previous tx sync_scope foundation_changed=0 previous_singleton_target singleton_prepare_failed=0
	# Foundation upgrades install shared control logic but never start, stop, or
	# publish singleton consumers. Their dedicated workflow owns that change.
	[[ "$mode" == foundation ]] && DEPLOY_SKIP_SINGLETONS=1
	# Cluster reconciliation owns placement and enablement policy only. It
	# preserves enabled singletons while retiring apps disabled by target policy.
	if [[ "$mode" == cluster-reconcile ]]; then
		DEPLOY_SKIP_SINGLETONS=1
		PLATFORM_RECONCILE_DISABLED_SINGLETONS=1
	fi
	sha_valid "$sha"
	exec 9>"$PLATFORM_LOCK_FILE"
	flock -w 300 9 || die 'timed out waiting for deployment lock'
	log "deployment start: node=$(node_value NODE_ID) role=$(runtime_node_role) mode=$mode sha=$sha workflow=${DEPLOY_WORKFLOW:-unknown} pipeline=${DEPLOY_PIPELINE:-unknown} build=${DEPLOY_BUILD:-unknown}"
	ensure_mirror
	if [[ "$mode" == rollback ]]; then
		git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'rollback target is not retained in the local mirror'
	else
		fetch_main || die 'unable to fetch repository'
		verify_target "$sha"
	fi
	release="$(prepare_release "$sha")"
	old_current="$(readlink "$CURRENT" 2>/dev/null || true)"
	verify_fast_forward "$old_current" "$sha" "$mode"
	[[ "$mode" == cluster-reconcile ]] && verify_cluster_scope "$old_current" "$release"
	validate_release "$release"
	old_previous="$(readlink "$PREVIOUS" 2>/dev/null || true)"
	old_app_previous="$(readlink "$APP_PREVIOUS" 2>/dev/null || true)"
	[[ "$mode" == app || "$mode" == app-upgrade || "$mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop ]] && verify_app_scope "$old_current" "$release" "$mode"
	verify_singleton_scope "$old_current" "$release" "$mode"
	record_singleton_transitions "$old_current" "$release"
	if [[ "$mode" == singleton-stage && -n "${SINGLETON_APP_ID:-}" ]]; then
		previous_singleton_target="$(singleton_previous_target "$old_current" "$SINGLETON_APP_ID")"
	fi
	backup "pre-$mode"
	stop_removed_projects "$old_current" "$release"
	tx="$(mktemp -d "$APP_ROOT/shared/runtime/transaction.XXXXXX")"
	cp -f "$APP_IMAGE_ENV" "$tx/images.apps" 2>/dev/null || true
	cp -f "$FOUNDATION_IMAGE_ENV" "$tx/images.foundation" 2>/dev/null || true
	cp -f "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}" "$tx/node.env" 2>/dev/null || true
	for file in caddy.yml woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml observer-controller.yml observer-collector.yml observer-vector.toml observer-log-proxy-entrypoint.sh; do cp -f "$FOUNDATION_ROOT/$file" "$tx/$file" 2>/dev/null || true; done
	[[ -d "$CONTROL_ROOT/descriptors" ]] && cp -a "$CONTROL_ROOT/descriptors" "$tx/descriptors"
	if [[ -n "$old_current" ]]; then
		atomic_link "$old_current" "$PREVIOUS"
		atomic_link "$old_current" "$APP_PREVIOUS"
	fi
	atomic_link "$release" "$CURRENT"
	atomic_link "$release" "$APP_CURRENT"
	sync_node_config "$release" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
	refresh_descriptor_registry "$release"
	# A newly introduced singleton needs its candidate image keys before
	# singleton-prepare evaluates the Compose project to stop/archive it.
	if [[ "$mode" == app-upgrade || "$mode" == singleton-stage || "$mode" == singleton-switch || "$mode" == singleton-stop ]]; then
		install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
	fi
	if [[ "$mode" == singleton-stage && -n "${SINGLETON_APP_ID:-}" ]]; then
		if ! SINGLETON_PREVIOUS_TARGET="$previous_singleton_target" SINGLETON_RELEASE_SHA="$sha" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-prepare "$SINGLETON_APP_ID"; then
			singleton_prepare_failed=1
		fi
	fi
	# Normal source deployments change application code/config only. Image
	# changes are explicit app-upgrade operations so a routine push cannot
	# silently move production to a new image set.
	if [[ "$mode" == foundation ]]; then
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
	if ((singleton_prepare_failed == 0)) && prefetch_images "$mode" && DEPLOY_RECREATE_FOUNDATION="$foundation_changed" DEPLOY_SYNC_SCOPE="$sync_scope" reconcile && smoke_apps && {
		[[ "$mode" != singleton-stage || -z "${SINGLETON_APP_ID:-}" ]] ||
			SINGLETON_RELEASE_SHA="$sha" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-origin-smoke "$SINGLETON_APP_ID"
	}; then
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
	if [[ -f "$tx/node.env" ]]; then install -m 600 "$tx/node.env" "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"; else rm -f -- "${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"; fi
	if ((foundation_changed)); then
		for file in caddy.yml woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml observer-controller.yml observer-collector.yml observer-vector.toml observer-log-proxy-entrypoint.sh; do
			if [[ -f "$tx/$file" ]]; then
				install -m 600 "$tx/$file" "$FOUNDATION_ROOT/$file"
			else
				rm -f -- "$FOUNDATION_ROOT/$file"
			fi
		done
	fi
	rm -rf -- "$CONTROL_ROOT/descriptors"
	[[ -d "$tx/descriptors" ]] && cp -a "$tx/descriptors" "$CONTROL_ROOT/descriptors"
	rm -rf -- "$tx"
	if [[ "$mode" == cluster-reconcile ]]; then
		DEPLOY_SKIP_SINGLETONS=0
		PLATFORM_RECONCILE_DISABLED_SINGLETONS=0
	fi
	DEPLOY_RECREATE_FOUNDATION="$foundation_changed" DEPLOY_SYNC_SCOPE=all reconcile || true
	if [[ "$mode" == singleton-stage && -n "${SINGLETON_APP_ID:-}" ]]; then
		SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-transition-fail "$SINGLETON_APP_ID" || true
	fi
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
singleton-stage)
	[[ $# -eq 2 && -n "${SINGLETON_APP_ID:-}" ]] || die 'usage: deploy-controller singleton-stage <sha>'
	DEPLOY_SKIP_SINGLETONS=0 apply "$2" singleton-stage
	;;
singleton-switch)
	[[ $# -eq 2 && -n "${SINGLETON_APP_ID:-}" ]] || die 'usage: deploy-controller singleton-switch <sha>'
	DEPLOY_SKIP_SINGLETONS=1 apply "$2" singleton-switch
	PLATFORM_SKIP_SINGLETONS=0 SINGLETON_RELEASE_SHA="$2" SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-switch "$SINGLETON_APP_ID"
	;;
singleton-stop)
	[[ $# -eq 2 && -n "${SINGLETON_APP_ID:-}" ]] || die 'usage: deploy-controller singleton-stop <sha>'
	DEPLOY_SKIP_SINGLETONS=1 apply "$2" singleton-stop
	SINGLETON_STATE_ROOT="$SINGLETON_STATE_ROOT" PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" singleton-stop "$SINGLETON_APP_ID"
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
