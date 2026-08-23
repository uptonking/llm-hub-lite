#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_ROOT/restic-password}"
STAGE_ROOT="${BACKUP_STAGE_ROOT:-/run/llm-hub-lite/backup}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
MIN_FREE_BYTES="${BACKUP_MIN_FREE_BYTES:-5368709120}"
MIN_FREE_PERCENT="${BACKUP_MIN_FREE_PERCENT:-10}"
operation="${1:-snapshot}"
reason="${2:-manual}"
command -v flock >/dev/null 2>&1 || {
	printf 'flock is required\n' >&2
	exit 1
}

acquire_lock() {
	[[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return 0
	install -d -m 700 "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || {
		printf 'timed out waiting for platform lock\n' >&2
		exit 1
	}
	export PLATFORM_LOCK_HELD=1
}
acquire_lock

command -v restic >/dev/null 2>&1 || {
	printf 'restic is required\n' >&2
	exit 1
}
[[ -s "$PASSWORD_FILE" ]] || {
	printf 'missing Restic password file: %s\n' "$PASSWORD_FILE" >&2
	exit 1
}
env_value() {
	local key="$1" file="${2:-$APP_ENV}"
	[[ -f "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$(env_value RESTIC_REMOTE_ENV_FILE)}"
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$CONFIG_ROOT/restic-remote.env}"
if [[ -n "$RESTIC_REMOTE_ENV_FILE" && -f "$RESTIC_REMOTE_ENV_FILE" ]]; then
	# Provider credentials (for example AWS_ACCESS_KEY_ID / B2_ACCOUNT_KEY)
	# belong in a root-only file and must also be available to systemd timers.
	set -a
	# shellcheck disable=SC1090
	. "$RESTIC_REMOTE_ENV_FILE"
	set +a
fi
policy_value() { env_value "$1" "$CLUSTER_POLICY_FILE"; }
node_value() { env_value "$1" "$NODE_CONFIG_FILE"; }
csv_has() {
	local list=",${1//[[:space:]]/},"
	[[ "$list" == *",$2,"* ]]
}
NODE_ID="${NODE_ID:-$(node_value NODE_ID)}"
NODE_ID="${NODE_ID:-leader}"
[[ "$NODE_ID" =~ ^[a-z][a-z0-9-]*$ ]] || {
	printf 'invalid backup NODE_ID: %s\n' "$NODE_ID" >&2
	exit 1
}
NODE_TAG="node:$NODE_ID"
NEW_API_BACKUP_NODE_ID="$(policy_value NEW_API_BACKUP_NODE_ID)"
NEW_API_BACKUP_NODE_ID="${NEW_API_BACKUP_NODE_ID:-$NODE_ID}"
newapi_enabled=1
csv_has "$(policy_value DISABLED_APPS)" newapi && newapi_enabled=0
if ((newapi_enabled == 1)) && [[ -f "$CLUSTER_POLICY_FILE" ]]; then
	csv_has "$(policy_value NODE_IDS)" "$NEW_API_BACKUP_NODE_ID" || {
		printf 'NEW_API_BACKUP_NODE_ID is absent from cluster inventory: %s\n' "$NEW_API_BACKUP_NODE_ID" >&2
		exit 1
	}
fi
DATA_ROOT="${DATA_ROOT:-$(env_value DATA_ROOT)}"
DATA_ROOT="${DATA_ROOT:-$APP_ROOT/shared/data/prod}"
RESTIC_REMOTE_ENABLED="${RESTIC_REMOTE_ENABLED:-$(env_value RESTIC_REMOTE_ENABLED)}"
RESTIC_REMOTE_REPOSITORY="${RESTIC_REMOTE_REPOSITORY:-$(env_value RESTIC_REMOTE_REPOSITORY)}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$(env_value RESTIC_REMOTE_PASSWORD_FILE)}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$CONFIG_ROOT/restic-remote-password}"
PRODUCTION_REQUIRE_REMOTE_BACKUP="${PRODUCTION_REQUIRE_REMOTE_BACKUP:-$(env_value PRODUCTION_REQUIRE_REMOTE_BACKUP)}"
NEW_API_SQL_DSN="${NEW_API_SQL_DSN:-$(env_value NEW_API_SQL_DSN)}"
LIBRECHAT_MONGO_URI="${LIBRECHAT_MONGO_URI:-$(env_value LIBRECHAT_MONGO_URI)}"
LIBRECHAT_MONGO_BACKUP_ENABLED="${LIBRECHAT_MONGO_BACKUP_ENABLED:-$(env_value LIBRECHAT_MONGO_BACKUP_ENABLED)}"
LIBRECHAT_MONGO_BACKUP_NODE_ID="${LIBRECHAT_MONGO_BACKUP_NODE_ID:-$(env_value LIBRECHAT_MONGO_BACKUP_NODE_ID)}"
LIBRECHAT_MONGO_BACKUP_NODE_ID="${LIBRECHAT_MONGO_BACKUP_NODE_ID:-worker-1}"
WOODPECKER_DATA_ROOT="${WOODPECKER_DATA_ROOT:-$PLATFORM_ROOT/woodpecker/data}"
BESZEL_DATA_ROOT="${BESZEL_DATA_ROOT:-$PLATFORM_ROOT/beszel/hub}"
CADDY_DATA_ROOT="${CADDY_DATA_ROOT:-$PLATFORM_ROOT/caddy}"
APPS_ROOT="${APPS_ROOT:-$CONTROL_ROOT/current/apps}"
remote_enabled() { [[ "$RESTIC_REMOTE_ENABLED" == true || "$RESTIC_REMOTE_ENABLED" == TRUE || "$RESTIC_REMOTE_ENABLED" == 1 ]]; }
remote_required() { [[ "$PRODUCTION_REQUIRE_REMOTE_BACKUP" == true || "$PRODUCTION_REQUIRE_REMOTE_BACKUP" == TRUE || "$PRODUCTION_REQUIRE_REMOTE_BACKUP" == 1 ]]; }
warn_local_only() {
	if remote_required && ! remote_enabled; then
		printf 'production backup policy requires RESTIC_REMOTE_ENABLED=true and a verified off-host repository\n' >&2
		return 1
	fi
	if ! remote_enabled; then
		printf 'WARNING: backups are local-only (%s); they will not survive loss of this VPS. Configure and verify RESTIC_REMOTE_ENABLED=true for off-host recovery.\n' "$REPO" >&2
	fi
}
descriptor_value() { sed -n "s/^$2=//p" "$1/manifest.env" | tail -n1; }
safe_relative() {
	local value="$1"
	[[ "$value" != /* && "$value" != *..* && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}
descriptor_ids() {
	{
		find -L "$APPS_ROOT" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; 2>/dev/null
		find -L "$CONTROL_ROOT/descriptors" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; 2>/dev/null
		find -L "$CONTROL_ROOT/releases" -path '*/apps/*/manifest.env' -exec dirname {} \; 2>/dev/null
	} | awk -F/ '!seen[$NF]++'
}

install -d -m 700 "$REPO"
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
if [[ ! -f "$REPO/config" ]]; then restic init >/dev/null; fi
remote_restic() {
	[[ -n "$RESTIC_REMOTE_REPOSITORY" ]] || {
		printf 'RESTIC_REMOTE_REPOSITORY is required when remote backups are enabled\n' >&2
		return 1
	}
	[[ -s "$RESTIC_REMOTE_PASSWORD_FILE" ]] || {
		printf 'missing remote Restic password file: %s\n' "$RESTIC_REMOTE_PASSWORD_FILE" >&2
		return 1
	}
	RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE" restic "$@"
}
check_remote_repository() {
	remote_enabled || return 0
	# Never auto-initialize a remote repository: a typo in an S3/path URL must
	# not create a new empty repository and make backups appear successful.
	remote_restic snapshots --no-lock >/dev/null || {
		printf 'remote Restic repository is unavailable or uninitialized: %s\n' "$RESTIC_REMOTE_REPOSITORY" >&2
		printf 'initialize it explicitly with: RESTIC_REPOSITORY=%q RESTIC_PASSWORD_FILE=%q restic init\n' \
			"$RESTIC_REMOTE_REPOSITORY" "$RESTIC_REMOTE_PASSWORD_FILE" >&2
		return 1
	}
}

check_space() {
	local available_kb total_kb available total percent_guard required
	read -r total_kb available_kb < <(df -Pk "$REPO" | awk 'NR == 2 { print $2, $4 }')
	[[ "$available_kb" =~ ^[0-9]+$ && "$total_kb" =~ ^[0-9]+$ ]] || {
		printf 'unable to determine backup free-space\n' >&2
		return 1
	}
	available=$((available_kb * 1024))
	total=$((total_kb * 1024))
	percent_guard=$((total * MIN_FREE_PERCENT / 100))
	required="$MIN_FREE_BYTES"
	((percent_guard > required)) && required="$percent_guard"
	((available >= required)) || {
		printf 'backup free-space guard failed: available=%s required=%s\n' "$available" "$required" >&2
		return 1
	}
}

backup_sqlite() {
	local source="$1" target="$2" attempt delay
	[[ -f "$source" ]] || return 0
	for attempt in 1 2 3 4 5; do
		rm -f -- "$target"
		if sqlite3 -cmd '.timeout 30000' "$source" ".backup '$target'" &&
			sqlite3 "$target" 'PRAGMA integrity_check;' | grep -qx ok; then return 0; fi
		delay=$((attempt * 2))
		printf 'SQLite backup retry %s/5 for %s in %s seconds\n' "$attempt" "$source" "$delay" >&2
		sleep "$delay"
	done
	printf 'SQLite backup failed after retries: %s\n' "$source" >&2
	return 1
}

backup_postgres() {
	if ((newapi_enabled == 0)); then
		printf 'PostgreSQL dump skipped: New API is disabled by cluster policy (node=%s)\n' "$NODE_ID"
		return 0
	fi
	if [[ "$NODE_ID" != "$NEW_API_BACKUP_NODE_ID" ]]; then
		printf 'PostgreSQL dump skipped: backup owner is %s (local node=%s)\n' "$NEW_API_BACKUP_NODE_ID" "$NODE_ID"
		return 0
	fi
	[[ -n "$NEW_API_SQL_DSN" ]] || return 0
	command -v pg_dump >/dev/null 2>&1 || {
		printf 'pg_dump is required when NEW_API_SQL_DSN is configured\n' >&2
		return 1
	}
	[[ "$NEW_API_SQL_DSN" =~ ^postgres(ql)?:// ]] || {
		printf 'New API DSN must use postgres:// or postgresql://\n' >&2
		return 1
	}
	install -d -m 700 "$STAGE_ROOT/postgres"
	pg_dump --format=custom --no-owner --no-privileges --file "$STAGE_ROOT/postgres/new-api.dump" "$NEW_API_SQL_DSN"
	pg_restore --list "$STAGE_ROOT/postgres/new-api.dump" >/dev/null
}
backup_librechat_mongo() {
	[[ "$NODE_ID" == "$LIBRECHAT_MONGO_BACKUP_NODE_ID" ]] || {
		printf 'MongoDB Atlas export skipped: backup owner is %s (local node=%s)\n' "$LIBRECHAT_MONGO_BACKUP_NODE_ID" "$NODE_ID"
		return 0
	}
	[[ "$LIBRECHAT_MONGO_BACKUP_ENABLED" == true || "$LIBRECHAT_MONGO_BACKUP_ENABLED" == TRUE || "$LIBRECHAT_MONGO_BACKUP_ENABLED" == 1 ]] || {
		printf 'MongoDB Atlas export skipped: set LIBRECHAT_MONGO_BACKUP_ENABLED=true and install mongodump to enable it\n'
		return 0
	}
	[[ -n "$LIBRECHAT_MONGO_URI" ]] || {
		printf 'LIBRECHAT_MONGO_URI is required for the Atlas export\n' >&2
		return 1
	}
	command -v mongodump >/dev/null 2>&1 || {
		printf 'mongodump is required when LibreChat Atlas exports are enabled\n' >&2
		return 1
	}
	install -d -m 700 "$STAGE_ROOT/mongodb"
	mongodump --uri "$LIBRECHAT_MONGO_URI" --gzip --archive="$STAGE_ROOT/mongodb/librechat.archive.gz"
}

snapshot() {
	command -v sqlite3 >/dev/null 2>&1 || {
		printf 'sqlite3 is required\n' >&2
		exit 1
	}
	check_space
	install -d -m 700 "$STAGE_ROOT"
	find "$STAGE_ROOT" -mindepth 1 -delete 2>/dev/null || true
	install -d -m 700 "$STAGE_ROOT/sqlite"
	trap 'find "$STAGE_ROOT" -mindepth 1 -delete' EXIT

	: >"$STAGE_ROOT/sqlite/map.tsv"
	while IFS= read -r descriptor; do
		app_id="$(basename "$descriptor")"
		data_rel="$(descriptor_value "$descriptor" DATA_ROOT_REL)"
		sqlite_paths="$(descriptor_value "$descriptor" SQLITE_PATHS)"
		safe_relative "$data_rel" || {
			printf 'unsafe DATA_ROOT_REL in %s\n' "$descriptor" >&2
			return 1
		}
		for relative in $sqlite_paths; do
			safe_relative "$relative" || {
				printf 'unsafe SQLITE_PATHS entry in %s\n' "$descriptor" >&2
				return 1
			}
			path_hash="$(printf '%s' "$relative" | sha256sum | awk '{print substr($1, 1, 16)}')"
			source="$DATA_ROOT/$data_rel/$relative"
			target="$STAGE_ROOT/sqlite/app-$app_id-$path_hash-$(basename "$relative")"
			if backup_sqlite "$source" "$target"; then
				[[ -f "$target" ]] && printf '%s\t%s\t%s\t%s\n' "$app_id" "$data_rel" "$relative" "$(basename "$target")" >>"$STAGE_ROOT/sqlite/map.tsv"
			else return 1; fi
		done
	done < <(descriptor_ids)
	backup_sqlite "$WOODPECKER_DATA_ROOT/woodpecker.sqlite" "$STAGE_ROOT/sqlite/woodpecker.sqlite"
	backup_postgres
	backup_librechat_mongo
	: >"$STAGE_ROOT/sqlite/beszel-map.tsv"
	while IFS= read -r database; do
		relative="${database#"$BESZEL_DATA_ROOT/"}"
		path_hash="$(printf '%s' "$relative" | sha256sum | awk '{print substr($1, 1, 16)}')"
		target="$STAGE_ROOT/sqlite/beszel-$path_hash-$(basename "$database")"
		if backup_sqlite "$database" "$target" && [[ -f "$target" ]]; then
			printf '%s\t%s\n' "$relative" "$(basename "$target")" >>"$STAGE_ROOT/sqlite/beszel-map.tsv"
		fi
	done < <(find "$BESZEL_DATA_ROOT" -type f \( -name '*.db' -o -name '*.sqlite' \) -print 2>/dev/null | sort)

	printf 'created_utc=%s\nnode_id=%s\nreason=%s\nrelease=%s\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$NODE_ID" "$reason" "$(readlink "$APP_ROOT/current" 2>/dev/null || true)" >"$STAGE_ROOT/manifest.txt"

	local -a paths existing excludes
	paths=(
		"$DATA_ROOT" "$APP_ROOT/shared/.env.prod" "$APP_ROOT/shared/runtime"
		"$APP_ROOT/current" "$APP_ROOT/previous" "$CONTROL_ROOT/current" "$CONTROL_ROOT/previous"
		"$CONTROL_ROOT/releases" "$CONTROL_ROOT/descriptors" "$FOUNDATION_ROOT" "$CADDY_DATA_ROOT"
		"$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/beszel" "$CONFIG_ROOT/platform.env"
		"$CONFIG_ROOT/images.apps.env" "$CONFIG_ROOT/images.foundation.env"
		"$CONFIG_ROOT/images.apps.previous.env" "$CONFIG_ROOT/images.foundation.previous.env"
		"$CONFIG_ROOT/image-history" "$CONFIG_ROOT/beszel-initial-credentials" "$CONFIG_ROOT/beszel-enrollment.env" "$CONFIG_ROOT/shared-secrets.env" "$CONFIG_ROOT/node.env" "$CONFIG_ROOT/deploy-key" "$CONFIG_ROOT/known_hosts" "$CONFIG_ROOT/github-token" "$CONFIG_ROOT/restic-password" "$RESTIC_REMOTE_PASSWORD_FILE" "$RESTIC_REMOTE_ENV_FILE" "$STAGE_ROOT/sqlite" "$STAGE_ROOT/postgres" "$STAGE_ROOT/mongodb" "$STAGE_ROOT/manifest.txt"
	)
	existing=()
	for path in "${paths[@]}"; do [[ -e "$path" || -L "$path" ]] && existing+=("$path"); done
	excludes=(
		--exclude "$DATA_ROOT/*.db" --exclude "$DATA_ROOT/*.db-*" --exclude "$DATA_ROOT/*.sqlite" --exclude "$DATA_ROOT/*.sqlite-*"
		--exclude "$DATA_ROOT/**/*.db" --exclude "$DATA_ROOT/**/*.db-*" --exclude "$DATA_ROOT/**/*.sqlite" --exclude "$DATA_ROOT/**/*.sqlite-*"
		--exclude "$WOODPECKER_DATA_ROOT/*.db" --exclude "$WOODPECKER_DATA_ROOT/*.db-*" --exclude "$WOODPECKER_DATA_ROOT/*.sqlite" --exclude "$WOODPECKER_DATA_ROOT/*.sqlite-*"
		--exclude "$WOODPECKER_DATA_ROOT/**/*.db" --exclude "$WOODPECKER_DATA_ROOT/**/*.db-*" --exclude "$WOODPECKER_DATA_ROOT/**/*.sqlite" --exclude "$WOODPECKER_DATA_ROOT/**/*.sqlite-*"
		--exclude "$BESZEL_DATA_ROOT/*.db" --exclude "$BESZEL_DATA_ROOT/*.db-*" --exclude "$BESZEL_DATA_ROOT/*.sqlite" --exclude "$BESZEL_DATA_ROOT/*.sqlite-*"
		--exclude "$BESZEL_DATA_ROOT/**/*.db" --exclude "$BESZEL_DATA_ROOT/**/*.db-*" --exclude "$BESZEL_DATA_ROOT/**/*.sqlite" --exclude "$BESZEL_DATA_ROOT/**/*.sqlite-*"
	)
	check_remote_repository
	restic backup --tag platform --tag "$NODE_TAG" --tag "$reason" "${excludes[@]}" "${existing[@]}"
	if remote_enabled; then
		remote_restic backup --tag platform --tag "$NODE_TAG" --tag "$reason" "${excludes[@]}" "${existing[@]}"
	fi
	printf 'backup snapshot complete: repository=%s reason=%s\n' "$REPO" "$reason"
}

warn_local_only
case "$operation" in
snapshot) snapshot ;;
prune)
	check_remote_repository
	restic forget --tag "platform,$NODE_TAG" --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
	remote_enabled && remote_restic forget --tag "platform,$NODE_TAG" --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
	printf 'backup retention/prune complete\n'
	;;
check)
	check_remote_repository
	restic check
	remote_enabled && remote_restic check
	printf 'backup repository check complete\n'
	;;
*)
	printf 'usage: backup-platform {snapshot [reason]|prune|check}\n' >&2
	exit 2
	;;
esac
