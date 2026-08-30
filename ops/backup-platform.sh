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
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_ROOT/restic-password}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups/llm-hub-lite}"
# PGlite trees can exceed the size of /run (a tmpfs on many VPS images). Keep
# staging on the persistent backup filesystem; BACKUP_STAGE_ROOT remains an
# override for tests and operators with a dedicated volume.
STAGE_ROOT="${BACKUP_STAGE_ROOT:-$BACKUP_ROOT/stage}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
PLATFORMCTL_SCRIPT="${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}"
MIN_FREE_BYTES="${BACKUP_MIN_FREE_BYTES:-5368709120}"
MIN_FREE_PERCENT="${BACKUP_MIN_FREE_PERCENT:-10}"
operation="${1:-snapshot}"
reason="${2:-manual}"

env_value() {
	local key="$1" file="${2:-$APP_ENV}"
	[[ -f "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
observer_env_value() { env_value "$1" "$OBSERVER_ENV_FILE"; }
truthy() { [[ "$1" == true || "$1" == TRUE || "$1" == 1 ]]; }
node_value() { env_value "$1" "$NODE_CONFIG_FILE"; }
NODE_ID="${NODE_ID:-$(node_value NODE_ID)}"
NODE_ID="${NODE_ID:-leader}"
[[ "$NODE_ID" =~ ^[a-z][a-z0-9-]*$ ]] || {
	printf 'invalid backup NODE_ID: %s\n' "$NODE_ID" >&2
	exit 1
}
BACKUP_ENABLED="${BACKUP_ENABLED:-$(env_value BACKUP_ENABLED "$NODE_CONFIG_FILE")}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
case "$BACKUP_ENABLED" in
true | TRUE | 1) ;;
false | FALSE | 0)
	# Opted-out nodes do not need Restic, its password, or a backup lock.
	printf 'Restic backup is disabled for node %s by BACKUP_ENABLED=%s\n' "$NODE_ID" "$BACKUP_ENABLED"
	exit 0
	;;
*)
	printf 'BACKUP_ENABLED must be true or false\n' >&2
	exit 1
	;;
esac

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
csv_has() {
	local list=",${1//[[:space:]]/},"
	[[ "$list" == *",$2,"* ]]
}
NODE_TAG="node:$NODE_ID"
newapi_enabled=0
newapi_manifest="$CONTROL_ROOT/current/apps/newapi/manifest.env"
newapi_policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$newapi_manifest" 2>/dev/null | tail -n1 || true)"
newapi_policy="$CONTROL_ROOT/current/config/$newapi_policy_rel"
[[ "$(env_value ENABLED "$newapi_policy")" == true ]] && newapi_enabled=1
NEW_API_BACKUP_NODE_ID="$(env_value NEW_API_BACKUP_NODE_ID "$newapi_policy")"
NEW_API_BACKUP_NODE_ID="${NEW_API_BACKUP_NODE_ID:-$NODE_ID}"
if ((newapi_enabled == 1)) && [[ -f "$CLUSTER_POLICY_FILE" ]]; then
	csv_has "$(env_value NODES "$newapi_policy")" "$NEW_API_BACKUP_NODE_ID" || {
		printf 'NEW_API_BACKUP_NODE_ID is absent from New API placement: %s\n' "$NEW_API_BACKUP_NODE_ID" >&2
		exit 1
	}
fi
librechat_manifest="$CONTROL_ROOT/current/apps/librechat/manifest.env"
librechat_policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$librechat_manifest" 2>/dev/null | tail -n1 || true)"
librechat_policy="$CONTROL_ROOT/current/config/$librechat_policy_rel"
librechat_enabled=0
if [[ -f "$librechat_manifest" && "$(env_value ENABLED "$librechat_policy")" == true ]]; then
	librechat_enabled=1
fi
librechat_nodes="$(env_value NODES "$librechat_policy")"
LIBRECHAT_MONGO_BACKUP_ENABLED="$(env_value MONGO_BACKUP_ENABLED "$librechat_policy")"
LIBRECHAT_MONGO_BACKUP_ENABLED="${LIBRECHAT_MONGO_BACKUP_ENABLED:-false}"
LIBRECHAT_MONGO_BACKUP_NODE_ID="$(env_value MONGO_BACKUP_NODE_ID "$librechat_policy")"
LIBRECHAT_MONGO_BACKUP_NODE_ID="${LIBRECHAT_MONGO_BACKUP_NODE_ID:-${librechat_nodes%%,*}}"
LIBRECHAT_MONGO_BACKUP_NODE_ID="${LIBRECHAT_MONGO_BACKUP_NODE_ID:-$NODE_ID}"
if ((librechat_enabled == 1)) && truthy "$LIBRECHAT_MONGO_BACKUP_ENABLED" && [[ -f "$CLUSTER_POLICY_FILE" ]]; then
	csv_has "$librechat_nodes" "$LIBRECHAT_MONGO_BACKUP_NODE_ID" || {
		printf 'MONGO_BACKUP_NODE_ID is absent from LibreChat placement: %s\n' "$LIBRECHAT_MONGO_BACKUP_NODE_ID" >&2
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
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$(env_value RESTIC_CACHE_DIR)}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/llm-hub-lite/restic}"
RESTIC_READ_CONCURRENCY="${RESTIC_READ_CONCURRENCY:-$(env_value RESTIC_READ_CONCURRENCY)}"
RESTIC_READ_CONCURRENCY="${RESTIC_READ_CONCURRENCY:-1}"
RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-$(env_value RESTIC_COMPRESSION)}"
RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-auto}"
RESTIC_SKIP_IF_UNCHANGED="${RESTIC_SKIP_IF_UNCHANGED:-$(env_value RESTIC_SKIP_IF_UNCHANGED)}"
RESTIC_SKIP_IF_UNCHANGED="${RESTIC_SKIP_IF_UNCHANGED:-true}"
RESTIC_NICE_LEVEL="${RESTIC_NICE_LEVEL:-$(env_value RESTIC_NICE_LEVEL)}"
RESTIC_NICE_LEVEL="${RESTIC_NICE_LEVEL:-10}"
RESTIC_IONICE_ENABLED="${RESTIC_IONICE_ENABLED:-$(env_value RESTIC_IONICE_ENABLED)}"
RESTIC_IONICE_ENABLED="${RESTIC_IONICE_ENABLED:-true}"
RESTIC_IONICE_CLASS="${RESTIC_IONICE_CLASS:-$(env_value RESTIC_IONICE_CLASS)}"
RESTIC_IONICE_CLASS="${RESTIC_IONICE_CLASS:-2}"
RESTIC_IONICE_LEVEL="${RESTIC_IONICE_LEVEL:-$(env_value RESTIC_IONICE_LEVEL)}"
RESTIC_IONICE_LEVEL="${RESTIC_IONICE_LEVEL:-7}"
RESTIC_SCHEDULE_INTERVAL="${RESTIC_SCHEDULE_INTERVAL:-$(env_value RESTIC_SCHEDULE_INTERVAL)}"
RESTIC_SCHEDULE_INTERVAL="${RESTIC_SCHEDULE_INTERVAL:-3600}"
RESTIC_SCHEDULE_MARKER="${RESTIC_SCHEDULE_MARKER:-/run/llm-hub-lite/restic-scheduled.timestamp}"
NEW_API_SQL_DSN="${NEW_API_SQL_DSN:-$(env_value NEW_API_SQL_DSN)}"
LIBRECHAT_MONGO_URI="${LIBRECHAT_MONGO_URI:-$(env_value LIBRECHAT_MONGO_URI)}"
WOODPECKER_DATA_ROOT="${WOODPECKER_DATA_ROOT:-$PLATFORM_ROOT/woodpecker/data}"
BESZEL_DATA_ROOT="${BESZEL_DATA_ROOT:-$PLATFORM_ROOT/beszel/hub}"
CADDY_DATA_ROOT="${CADDY_DATA_ROOT:-$PLATFORM_ROOT/caddy}"
OBSERVER_DATA_ROOT="${OBSERVER_DATA_ROOT:-$(observer_env_value OBSERVER_DATA_ROOT)}"
OBSERVER_DATA_ROOT="${OBSERVER_DATA_ROOT:-$PLATFORM_ROOT/observer}"
safe_observer_data_root() {
	case "$1" in
	"$PLATFORM_ROOT"/*)
		[[ "$1" != "$PLATFORM_ROOT/" && "$1" != *..* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
		;;
	*) return 1 ;;
	esac
}
safe_observer_data_root "$OBSERVER_DATA_ROOT" || {
	printf 'OBSERVER_DATA_ROOT must be a non-root path below %s: %s\n' "$PLATFORM_ROOT" "$OBSERVER_DATA_ROOT" >&2
	exit 1
}
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
install -d -m 700 "$RESTIC_CACHE_DIR"
normalize_restic_compression() {
	local requested="${RESTIC_COMPRESSION:-auto}" modes
	case "$requested" in
	auto | off | max | fastest | better) ;;
	*)
		printf 'invalid RESTIC_COMPRESSION: %s (expected auto, off, max, fastest, or better)\n' "$requested" >&2
		exit 1
		;;
	esac
	modes="$(restic backup --help 2>&1 | sed -n 's/.*one of (\([^)]*\)).*/\1/p' | head -n1)"
	case "|$modes|" in
	*"|$requested|"*)
		return 0
		;;
	esac
	case "$requested" in
	fastest | better | max)
		printf 'Restic does not support compression mode %s; falling back to auto\n' "$requested" >&2
		RESTIC_COMPRESSION=auto
		modes="$(restic backup --help 2>&1 | sed -n 's/.*one of (\([^)]*\)).*/\1/p' | head -n1)"
		case "|$modes|" in
		*"|auto|"*) ;;
		*)
			printf 'installed Restic does not support compression mode auto\n' >&2
			exit 1
			;;
		esac
		;;
	*)
		printf 'installed Restic does not support compression mode: %s\n' "$requested" >&2
		exit 1
		;;
	esac
}
normalize_restic_compression
restic_skip_if_unchanged_supported=0
if truthy "$RESTIC_SKIP_IF_UNCHANGED"; then
	if restic backup --help 2>&1 | grep -q -- '--skip-if-unchanged'; then
		restic_skip_if_unchanged_supported=1
	else
		printf 'Restic does not support --skip-if-unchanged; continuing without it\n' >&2
		RESTIC_SKIP_IF_UNCHANGED=false
	fi
fi
[[ "$RESTIC_READ_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || {
	printf 'invalid RESTIC_READ_CONCURRENCY: %s\n' "$RESTIC_READ_CONCURRENCY" >&2
	exit 1
}
[[ "$RESTIC_NICE_LEVEL" =~ ^[0-9]+$ && "$RESTIC_IONICE_CLASS" =~ ^[0-9]+$ && "$RESTIC_IONICE_LEVEL" =~ ^[0-9]+$ ]] || {
	printf 'invalid Restic priority settings\n' >&2
	exit 1
}
[[ "$RESTIC_SCHEDULE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
	printf 'invalid RESTIC_SCHEDULE_INTERVAL: %s\n' "$RESTIC_SCHEDULE_INTERVAL" >&2
	exit 1
}
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE" RESTIC_CACHE_DIR RESTIC_READ_CONCURRENCY RESTIC_COMPRESSION
restic_run() {
	if truthy "$RESTIC_IONICE_ENABLED" && command -v ionice >/dev/null 2>&1; then
		if command -v nice >/dev/null 2>&1; then
			ionice -c "$RESTIC_IONICE_CLASS" -n "$RESTIC_IONICE_LEVEL" nice -n "$RESTIC_NICE_LEVEL" restic "$@"
		else
			ionice -c "$RESTIC_IONICE_CLASS" -n "$RESTIC_IONICE_LEVEL" restic "$@"
		fi
	elif command -v nice >/dev/null 2>&1; then
		nice -n "$RESTIC_NICE_LEVEL" restic "$@"
	else
		restic "$@"
	fi
}
restic_backup() {
	local -a options
	options=(--tag platform --tag "$NODE_TAG" --tag "$reason")
	((restic_skip_if_unchanged_supported)) && options+=(--skip-if-unchanged)
	restic_run backup --compression "$RESTIC_COMPRESSION" "${options[@]}" "$@"
}
scheduled_snapshot_recent() {
	local last now
	[[ "$operation" == snapshot && "$reason" == scheduled ]] || return 1
	[[ -r "$RESTIC_SCHEDULE_MARKER" ]] || return 1
	last="$(cat "$RESTIC_SCHEDULE_MARKER" 2>/dev/null || true)"
	[[ "$last" =~ ^[0-9]+$ ]] || return 1
	now="$(date +%s)"
	((now >= last && now - last < RESTIC_SCHEDULE_INTERVAL))
}
if scheduled_snapshot_recent; then
	printf 'scheduled backup skipped: last snapshot is less than %s seconds old\n' "$RESTIC_SCHEDULE_INTERVAL"
	exit 0
fi
if [[ ! -f "$REPO/config" ]]; then restic_run init >/dev/null; fi
remote_restic() {
	[[ -n "$RESTIC_REMOTE_REPOSITORY" ]] || {
		printf 'RESTIC_REMOTE_REPOSITORY is required when remote backups are enabled\n' >&2
		return 1
	}
	[[ -s "$RESTIC_REMOTE_PASSWORD_FILE" ]] || {
		printf 'missing remote Restic password file: %s\n' "$RESTIC_REMOTE_PASSWORD_FILE" >&2
		return 1
	}
	RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE" restic_run "$@"
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
			[[ -f "$target" ]] &&
			sqlite3 "$target" 'PRAGMA integrity_check;' | grep -qx ok; then return 0; fi
		delay=$((attempt * 2))
		printf 'SQLite backup retry %s/5 for %s in %s seconds\n' "$attempt" "$source" "$delay" >&2
		sleep "$delay"
	done
	printf 'SQLite backup failed after retries: %s\n' "$source" >&2
	return 1
}

backup_pglite() {
	local source="$1" target="$2" tmp
	[[ -d "$source" ]] || return 0
	install -d -m 700 "$(dirname "$target")"
	tmp="${target}.tmp"
	rm -rf -- "$tmp"
	cp -a -- "$source" "$tmp" || {
		rm -rf -- "$tmp"
		printf 'PGlite backup failed: %s\n' "$source" >&2
		return 1
	}
	rm -rf -- "$target"
	mv -- "$tmp" "$target"
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
	((librechat_enabled == 1)) || {
		printf 'MongoDB Atlas export skipped: LibreChat is disabled by cluster policy\n'
		return 0
	}
	truthy "$LIBRECHAT_MONGO_BACKUP_ENABLED" || {
		printf 'MongoDB Atlas export skipped: set MONGO_BACKUP_ENABLED=true in config/cluster/apps/librechat.policy to enable it\n'
		return 0
	}
	[[ "$NODE_ID" == "$LIBRECHAT_MONGO_BACKUP_NODE_ID" ]] || {
		printf 'MongoDB Atlas export skipped: backup owner is %s (local node=%s)\n' "$LIBRECHAT_MONGO_BACKUP_NODE_ID" "$NODE_ID"
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
	local -a stopped_pglite_apps=()
	restart_stopped_pglite() {
		local app descriptor
		for app in "${stopped_pglite_apps[@]-}"; do
			[[ -n "$app" ]] || continue
			descriptor="$APPS_ROOT/$app"
			if [[ ! -f "$descriptor/manifest.env" ]]; then
				printf 'PGlite app descriptor disappeared during backup: %s\n' "$descriptor" >&2
				return 1
			fi
			# Singleton reconciliation is normally suppressed during cluster-wide
			# operations. Force this explicitly stopped app back up and retry once;
			# a successful backup must never leave its workload offline.
			if ! PLATFORM_FORCE_SINGLETON_ACTION=1 PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start "app:$descriptor"; then
				printf 'retrying PGlite app restart after backup: %s\n' "$app" >&2
				PLATFORM_FORCE_SINGLETON_ACTION=1 PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start "app:$descriptor" || {
					printf 'PGlite app remained stopped after backup: %s\n' "$app" >&2
					return 1
				}
			fi
		done
	}
	cleanup_snapshot() {
		restart_stopped_pglite
		find "$STAGE_ROOT" -mindepth 1 -delete 2>/dev/null || true
	}
	install -d -m 700 "$STAGE_ROOT"
	find "$STAGE_ROOT" -mindepth 1 -delete 2>/dev/null || true
	install -d -m 700 "$STAGE_ROOT/sqlite" "$STAGE_ROOT/pglite"
	trap cleanup_snapshot EXIT

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
		if [[ "$(descriptor_value "$descriptor" STATE_MODE)" == pglite ]]; then
			pglite_rel="$(descriptor_value "$descriptor" PGLITE_PATH_REL)"
			safe_relative "$pglite_rel" || {
				printf 'unsafe PGLITE_PATH_REL in %s\n' "$descriptor" >&2
				return 1
			}
			source="$DATA_ROOT/$data_rel/$pglite_rel"
			target="$STAGE_ROOT/pglite/$app_id"
			project="$(descriptor_value "$descriptor" COMPOSE_PROJECT)"
			if [[ "$NODE_ID" != leader && "$(descriptor_value "$descriptor" UPSTREAM_MODE)" == singleton && "$(env_value NODES "$CONTROL_ROOT/current/config/cluster/apps/$app_id.policy")" == "$NODE_ID" ]]; then
				if running_ids="$(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null)" && [[ -n "$running_ids" ]]; then
					PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop "app:$descriptor" || return 1
					stopped_pglite_apps+=("$app_id")
				fi
			fi
			backup_pglite "$source" "$target" || return 1
			[[ -d "$target" ]] && printf '%s\t%s\t%s\n' "$app_id" "$data_rel" "$pglite_rel" >>"$STAGE_ROOT/pglite/map.tsv"
		fi
	done < <(descriptor_ids)
	restart_stopped_pglite
	stopped_pglite_apps=()
	backup_sqlite "$WOODPECKER_DATA_ROOT/woodpecker.sqlite" "$STAGE_ROOT/sqlite/woodpecker.sqlite"
	# OpenObserve keeps its metadata catalog in SQLite beneath the mounted data
	# directory.  Back it up through SQLite's online backup API rather than
	# copying the live database/WAL files as part of the raw Observer tree.
	backup_sqlite "$OBSERVER_DATA_ROOT/data/db/metadata.sqlite" "$STAGE_ROOT/sqlite/observer-metadata.sqlite"
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

	local -a paths existing excludes ephemeral_excludes
	paths=(
		"$DATA_ROOT" "$APP_ROOT/shared/.env.prod" "$APP_ROOT/shared/runtime"
		"$APP_ROOT/current" "$APP_ROOT/previous" "$CONTROL_ROOT/current" "$CONTROL_ROOT/previous"
		"$CONTROL_ROOT/releases" "$CONTROL_ROOT/descriptors" "$FOUNDATION_ROOT" "$CADDY_DATA_ROOT" "$OBSERVER_DATA_ROOT"
		"$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/beszel" "$CONFIG_ROOT/platform.env"
		"$CONFIG_ROOT/images.apps.env" "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/control-sync.state"
		"$CONFIG_ROOT/images.apps.previous.env" "$CONFIG_ROOT/images.foundation.previous.env"
		"$CONFIG_ROOT/image-history" "$CONFIG_ROOT/singleton-state" "$CONFIG_ROOT/beszel-initial-credentials" "$CONFIG_ROOT/beszel-enrollment.env" "$CONFIG_ROOT/shared-secrets.env" "$CONFIG_ROOT/node.env" "$CONFIG_ROOT/deploy-key" "$CONFIG_ROOT/known_hosts" "$CONFIG_ROOT/github-token" "$CONFIG_ROOT/restic-password" "$RESTIC_REMOTE_PASSWORD_FILE" "$RESTIC_REMOTE_ENV_FILE" "$STAGE_ROOT/sqlite" "$STAGE_ROOT/pglite" "$STAGE_ROOT/postgres" "$STAGE_ROOT/mongodb" "$STAGE_ROOT/manifest.txt"
	)
	while IFS= read -r descriptor; do
		runtime_rel="$(descriptor_value "$descriptor" RUNTIME_ENV_FILE)"
		[[ -n "$runtime_rel" ]] || continue
		safe_relative "$runtime_rel" || {
			printf 'unsafe runtime env path in app manifest: %s\n' "$descriptor" >&2
			return 1
		}
		paths+=("$CONFIG_ROOT/$runtime_rel")
	done < <(descriptor_ids)
	existing=()
	for path in "${paths[@]}"; do [[ -e "$path" || -L "$path" ]] && existing+=("$path"); done
	ephemeral_excludes=()
	while IFS= read -r descriptor; do
		data_rel="$(descriptor_value "$descriptor" DATA_ROOT_REL)"
		ephemeral_rel="$(descriptor_value "$descriptor" EPHEMERAL_DATA_REL)"
		[[ -n "$ephemeral_rel" ]] || continue
		safe_relative "$data_rel" || {
			printf 'unsafe DATA_ROOT_REL in %s\n' "$descriptor" >&2
			return 1
		}
		safe_relative "$ephemeral_rel" || {
			printf 'unsafe EPHEMERAL_DATA_REL in %s\n' "$descriptor" >&2
			return 1
		}
		ephemeral_excludes+=(--exclude "$DATA_ROOT/$data_rel/$ephemeral_rel")
	done < <(descriptor_ids)
	while IFS= read -r descriptor; do
		[[ "$(descriptor_value "$descriptor" STATE_MODE)" == pglite ]] || continue
		data_rel="$(descriptor_value "$descriptor" DATA_ROOT_REL)"
		pglite_rel="$(descriptor_value "$descriptor" PGLITE_PATH_REL)"
		safe_relative "$data_rel" || {
			printf 'unsafe PGlite path in %s\n' "$descriptor" >&2
			return 1
		}
		safe_relative "$pglite_rel" || {
			printf 'unsafe PGlite path in %s\n' "$descriptor" >&2
			return 1
		}
		ephemeral_excludes+=(--exclude "$DATA_ROOT/$data_rel/$pglite_rel")
	done < <(descriptor_ids)
	excludes=(
		--exclude "$DATA_ROOT/*.db" --exclude "$DATA_ROOT/*.db-*" --exclude "$DATA_ROOT/*.sqlite" --exclude "$DATA_ROOT/*.sqlite-*"
		--exclude "$DATA_ROOT/**/*.db" --exclude "$DATA_ROOT/**/*.db-*" --exclude "$DATA_ROOT/**/*.sqlite" --exclude "$DATA_ROOT/**/*.sqlite-*"
		--exclude "$WOODPECKER_DATA_ROOT/*.db" --exclude "$WOODPECKER_DATA_ROOT/*.db-*" --exclude "$WOODPECKER_DATA_ROOT/*.sqlite" --exclude "$WOODPECKER_DATA_ROOT/*.sqlite-*"
		--exclude "$WOODPECKER_DATA_ROOT/**/*.db" --exclude "$WOODPECKER_DATA_ROOT/**/*.db-*" --exclude "$WOODPECKER_DATA_ROOT/**/*.sqlite" --exclude "$WOODPECKER_DATA_ROOT/**/*.sqlite-*"
		--exclude "$BESZEL_DATA_ROOT/*.db" --exclude "$BESZEL_DATA_ROOT/*.db-*" --exclude "$BESZEL_DATA_ROOT/*.sqlite" --exclude "$BESZEL_DATA_ROOT/*.sqlite-*"
		--exclude "$BESZEL_DATA_ROOT/**/*.db" --exclude "$BESZEL_DATA_ROOT/**/*.db-*" --exclude "$BESZEL_DATA_ROOT/**/*.sqlite" --exclude "$BESZEL_DATA_ROOT/**/*.sqlite-*"
		--exclude "$OBSERVER_DATA_ROOT/data/db/metadata.sqlite*"
		--exclude "$OBSERVER_DATA_ROOT/collector-buffer"
	)
	if ((${#ephemeral_excludes[@]} > 0)); then excludes+=("${ephemeral_excludes[@]}"); fi
	check_remote_repository
	restic_backup "${excludes[@]}" "${existing[@]}"
	if remote_enabled; then
		RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE" restic_backup "${excludes[@]}" "${existing[@]}"
	fi
	if [[ "$operation" == snapshot && "$reason" == scheduled ]]; then
		install -d -m 700 "$(dirname "$RESTIC_SCHEDULE_MARKER")"
		printf '%s\n' "$(date +%s)" >"$RESTIC_SCHEDULE_MARKER"
		chmod 600 "$RESTIC_SCHEDULE_MARKER"
	fi
	printf 'backup snapshot complete: repository=%s reason=%s\n' "$REPO" "$reason"
}

warn_local_only
case "$operation" in
snapshot) snapshot ;;
prune)
	check_remote_repository
	restic_run forget --tag "platform,$NODE_TAG" --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
	remote_enabled && remote_restic forget --tag "platform,$NODE_TAG" --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
	printf 'backup retention/prune complete\n'
	;;
check)
	check_remote_repository
	restic_run check
	remote_enabled && remote_restic check
	printf 'backup repository check complete\n'
	;;
*)
	printf 'usage: backup-platform {snapshot [reason]|prune|check}\n' >&2
	exit 2
	;;
esac
