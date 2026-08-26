#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
OBSERVER_ENV_FILE="${OBSERVER_ENV_FILE:-$FOUNDATION_ROOT/env/observer.env}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_ROOT/restic-password}"
RESTORE_ROOT="${RESTORE_ROOT:-/opt/backups/llm-hub-lite/restores}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
PLATFORMCTL_SCRIPT="${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}"
operation="${1:-extract}"
snapshot="${2:-latest}"
requested_target="${3:-}"
die() {
	printf 'restore-platform: %s\n' "$*" >&2
	exit 1
}
command -v flock >/dev/null 2>&1 || die 'flock is required'

acquire_lock() {
	[[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return 0
	install -d -m 700 "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for platform lock'
	export PLATFORM_LOCK_HELD=1
}

RESTORE_MAINTENANCE_ACTIVE=0
restore_failure_trap() {
	local rc=$?
	if ((rc != 0)) && ((RESTORE_MAINTENANCE_ACTIVE == 1)); then
		install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
		printf 'started_utc=%s\nreason=restore failed; manual verification required\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$MAINTENANCE_FILE"
		printf 'restore-platform: maintenance mode retained after failure: %s\n' "$MAINTENANCE_FILE" >&2
	fi
	trap - EXIT
	exit "$rc"
}
trap restore_failure_trap EXIT

acquire_lock

command -v restic >/dev/null 2>&1 || {
	printf 'restic is required\n' >&2
	exit 1
}
command -v sqlite3 >/dev/null 2>&1 || {
	printf 'sqlite3 is required\n' >&2
	exit 1
}
env_value() {
	local key="$1" file="${2:-$APP_ENV}"
	[[ -f "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
observer_env_value() { env_value "$1" "$OBSERVER_ENV_FILE"; }
DATA_ROOT="${DATA_ROOT:-$(env_value DATA_ROOT)}"
DATA_ROOT="${DATA_ROOT:-$APP_ROOT/shared/data/prod}"
OBSERVER_DATA_ROOT="${OBSERVER_DATA_ROOT:-$(observer_env_value OBSERVER_DATA_ROOT)}"
OBSERVER_DATA_ROOT="${OBSERVER_DATA_ROOT:-$PLATFORM_ROOT/observer}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
NODE_ID="${NODE_ID:-$(sed -n 's/^NODE_ID=//p' "$NODE_CONFIG_FILE" 2>/dev/null | tail -n1)}"
RESTORE_NODE_ID="${RESTORE_NODE_ID:-$NODE_ID}"
[[ "$RESTORE_NODE_ID" =~ ^[a-z][a-z0-9-]*$ ]] || die 'RESTORE_NODE_ID must be a stable cluster node ID'
RESTORE_SOURCE="${RESTORE_SOURCE:-local}"
RESTIC_REMOTE_REPOSITORY="${RESTIC_REMOTE_REPOSITORY:-$(env_value RESTIC_REMOTE_REPOSITORY)}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$(env_value RESTIC_REMOTE_PASSWORD_FILE)}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$CONFIG_ROOT/restic-remote-password}"
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$(env_value RESTIC_REMOTE_ENV_FILE)}"
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$CONFIG_ROOT/restic-remote.env}"
if [[ -s "$RESTIC_REMOTE_ENV_FILE" ]]; then
	set -a
	# shellcheck disable=SC1090
	. "$RESTIC_REMOTE_ENV_FILE"
	set +a
fi
case "$RESTORE_SOURCE" in
local) ;;
remote)
	[[ -n "$RESTIC_REMOTE_REPOSITORY" ]] || die 'RESTIC_REMOTE_REPOSITORY is required for RESTORE_SOURCE=remote'
	[[ -s "$RESTIC_REMOTE_PASSWORD_FILE" ]] || die 'RESTIC_REMOTE_PASSWORD_FILE is required for RESTORE_SOURCE=remote'
	REPO="$RESTIC_REMOTE_REPOSITORY"
	PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE"
	;;
*) die 'RESTORE_SOURCE must be local or remote' ;;
esac
[[ -s "$PASSWORD_FILE" ]] || die "missing Restic password file: $PASSWORD_FILE"
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

safe_target() { [[ "$1" == "$RESTORE_ROOT"/* && "$1" != *..* ]] || {
	printf 'restore target must be below %s\n' "$RESTORE_ROOT" >&2
	exit 1
}; }

safe_observer_data_root() {
	case "$1" in
	"$PLATFORM_ROOT"/*)
		[[ "$1" != "$PLATFORM_ROOT/" && "$1" != *..* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
		;;
	*)
		return 1
		;;
	esac
}

validate_extract() {
	local target="$1" database count=0
	while IFS= read -r database; do
		sqlite3 "$database" 'PRAGMA integrity_check;' | grep -qx ok || {
			printf 'restored SQLite integrity check failed: %s\n' "$database" >&2
			return 1
		}
		count=$((count + 1))
	done < <(find "$target/run/llm-hub-lite/backup/sqlite" -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | sort)
	# A newly bootstrapped instance may not have created every optional database.
	((count > 0)) || printf 'snapshot contains no SQLite copies; continuing (optional databases may be empty)\n' >&2
	if [[ -f "$target/run/llm-hub-lite/backup/postgres/new-api.dump" ]]; then
		command -v pg_restore >/dev/null 2>&1 || {
			printf 'pg_restore is required to validate the New API dump\n' >&2
			return 1
		}
		pg_restore --list "$target/run/llm-hub-lite/backup/postgres/new-api.dump" >/dev/null
		printf 'New API PostgreSQL dump validated; restore it explicitly with pg_restore after review\n' >&2
	fi
}

extract_snapshot() {
	local target="$1"
	safe_target "$target"
	[[ ! -e "$target" ]] || {
		printf 'restore target already exists: %s\n' "$target" >&2
		exit 1
	}
	install -d -m 700 "$target"
	restic restore "$snapshot" --target "$target" --tag "platform,node:$RESTORE_NODE_ID"
	validate_extract "$target"
	printf '%s\n' "$target"
}

install_verified_databases() {
	local target="$1" staged database app_id relative data_rel snapshot_file
	staged="$target/run/llm-hub-lite/backup/sqlite"
	install -d -m 700 "$target$PLATFORM_ROOT/woodpecker/data" "$target$PLATFORM_ROOT/beszel/hub"
	if [[ -f "$staged/map.tsv" ]]; then
		while IFS=$'\t' read -r app_id data_rel relative snapshot_file; do
			[[ -n "$app_id" && -n "$data_rel" && -n "$relative" && -n "$snapshot_file" ]] || die 'invalid application database restore map'
			[[ "$data_rel" != /* && "$data_rel" != *..* && "$relative" != /* && "$relative" != *..* ]] || die 'unsafe application database restore path'
			[[ "$snapshot_file" != /* && "$snapshot_file" != *..* && -f "$staged/$snapshot_file" ]] || die 'missing application database artifact'
			install -d -m 700 "$target$DATA_ROOT/$data_rel/$(dirname "$relative")"
			install -m 600 "$staged/$snapshot_file" "$target$DATA_ROOT/$data_rel/$relative"
		done <"$staged/map.tsv"
	fi
	[[ -f "$staged/woodpecker.sqlite" ]] && install -m 600 "$staged/woodpecker.sqlite" "$target$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite"
	if [[ -f "$staged/observer-metadata.sqlite" ]]; then
		install -d -m 700 "$target$OBSERVER_DATA_ROOT/data/db"
		install -m 600 "$staged/observer-metadata.sqlite" "$target$OBSERVER_DATA_ROOT/data/db/metadata.sqlite"
	fi
	if [[ -f "$staged/beszel-map.tsv" ]]; then
		while IFS=$'\t' read -r relative snapshot_file; do
			[[ -n "$relative" && -n "$snapshot_file" && "$relative" != /* && "$relative" != *..* ]] || die 'invalid Beszel database restore map'
			[[ "$snapshot_file" != /* && "$snapshot_file" != *..* ]] || die 'invalid Beszel database artifact name'
			install -d -m 700 "$target$PLATFORM_ROOT/beszel/hub/$(dirname "$relative")"
			install -m 600 "$staged/$snapshot_file" "$target$PLATFORM_ROOT/beszel/hub/$relative"
		done <"$staged/beszel-map.tsv"
	fi
}

rollback_swaps() {
	local manifest="$1" count=0 live saved i
	local -a lives=() saveds=()
	while IFS=$'\t' read -r live saved; do
		[[ -n "$live" && -e "$saved" ]] || continue
		lives+=("$live")
		saveds+=("$saved")
		count=$((count + 1))
	done <"$manifest"
	for ((i = count - 1; i >= 0; i--)); do
		live="${lives[$i]}"
		saved="${saveds[$i]}"
		[[ -e "$live" || -L "$live" ]] && mv "$live" "$live.failed-$(date -u +%s)"
		mv "$saved" "$live"
	done
}

swap_path() {
	local restored="$1" live="$2" rollback_root="$3" manifest="$4" saved
	[[ -e "$restored" || -L "$restored" ]] || return 0
	saved="$rollback_root$live"
	install -d -m 700 "$(dirname "$saved")" "$(dirname "$live")"
	if [[ -e "$live" || -L "$live" ]]; then mv "$live" "$saved"; fi
	if ! mv "$restored" "$live"; then
		[[ -e "$saved" || -L "$saved" ]] && mv "$saved" "$live"
		return 1
	fi
	printf '%s\t%s\n' "$live" "$saved" >>"$manifest"
}

apply_snapshot() {
	[[ "$EUID" -eq 0 ]] || {
		printf 'restore apply must run as root\n' >&2
		exit 1
	}
	local stamp target rollback_root manifest path restored_node_id descriptor runtime_rel restored_observer_data_root
	local -a restore_paths
	add_restore_path() {
		local candidate="$1" existing
		for existing in "${restore_paths[@]-}"; do
			[[ "$existing" == "$candidate" ]] && return 0
		done
		restore_paths+=("$candidate")
	}
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	target="${requested_target:-$RESTORE_ROOT/apply-$stamp}"
	extract_snapshot "$target" >/dev/null
	restored_observer_data_root="$(sed -n 's/^OBSERVER_DATA_ROOT=//p' "$target$FOUNDATION_ROOT/env/observer.env" 2>/dev/null | tail -n1)"
	restored_observer_data_root="${restored_observer_data_root:-$PLATFORM_ROOT/observer}"
	safe_observer_data_root "$OBSERVER_DATA_ROOT" || die "current Observer data root must be below $PLATFORM_ROOT: $OBSERVER_DATA_ROOT"
	safe_observer_data_root "$restored_observer_data_root" || die "restored Observer data root must be below $PLATFORM_ROOT: $restored_observer_data_root"
	if [[ "${RESTORE_IDENTITY:-0}" == 1 && -e "$target$CONFIG_ROOT/node.env" ]]; then
		restored_node_id="$(sed -n 's/^NODE_ID=//p' "$target$CONFIG_ROOT/node.env" | tail -n1)"
		[[ "$restored_node_id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'explicit identity restore contains an invalid NODE_ID'
		[[ -f "$target$CONTROL_ROOT/current/config/cluster/nodes/$restored_node_id.env" ]] || die 'explicit identity restore is not present in the restored cluster inventory'
	fi
	install_verified_databases "$target"
	for path in \
		"$DATA_ROOT" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/.env.prod" "$APP_ROOT/current" "$APP_ROOT/previous" \
		"$CONTROL_ROOT/current" "$CONTROL_ROOT/previous" "$CONTROL_ROOT/releases" "$CONTROL_ROOT/descriptors" "$FOUNDATION_ROOT" \
		"$PLATFORM_ROOT/caddy" "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/beszel" \
		"$OBSERVER_DATA_ROOT" "$restored_observer_data_root" \
		"$CONFIG_ROOT/platform.env" "$CONFIG_ROOT/images.apps.env" "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/singleton-state" \
		"$CONFIG_ROOT/beszel-initial-credentials" "$CONFIG_ROOT/beszel-enrollment.env" "$CONFIG_ROOT/shared-secrets.env" "$CONFIG_ROOT/deploy-key" "$CONFIG_ROOT/known_hosts" "$CONFIG_ROOT/github-token" \
		"${RESTIC_REMOTE_PASSWORD_FILE:-$CONFIG_ROOT/restic-remote-password}" "$RESTIC_REMOTE_ENV_FILE"; do
		add_restore_path "$path"
	done
	while IFS= read -r descriptor; do
		runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$descriptor" | tail -n1)"
		[[ -n "$runtime_rel" ]] || continue
		[[ "$runtime_rel" != /* && "$runtime_rel" != *..* && "$runtime_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "unsafe runtime env path in restored manifest: $descriptor"
		add_restore_path "$CONFIG_ROOT/$runtime_rel"
	done < <(find -L "$target$CONTROL_ROOT/current/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null | sort)
	"$BACKUP_SCRIPT" snapshot pre-restore
	install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
	printf 'started_utc=%s\nreason=restore %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$snapshot" >"$MAINTENANCE_FILE"
	RESTORE_MAINTENANCE_ACTIVE=1
	PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all
	rollback_root="$RESTORE_ROOT/rollback-$stamp"
	manifest="$rollback_root/manifest.tsv"
	install -d -m 700 "$rollback_root"
	: >"$manifest"
	for path in "${restore_paths[@]}"; do
		if ! swap_path "$target$path" "$path" "$rollback_root" "$manifest"; then
			rollback_swaps "$manifest"
			PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all || true
			die 'restore swap failed; prior paths restored; maintenance mode retained for verification'
		fi
	done
	if [[ "${RESTORE_IDENTITY:-0}" == 1 && -e "$target$CONFIG_ROOT/node.env" ]]; then
		if ! swap_path "$target$CONFIG_ROOT/node.env" "$CONFIG_ROOT/node.env" "$rollback_root" "$manifest"; then
			rollback_swaps "$manifest"
			PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all || true
			die 'identity restore swap failed; prior paths restored; maintenance mode retained for verification'
		fi
	fi
	if PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" validate && PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all && "$PLATFORMCTL_SCRIPT" health true; then
		RESTORE_MAINTENANCE_ACTIVE=0
		rm -f -- "$MAINTENANCE_FILE"
		printf 'restore applied successfully; rollback data retained at %s\n' "$rollback_root"
	else
		PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all || true
		rollback_swaps "$manifest"
		PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all || true
		printf 'restore validation failed; prior data restored from %s; maintenance mode retained for verification\n' "$rollback_root" >&2
		exit 1
	fi
}

case "$operation" in
extract)
	target="${requested_target:-$RESTORE_ROOT/extract-$(date -u +%Y%m%dT%H%M%SZ)}"
	extract_snapshot "$target" >/dev/null
	printf 'restore extracted and validated at %s\n' "$target"
	;;
apply) apply_snapshot ;;
rollback)
	[[ -n "$requested_target" && -f "$requested_target/manifest.tsv" ]] || {
		printf 'rollback requires a rollback directory\n' >&2
		exit 2
	}
	install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
	printf 'started_utc=%s\nreason=restore rollback\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$MAINTENANCE_FILE"
	RESTORE_MAINTENANCE_ACTIVE=1
	PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all
	rollback_swaps "$requested_target/manifest.tsv"
	PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all
	RESTORE_MAINTENANCE_ACTIVE=0
	rm -f -- "$MAINTENANCE_FILE"
	;;
*)
	printf 'usage: restore-platform {extract|apply|rollback} [snapshot] [target]\n' >&2
	exit 2
	;;
esac
