#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ "$EUID" -eq 0 || "${IDENTITY_MIGRATION_TEST_MODE:-0}" == 1 ]] || {
	printf 'migrate-app-identity: run this command as root\n' >&2
	exit 1
}

action="${1:-}"
app="${2:-}"
case "$action" in prepare | finalize | rollback) ;; *)
	printf 'usage: %s {prepare|finalize|rollback} <app-id>\n' "$0" >&2
	exit 2
	;;
esac
[[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || {
	printf 'migrate-app-identity: invalid target application ID: %s\n' "$app" >&2
	exit 2
}

die() {
	printf 'migrate-app-identity: %s\n' "$*" >&2
	exit 1
}
log() { printf 'migrate-app-identity: %s\n' "$*"; }
env_value() {
	local key="$1" file="$2" line value=''
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$key="* ]] || continue
		value="${line#*=}"
	done <"$file"
	printf '%s\n' "$value"
}
safe_relative() {
	[[ -n "$1" && "$1" != /* && "$1" != *..* && "$1" =~ ^[A-Za-z0-9._/-]+$ ]]
}
safe_project() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }
same_symlink() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
control_root="${CONTROL_ROOT:-/opt/platform/control}"
if [[ -d "$script_root/apps" ]]; then
	release_root="$script_root"
else
	release_root="${REPO_ROOT:-$control_root/current}"
fi
manifest="${IDENTITY_MIGRATION_MANIFEST:-$release_root/apps/$app/manifest.env}"
[[ -r "$manifest" ]] || die "missing target manifest: $manifest"
[[ "$(env_value APP_ID "$manifest")" == "$app" ]] || die 'target manifest APP_ID mismatch'
[[ "$(env_value UPSTREAM_MODE "$manifest")" == singleton ]] || die 'identity migration is supported only for singleton applications'

source_app="$(env_value IDENTITY_MIGRATION_FROM_APP_ID "$manifest")"
source_data_rel="$(env_value IDENTITY_MIGRATION_FROM_DATA_ROOT_REL "$manifest")"
source_runtime_rel="$(env_value IDENTITY_MIGRATION_FROM_RUNTIME_ENV_FILE "$manifest")"
source_project="$(env_value IDENTITY_MIGRATION_FROM_COMPOSE_PROJECT "$manifest")"
source_network="$(env_value IDENTITY_MIGRATION_FROM_NETWORK "$manifest")"
source_prefix="$(env_value IDENTITY_MIGRATION_FROM_ENV_PREFIX "$manifest")"
target_prefix="$(env_value IDENTITY_MIGRATION_TO_ENV_PREFIX "$manifest")"
target_network="$(env_value IDENTITY_MIGRATION_TO_NETWORK "$manifest")"
target_data_rel="$(env_value DATA_ROOT_REL "$manifest")"
target_runtime_rel="$(env_value RUNTIME_ENV_FILE "$manifest")"
target_project="$(env_value COMPOSE_PROJECT "$manifest")"

[[ "$source_app" =~ ^[a-z][a-z0-9-]*$ && "$source_app" != "$app" ]] || die 'invalid IDENTITY_MIGRATION_FROM_APP_ID'
for rel in "$source_data_rel" "$source_runtime_rel" "$target_data_rel" "$target_runtime_rel"; do
	safe_relative "$rel" || die "unsafe identity migration path: $rel"
done
safe_project "$source_project" || die 'invalid source Compose project'
safe_project "$target_project" || die 'invalid target Compose project'
safe_project "$source_network" || die 'invalid source network'
safe_project "$target_network" || die 'invalid target network'
[[ "$source_prefix" =~ ^[A-Z][A-Z0-9_]*$ && "$target_prefix" =~ ^[A-Z][A-Z0-9_]*$ && "$source_prefix" != "$target_prefix" ]] ||
	die 'invalid identity migration environment prefixes'

config_root="${CONFIG_ROOT:-/etc/llm-hub-lite}"
app_env="${APP_ENV:-/opt/apps/llm-hub-lite/shared/.env.prod}"
data_root="$(env_value DATA_ROOT "$app_env")"
data_root="${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}"
source_data="$data_root/$source_data_rel"
target_data="$data_root/$target_data_rel"
source_runtime="$config_root/$source_runtime_rel"
target_runtime="$config_root/$target_runtime_rel"
state_root="${IDENTITY_MIGRATION_STATE_ROOT:-$control_root/app-identity-migrations}"
state_file="$state_root/$app.state"
expected_file=''
trap '[[ -z "$expected_file" ]] || rm -f -- "$expected_file"' EXIT

case "$source_data" in "$data_root"/*) ;; *) die 'source data path escapes DATA_ROOT' ;; esac
case "$target_data" in "$data_root"/*) ;; *) die 'target data path escapes DATA_ROOT' ;; esac
[[ "$source_data" != "$target_data" && "$source_runtime" != "$target_runtime" ]] || die 'source and target paths must differ'

if [[ "${PLATFORM_LOCK_HELD:-0}" != 1 ]]; then
	command -v flock >/dev/null 2>&1 || die 'flock is required'
	install -d -m 700 "$(dirname "${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}")"
	exec 9>"${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
	flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for platform lock'
fi

transformed_env() {
	local destination="$1"
	sed "s/^${source_prefix}_/${target_prefix}_/" "$source_runtime" >"$destination"
}
stop_project() {
	local project="$1" ids id
	ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project")" || die "unable to enumerate Compose project: $project"
	[[ -n "$ids" ]] || return 0
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		docker stop -t 60 "$id" >/dev/null || die "unable to stop container in project $project"
		docker rm "$id" >/dev/null || die "unable to remove container in project $project"
	done <<<"$ids"
}
remove_network() {
	local network="$1" attachments
	docker network inspect "$network" >/dev/null 2>&1 || return 0
	attachments="$(docker network inspect --format '{{len .Containers}}' "$network")" || die "unable to inspect network: $network"
	[[ "$attachments" == 0 ]] || die "network still has attached containers: $network"
	docker network rm "$network" >/dev/null || die "unable to remove network: $network"
}
write_state() {
	local phase="$1" tmp
	install -d -m 700 "$state_root"
	tmp="$(mktemp "$state_file.XXXXXX")"
	printf 'VERSION=1\nAPP_ID=%s\nSOURCE_APP_ID=%s\nPHASE=%s\nUPDATED_UTC=%s\n' \
		"$app" "$source_app" "$phase" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$state_file"
}

prepare() {
	if [[ ! -e "$source_data" && ! -L "$source_data" && -d "$target_data" && ! -e "$source_runtime" && -f "$target_runtime" ]]; then
		log "$source_app to $app migration is already finalized"
		return 0
	fi
	[[ -f "$source_runtime" && ! -L "$source_runtime" ]] || die "source runtime env is missing or unsafe: $source_runtime"
	expected_file="$(mktemp "${target_runtime}.expected.XXXXXX")"
	transformed_env "$expected_file"
	if [[ -e "$target_runtime" || -L "$target_runtime" ]]; then
		[[ -f "$target_runtime" && ! -L "$target_runtime" ]] || die "target runtime env is unsafe: $target_runtime"
		cmp -s "$expected_file" "$target_runtime" || die 'target runtime env conflicts with transformed source values'
	fi
	if [[ -e "$source_data" || -L "$source_data" ]]; then
		if same_symlink "$source_data" "$target_data"; then
			[[ -d "$target_data" && ! -L "$target_data" ]] || die 'prepared target data directory is missing or unsafe'
		elif [[ -d "$source_data" && ! -L "$source_data" && ! -e "$target_data" && ! -L "$target_data" ]]; then
			:
		else
			die 'source and target data paths conflict; refusing to merge or overwrite'
		fi
	else
		[[ -d "$target_data" && ! -L "$target_data" ]] || die 'source data is missing and target data is not a safe directory'
	fi

	stop_project "$source_project"
	if [[ ! -e "$target_runtime" && ! -L "$target_runtime" ]]; then
		install -m 600 "$expected_file" "$target_runtime"
	fi
	if [[ -d "$source_data" && ! -L "$source_data" ]]; then
		mv -- "$source_data" "$target_data"
		ln -s "$target_data" "$source_data"
	elif [[ ! -e "$source_data" && ! -L "$source_data" ]]; then
		ln -s "$target_data" "$source_data"
	fi
	write_state prepared
	sync
	log "prepared $source_app to $app; rollback compatibility remains until finalization"
}

rollback() {
	if [[ -d "$source_data" && ! -L "$source_data" && ! -e "$target_data" && ! -L "$target_data" ]]; then
		log "$source_app identity is already restored"
		return 0
	fi
	same_symlink "$source_data" "$target_data" || die 'rollback requires the guarded source data symlink'
	[[ -d "$target_data" && ! -L "$target_data" ]] || die 'rollback target data directory is missing or unsafe'
	[[ -f "$source_runtime" && ! -L "$source_runtime" && -f "$target_runtime" && ! -L "$target_runtime" ]] || die 'rollback runtime env files are missing or unsafe'
	expected_file="$(mktemp "${target_runtime}.expected.XXXXXX")"
	transformed_env "$expected_file"
	cmp -s "$expected_file" "$target_runtime" || die 'target runtime env changed during migration; refusing rollback'
	stop_project "$target_project"
	remove_network "$target_network"
	rm -- "$source_data"
	mv -- "$target_data" "$source_data"
	rm -- "$target_runtime"
	rm -f -- "$state_file"
	sync
	log "restored $source_app after failed $app deployment"
}

finalize() {
	local ids id health
	if [[ ! -e "$source_data" && ! -L "$source_data" && -d "$target_data" && ! -e "$source_runtime" && -f "$target_runtime" ]]; then
		rm -f -- "$state_file"
		log "$source_app to $app migration is already finalized"
		return 0
	fi
	same_symlink "$source_data" "$target_data" || die 'finalization requires the guarded source data symlink'
	[[ -d "$target_data" && ! -L "$target_data" ]] || die 'target data directory is missing or unsafe'
	[[ -f "$source_runtime" && ! -L "$source_runtime" && -f "$target_runtime" && ! -L "$target_runtime" ]] || die 'runtime env files are missing or unsafe'
	expected_file="$(mktemp "${target_runtime}.expected.XXXXXX")"
	transformed_env "$expected_file"
	cmp -s "$expected_file" "$target_runtime" || die 'target runtime env changed during migration; refusing finalization'
	ids="$(docker ps -q --filter "label=com.docker.compose.project=$target_project")" || die 'unable to enumerate target project'
	[[ -n "$ids" ]] || die 'target project has no running container'
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
		[[ "$health" == healthy ]] || die "target project is not healthy: $health"
	done <<<"$ids"
	[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$source_project")" ]] || die 'source project still has containers'
	remove_network "$source_network"
	rm -- "$source_data"
	rm -- "$source_runtime"
	rm -f -- "$state_file"
	sync
	log "finalized $source_app to $app identity migration"
}

"$action"
