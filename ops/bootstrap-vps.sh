#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$-" == *x* ]]; then
	set +x
	printf 'WARNING: shell xtrace was disabled before loading secrets.\n' >&2
fi
[[ "$EUID" -eq 0 ]] || {
	printf 'Run bootstrap as root.\n' >&2
	exit 1
}
umask 077

REPO_URL="${REPO_URL:-https://github.com/uptonking/llm-hub-lite.git}"
REPO_SLUG="${REPO_SLUG:-uptonking/llm-hub-lite}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-first}"
BOOTSTRAP_SKIP_POST_BACKUP="${BOOTSTRAP_SKIP_POST_BACKUP:-0}"
BOOTSTRAP_RELEASE_SHA="${BOOTSTRAP_RELEASE_SHA:-}"
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/source}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
PLATFORM_LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
NODE_ID="${NODE_ID:-}"
LEADER_PUBLIC_IP="${LEADER_PUBLIC_IP:-}"
BESZEL_ENROLLMENT_BUNDLE_B64="${BESZEL_ENROLLMENT_BUNDLE_B64:-}"
OBSERVER_ROOT_USER_EMAIL="${OBSERVER_ROOT_USER_EMAIL:-}"
OBSERVER_ROOT_USER_PASSWORD="${OBSERVER_ROOT_USER_PASSWORD:-}"
OBSERVER_INGEST_USER="${OBSERVER_INGEST_USER:-}"
OBSERVER_INGEST_TOKEN="${OBSERVER_INGEST_TOKEN:-}"
WOODPECKER_AGENT_SECRET="${WOODPECKER_AGENT_SECRET:-}"
WOODPECKER_GRPC_SECRET="${WOODPECKER_GRPC_SECRET:-}"
WOODPECKER_GITHUB_CLIENT="${WOODPECKER_GITHUB_CLIENT:-}"
WOODPECKER_GITHUB_SECRET="${WOODPECKER_GITHUB_SECRET:-}"
DEPLOY_SSH_KEY_FILE="${DEPLOY_SSH_KEY_FILE:-}"
DEPLOY_KNOWN_HOSTS_FILE="${DEPLOY_KNOWN_HOSTS_FILE:-}"
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-${PLATFORM_GITHUB_TOKEN_FILE:-}}"
SHARED_SECRET_BUNDLE_FILE="${SHARED_SECRET_BUNDLE_FILE:-${PLATFORM_SECRET_BUNDLE_FILE:-$CONFIG_ROOT/shared-secrets.env}}"
app_env="$APP_ROOT/shared/.env.prod"
woodpecker_env="$PLATFORM_ROOT/foundation/env/woodpecker.env"
observer_env="$PLATFORM_ROOT/foundation/env/observer.env"
runtime_setting() {
	local key="$1"
	[[ -r "$app_env" ]] || return 0
	sed -n "s/^${key}=//p" "$app_env" 2>/dev/null | tail -n1 || true
}
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-admin@$DOMAIN_NAME}"
WOODPECKER_REPO_OWNERS="${WOODPECKER_REPO_OWNERS:-${REPO_SLUG%%/*}}"
WOODPECKER_AGENT_LABELS="${WOODPECKER_AGENT_LABELS:-node=${NODE_ID:-unknown},deployment=true,target=production,repo=$REPO_SLUG}"
WOODPECKER_DEPLOYER_LABELS="${WOODPECKER_DEPLOYER_LABELS:-node=${NODE_ID:-unknown},deployment=true,target=production,repo=$REPO_SLUG}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-${REPO_SLUG%%/*}}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.33.0}"
COMPOSE_SHA256_AMD64="${COMPOSE_SHA256_AMD64:-6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee}"
COMPOSE_SHA256_ARM64="${COMPOSE_SHA256_ARM64:-03a42a0fc0614ffc3c9ebca521cab75e02c427b68e45e3f6867d9510b9a28818}"
COMPOSE_SHA256_OVERRIDE="${COMPOSE_SHA256:-}"
COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}"
RESTIC_REMOTE_ENABLED="${RESTIC_REMOTE_ENABLED:-false}"
RESTIC_REMOTE_REPOSITORY="${RESTIC_REMOTE_REPOSITORY:-}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$CONFIG_ROOT/restic-remote-password}"
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$CONFIG_ROOT/restic-remote.env}"
RESTIC_REMOTE_ENV_SOURCE_FILE="${RESTIC_REMOTE_ENV_SOURCE_FILE:-}"
PRODUCTION_REQUIRE_REMOTE_BACKUP="${PRODUCTION_REQUIRE_REMOTE_BACKUP:-false}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/llm-hub-lite/restic}"
RESTIC_READ_CONCURRENCY="${RESTIC_READ_CONCURRENCY:-1}"
RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-$(runtime_setting RESTIC_COMPRESSION)}"
RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-auto}"
RESTIC_SKIP_IF_UNCHANGED="${RESTIC_SKIP_IF_UNCHANGED:-$(runtime_setting RESTIC_SKIP_IF_UNCHANGED)}"
RESTIC_SKIP_IF_UNCHANGED="${RESTIC_SKIP_IF_UNCHANGED:-true}"
RESTIC_NICE_LEVEL="${RESTIC_NICE_LEVEL:-10}"
RESTIC_IONICE_ENABLED="${RESTIC_IONICE_ENABLED:-true}"
RESTIC_IONICE_CLASS="${RESTIC_IONICE_CLASS:-2}"
RESTIC_IONICE_LEVEL="${RESTIC_IONICE_LEVEL:-7}"
RESTIC_SCHEDULE_INTERVAL="${RESTIC_SCHEDULE_INTERVAL:-3600}"
LOW_MEMORY_SWAP_ENABLED="${LOW_MEMORY_SWAP_ENABLED:-true}"
LOW_MEMORY_SWAPFILE="${LOW_MEMORY_SWAPFILE:-/swapfile}"
LOW_MEMORY_SWAP_SIZE="${LOW_MEMORY_SWAP_SIZE:-1G}"
LOW_MEMORY_SWAP_SWAPPINESS="${LOW_MEMORY_SWAP_SWAPPINESS:-10}"
edge_network="${PLATFORM_EDGE_NETWORK:-platform_edge}"
SSH_PORT="${SSH_PORT:-}"
BOOTSTRAP_SYSTEMD_WAIT_SECONDS="${BOOTSTRAP_SYSTEMD_WAIT_SECONDS:-8}"
BOOTSTRAP_ENDPOINT_RETRIES="${BOOTSTRAP_ENDPOINT_RETRIES:-1}"
BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS="${BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS:-10}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}
bootstrap_error() {
	local status="$?" line="${BASH_LINENO[0]:-0}"
	# Do not print BASH_COMMAND: bootstrap commands can contain credentials.
	# A line number and exit status are enough to correlate a failed run with
	# the reviewed script while keeping SSH output safe to share.
	printf 'ERROR: bootstrap failed at line %s (exit status %s)\n' "$line" "$status" >&2
	exit "$status"
}
trap bootstrap_error ERR
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
truthy() { [[ "$1" == true || "$1" == TRUE || "$1" == 1 ]]; }
[[ "$BOOTSTRAP_SYSTEMD_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die 'BOOTSTRAP_SYSTEMD_WAIT_SECONDS must be an integer'
((BOOTSTRAP_SYSTEMD_WAIT_SECONDS <= 60)) || die 'BOOTSTRAP_SYSTEMD_WAIT_SECONDS must be between 0 and 60 seconds'
[[ "$BOOTSTRAP_ENDPOINT_RETRIES" =~ ^[0-9]+$ ]] || die 'BOOTSTRAP_ENDPOINT_RETRIES must be an integer'
((BOOTSTRAP_ENDPOINT_RETRIES <= 3)) || die 'BOOTSTRAP_ENDPOINT_RETRIES must be between 0 and 3'
[[ "$BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die 'BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS must be an integer'
((BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS >= 1 && BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS <= 60)) || die 'BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS must be between 1 and 60 seconds'
[[ "$BOOTSTRAP_SKIP_POST_BACKUP" == 0 || "$BOOTSTRAP_SKIP_POST_BACKUP" == 1 ]] || die 'BOOTSTRAP_SKIP_POST_BACKUP must be 0 or 1'
if [[ -n "$BOOTSTRAP_RELEASE_SHA" ]]; then
	[[ "$BOOTSTRAP_RELEASE_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || die 'BOOTSTRAP_RELEASE_SHA must be a full 40-character hexadecimal Git commit'
fi
start_platform_target() {
	local wait_seconds="$1" elapsed=0 state
	# Recovery is already performed by the foreground sync above. Queue the
	# boot target asynchronously so an unhealthy consumer cannot hold an
	# interactive bootstrap open for systemd's long recovery timeout.
	if ! systemctl start --no-block platform.target; then
		printf 'ERROR: unable to queue platform.target; inspect systemd status\n' >&2
		systemctl status platform.target platform-network.service platform-recovery.service --no-pager -l >&2 || true
		return 1
	fi
	while ((elapsed < wait_seconds)); do
		state="$(systemctl is-active platform.target 2>/dev/null || true)"
		case "$state" in
		active) return 0 ;;
		failed | inactive | deactivating)
			printf 'WARNING: platform.target entered %s state; recovery will retry via its timer\n' "$state" >&2
			systemctl status platform.target platform-network.service platform-recovery.service --no-pager -l >&2 || true
			return 0
			;;
		esac
		sleep 1
		elapsed=$((elapsed + 1))
	done
	printf 'platform.target queued; recovery continues in the background\n' >&2
}
safe_observer_data_root() {
	local root="$1"
	case "$root" in
	"$PLATFORM_ROOT"/*)
		[[ "$root" != "$PLATFORM_ROOT/" && "$root" != *..* && "$root" != *$'\n'* && "$root" != *$'\r'* ]]
		;;
	*)
		return 1
		;;
	esac
}
remote_enabled() { truthy "$RESTIC_REMOTE_ENABLED"; }
csv_contains() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
bootstrap_foundation_enabled() {
	local component="$1" manifest roles policy_rel enabled mandatory
	manifest="$bootstrap_tree/compose/foundation/manifests/$component.env"
	[[ -f "$manifest" ]] || return 1
	roles="$(sed -n 's/^ROLES=//p' "$manifest" | tail -n1)"
	csv_contains "$roles" "$NODE_ROLE" || return 1
	policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"
	enabled="$(sed -n 's/^ENABLED=//p' "$bootstrap_tree/config/$policy_rel" | tail -n1)"
	mandatory="$(sed -n 's/^MANDATORY=//p' "$manifest" | tail -n1)"
	[[ "$mandatory" != true || "$enabled" == true ]] || die "mandatory foundation service is disabled: $component"
	[[ "$enabled" == true ]]
}
pull_image() {
	local image="$1" attempt
	for attempt in 1 2 3 4 5; do
		if docker pull "$image"; then
			return 0
		fi
		((attempt < 5)) || die "unable to pull image after $attempt attempts: $image"
		printf 'Image pull failed; retrying in %s seconds (attempt %s/5): %s\n' "$((attempt * 5))" "$attempt" "$image" >&2
		sleep "$((attempt * 5))"
	done
}
normalize_restic_compression() {
	local requested="${RESTIC_COMPRESSION:-auto}" modes
	case "$requested" in
	auto | off | max | fastest | better) ;;
	*) die "invalid RESTIC_COMPRESSION: $requested (expected auto, off, max, fastest, or better)" ;;
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
		*) die 'installed Restic does not support compression mode auto' ;;
		esac
		;;
	*) die "installed Restic does not support compression mode: $requested" ;;
	esac
}
normalize_restic_features() {
	normalize_restic_compression
	if truthy "$RESTIC_SKIP_IF_UNCHANGED" && ! restic backup --help 2>&1 | grep -q -- '--skip-if-unchanged'; then
		printf 'Restic does not support --skip-if-unchanged; continuing without it\n' >&2
		RESTIC_SKIP_IF_UNCHANGED=false
	fi
}
image_key_declared() {
	local key="$1" manifest image_key
	for manifest in "$bootstrap_tree"/compose/foundation/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		for image_key in $(sed -n 's/^IMAGE_KEYS=//p' "$manifest" | tail -n1); do
			[[ "$image_key" == "$key" ]] && return 0
		done
	done
	while IFS= read -r manifest; do
		while IFS= read -r image_key; do
			[[ "$image_key" == "$key" ]] && return 0
		done < <(sed -n 's/^IMAGE_KEYS=//p' "$manifest" | tail -n1 | tr ' ' '\n')
	done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
	return 1
}
image_required() {
	local key="$1" manifest image_key app_id component
	image_key_declared "$key" || die "image key is not declared by a manifest: $key"
	for manifest in "$bootstrap_tree"/compose/foundation/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		component="$(sed -n 's/^COMPONENT_ID=//p' "$manifest" | tail -n1)"
		for image_key in $(sed -n 's/^IMAGE_KEYS=//p' "$manifest" | tail -n1); do
			[[ "$image_key" == "$key" ]] || continue
			bootstrap_foundation_enabled "$component" && return 0
		done
	done
	while IFS= read -r manifest; do
		while IFS= read -r image_key; do
			[[ "$image_key" == "$key" ]] || continue
			app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
			app_active_on_node "$app_id" && return 0
		done < <(sed -n 's/^IMAGE_KEYS=//p' "$manifest" | tail -n1 | tr ' ' '\n')
	done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
	return 1
}
valid_ipv4() {
	local ip="$1" octet
	local -a octets
	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS=. read -r -a octets <<<"$ip"
	[[ "${#octets[@]}" -eq 4 ]] || return 1
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
	done
}
[[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid REPO_SLUG: $REPO_SLUG"
case "$BOOTSTRAP_MODE" in
first | repair) ;;
*) die "BOOTSTRAP_MODE must be first or repair: $BOOTSTRAP_MODE" ;;
esac
ensure_key() {
	local file="$1" key="$2" value="$3"
	grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"
}
set_derived_key() {
	local file="$1" key="$2" value="$3" previous_domain="$4" prefix="$5" current old_value
	# Missing environment files are expected during first bootstrap. Avoid a
	# pipefail exit from sed(1) before the file is created below.
	current=''
	if [[ -r "$file" ]]; then
		current="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
	fi
	if [[ -z "$current" ]]; then
		ensure_key "$file" "$key" "$value"
		return 0
	fi
	[[ -n "$previous_domain" ]] || return 0
	old_value="${prefix}${previous_domain}"
	[[ "$current" == "$old_value" ]] || return 0
	set_key "$file" "$key" "$value"
}
set_key() {
	local file="$1" key="$2" value="$3" tmp
	install -d -m 700 "$(dirname "$file")"
	tmp="$(mktemp "${file}.tmp.XXXXXX")"
	[[ -f "$file" ]] && sed "/^${key}=/d" "$file" >"$tmp"
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
set_key_if_changed() {
	local file="$1" key="$2" value="$3" current=''
	if [[ -r "$file" ]]; then
		current="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
	fi
	[[ "$current" == "$value" ]] || set_key "$file" "$key" "$value"
}
merge_image_manifest() {
	local source="$1" target="$2" key value
	if [[ ! -s "$target" ]]; then
		install -o root -g root -m 600 "$source" "$target"
		return 0
	fi
	while IFS='=' read -r key value; do
		[[ -n "$key" && "$key" != \#* && -n "$value" ]] || continue
		grep -q "^${key}=" "$target" || printf '%s=%s\n' "$key" "$value" >>"$target"
	done <"$source"
	chmod 600 "$target"
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
				printf 'Removing stale image key from %s: %s\n' "$target" "$key" >&2
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
remove_key() {
	local file="$1" key="$2" tmp
	[[ -f "$file" ]] || return 0
	tmp="$(mktemp "${file}.tmp.XXXXXX")"
	sed "/^${key}=/d" "$file" >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
bundle_value() {
	local key="$1"
	[[ -n "$SHARED_SECRET_BUNDLE_FILE" && -r "$SHARED_SECRET_BUNDLE_FILE" ]] || return 0
	sed -n "s/^${key}=//p" "$SHARED_SECRET_BUNDLE_FILE" | tail -n1
}
load_bundle_value() {
	local key="$1" value
	[[ -n "${!key:-}" ]] && return 0
	value="$(bundle_value "$key")"
	if [[ -n "$value" ]]; then
		printf -v "$key" '%s' "$value"
	fi
	return 0
}
load_runtime_value() {
	local key="$1" file="$2" value
	[[ -n "${!key:-}" ]] && return 0
	[[ -r "$file" ]] || return 0
	value="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
	if [[ -n "$value" ]]; then
		printf -v "$key" '%s' "$value"
	fi
	return 0
}
clear_placeholder() {
	local key="$1" value
	value="${!key:-}"
	case "$value" in replace-with-* | bootstrap-pending | example.invalid | *'<'* | *'>'* | *example.* | *your-upstash* | *account-id*) printf -v "$key" '%s' '' ;; esac
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
	# Keep this deliberately structural: it catches pasted duplicate schemes
	# before the application starts and avoids logging or parsing credentials.
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
valid_input_value() {
	local key="$1" value="$2" min_length="${3:-1}" regex="${4:-}"
	[[ -n "$value" ]] || {
		printf '%s is required and cannot be empty\n' "$key" >&2
		return 1
	}
	[[ "$min_length" =~ ^[1-9][0-9]*$ ]] || {
		printf 'invalid minimum length for %s: %s\n' "$key" "$min_length" >&2
		return 1
	}
	if ((${#value} < min_length)); then
		printf '%s must contain at least %s characters\n' "$key" "$min_length" >&2
		return 1
	fi
	if [[ -n "$regex" && ! "$value" =~ $regex ]]; then
		printf '%s does not match the configured secret format\n' "$key" >&2
		return 1
	fi
	# Secrets and connection strings must never contain C0 controls or DEL.
	# In particular, an arrow key pasted into a prompt can introduce ESC.
	# Use printf rather than a here-string: Bash here-strings append a newline,
	# which would make every otherwise valid value look invalid.
	if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then
		printf '%s contains control characters; enter a clean single-line value\n' "$key" >&2
		return 1
	fi
	if [[ "$key" == LIBRECHAT_MONGO_URI ]] && ! valid_mongo_uri "$value"; then
		printf '%s must be one valid mongodb:// or mongodb+srv:// URI\n' "$key" >&2
		return 1
	fi
}
prompt_available() {
	[[ -r /dev/tty || -t 0 ]]
}
PROMPT_VALUE=''
prompt_read() {
	local prompt="$1" secret="${2:-0}" value=''
	# Use stdin when it is a real terminal or a deliberately supplied pipe. The
	# secret reconciliation loops redirect stdin to process substitutions; only
	# in that case do we read from the controlling TTY instead.
	if [[ -t 0 ]]; then
		if [[ "$secret" == 1 ]]; then
			if IFS= read -r -s -p "$prompt: " value; then
				printf '\n'
				PROMPT_VALUE="$value"
				return 0
			fi
		else
			if IFS= read -r -p "$prompt: " value; then
				PROMPT_VALUE="$value"
				return 0
			fi
		fi
	fi
	if [[ -r /dev/tty ]]; then
		if [[ "$secret" == 1 ]]; then
			if IFS= read -r -s -p "$prompt: " value </dev/tty; then
				printf '\n'
				PROMPT_VALUE="$value"
				return 0
			fi
		else
			if IFS= read -r -p "$prompt: " value </dev/tty; then
				PROMPT_VALUE="$value"
				return 0
			fi
		fi
	fi
	return 1
}
prompt_required() {
	local key="$1" prompt="$2" secret="${3:-0}" min_length="${4:-1}" regex="${5:-}" value
	while :; do
		value="${!key:-}"
		if [[ -n "$value" ]]; then
			if valid_input_value "$key" "$value" "$min_length" "$regex"; then
				return 0
			fi
			prompt_available || die "$key is invalid; provide a clean replacement through the environment or shared secret bundle"
			printf 'Please replace %s with a value containing no control characters.\n' "$key" >&2
			printf -v "$key" '%s' ''
		fi
		if ! prompt_read "$prompt" "$secret"; then die "$key input was not received"; fi
		value="$PROMPT_VALUE"
		if valid_input_value "$key" "$value" "$min_length" "$regex"; then
			printf -v "$key" '%s' "$value"
			return 0
		fi
		printf 'Please enter %s again.\n' "$key" >&2
		test -n "$value" || printf 'The value cannot be empty.\n' >&2
	done
}
manifest_secret_min_length() {
	local manifest="$1" wanted="$2" rule key min_length
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		min_length="${rule#*:}"
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$min_length" =~ ^[1-9][0-9]*$ ]] || die "invalid SECRET_MIN_LENGTHS entry in $manifest: $rule"
		if [[ "$key" == "$wanted" ]]; then
			printf '%s\n' "$min_length"
			return 0
		fi
	done < <(sed -n 's/^SECRET_MIN_LENGTHS=//p' "$manifest" | tail -n1 | tr ',' '\n')
	printf '1\n'
}
manifest_secret_regex() {
	local manifest="$1" wanted="$2" rule key regex
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		regex="${rule#*:}"
		[[ "$key" == "$wanted" ]] && {
			printf '%s\n' "$regex"
			return 0
		}
	done < <(sed -n 's/^SECRET_REGEXES=//p' "$manifest" | tail -n1 | tr ',' '\n')
	printf '\n'
}
manifest_secret_bytes() {
	local manifest="$1" wanted="$2" rule key bytes
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		bytes="${rule#*:}"
		[[ "$key" == "$wanted" ]] && {
			printf '%s\n' "$bytes"
			return 0
		}
	done < <(sed -n 's/^GENERATED_SECRET_BYTES=//p' "$manifest" | tail -n1 | tr ',' '\n')
	printf '32\n'
}
prompt_observer_ingest_token() {
	while :; do
		prompt_required OBSERVER_INGEST_TOKEN 'OpenObserve collector ingestion token' 1
		observer_token_suffix="${OBSERVER_INGEST_TOKEN#o2oi_}"
		if [[ "$OBSERVER_INGEST_TOKEN" == o2oi_* && "${#observer_token_suffix}" -eq 32 && "$observer_token_suffix" != *[!A-Za-z0-9]* ]]; then
			return 0
		fi
		printf 'OBSERVER_INGEST_TOKEN must be an OpenObserve token in the o2oi_<32 characters> format.\n' >&2
		[[ -t 0 ]] || die 'OBSERVER_INGEST_TOKEN is invalid; provide the full token through the environment or shared secret bundle'
		OBSERVER_INGEST_TOKEN=''
	done
}
prompt_observer_ingest_user() {
	while :; do
		prompt_required OBSERVER_INGEST_USER 'OpenObserve collector ingestion username'
		if [[ -n "$OBSERVER_INGEST_USER" && "${#OBSERVER_INGEST_USER}" -le 256 && "$OBSERVER_INGEST_USER" != *[!A-Za-z0-9_-]* ]]; then
			return 0
		fi
		printf 'OBSERVER_INGEST_USER must contain only letters, numbers, hyphens, or underscores.\n' >&2
		[[ -t 0 ]] || die 'OBSERVER_INGEST_USER is invalid; provide a valid name through the environment or shared secret bundle'
		OBSERVER_INGEST_USER=''
	done
}
if [[ -n "$RESTIC_REMOTE_ENV_SOURCE_FILE" ]]; then
	[[ -s "$RESTIC_REMOTE_ENV_SOURCE_FILE" ]] || die "Restic remote environment file does not exist: $RESTIC_REMOTE_ENV_SOURCE_FILE"
	install -o root -g root -m 600 "$RESTIC_REMOTE_ENV_SOURCE_FILE" "$RESTIC_REMOTE_ENV_FILE"
fi
if [[ -s "$RESTIC_REMOTE_ENV_FILE" ]]; then
	set -a
	# shellcheck disable=SC1090
	. "$RESTIC_REMOTE_ENV_FILE"
	set +a
fi
if remote_enabled; then
	prompt_required RESTIC_REMOTE_REPOSITORY 'Remote Restic repository'
	if [[ ! -s "$RESTIC_REMOTE_PASSWORD_FILE" ]]; then
		RESTIC_REMOTE_PASSWORD="${RESTIC_REMOTE_PASSWORD:-}"
		prompt_required RESTIC_REMOTE_PASSWORD 'Remote Restic password' 1
		restic_remote_password="$RESTIC_REMOTE_PASSWORD"
		unset RESTIC_REMOTE_PASSWORD
		install -d -m 700 "$(dirname "$RESTIC_REMOTE_PASSWORD_FILE")"
		printf '%s\n' "$restic_remote_password" >"$RESTIC_REMOTE_PASSWORD_FILE"
		chmod 600 "$RESTIC_REMOTE_PASSWORD_FILE"
	fi
elif truthy "$PRODUCTION_REQUIRE_REMOTE_BACKUP"; then
	die 'production bootstrap requires RESTIC_REMOTE_ENABLED=true'
fi
generate_shared_secret() {
	local key="$1"
	[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(openssl rand -hex 32)"
}
if [[ -z "$LEADER_PUBLIC_IP" && -r "$CONFIG_ROOT/node.env" ]]; then
	LEADER_PUBLIC_IP="$(sed -n 's/^LEADER_PUBLIC_IP=//p' "$CONFIG_ROOT/node.env" 2>/dev/null | tail -n1)"
fi
for shared_key in LEADER_PUBLIC_IP WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET OBSERVER_INGEST_USER OBSERVER_INGEST_TOKEN; do
	load_bundle_value "$shared_key"
done
for shared_key in LEADER_PUBLIC_IP WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET; do
	clear_placeholder "$shared_key"
done
for runtime_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET; do
	load_runtime_value "$runtime_key" "$woodpecker_env"
done
for runtime_key in OBSERVER_ROOT_USER_EMAIL OBSERVER_ROOT_USER_PASSWORD OBSERVER_INGEST_USER OBSERVER_INGEST_TOKEN; do
	load_runtime_value "$runtime_key" "$observer_env"
done
# The default is applied only after the shared bundle and existing foundation
# environment have had a chance to provide a custom collector username. This
# keeps the username and its token paired when Followers bootstrap from the
# Leader's bundle.
OBSERVER_INGEST_USER="${OBSERVER_INGEST_USER:-llm-hub-lite-collector}"
clear_placeholder OBSERVER_INGEST_USER
clear_placeholder OBSERVER_INGEST_TOKEN
install_docker() {
	command -v docker >/dev/null 2>&1 && return 0
	[[ -r /etc/os-release ]] || die 'Docker installation requires /etc/os-release'
	# shellcheck disable=SC1091
	. /etc/os-release
	case "${ID:-}" in ubuntu | debian) ;; *) die "unsupported OS for automatic Docker installation: ${ID:-unknown}" ;; esac
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
	chmod a+r /etc/apt/keyrings/docker.gpg
	printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
		"$(dpkg --print-architecture)" "$ID" "${VERSION_CODENAME:?missing VERSION_CODENAME}" >/etc/apt/sources.list.d/docker.list
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
}

configure_docker_daemon() {
	local daemon_file="${DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}" tmp
	install -d -m 755 "$(dirname "$daemon_file")"
	if [[ -f "$daemon_file" ]]; then
		jq empty "$daemon_file" >/dev/null 2>&1 || die "invalid Docker daemon configuration: $daemon_file"
		jq '. + {"live-restore": true, "log-driver": "local", "log-opts": ((."log-opts" // {}) + {"max-size": "20m", "max-file": "5"})}' \
			"$daemon_file" >"$daemon_file.tmp"
	else
		jq -n '{"live-restore": true, "log-driver": "local", "log-opts": {"max-size": "20m", "max-file": "5"}}' >"$daemon_file.tmp"
	fi
	chmod 644 "$daemon_file.tmp"
	if ! cmp -s "$daemon_file.tmp" "$daemon_file" 2>/dev/null; then
		mv -f -- "$daemon_file.tmp" "$daemon_file"
		systemctl restart docker.service
	else
		rm -f -- "$daemon_file.tmp"
	fi
}

configure_low_memory_swap() {
	truthy "$LOW_MEMORY_SWAP_ENABLED" || return 0
	command -v swapon >/dev/null 2>&1 || return 0
	if swapon --show --noheadings 2>/dev/null | grep -q .; then
		printf 'Active swap detected; leaving existing swap configuration unchanged\n'
		return 0
	fi
	if [[ -e "$LOW_MEMORY_SWAPFILE" ]]; then
		[[ -f "$LOW_MEMORY_SWAPFILE" ]] || die "swap path exists but is not a regular file: $LOW_MEMORY_SWAPFILE"
		command -v swaplabel >/dev/null 2>&1 || die 'swaplabel is required to inspect an existing swap file'
		swaplabel "$LOW_MEMORY_SWAPFILE" >/dev/null 2>&1 || die "existing swap path is not a swap file: $LOW_MEMORY_SWAPFILE"
	else
		command -v fallocate >/dev/null 2>&1 || die 'fallocate is required to create the low-memory swap file'
		command -v mkswap >/dev/null 2>&1 || die 'mkswap is required to create the low-memory swap file'
		fallocate -l "$LOW_MEMORY_SWAP_SIZE" "$LOW_MEMORY_SWAPFILE"
		chmod 600 "$LOW_MEMORY_SWAPFILE"
		mkswap "$LOW_MEMORY_SWAPFILE" >/dev/null
	fi
	chmod 600 "$LOW_MEMORY_SWAPFILE"
	swapon "$LOW_MEMORY_SWAPFILE"
	grep -Fq "$LOW_MEMORY_SWAPFILE none swap" /etc/fstab 2>/dev/null || printf '%s none swap sw,nofail 0 0\n' "$LOW_MEMORY_SWAPFILE" >>/etc/fstab
	install -d -m 755 /etc/sysctl.d
	printf 'vm.swappiness=%s\n' "$LOW_MEMORY_SWAP_SWAPPINESS" >/etc/sysctl.d/99-llm-hub-lite-memory.conf
	sysctl -p /etc/sysctl.d/99-llm-hub-lite-memory.conf >/dev/null
}
detect_ssh_port() {
	if [[ -z "$SSH_PORT" && -n "${SSH_CONNECTION:-}" ]]; then
		SSH_PORT="${SSH_CONNECTION##* }"
	elif [[ -z "$SSH_PORT" ]] && command -v sshd >/dev/null 2>&1; then
		SSH_PORT="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | head -n1)"
	fi
	SSH_PORT="${SSH_PORT:-22}"
	[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die 'SSH_PORT must be a valid TCP port'
	((10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535)) || die 'SSH_PORT must be a valid TCP port'
}
directory_has_entries() { [[ -d "$1" ]] && find "$1" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; }
move_directory_contents() {
	local source="$1" destination="$2" entry name
	directory_has_entries "$source" || return 0
	install -d -m 700 "$destination"
	while IFS= read -r -d '' entry; do
		name="${entry##*/}"
		[[ ! -e "$destination/$name" ]] || die "cannot migrate $source: destination already contains $name"
	done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
	while IFS= read -r -d '' entry; do mv -- "$entry" "$destination/"; done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
	rmdir "$source"
}
migrate_legacy_beszel_layout() {
	local component container
	if ! directory_has_entries "$PLATFORM_ROOT/beszel/hub/hub" && ! directory_has_entries "$PLATFORM_ROOT/beszel/hub/agent"; then
		return 0
	fi
	for component in foundation-beszel-controller foundation-beszel-worker; do
		while IFS= read -r container; do
			[[ -n "$container" ]] && docker stop --time 60 "$container" >/dev/null
		done < <(docker ps -q --filter "label=com.aichorage.component=$component")
	done
	move_directory_contents "$PLATFORM_ROOT/beszel/hub/hub" "$PLATFORM_ROOT/beszel/hub"
	move_directory_contents "$PLATFORM_ROOT/beszel/hub/agent" "$PLATFORM_ROOT/beszel/agent"
}
migrate_legacy_woodpecker_layout() {
	local component container
	if ! directory_has_entries "$PLATFORM_ROOT/woodpecker/agent/agent" && ! directory_has_entries "$PLATFORM_ROOT/woodpecker/agent/deployer"; then
		return 0
	fi
	for component in foundation-woodpecker-worker foundation-woodpecker-deployer; do
		while IFS= read -r container; do
			[[ -n "$container" ]] && docker stop --time 120 "$container" >/dev/null
		done < <(docker ps -q --filter "label=com.aichorage.component=$component")
	done
	move_directory_contents "$PLATFORM_ROOT/woodpecker/agent/agent" "$PLATFORM_ROOT/woodpecker/agent"
	move_directory_contents "$PLATFORM_ROOT/woodpecker/agent/deployer" "$PLATFORM_ROOT/woodpecker/deployer"
}

# Beszel normally derives its fingerprint from the VPS machine identity. Images
# cloned from another node can carry the same machine identity, causing the Hub
# to attach the new agent to the original system. Seed a stable, node-scoped
# fingerprint on first bootstrap; once enrolled, preserve the persisted value.
ensure_beszel_fingerprint() {
	local fingerprint_file="$PLATFORM_ROOT/beszel/agent/fingerprint" digest
	[[ -s "$fingerprint_file" ]] && return 0
	digest="$(printf 'llm-hub-lite/beszel/%s' "$NODE_ID" | sha256sum)"
	digest="${digest%% *}"
	printf '%s\n' "${digest:0:48}" >"$fingerprint_file"
	chmod 644 "$fingerprint_file"
}

need apt-get
bootstrap_packages=()
for pair in curl:curl gpg:gnupg git:git openssl:openssl ufw:ufw iptables:iptables ip:iproute2 tar:tar flock:util-linux; do
	command="${pair%%:*}"
	package="${pair#*:}"
	command -v "$command" >/dev/null 2>&1 || bootstrap_packages+=("$package")
done
if ((${#bootstrap_packages[@]})); then
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates "${bootstrap_packages[@]}"
fi
for command in git curl openssl install systemctl apt-get sha256sum ufw iptables ip base64 tar gpg dpkg cmp; do need "$command"; done
install_docker
need docker
missing=()
for pair in restic:restic sqlite3:sqlite3 jq:jq postgresql-client:pg_dump; do
	package="${pair%%:*}"
	command_name="${pair#*:}"
	command -v "$command_name" >/dev/null 2>&1 || missing+=("$package")
done
if ((${#missing[@]})); then
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi
need jq
normalize_restic_features
# Serialize the complete bootstrap transaction, including source/runtime
# mutation and credential provisioning. Nested platformctl calls inherit this
# marker and therefore do not try to acquire the same lock recursively.
install -d -m 700 "$(dirname "$PLATFORM_LOCK_FILE")"
exec 9>"$PLATFORM_LOCK_FILE"
flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for the platform bootstrap lock'
export PLATFORM_LOCK_HELD=1
if remote_enabled; then
	export RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE" RESTIC_COMPRESSION
	restic snapshots --no-lock >/dev/null 2>&1 || die "remote Restic repository is unavailable or uninitialized: $RESTIC_REMOTE_REPOSITORY; initialize it explicitly with RESTIC_REPOSITORY='$RESTIC_REMOTE_REPOSITORY' RESTIC_PASSWORD_FILE='$RESTIC_REMOTE_PASSWORD_FILE' restic init"
	unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
fi
configure_docker_daemon
systemctl enable --now docker.service
configure_low_memory_swap
detect_ssh_port

install -d -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/data/prod/librechat/uploads" "$APP_ROOT/shared/data/prod/librechat/images" "$APP_ROOT/shared/data/prod/librechat/skills" "$APP_ROOT/shared/data/prod/librechat/logs" "$APP_ROOT/shared/data/prod/librechat/data" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/logs" \
	"$PLATFORM_ROOT" "$PLATFORM_ROOT/caddy/data" "$PLATFORM_ROOT/caddy/config" \
	"$PLATFORM_ROOT/woodpecker/data" "$PLATFORM_ROOT/woodpecker/agent" "$PLATFORM_ROOT/woodpecker/deployer" \
	"$PLATFORM_ROOT/beszel/hub" "$PLATFORM_ROOT/beszel/agent" "$PLATFORM_ROOT/beszel/secrets" \
	"$CONTROL_ROOT/releases" "$FOUNDATION_ROOT/env" "$CONFIG_ROOT/image-history" \
	/opt/backups/llm-hub-lite/repository /opt/backups/llm-hub-lite/restores /run/lock/llm-hub-lite
# The rootless Woodpecker server image runs as UID/GID 1000.
install -d -o 1000 -g 1000 -m 700 "$PLATFORM_ROOT/woodpecker/data"
# Older bootstraps nested Hub and agent state below the Hub data directory.
migrate_legacy_beszel_layout
# Older bootstraps appended agent/deployer to an already component-specific path.
migrate_legacy_woodpecker_layout

if [[ -n "$DEPLOY_SSH_KEY_FILE" ]]; then
	[[ -s "$DEPLOY_SSH_KEY_FILE" ]] || die "deployment key does not exist: $DEPLOY_SSH_KEY_FILE"
	install -o root -g root -m 600 "$DEPLOY_SSH_KEY_FILE" "$CONFIG_ROOT/deploy-key"
fi
if [[ -n "$DEPLOY_KNOWN_HOSTS_FILE" ]]; then
	[[ -s "$DEPLOY_KNOWN_HOSTS_FILE" ]] || die "deployment known_hosts file does not exist: $DEPLOY_KNOWN_HOSTS_FILE"
	install -o root -g root -m 600 "$DEPLOY_KNOWN_HOSTS_FILE" "$CONFIG_ROOT/known_hosts"
fi
if [[ -s "$CONFIG_ROOT/deploy-key" ]]; then
	[[ -s "$CONFIG_ROOT/known_hosts" ]] || die 'DEPLOY_KNOWN_HOSTS_FILE is required when using a deployment SSH key'
	export GIT_SSH_COMMAND="ssh -i $CONFIG_ROOT/deploy-key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$CONFIG_ROOT/known_hosts"
fi
if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
	[[ -s "$GITHUB_TOKEN_FILE" ]] || die "GitHub token does not exist: $GITHUB_TOKEN_FILE"
	install -o root -g root -m 600 "$GITHUB_TOKEN_FILE" "$CONFIG_ROOT/github-token"
	GITHUB_TOKEN_FILE="$CONFIG_ROOT/github-token"
fi
source_repo_url="$REPO_URL"
if [[ -s "$CONFIG_ROOT/github-token" ]]; then
	export GITHUB_TOKEN_FILE="$CONFIG_ROOT/github-token" GIT_TERMINAL_PROMPT=0
	github_askpass="$(mktemp "${TMPDIR:-/tmp}/llm-hub-lite-askpass.XXXXXX")"
	trap 'rm -f -- "$github_askpass"' EXIT
	cat >"$github_askpass" <<'EOF'
#!/bin/sh
case "${1:-}" in *[Uu]sername*) printf '%s\n' x-access-token ;; *) cat -- "${GITHUB_TOKEN_FILE:?GITHUB_TOKEN_FILE is not set}" ;; esac
EOF
	chmod 700 "$github_askpass"
	export GIT_ASKPASS="$github_askpass"
elif [[ -s "$CONFIG_ROOT/deploy-key" && "$REPO_URL" =~ ^https://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
	source_repo_url="git@github.com:${BASH_REMATCH[1]}.git"
fi

git_fetch_bootstrap() {
	local attempt
	for attempt in 1 2 3 4 5; do
		if git -C "$source_checkout_root" fetch --prune origin "$MAIN_BRANCH"; then
			return 0
		fi
		((attempt < 5)) || die "unable to fetch $MAIN_BRANCH after $attempt attempts"
		printf 'Git fetch failed; retrying in %s seconds (attempt %s/5)\n' "$((attempt * 5))" "$attempt" >&2
		sleep "$((attempt * 5))"
	done
}
git_clone_bootstrap() {
	local attempt clone_root="${source_checkout_root}.bootstrap.$$"
	[[ ! -e "$source_checkout_root" ]] || die "source root already exists but is not a Git checkout: $source_checkout_root"
	for attempt in 1 2 3 4 5; do
		rm -rf -- "$clone_root"
		if git clone --branch "$MAIN_BRANCH" --single-branch "$source_repo_url" "$clone_root"; then
			mv -- "$clone_root" "$source_checkout_root"
			return 0
		fi
		((attempt < 5)) || die "unable to clone $MAIN_BRANCH after $attempt attempts"
		printf 'Git clone failed; retrying in %s seconds (attempt %s/5)\n' "$((attempt * 5))" "$attempt" >&2
		sleep "$((attempt * 5))"
	done
}

source_checkout_root="$SOURCE_ROOT"
if [[ "${BOOTSTRAP_SKIP_SOURCE_UPDATE:-0}" == 1 ]]; then
	[[ -d "$source_checkout_root/.git" ]] || die "SOURCE_ROOT is not a Git checkout: $source_checkout_root"
else
	if [[ ! -d "$source_checkout_root/.git" ]]; then git_clone_bootstrap; else
		git -C "$source_checkout_root" remote set-url origin "$source_repo_url"
		git_fetch_bootstrap
		git -C "$source_checkout_root" checkout --quiet "$MAIN_BRANCH"
		git -C "$source_checkout_root" reset --hard --quiet "origin/$MAIN_BRANCH"
	fi
fi

# A migration can provide an already-installed release tree. Use it for every
# policy, manifest, foundation, and runner read while retaining the checkout
# path above for Git operations and source-update compatibility.
bootstrap_tree="$SOURCE_ROOT"
if [[ -n "$BOOTSTRAP_RELEASE_SHA" ]]; then
	bootstrap_tree="$CONTROL_ROOT/releases/$BOOTSTRAP_RELEASE_SHA"
	[[ -d "$bootstrap_tree/config/cluster" ]] || die "requested bootstrap release is not installed: $bootstrap_tree"
fi

policy_file="$bootstrap_tree/config/cluster/policy.env"
[[ -f "$policy_file" ]] || die "missing cluster policy: $policy_file"
[[ "$(sed -n 's/^CLUSTER_CONFIG_VERSION=//p' "$policy_file" | tail -n1)" == 3 ]] || die 'unsupported cluster policy version'
if [[ -z "$NODE_ID" && "$BOOTSTRAP_MODE" == repair && -r "$CONFIG_ROOT/node.env" ]]; then
	NODE_ID="$(sed -n 's/^NODE_ID=//p' "$CONFIG_ROOT/node.env" | tail -n1)"
fi
leader_node_id="$(sed -n 's/^LEADER_NODE_ID=//p' "$policy_file" | tail -n1)"
[[ -n "$leader_node_id" ]] || die 'cluster policy is missing LEADER_NODE_ID'
node_ids="$(sed -n 's/^NODE_IDS=//p' "$policy_file" | tail -n1)"
if [[ -z "$NODE_ID" ]]; then
	[[ -t 0 ]] || die 'NODE_ID is required for non-interactive bootstrap'
	while :; do
		if ! read -r -p 'Node role (leader or follower): ' requested_role; then
			die 'node role input was not received'
		fi
		case "$requested_role" in
		leader | Leader | LEADER)
			NODE_ID="$leader_node_id"
			break
			;;
		follower | Follower | FOLLOWER)
			followers=''
			old_ifs="$IFS"
			IFS=,
			for candidate in $node_ids; do
				[[ -n "$candidate" && "$candidate" != "$leader_node_id" ]] || continue
				followers="${followers:+$followers,}$candidate"
			done
			IFS="$old_ifs"
			[[ -n "$followers" ]] || die 'cluster policy has no follower nodes'
			printf 'Configured follower node IDs: %s\n' "$followers"
			if ! read -r -p 'Stable follower node ID: ' NODE_ID; then
				die 'NODE_ID input was not received'
			fi
			break
			;;
		*) printf 'Enter leader or follower.\n' >&2 ;;
		esac
	done
fi
[[ "$NODE_ID" =~ ^[a-z][a-z0-9-]*$ ]] || die 'invalid NODE_ID'
csv_contains "$node_ids" "$NODE_ID" || die "node is absent from NODE_IDS: $NODE_ID"
if [[ "$BOOTSTRAP_MODE" == repair && -r "$CONFIG_ROOT/node.env" ]]; then
	existing_node_id="$(sed -n 's/^NODE_ID=//p' "$CONFIG_ROOT/node.env" | tail -n1)"
	[[ -z "$existing_node_id" || "$existing_node_id" == "$NODE_ID" ]] ||
		die "repair NODE_ID $NODE_ID does not match the installed node identity $existing_node_id"
fi
NODE_ROLE=leader
[[ "$NODE_ID" == "$leader_node_id" ]] || NODE_ROLE=follower
ensure_beszel_fingerprint
app_policy_file() {
	local app="$1" rel
	rel="$(sed -n 's/^POLICY_FILE=//p' "$bootstrap_tree/apps/$app/manifest.env" | tail -n1)"
	printf '%s/config/%s\n' "$bootstrap_tree" "$rel"
}
app_enabled() {
	local app="$1" file
	file="$(app_policy_file "$app")"
	# Policies are authoritative. Treat a missing or malformed ENABLED value as
	# disabled here; validate() will report the precise policy error later. This
	# prevents a partially fetched release from prompting for secrets or pulling
	# images for an app that was never explicitly enabled.
	[[ "$(sed -n 's/^ENABLED=//p' "$file" 2>/dev/null | tail -n1)" == true ]]
}
app_nodes() { sed -n 's/^NODES=//p' "$(app_policy_file "$1")" | tail -n1; }
app_target() {
	local app="$1" nodes
	nodes="$(app_nodes "$app")"
	[[ "$(sed -n 's/^UPSTREAM_MODE=//p' "$bootstrap_tree/apps/$app/manifest.env" | tail -n1)" == singleton && -n "$nodes" && "$nodes" != *,* ]] || return 1
	printf '%s\n' "$nodes"
}
app_active_on_node() {
	local app="$1"
	app_enabled "$app" || return 1
	[[ "$NODE_ROLE" == follower ]] || return 1
	[[ "${NODE_STATE:-}" == active ]] || return 1
	csv_contains "$(app_nodes "$app")" "$NODE_ID"
}
inventory_file="$bootstrap_tree/config/cluster/nodes/$NODE_ID.env"
[[ -f "$inventory_file" ]] || die "node is absent from cluster inventory: $NODE_ID"
[[ "$(sed -n 's/^NODE_ID=//p' "$inventory_file" | tail -n1)" == "$NODE_ID" ]] || die "node inventory identity mismatch: $NODE_ID"
NODE_STATE="$(sed -n 's/^NODE_STATE=//p' "$inventory_file" | tail -n1)"
case "$NODE_STATE" in
joining | active) ;;
draining | retired) die "cannot bootstrap a node in $NODE_STATE state: $NODE_ID" ;;
*) die "invalid node state in cluster inventory: $NODE_ID/$NODE_STATE" ;;
esac
NODE_BACKUP_ENABLED="$(sed -n 's/^BACKUP_ENABLED=//p' "$inventory_file" | tail -n1)"
NODE_BACKUP_ENABLED="${NODE_BACKUP_ENABLED:-true}"
case "$NODE_BACKUP_ENABLED" in
true | TRUE | 1) NODE_BACKUP_ENABLED=true ;;
false | FALSE | 0) NODE_BACKUP_ENABLED=false ;;
*) die "BACKUP_ENABLED must be true or false in node inventory: $NODE_ID" ;;
esac
if [[ "$NODE_ROLE" == leader && "$NODE_STATE" != active ]]; then
	die 'the designated Leader must be active before bootstrap'
fi
if [[ "$BOOTSTRAP_MODE" == repair && ! -r "$CONFIG_ROOT/node.env" ]]; then
	die 'BOOTSTRAP_MODE=repair requires an existing node installation'
fi
prompt_required LEADER_PUBLIC_IP 'Leader public IPv4 address'
valid_ipv4 "$LEADER_PUBLIC_IP" || die 'LEADER_PUBLIC_IP must be a valid IPv4 address'
printf 'Derived node role: %s (Leader node ID: %s)\n' "$NODE_ROLE" "$leader_node_id"
[[ "$WOODPECKER_AGENT_LABELS" == node=unknown,* ]] && WOODPECKER_AGENT_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"
[[ "$WOODPECKER_DEPLOYER_LABELS" == node=unknown,* ]] && WOODPECKER_DEPLOYER_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"

# Observer is a Leader-owned foundation service. A host that previously ran
# the retired singleton layout may still have the controller's root password
# in its local foundation environment; Followers only need the write-only
# ingestion credential, so remove those stale administrator values.
if [[ "$NODE_ROLE" == follower ]]; then
	remove_key "$observer_env" OBSERVER_ROOT_USER_EMAIL
	remove_key "$observer_env" OBSERVER_ROOT_USER_PASSWORD
	OBSERVER_ROOT_USER_EMAIL=''
	OBSERVER_ROOT_USER_PASSWORD=''
fi

if [[ "${BOOTSTRAP_ASSUME_YES:-0}" != 1 && -t 0 ]]; then
	if ! read -r -p "Continue $BOOTSTRAP_MODE bootstrap of $NODE_ID as $NODE_ROLE ($NODE_STATE)? [y/N]: " confirm; then
		die 'bootstrap confirmation was not received; rerun with ssh -tt or set BOOTSTRAP_ASSUME_YES=1'
	fi
	[[ "$confirm" =~ ^[Yy]$ ]] || die 'bootstrap cancelled'
fi

# Create the shared application environment before resolving application
# secrets. set_key() is deliberately allowed to create a file, so doing this
# afterwards could leave a fresh host with only secret keys and skip all of
# the required platform defaults. ensure_key() keeps this repairable for hosts
# that were initialized by an older bootstrap revision.
if [[ ! -f "$app_env" ]]; then
	{
		printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=%s\nPLATFORM_EDGE_NETWORK=%s\n' "$DOMAIN_NAME" "$SSL_EMAIL" "$edge_network" "$edge_network"
		printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
		printf 'RESTIC_REMOTE_ENABLED=%s\nRESTIC_REMOTE_REPOSITORY=%s\nRESTIC_REMOTE_PASSWORD_FILE=%s\nRESTIC_REMOTE_ENV_FILE=%s\nRESTIC_CACHE_DIR=%s\nRESTIC_READ_CONCURRENCY=%s\nRESTIC_COMPRESSION=%s\nRESTIC_SKIP_IF_UNCHANGED=%s\nRESTIC_NICE_LEVEL=%s\nRESTIC_IONICE_ENABLED=%s\nRESTIC_IONICE_CLASS=%s\nRESTIC_IONICE_LEVEL=%s\nRESTIC_SCHEDULE_INTERVAL=%s\nPRODUCTION_REQUIRE_REMOTE_BACKUP=%s\n' "$RESTIC_REMOTE_ENABLED" "$RESTIC_REMOTE_REPOSITORY" "$RESTIC_REMOTE_PASSWORD_FILE" "$RESTIC_REMOTE_ENV_FILE" "$RESTIC_CACHE_DIR" "$RESTIC_READ_CONCURRENCY" "$RESTIC_COMPRESSION" "$RESTIC_SKIP_IF_UNCHANGED" "$RESTIC_NICE_LEVEL" "$RESTIC_IONICE_ENABLED" "$RESTIC_IONICE_CLASS" "$RESTIC_IONICE_LEVEL" "$RESTIC_SCHEDULE_INTERVAL" "$PRODUCTION_REQUIRE_REMOTE_BACKUP"
		printf 'NODE_ID=%s\nCLUSTER_POLICY_FILE=%s\nNODE_CONFIG_FILE=%s/node.env\n' "$NODE_ID" "$CONTROL_ROOT/current/config/cluster/policy.env" "$CONFIG_ROOT"
		printf 'WOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME"
		printf 'WOODPECKER_GRPC_SITE=https://ci-grpc.%s\nOBSERVER_SITE=https://observer.%s\nOBSERVER_INGEST_SITE=https://observer-ingest.%s\nOBSERVER_INGEST_URL=https://observer-ingest.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
	} >"$app_env"
fi
for pair in \
	"DOMAIN_NAME=$DOMAIN_NAME" "SSL_EMAIL=$SSL_EMAIL" "SHARED_NETWORK_NAME=$edge_network" \
	"PLATFORM_EDGE_NETWORK=$edge_network" "DATA_ROOT=$APP_ROOT/shared/data/prod" "TZ=Asia/Shanghai" \
	"RESTIC_REMOTE_ENABLED=$RESTIC_REMOTE_ENABLED" "RESTIC_REMOTE_REPOSITORY=$RESTIC_REMOTE_REPOSITORY" \
	"RESTIC_REMOTE_PASSWORD_FILE=$RESTIC_REMOTE_PASSWORD_FILE" "RESTIC_REMOTE_ENV_FILE=$RESTIC_REMOTE_ENV_FILE" \
	"RESTIC_CACHE_DIR=$RESTIC_CACHE_DIR" "RESTIC_READ_CONCURRENCY=$RESTIC_READ_CONCURRENCY" \
	"RESTIC_COMPRESSION=$RESTIC_COMPRESSION" "RESTIC_SKIP_IF_UNCHANGED=$RESTIC_SKIP_IF_UNCHANGED" \
	"RESTIC_NICE_LEVEL=$RESTIC_NICE_LEVEL" "RESTIC_IONICE_ENABLED=$RESTIC_IONICE_ENABLED" \
	"RESTIC_IONICE_CLASS=$RESTIC_IONICE_CLASS" "RESTIC_IONICE_LEVEL=$RESTIC_IONICE_LEVEL" \
	"RESTIC_SCHEDULE_INTERVAL=$RESTIC_SCHEDULE_INTERVAL" "PRODUCTION_REQUIRE_REMOTE_BACKUP=$PRODUCTION_REQUIRE_REMOTE_BACKUP" \
	"NODE_ID=$NODE_ID" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env"; do
	ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"
done
chmod 600 "$app_env"

manifest_has_generated_secret() {
	local manifest="$1" key="$2" generated
	generated="$(sed -n 's/^GENERATED_SECRET_KEYS=//p' "$manifest" | tail -n1)"
	csv_contains "$generated" "$key"
}
manifest_conditional_secret_keys() {
	local manifest="$1" rule selector expected keys config_file result=''
	config_file="$(dirname "$manifest")/$(sed -n 's/^CONFIG_FILE=//p' "$manifest" | tail -n1)"
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		selector="${rule%%=*}"
		expected="${rule#*=}"
		keys="${expected#*|}"
		expected="${expected%%|*}"
		[[ "$(sed -n "s/^${selector}=//p" "$config_file" | tail -n1)" == "$expected" ]] || continue
		result="${result:+$result,}$keys"
	done < <(sed -n 's/^CONDITIONAL_SECRET_KEYS=//p' "$manifest" | tail -n1 | tr ';' '\n')
	printf '%s\n' "$result"
}
prepare_application_secrets() {
	local manifest app_id keys runtime_rel runtime_file key min_length conditional_keys regex bytes
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		[[ "$(sed -n 's/^MANIFEST_VERSION=//p' "$manifest" | tail -n1)" == 5 ]] || die "unsupported application manifest version: $manifest"
		app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
		app_enabled "$app_id" || continue
		conditional_keys="$(manifest_conditional_secret_keys "$manifest")"
		if [[ "$NODE_ROLE" == leader ]]; then
			keys="$(sed -n 's/^CLUSTER_SECRET_KEYS=//p' "$manifest" | tail -n1)"
			keys="${keys}${conditional_keys:+${keys:+,}$conditional_keys}"
			while IFS= read -r key; do
				[[ -n "$key" ]] || continue
				load_bundle_value "$key"
				load_runtime_value "$key" "$app_env"
				clear_placeholder "$key"
				if manifest_has_generated_secret "$manifest" "$key"; then
					bytes="$(manifest_secret_bytes "$manifest" "$key")"
					[[ "$bytes" =~ ^[1-9][0-9]*$ ]] || die "invalid GENERATED_SECRET_BYTES entry for $app_id/$key"
					[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(openssl rand -hex "$bytes")"
				fi
				min_length="$(manifest_secret_min_length "$manifest" "$key")"
				regex="$(manifest_secret_regex "$manifest" "$key")"
				prompt_required "$key" "$app_id shared $key" 1 "$min_length" "$regex"
			done < <(printf '%s\n' "$keys" | tr ',' '\n')
			continue
		fi
		app_active_on_node "$app_id" || continue
		keys="$(sed -n 's/^CLUSTER_SECRET_KEYS=//p' "$manifest" | tail -n1)"
		keys="${keys}${conditional_keys:+${keys:+,}$conditional_keys}"
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			load_bundle_value "$key"
			load_runtime_value "$key" "$app_env"
			clear_placeholder "$key"
			min_length="$(manifest_secret_min_length "$manifest" "$key")"
			regex="$(manifest_secret_regex "$manifest" "$key")"
			prompt_required "$key" "$app_id shared $key" 1 "$min_length" "$regex"
		done < <(printf '%s\n' "$keys" | tr ',' '\n')
		runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$manifest" | tail -n1)"
		keys="$(sed -n 's/^NODE_SECRET_KEYS=//p' "$manifest" | tail -n1)"
		[[ -z "$keys" || (-n "$runtime_rel" && "$runtime_rel" != /* && "$runtime_rel" != *..* && "$runtime_rel" =~ ^[A-Za-z0-9._/-]+$) ]] || die "invalid RUNTIME_ENV_FILE for $app_id"
		runtime_file="$CONFIG_ROOT/$runtime_rel"
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			load_runtime_value "$key" "$runtime_file"
			clear_placeholder "$key"
			if manifest_has_generated_secret "$manifest" "$key"; then
				bytes="$(manifest_secret_bytes "$manifest" "$key")"
				[[ "$bytes" =~ ^[1-9][0-9]*$ ]] || die "invalid GENERATED_SECRET_BYTES entry for $app_id/$key"
				[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(openssl rand -hex "$bytes")"
			fi
			min_length="$(manifest_secret_min_length "$manifest" "$key")"
			regex="$(manifest_secret_regex "$manifest" "$key")"
			prompt_required "$key" "$app_id node-local $key" 1 "$min_length" "$regex"
		done < <(printf '%s\n' "$keys" | tr ',' '\n')
	done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}
prepare_application_secrets
if bootstrap_foundation_enabled observer-controller; then
	clear_placeholder OBSERVER_ROOT_USER_EMAIL
	clear_placeholder OBSERVER_ROOT_USER_PASSWORD
	prompt_required OBSERVER_ROOT_USER_EMAIL 'OpenObserve root email'
	prompt_required OBSERVER_ROOT_USER_PASSWORD 'OpenObserve root password' 1
fi
if bootstrap_foundation_enabled observer-collector; then
	prompt_observer_ingest_user
	if [[ "$NODE_ROLE" == follower ]]; then
		prompt_observer_ingest_token
	fi
fi
if [[ "$NODE_ROLE" == leader ]]; then
	generate_shared_secret WOODPECKER_AGENT_SECRET
	generate_shared_secret WOODPECKER_GRPC_SECRET
else
	prompt_required WOODPECKER_AGENT_SECRET 'Shared Woodpecker agent secret' 1
	prompt_required WOODPECKER_GRPC_SECRET 'Shared Woodpecker gRPC secret' 1
fi

case "$(uname -m)" in
x86_64 | amd64) compose_arch=x86_64 ;;
aarch64 | arm64) compose_arch=aarch64 ;;
*) die "unsupported architecture for Docker Compose: $(uname -m)" ;;
esac
if [[ -n "$COMPOSE_SHA256_OVERRIDE" ]]; then
	compose_sha256="$COMPOSE_SHA256_OVERRIDE"
elif [[ "$compose_arch" == x86_64 ]]; then
	compose_sha256="$COMPOSE_SHA256_AMD64"
else
	compose_sha256="$COMPOSE_SHA256_ARM64"
fi
compose_tmp="$(mktemp)"
trap 'rm -f -- "$compose_tmp" "${github_askpass:-}"' EXIT
if [[ ! -x "$COMPOSE_BIN" ]] || ! echo "$compose_sha256  $COMPOSE_BIN" | sha256sum -c - >/dev/null 2>&1; then
	curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$compose_arch" -o "$compose_tmp"
	echo "$compose_sha256  $compose_tmp" | sha256sum -c - >/dev/null || die 'Compose checksum verification failed'
	install -o root -g root -m 755 "$compose_tmp" "$COMPOSE_BIN"
fi
"$COMPOSE_BIN" version >/dev/null

docker network inspect "$edge_network" >/dev/null 2>&1 || docker network create "$edge_network" >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT"/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw --force enable >/dev/null

previous_app_domain="$(sed -n 's/^DOMAIN_NAME=//p' "$app_env" 2>/dev/null | tail -n1)"
set_key "$app_env" DOMAIN_NAME "$DOMAIN_NAME"
set_key "$app_env" SSL_EMAIL "$SSL_EMAIL"
for pair in "PLATFORM_EDGE_NETWORK=$edge_network" "NODE_ID=$NODE_ID" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env" "RESTIC_REMOTE_ENABLED=$RESTIC_REMOTE_ENABLED" "RESTIC_REMOTE_REPOSITORY=$RESTIC_REMOTE_REPOSITORY" "RESTIC_REMOTE_PASSWORD_FILE=$RESTIC_REMOTE_PASSWORD_FILE" "RESTIC_REMOTE_ENV_FILE=$RESTIC_REMOTE_ENV_FILE" "RESTIC_CACHE_DIR=$RESTIC_CACHE_DIR" "RESTIC_READ_CONCURRENCY=$RESTIC_READ_CONCURRENCY" "RESTIC_SKIP_IF_UNCHANGED=$RESTIC_SKIP_IF_UNCHANGED" "RESTIC_NICE_LEVEL=$RESTIC_NICE_LEVEL" "RESTIC_IONICE_ENABLED=$RESTIC_IONICE_ENABLED" "RESTIC_IONICE_CLASS=$RESTIC_IONICE_CLASS" "RESTIC_IONICE_LEVEL=$RESTIC_IONICE_LEVEL" "RESTIC_SCHEDULE_INTERVAL=$RESTIC_SCHEDULE_INTERVAL" "PRODUCTION_REQUIRE_REMOTE_BACKUP=$PRODUCTION_REQUIRE_REMOTE_BACKUP"; do ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"; done
set_key "$app_env" RESTIC_COMPRESSION "$RESTIC_COMPRESSION"
set_key "$app_env" RESTIC_SKIP_IF_UNCHANGED "$RESTIC_SKIP_IF_UNCHANGED"
remove_key "$app_env" NODE_ROLE
remove_key "$app_env" LEADER_PUBLIC_IP
set_derived_key "$app_env" WOODPECKER_SITE "https://ci.$DOMAIN_NAME" "$previous_app_domain" 'https://ci.'
set_derived_key "$app_env" BESZEL_SITE "https://status.$DOMAIN_NAME" "$previous_app_domain" 'https://status.'
set_derived_key "$app_env" WOODPECKER_GRPC_SITE "https://ci-grpc.$DOMAIN_NAME" "$previous_app_domain" 'https://ci-grpc.'
set_derived_key "$app_env" OBSERVER_SITE "https://observer.$DOMAIN_NAME" "$previous_app_domain" 'https://observer.'
set_derived_key "$app_env" OBSERVER_INGEST_SITE "https://observer-ingest.$DOMAIN_NAME" "$previous_app_domain" 'https://observer-ingest.'
set_derived_key "$app_env" OBSERVER_INGEST_URL "https://observer-ingest.$DOMAIN_NAME" "$previous_app_domain" 'https://observer-ingest.'
while IFS= read -r manifest; do
	while IFS='|' read -r public_key public_host; do
		[[ -n "$public_key" && -n "$public_host" ]] || continue
		set_derived_key "$app_env" "$public_key" "https://$public_host.$DOMAIN_NAME" "$previous_app_domain" "https://$public_host."
	done < <(sed -n 's/^PUBLIC_ENDPOINTS=//p' "$manifest" | tail -n1 | tr ';' '\n')
done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)

# App tuning is committed in apps/<id>/config.env and may be overridden only
# by a committed per-node override. Remove keys written by older bootstraps so
# the shared host environment cannot keep shadowing the declarative values.
while IFS= read -r manifest; do
	[[ -f "$manifest" ]] || continue
	while IFS= read -r config_key; do
		[[ -n "$config_key" ]] && remove_key "$app_env" "$config_key"
	done < <(sed -n 's/^ENV_KEYS=//p' "$manifest" | tail -n1 | tr ',' '\n')
done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)

chmod 600 "$app_env"

if [[ -n "$SHARED_SECRET_BUNDLE_FILE" && -s "$SHARED_SECRET_BUNDLE_FILE" && "$SHARED_SECRET_BUNDLE_FILE" != "$CONFIG_ROOT/shared-secrets.env" ]]; then
	install -o root -g root -m 600 "$SHARED_SECRET_BUNDLE_FILE" "$CONFIG_ROOT/shared-secrets.env"
	SHARED_SECRET_BUNDLE_FILE="$CONFIG_ROOT/shared-secrets.env"
fi
persist_application_secrets() {
	local manifest app_id keys runtime_rel runtime_file key value conditional_keys
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
		app_enabled "$app_id" || continue
		keys="$(sed -n 's/^CLUSTER_SECRET_KEYS=//p' "$manifest" | tail -n1)"
		conditional_keys="$(manifest_conditional_secret_keys "$manifest")"
		keys="${keys}${conditional_keys:+${keys:+,}$conditional_keys}"
		if [[ "$NODE_ROLE" == leader || "$(app_active_on_node "$app_id" && printf true || printf false)" == true ]]; then
			while IFS= read -r key; do
				[[ -n "$key" ]] || continue
				value="${!key:-}"
				[[ -n "$value" ]] || die "application secret was not prepared: $app_id/$key"
				set_key_if_changed "$app_env" "$key" "$value"
				[[ "$NODE_ROLE" != leader ]] || set_key_if_changed "$CONFIG_ROOT/shared-secrets.env" "$key" "$value"
			done < <(printf '%s\n' "$keys" | tr ',' '\n')
		fi
		[[ "$NODE_ROLE" == follower ]] || continue
		app_active_on_node "$app_id" || continue
		keys="$(sed -n 's/^NODE_SECRET_KEYS=//p' "$manifest" | tail -n1)"
		[[ -n "$keys" ]] || continue
		runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$manifest" | tail -n1)"
		runtime_file="$CONFIG_ROOT/$runtime_rel"
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			value="${!key:-}"
			[[ -n "$value" ]] || die "node-local application secret was not prepared: $app_id/$key"
			set_key_if_changed "$runtime_file" "$key" "$value"
		done < <(printf '%s\n' "$keys" | tr ',' '\n')
	done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
}
persist_application_secrets

woodpecker_env="$FOUNDATION_ROOT/env/woodpecker.env"
previous_woodpecker_domain=''
if [[ -r "$woodpecker_env" ]]; then
	previous_woodpecker_domain="$(sed -n 's/^WOODPECKER_HOST=https:\/\/ci\.//p' "$woodpecker_env" | tail -n1)"
fi
if [[ ! -f "$woodpecker_env" ]]; then
	oauth_client=""
	oauth_secret=""
	if [[ "$NODE_ROLE" == leader ]]; then
		oauth_client="${WOODPECKER_GITHUB_CLIENT:-}"
		oauth_secret="${WOODPECKER_GITHUB_SECRET:-}"
	fi
	if [[ "$NODE_ROLE" == leader ]]; then
		WOODPECKER_GITHUB_CLIENT="${oauth_client:-}"
		prompt_required WOODPECKER_GITHUB_CLIENT 'GitHub OAuth client ID'
		oauth_client="$WOODPECKER_GITHUB_CLIENT"
		WOODPECKER_GITHUB_SECRET="${oauth_secret:-}"
		prompt_required WOODPECKER_GITHUB_SECRET 'GitHub OAuth client secret' 1
		oauth_secret="$WOODPECKER_GITHUB_SECRET"
	fi
	{
		printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_DEPLOYER_CONFIG_ROOT=%s/deployer\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/woodpecker" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
		printf 'WOODPECKER_GITHUB_CLIENT=%s\nWOODPECKER_GITHUB_SECRET=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_GRPC_SECRET=%s\n' "$oauth_client" "$oauth_secret" "$WOODPECKER_AGENT_SECRET" "$WOODPECKER_GRPC_SECRET"
		printf 'WOODPECKER_REPO_OWNERS=%s\nWOODPECKER_AGENT_LABELS=%s\nWOODPECKER_DEPLOYER_LABELS=%s\nWOODPECKER_AGENT_SERVER=ci-grpc.%s:443\nWOODPECKER_DEPLOYER_SERVER=ci-grpc.%s:443\nWOODPECKER_GRPC_SECURE=true\nWOODPECKER_GRPC_SKIP_VERIFY=false\nWOODPECKER_MAX_WORKFLOWS=1\nWOODPECKER_DATABASE_MAX_CONNECTIONS=1\nWOODPECKER_DATABASE_IDLE_CONNECTIONS=1\nWOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false\n' "$WOODPECKER_REPO_OWNERS" "$WOODPECKER_AGENT_LABELS" "$WOODPECKER_DEPLOYER_LABELS" "$DOMAIN_NAME" "$DOMAIN_NAME"
	} >"$woodpecker_env"
fi
chmod 600 "$woodpecker_env"

caddy_env="$FOUNDATION_ROOT/env/caddy.env"
if [[ ! -f "$caddy_env" ]]; then : >"$caddy_env"; fi
for pair in "CADDY_DATA_ROOT=$PLATFORM_ROOT/caddy" "CADDY_CONFIG_ROOT=$APP_ROOT/shared/runtime/config" "CADDY_HTTP_BIND=0.0.0.0" "CADDY_HTTPS_BIND=0.0.0.0"; do
	ensure_key "$caddy_env" "${pair%%=*}" "${pair#*=}"
done
chmod 600 "$caddy_env"

beszel_env="$FOUNDATION_ROOT/env/beszel.env"
previous_beszel_domain=''
if [[ -r "$beszel_env" ]]; then
	previous_beszel_domain="$(sed -n 's/^BESZEL_APP_URL=https:\/\/status\.//p' "$beszel_env" | tail -n1)"
fi
if [[ ! -f "$beszel_env" ]]; then
	{
		printf 'BESZEL_APP_URL=https://status.%s\nBESZEL_DATA_ROOT=%s/hub\nBESZEL_AGENT_DATA_ROOT=%s/agent\n' "$DOMAIN_NAME" "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel"
		printf 'BESZEL_KEY_FILE=%s/secrets/key\nBESZEL_TOKEN_FILE=%s/secrets/token\nBESZEL_SYSTEM_NAME=%s\n' "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel" "$NODE_ID"
		printf 'BESZEL_CONTAINER_DETAILS=false\nBESZEL_SOCKET_PROXY_PORT=2375\nBESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service\nBESZEL_HEARTBEAT_URL=\nBESZEL_HEARTBEAT_METHOD=POST\nBESZEL_HEARTBEAT_INTERVAL=60\nBESZEL_MFA_OTP=false\nBESZEL_DISABLE_PASSWORD_AUTH=false\nBESZEL_USER_CREATION=false\n'
	} >"$beszel_env"
fi
for pair in \
	"BESZEL_APP_URL=https://status.$DOMAIN_NAME" "BESZEL_DATA_ROOT=$PLATFORM_ROOT/beszel/hub" \
	"BESZEL_AGENT_DATA_ROOT=$PLATFORM_ROOT/beszel/agent" "BESZEL_KEY_FILE=$PLATFORM_ROOT/beszel/secrets/key" \
	"BESZEL_TOKEN_FILE=$PLATFORM_ROOT/beszel/secrets/token" "BESZEL_SYSTEM_NAME=$NODE_ID" \
	"BESZEL_CONTAINER_DETAILS=false" "BESZEL_SOCKET_PROXY_PORT=2375" \
	"BESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service" "BESZEL_SYSTEMD_PRIVATE_SOCKET=/run/systemd/private" \
	"BESZEL_HEARTBEAT_METHOD=POST" "BESZEL_HEARTBEAT_INTERVAL=60" \
	"BESZEL_MFA_OTP=false" "BESZEL_DISABLE_PASSWORD_AUTH=false" "BESZEL_USER_CREATION=false"; do
	if [[ "${pair%%=*}" == BESZEL_SYSTEM_NAME ]]; then
		# Beszel's system name is the stable cluster identity, not the mutable
		# host name assigned by a VPS provider.
		set_key "$beszel_env" "${pair%%=*}" "${pair#*=}"
	else
		ensure_key "$beszel_env" "${pair%%=*}" "${pair#*=}"
	fi
done
set_derived_key "$beszel_env" BESZEL_APP_URL "https://status.$DOMAIN_NAME" "$previous_beszel_domain" 'https://status.'
ensure_key "$beszel_env" BESZEL_AGENT_APPARMOR unconfined
set_derived_key "$beszel_env" BESZEL_HUB_URL "https://status.$DOMAIN_NAME" "$previous_beszel_domain" 'https://status.'
for pair in \
	"WOODPECKER_DATA_ROOT=$PLATFORM_ROOT/woodpecker/data" "WOODPECKER_AGENT_CONFIG_ROOT=$PLATFORM_ROOT/woodpecker/agent" "WOODPECKER_DEPLOYER_CONFIG_ROOT=$PLATFORM_ROOT/woodpecker/deployer" \
	"WOODPECKER_HOST=https://ci.$DOMAIN_NAME" "WOODPECKER_ADMIN=$WOODPECKER_ADMIN" \
	"WOODPECKER_REPO_OWNERS=$WOODPECKER_REPO_OWNERS" "WOODPECKER_AGENT_LABELS=$WOODPECKER_AGENT_LABELS" \
	"WOODPECKER_DEPLOYER_LABELS=$WOODPECKER_DEPLOYER_LABELS" "WOODPECKER_AGENT_SERVER=ci-grpc.$DOMAIN_NAME:443" \
	"WOODPECKER_DEPLOYER_SERVER=ci-grpc.$DOMAIN_NAME:443" "WOODPECKER_GRPC_SECURE=true" "WOODPECKER_GRPC_SKIP_VERIFY=false" \
	"WOODPECKER_MAX_WORKFLOWS=1" "WOODPECKER_DATABASE_MAX_CONNECTIONS=1" "WOODPECKER_DATABASE_IDLE_CONNECTIONS=1" \
	"WOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false"; do
	ensure_key "$woodpecker_env" "${pair%%=*}" "${pair#*=}"
done
set_derived_key "$woodpecker_env" WOODPECKER_HOST "https://ci.$DOMAIN_NAME" "$previous_woodpecker_domain" 'https://ci.'
set_derived_key "$woodpecker_env" WOODPECKER_AGENT_SERVER "ci-grpc.$DOMAIN_NAME:443" "$previous_woodpecker_domain" 'ci-grpc.'
set_derived_key "$woodpecker_env" WOODPECKER_DEPLOYER_SERVER "ci-grpc.$DOMAIN_NAME:443" "$previous_woodpecker_domain" 'ci-grpc.'
if [[ "$NODE_ROLE" == leader ]]; then
	oauth_client="$(sed -n 's/^WOODPECKER_GITHUB_CLIENT=//p' "$woodpecker_env" | tail -n1)"
	WOODPECKER_GITHUB_CLIENT="$oauth_client"
	prompt_required WOODPECKER_GITHUB_CLIENT 'GitHub OAuth client ID'
	set_key "$woodpecker_env" WOODPECKER_GITHUB_CLIENT "$WOODPECKER_GITHUB_CLIENT"
	oauth_secret="$(sed -n 's/^WOODPECKER_GITHUB_SECRET=//p' "$woodpecker_env" | tail -n1)"
	WOODPECKER_GITHUB_SECRET="$oauth_secret"
	prompt_required WOODPECKER_GITHUB_SECRET 'GitHub OAuth client secret' 1
	set_key "$woodpecker_env" WOODPECKER_GITHUB_SECRET "$WOODPECKER_GITHUB_SECRET"
fi
for shared_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
	shared_value="${!shared_key:-}"
	[[ -n "$shared_value" ]] || die "$shared_key is required and cannot be empty"
	if [[ "$NODE_ROLE" == follower ]]; then
		# The Leader-generated shared bundle is authoritative on Followers. A
		# prior partial bootstrap may have left an older runtime value behind;
		# preserving it would make repair fail even though the supplied bundle is
		# the exact cluster credential we need to use.
		set_key_if_changed "$woodpecker_env" "$shared_key" "$shared_value"
	else
		ensure_key "$woodpecker_env" "$shared_key" "$shared_value"
	fi
done
for shared_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
	shared_value="${!shared_key:-}"
	if [[ -n "$shared_value" && "$NODE_ROLE" == leader ]]; then
		existing_value="$(sed -n "s/^${shared_key}=//p" "$woodpecker_env" | tail -n1)"
		if [[ -n "$existing_value" && "$existing_value" != "$shared_value" && "$existing_value" != replace-with-* ]]; then
			die "$shared_key already differs from the configured Leader value"
		fi
		set_key "$woodpecker_env" "$shared_key" "$shared_value"
	fi
done
chmod 600 "$woodpecker_env" "$beszel_env"

if [[ ! -f "$observer_env" ]]; then : >"$observer_env"; fi
previous_observer_domain="$(sed -n 's/^OBSERVER_SITE=https:\/\/observer\.//p' "$observer_env" 2>/dev/null | tail -n1)"
observer_data_root="$(sed -n 's/^OBSERVER_DATA_ROOT=//p' "$observer_env" | tail -n1)"
observer_data_root="${observer_data_root:-$PLATFORM_ROOT/observer}"
safe_observer_data_root "$observer_data_root" || die "OBSERVER_DATA_ROOT must be a non-root path below $PLATFORM_ROOT: $observer_data_root"
install -d -m 700 "$observer_data_root/data" "$observer_data_root/collector-buffer"
observer_token_value="$OBSERVER_INGEST_TOKEN"
[[ "$NODE_ROLE" == leader && -z "$observer_token_value" ]] && observer_token_value=bootstrap-pending
# Keep non-secret defaults in one canonical template. Existing operator values
# in observer.env still win; generated domains and credentials remain explicit.
observer_default_value() {
	local key="$1" fallback="$2" value=''
	if [[ -r "$bootstrap_tree/ops/foundation/observer.env.example" ]]; then
		value="$(sed -n "s/^${key}=//p" "$bootstrap_tree/ops/foundation/observer.env.example" | tail -n1)"
	fi
	printf '%s\n' "${value:-$fallback}"
}
for pair in \
	"OBSERVER_DATA_ROOT=$observer_data_root" \
	"OBSERVER_SITE=https://observer.$DOMAIN_NAME" \
	"OBSERVER_API_URL=$(observer_default_value OBSERVER_API_URL http://observer-controller:5080)" \
	"OBSERVER_COOKIE_SECURE_ONLY=$(observer_default_value OBSERVER_COOKIE_SECURE_ONLY true)" \
	"OBSERVER_INGEST_SITE=https://observer-ingest.$DOMAIN_NAME" \
	"OBSERVER_INGEST_URL=https://observer-ingest.$DOMAIN_NAME" \
	"OBSERVER_ROOT_USER_EMAIL=$OBSERVER_ROOT_USER_EMAIL" \
	"OBSERVER_ROOT_USER_PASSWORD=$OBSERVER_ROOT_USER_PASSWORD" \
	"OBSERVER_INGEST_USER=$OBSERVER_INGEST_USER" \
	"OBSERVER_INGEST_TOKEN=$observer_token_value" \
	"OBSERVER_LOG_ORGANIZATION=$(observer_default_value OBSERVER_LOG_ORGANIZATION default)" \
	"OBSERVER_LOG_STREAM=$(observer_default_value OBSERVER_LOG_STREAM docker)" \
	"OBSERVER_LOG_BUFFER_MAX_BYTES=$(observer_default_value OBSERVER_LOG_BUFFER_MAX_BYTES 536870912)" \
	"OBSERVER_LOG_BUFFER_WHEN_FULL=$(observer_default_value OBSERVER_LOG_BUFFER_WHEN_FULL block)" \
	"OBSERVER_DURABLE_WARN_BYTES=$(observer_default_value OBSERVER_DURABLE_WARN_BYTES 8589934592)" \
	"OBSERVER_LOG_BUFFER_WARN_PERCENT=$(observer_default_value OBSERVER_LOG_BUFFER_WARN_PERCENT 80)" \
	"OBSERVER_MEMORY_LIMIT=$(observer_default_value OBSERVER_MEMORY_LIMIT 512m)" \
	"OBSERVER_CPUS=$(observer_default_value OBSERVER_CPUS 0.50)" \
	"OBSERVER_PIDS_LIMIT=$(observer_default_value OBSERVER_PIDS_LIMIT 256)" \
	"OBSERVER_DATA_RETENTION_DAYS=$(observer_default_value OBSERVER_DATA_RETENTION_DAYS 30)" \
	"OBSERVER_QUERY_THREAD_NUM=$(observer_default_value OBSERVER_QUERY_THREAD_NUM 1)" \
	"OBSERVER_HTTP_WORKER_NUM=$(observer_default_value OBSERVER_HTTP_WORKER_NUM 1)" \
	"OBSERVER_HTTP_WORKER_MAX_BLOCKING=$(observer_default_value OBSERVER_HTTP_WORKER_MAX_BLOCKING 16)" \
	"OBSERVER_GRPC_RUNTIME_WORKER_NUM=$(observer_default_value OBSERVER_GRPC_RUNTIME_WORKER_NUM 1)" \
	"OBSERVER_GRPC_RUNTIME_BLOCKING_WORKER_NUM=$(observer_default_value OBSERVER_GRPC_RUNTIME_BLOCKING_WORKER_NUM 16)" \
	"OBSERVER_JOB_RUNTIME_WORKER_NUM=$(observer_default_value OBSERVER_JOB_RUNTIME_WORKER_NUM 1)" \
	"OBSERVER_JOB_RUNTIME_BLOCKING_WORKER_NUM=$(observer_default_value OBSERVER_JOB_RUNTIME_BLOCKING_WORKER_NUM 16)" \
	"OBSERVER_WAL_RUNTIME_WORKER_NUM=$(observer_default_value OBSERVER_WAL_RUNTIME_WORKER_NUM 1)" \
	"OBSERVER_WAL_WRITE_QUEUE_SIZE=$(observer_default_value OBSERVER_WAL_WRITE_QUEUE_SIZE 1000)" \
	"OBSERVER_COMPACT_INTERVAL=$(observer_default_value OBSERVER_COMPACT_INTERVAL 30)" \
	"OBSERVER_COMPACT_DATA_RETENTION_INTERVAL=$(observer_default_value OBSERVER_COMPACT_DATA_RETENTION_INTERVAL 3600)" \
	"OBSERVER_COMPACT_TANTIVY_BUILDER_THREAD_NUM=$(observer_default_value OBSERVER_COMPACT_TANTIVY_BUILDER_THREAD_NUM 1)" \
	"OBSERVER_ENABLE_INVERTED_INDEX=$(observer_default_value OBSERVER_ENABLE_INVERTED_INDEX false)" \
	"OBSERVER_DISK_CACHE_MAX_SIZE=$(observer_default_value OBSERVER_DISK_CACHE_MAX_SIZE 128)" \
	"OBSERVER_LOG_PROXY_MEMORY_LIMIT=$(observer_default_value OBSERVER_LOG_PROXY_MEMORY_LIMIT 32m)" \
	"OBSERVER_LOG_PROXY_CPUS=$(observer_default_value OBSERVER_LOG_PROXY_CPUS 0.10)" \
	"OBSERVER_LOG_PROXY_PIDS_LIMIT=$(observer_default_value OBSERVER_LOG_PROXY_PIDS_LIMIT 64)" \
	"OBSERVER_LOG_PROXY_STREAM_TIMEOUT=$(observer_default_value OBSERVER_LOG_PROXY_STREAM_TIMEOUT 24h)" \
	"OBSERVER_LOG_SHIPPER_MEMORY_LIMIT=$(observer_default_value OBSERVER_LOG_SHIPPER_MEMORY_LIMIT 96m)" \
	"OBSERVER_LOG_SHIPPER_CPUS=$(observer_default_value OBSERVER_LOG_SHIPPER_CPUS 0.10)" \
	"OBSERVER_LOG_SHIPPER_PIDS_LIMIT=$(observer_default_value OBSERVER_LOG_SHIPPER_PIDS_LIMIT 128)" \
	"OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS=$(observer_default_value OBSERVER_LOG_HEARTBEAT_INTERVAL_SECONDS 300)"; do
	ensure_key "$observer_env" "${pair%%=*}" "${pair#*=}"
done
set_derived_key "$observer_env" OBSERVER_SITE "https://observer.$DOMAIN_NAME" "$previous_observer_domain" 'https://observer.'
set_derived_key "$observer_env" OBSERVER_INGEST_SITE "https://observer-ingest.$DOMAIN_NAME" "$previous_observer_domain" 'https://observer-ingest.'
set_derived_key "$observer_env" OBSERVER_INGEST_URL "https://observer-ingest.$DOMAIN_NAME" "$previous_observer_domain" 'https://observer-ingest.'
# Credentials are deliberately written with set_key.  An earlier singleton
# deployment may have left a placeholder in the foundation environment; using
# ensure_key for these fields would preserve that placeholder and make the new
# controller fail even after the operator entered valid credentials.
for observer_key in OBSERVER_ROOT_USER_EMAIL OBSERVER_ROOT_USER_PASSWORD OBSERVER_INGEST_USER OBSERVER_INGEST_TOKEN; do
	observer_value="${!observer_key:-}"
	[[ -n "$observer_value" ]] || continue
	set_key "$observer_env" "$observer_key" "$observer_value"
done
if [[ "$NODE_ROLE" == follower ]]; then
	remove_key "$observer_env" OBSERVER_ROOT_USER_EMAIL
	remove_key "$observer_env" OBSERVER_ROOT_USER_PASSWORD
fi
chmod 600 "$observer_env"

beszel_credentials="$CONFIG_ROOT/beszel-initial-credentials"
beszel_key_exists=0
beszel_token_exists=0
[[ -s "$PLATFORM_ROOT/beszel/secrets/key" ]] && beszel_key_exists=1
[[ -s "$PLATFORM_ROOT/beszel/secrets/token" ]] && beszel_token_exists=1
if ((beszel_key_exists != beszel_token_exists)); then
	# enrollment will quarantine the orphan and issue a fresh pair after the
	# hub is available; never discard it during an idempotent bootstrap.
	install -d -m 700 "$PLATFORM_ROOT/beszel/secrets/orphaned"
	orphan_stamp="$(date -u '+%Y%m%dT%H%M%SZ').$$"
	if [[ -e "$PLATFORM_ROOT/beszel/secrets/key" ]]; then
		mv -f -- "$PLATFORM_ROOT/beszel/secrets/key" "$PLATFORM_ROOT/beszel/secrets/orphaned/key.$orphan_stamp"
	fi
	if [[ -e "$PLATFORM_ROOT/beszel/secrets/token" ]]; then
		mv -f -- "$PLATFORM_ROOT/beszel/secrets/token" "$PLATFORM_ROOT/beszel/secrets/orphaned/token.$orphan_stamp"
	fi
	beszel_key_exists=0
	beszel_token_exists=0
fi
if ((beszel_key_exists == 0)); then
	install -d -m 700 "$PLATFORM_ROOT/beszel/secrets" "$PLATFORM_ROOT/beszel/hub" "$PLATFORM_ROOT/beszel/agent"
	if [[ "$NODE_ROLE" == leader ]]; then
		if [[ ! -s "$beszel_credentials" ]]; then
			beszel_password="$(openssl rand -base64 36 | tr -d '=+/')"
			printf 'email=admin@%s\npassword=%s\n' "$DOMAIN_NAME" "$beszel_password" >"$beszel_credentials"
			chmod 600 "$beszel_credentials"
		else
			beszel_password="$(sed -n 's/^password=//p' "$beszel_credentials" | tail -n1)"
		fi
		ensure_key "$beszel_env" BESZEL_USER_EMAIL "admin@$DOMAIN_NAME"
		ensure_key "$beszel_env" BESZEL_USER_PASSWORD "$beszel_password"
	fi
fi

if [[ "$NODE_ROLE" == follower ]]; then
	bundle_file="$CONFIG_ROOT/beszel-enrollment.env"
	if [[ -n "$BESZEL_ENROLLMENT_BUNDLE_B64" ]]; then
		printf '%s' "$BESZEL_ENROLLMENT_BUNDLE_B64" | base64 --decode >"$bundle_file" || die 'invalid BESZEL_ENROLLMENT_BUNDLE_B64'
		chmod 600 "$bundle_file"
	elif [[ ! -s "$bundle_file" ]]; then
		if [[ -t 0 ]]; then
			read -r -p 'Path to the Leader-generated Beszel enrollment bundle (or leave empty to defer): ' bundle_source
			if [[ -n "$bundle_source" ]]; then install -m 600 "$bundle_source" "$bundle_file"; fi
		else
			# Enrollment is intentionally retryable. An unattended bootstrap can
			# bring up Caddy, the collector, and the socket proxy before the Leader
			# bundle is transferred; the enrollment timer will finish the agent.
			printf 'Beszel enrollment bundle not provided; deferring agent enrollment to platform-beszel-enroll.timer\n' >&2
		fi
	fi
fi

restic_password="$CONFIG_ROOT/restic-password"
[[ -s "$restic_password" ]] || openssl rand -base64 48 >"$restic_password"
chmod 600 "$restic_password"
merge_image_manifest "$bootstrap_tree/ops/images.foundation.prod.env" "$CONFIG_ROOT/images.foundation.env"
merge_image_manifest "$bootstrap_tree/ops/images.apps.prod.env" "$CONFIG_ROOT/images.apps.env"
prune_stale_image_keys "$CONFIG_ROOT/images.foundation.env"
prune_stale_image_keys "$CONFIG_ROOT/images.apps.env"

# Persist the shared values generated or supplied on the Leader so the exact
# same bundle can be copied to every Follower during first deployment.
if [[ "$NODE_ROLE" == leader ]]; then
	set_key "$CONFIG_ROOT/shared-secrets.env" WOODPECKER_AGENT_SECRET "$(sed -n 's/^WOODPECKER_AGENT_SECRET=//p' "$woodpecker_env" | tail -n1)"
	set_key "$CONFIG_ROOT/shared-secrets.env" WOODPECKER_GRPC_SECRET "$(sed -n 's/^WOODPECKER_GRPC_SECRET=//p' "$woodpecker_env" | tail -n1)"
	set_key "$CONFIG_ROOT/shared-secrets.env" LEADER_PUBLIC_IP "$LEADER_PUBLIC_IP"
	set_key "$CONFIG_ROOT/shared-secrets.env" OBSERVER_INGEST_USER "$(sed -n 's/^OBSERVER_INGEST_USER=//p' "$observer_env" | tail -n1)"
	set_key "$CONFIG_ROOT/shared-secrets.env" OBSERVER_INGEST_TOKEN "$(sed -n 's/^OBSERVER_INGEST_TOKEN=//p' "$observer_env" | tail -n1)"
fi

sha="${BOOTSTRAP_RELEASE_SHA:-$(git -C "$source_checkout_root" rev-parse "origin/$MAIN_BRANCH" 2>/dev/null || git -C "$source_checkout_root" rev-parse HEAD)}"
release="$CONTROL_ROOT/releases/$sha"
[[ -e "$release" ]] || {
	install -d -m 700 "$release"
	git -C "$source_checkout_root" archive "$sha" | tar -x -C "$release"
}
ln -sfn "$release" "$CONTROL_ROOT/current"
install -d -m 700 "$APP_ROOT"
if [[ ! -e "$APP_ROOT/current" && ! -L "$APP_ROOT/current" ]]; then
	ln -s "$release" "$APP_ROOT/current"
fi
install -o root -g root -m 600 "$release/config/cluster/nodes/$NODE_ID.env" "$CONFIG_ROOT/node.env"
set_key "$CONFIG_ROOT/node.env" LEADER_PUBLIC_IP "$LEADER_PUBLIC_IP"
install -d -m 700 "$CONTROL_ROOT/descriptors"
for descriptor in "$release"/apps/*; do
	[[ -f "$descriptor/manifest.env" ]] || continue
	descriptor_id="$(basename "$descriptor")"
	install -d -m 700 "$CONTROL_ROOT/descriptors/$descriptor_id"
	install -m 600 "$descriptor/manifest.env" "$CONTROL_ROOT/descriptors/$descriptor_id/manifest.env"
done
install -d -o root -g root -m 700 "$FOUNDATION_ROOT/manifests"
for foundation_file in "$bootstrap_tree"/compose/foundation/*; do
	[[ -f "$foundation_file" ]] || continue
	foundation_mode=600
	[[ "$foundation_file" == *.sh ]] && foundation_mode=700
	install -o root -g root -m "$foundation_mode" "$foundation_file" "$FOUNDATION_ROOT/$(basename "$foundation_file")"
done
for foundation_file in "$bootstrap_tree"/compose/foundation/manifests/*.env; do
	[[ -f "$foundation_file" ]] || continue
	install -o root -g root -m 600 "$foundation_file" "$FOUNDATION_ROOT/manifests/$(basename "$foundation_file")"
done

install -d -m 700 /usr/local/libexec
for script in platformctl restart-platform backup-platform restore-platform configure-beszel configure-firewall configure-app-placement configure-app-secrets configure-observer-ingest enroll-beszel upgrade-runner platform-submit deploy-controller generate-woodpecker-workflows woodpecker-repair; do
	cat >"/usr/local/bin/$script" <<EOF
#!/bin/sh
exec /opt/platform/control/current/ops/$script.sh "\$@"
EOF
	chmod 700 "/usr/local/bin/$script"
done
cat >/usr/local/bin/git-auth.sh <<EOF
#!/bin/sh
exec /opt/platform/control/current/ops/git-auth.sh "\$@"
EOF
chmod 700 /usr/local/bin/git-auth.sh

platform_env="$CONFIG_ROOT/platform.env"
for pair in \
	"APP_ROOT=$APP_ROOT" "PLATFORM_ROOT=$PLATFORM_ROOT" "CONTROL_ROOT=$CONTROL_ROOT" "FOUNDATION_ROOT=$FOUNDATION_ROOT" \
	"REPO_URL=$REPO_URL" "MAIN_BRANCH=$MAIN_BRANCH" "APP_ENV=$app_env" "APP_IMAGE_ENV=$CONFIG_ROOT/images.apps.env" \
	"FOUNDATION_IMAGE_ENV=$CONFIG_ROOT/images.foundation.env" "FOUNDATION_ENV_ROOT=$FOUNDATION_ROOT/env" \
	"CONTROL_SYNC_STATE_FILE=$CONFIG_ROOT/control-sync.state" \
	"RUNTIME_ROOT=$APP_ROOT/shared/runtime" "PLATFORM_EDGE_NETWORK=$edge_network" "NODE_ID=$NODE_ID" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" \
	"PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock" "GITHUB_TOKEN_FILE=${GITHUB_TOKEN_FILE:-$CONFIG_ROOT/github-token}" "PLATFORM_RUNNER_IMAGE=llm-hub-lite/deploy-runner:current"; do
	set_key "$platform_env" "${pair%%=*}" "${pair#*=}"
done

for unit in "$bootstrap_tree"/ops/systemd/*; do install -o root -g root -m 644 "$unit" /etc/systemd/system/; done
systemctl daemon-reload
while IFS='=' read -r image_key image_ref; do
	[[ -n "$image_key" && "$image_key" != \#* ]] || continue
	image_required "$image_key" || {
		printf 'Skipping image for disabled or inactive service: %s\n' "$image_key"
		continue
	}
	pull_image "$image_ref"
done < <(cat "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/images.apps.env")
runner_base_image="$(sed -n 's/^FROM \([^ ]*\).*$/\1/p' "$bootstrap_tree/ops/deploy-runner/Dockerfile" | head -n1)"
[[ -n "$runner_base_image" ]] || die 'unable to determine deployment runner base image'
pull_image "$runner_base_image"
docker build --pull=false --build-arg COMPOSE_ARCH="$compose_arch" --build-arg COMPOSE_SHA256="$compose_sha256" \
	--build-arg APK_LOCK_SHA256_AMD64="$(sha256sum "$bootstrap_tree/ops/deploy-runner/apk-packages.lock.amd64" | awk '{print $1}')" \
	--build-arg APK_LOCK_SHA256_ARM64="$(sha256sum "$bootstrap_tree/ops/deploy-runner/apk-packages.lock.arm64" | awk '{print $1}')" \
	-t llm-hub-lite/deploy-runner:current "$bootstrap_tree/ops/deploy-runner"
runner_image_id="$(docker image inspect --format '{{.Id}}' llm-hub-lite/deploy-runner:current)"
[[ -n "$runner_image_id" ]] || die 'deployment runner image was not created'
set_key "$platform_env" PLATFORM_RUNNER_IMAGE_ID "$runner_image_id"
PLATFORM_ALLOW_OBSERVER_BOOTSTRAP=1 PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl validate
# Apply follower Docker ingress filtering before any public container starts.
/usr/local/bin/configure-firewall
if [[ "$NODE_ROLE" == follower ]]; then
	docker run --rm --network "$edge_network" llm-hub-lite/deploy-runner:current \
		curl --http2 -sS --connect-timeout 10 --max-time 20 -o /dev/null "https://ci-grpc.$DOMAIN_NAME/" ||
		die 'container HTTPS preflight failed; check follower firewall, DNS, and TLS connectivity to the Leader'
fi
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start caddy
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel-worker
if [[ "$NODE_ROLE" == follower && -s "$CONFIG_ROOT/beszel-enrollment.env" ]]; then /usr/local/bin/enroll-beszel; fi
if [[ "$NODE_ROLE" == leader ]]; then
	PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel-controller
	/usr/local/bin/enroll-beszel || printf 'Beszel enrollment deferred; platform-beszel-enroll.timer will retry it\n' >&2
	PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start observer-controller
	/usr/local/bin/configure-observer-ingest
fi
# Foundation files are installed into stable host paths. Recreate their
# containers so repeated recovery/bootstrap runs cannot retain an old
# bind-mounted inode (notably Vector's observer-vector.toml).
PLATFORM_RECREATE_FOUNDATION=1 PLATFORM_BOOTSTRAP_VALIDATION_REUSE=1 PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl sync all

# platform-network.service and platform-recovery.service invoke platformctl
# and need this same lock. Finish the locked backup and then release the lock
# before starting platform.target; otherwise systemd waits for the lock until
# its timeout even though this bootstrap has already reconciled all projects.
systemctl enable platform.target platform-firewall.service platform-firewall.timer platform-firewall.path platform-recovery.timer platform-health.timer platform-beszel-enroll.timer platform-woodpecker-repair.timer >/dev/null
if [[ "$NODE_BACKUP_ENABLED" == true ]]; then
	systemctl enable platform-backup.timer platform-backup-prune.timer platform-backup-check.timer >/dev/null
else
	systemctl disable --now platform-backup.timer platform-backup-prune.timer platform-backup-check.timer >/dev/null
fi
# A previous interrupted bootstrap may have left dependency units in a
# failed state. All platform projects have just passed the foreground sync,
# so clear those stale systemd result flags without starting another recovery
# transaction while the bootstrap lock is held.
systemctl reset-failed platform.target platform-network.service platform-recovery.service >/dev/null 2>&1 || true
if [[ "$BOOTSTRAP_SKIP_POST_BACKUP" == 1 ]]; then
	printf 'Skipping bootstrap post-backup by request (BOOTSTRAP_SKIP_POST_BACKUP=1)\n'
else
	PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl backup snapshot post-bootstrap
fi

# The remaining systemd operations launch platformctl in independent
# processes, so they must run after the bootstrap lock is closed. No later
# bootstrap step mutates shared state or needs this descriptor.
flock -u 9
exec 9>&-
unset PLATFORM_LOCK_HELD
start_platform_target "$BOOTSTRAP_SYSTEMD_WAIT_SECONDS"
systemctl restart platform-firewall.timer platform-firewall.path platform-recovery.timer platform-health.timer platform-beszel-enroll.timer platform-woodpecker-repair.timer
if [[ "$NODE_BACKUP_ENABLED" == true ]]; then
	systemctl restart platform-backup.timer platform-backup-prune.timer platform-backup-check.timer
fi

curl -fsS --retry "$BOOTSTRAP_ENDPOINT_RETRIES" --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time "$BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS" "https://ci.$DOMAIN_NAME/" >/dev/null || printf 'Woodpecker endpoint not ready yet; systemd recovery will retry\n' >&2
if [[ "$NODE_ROLE" == leader ]]; then
	/usr/local/bin/woodpecker-repair || printf 'Woodpecker webhook repair deferred; platform-woodpecker-repair.timer will retry\n' >&2
fi
curl -fsS --retry "$BOOTSTRAP_ENDPOINT_RETRIES" --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time "$BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS" "https://status.$DOMAIN_NAME/api/health" >/dev/null || printf 'Beszel endpoint not ready yet; systemd recovery will retry\n' >&2
print_bootstrap_summary() {
	local foundation consumers disabled manifest app_id display_name placement origin_key public_key public_host route_label route_index groups availability_note summary_observer_root component
	local -a local_consumers=()
	# Keep the summary callable from tests and recovery tooling that do not run
	# the full data-directory initialization block first.
	summary_observer_root="${observer_data_root:-${OBSERVER_DATA_ROOT:-${PLATFORM_ROOT:-/opt/platform}/observer}}"
	foundation='none'
	consumers='none'
	disabled='none'
	for manifest in "$bootstrap_tree"/compose/foundation/manifests/*.env; do
		[[ -f "$manifest" ]] || continue
		component="$(sed -n 's/^COMPONENT_ID=//p' "$manifest" | tail -n1)"
		bootstrap_foundation_enabled "$component" || continue
		[[ "$foundation" == none ]] && foundation="$component" || foundation+=", $component"
	done
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
		placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
		[[ "$placement" == consumer ]] || continue
		display_name="$(sed -n 's/^DISPLAY_NAME=//p' "$manifest" | tail -n1)"
		display_name="${display_name:-$app_id}"
		if ! app_enabled "$app_id"; then
			[[ "$disabled" == none ]] && disabled="$display_name (disabled by policy)" || disabled+=", $display_name (disabled by policy)"
			continue
		fi
		if app_active_on_node "$app_id"; then
			local_consumers+=("$display_name")
		else
			[[ "$disabled" == none ]] && disabled="$display_name (not on this node)" || disabled+=", $display_name (not on this node)"
		fi
	done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
	for display_name in "${local_consumers[@]-}"; do
		[[ -n "$display_name" ]] || continue
		[[ "$consumers" == none ]] && consumers="$display_name" || consumers+=", $display_name"
	done

	printf '\nBootstrap complete.\n\n'
	printf 'Node\n  ID: %s\n  Role: %s\n\n' "$NODE_ID" "$NODE_ROLE"
	printf 'Services\n  Foundation: %s\n  Consumers: %s\n  Disabled consumers: %s\n\n' "$foundation" "$consumers" "$disabled"
	printf 'Endpoints\n'
	if [[ "$NODE_ROLE" == leader ]]; then
		printf '  Woodpecker: https://ci.%s\n' "$DOMAIN_NAME"
		printf '  Beszel: https://status.%s\n' "$DOMAIN_NAME"
		printf '  OpenObserve: https://observer.%s\n' "$DOMAIN_NAME"
		printf '  OpenObserve ingest (DNS-only): https://observer-ingest.%s\n' "$DOMAIN_NAME"
		while IFS= read -r manifest; do
			[[ -f "$manifest" ]] || continue
			app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
			app_enabled "$app_id" || continue
			placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
			[[ "$placement" == consumer ]] || continue
			display_name="$(sed -n 's/^DISPLAY_NAME=//p' "$manifest" | tail -n1)"
			display_name="${display_name:-$app_id}"
			groups="$(sed -n 's/^ROUTE_GROUPS=//p' "$manifest" | tail -n1)"
			availability_note='available after a Follower is healthy'
			[[ "$(sed -n 's/^UPSTREAM_MODE=//p' "$manifest" | tail -n1)" == singleton ]] && availability_note='available after its selected Follower is healthy'
			route_index=0
			while IFS='|' read -r public_key _; do
				[[ -n "$public_key" ]] || continue
				public_host="$(sed -n "s/^$public_key=//p" "$app_env" | tail -n1)"
				[[ -n "$public_host" ]] || continue
				route_label="$display_name"
				if ((route_index > 0)); then route_label="$display_name ($public_key)"; fi
				[[ "$public_key" == *_ADMIN_SITE ]] && route_label="$display_name admin"
				printf '  %s: %s (%s)\n' "$route_label" "$public_host" "$availability_note"
				route_index=$((route_index + 1))
			done < <(printf '%s\n' "$groups" | tr ';' '\n')
		done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
	else
		if [[ "$consumers" != none ]]; then
			while IFS= read -r manifest; do
				[[ -f "$manifest" ]] || continue
				app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
				app_enabled "$app_id" || continue
				placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
				app_active_on_node "$app_id" || continue
				display_name="$(sed -n 's/^DISPLAY_NAME=//p' "$manifest" | tail -n1)"
				display_name="${display_name:-$app_id}"
				groups="$(sed -n 's/^ROUTE_GROUPS=//p' "$manifest" | tail -n1)"
				route_index=0
				while IFS='|' read -r _ origin_key _; do
					[[ -n "$origin_key" ]] || continue
					origin_host="$(sed -n "s/^$origin_key=//p" "$inventory_file" | tail -n1)"
					[[ -n "$origin_host" ]] || continue
					route_label="$display_name"
					if ((route_index > 0)); then route_label="$display_name ($origin_key)"; fi
					[[ "$origin_key" == *_ADMIN_ORIGIN_HOST ]] && route_label="$display_name admin"
					printf '  %s origin: https://%s\n' "$route_label" "$origin_host"
					route_index=$((route_index + 1))
				done < <(printf '%s\n' "$groups" | tr ';' '\n')
			done < <(find "$bootstrap_tree/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
		else
			printf '  No consumer endpoints are enabled on this node.\n'
		fi
	fi

	printf '\nNext tasks\n'
	if [[ "$NODE_ROLE" == leader ]]; then
		printf '  1. Transfer %s/shared-secrets.env and %s/beszel-enrollment.env to each Follower.\n' "$CONFIG_ROOT" "$CONFIG_ROOT"
		printf '  2. Bootstrap worker-1, then worker-2.\n'
		printf '  3. Sign in to Woodpecker and enable this repository as trusted.\n'
		printf '  4. Verify cluster health and Observer ingestion after both Followers join.\n'
	else
		printf '  1. Verify this node\047s origin endpoints from the Leader.\n'
		printf '  2. Verify https://chat.%s and https://chat-admin.%s.\n' "$DOMAIN_NAME" "$DOMAIN_NAME"
		printf '  3. Bootstrap the remaining Follower, or verify the full cluster if this is the final node.\n'
	fi

	printf '\nOperations\n'
	printf '  platformctl status\n  platformctl health\n  platformctl diagnose foundation\n  docker ps\n  systemctl --failed\n'
	printf '\nObserver\n  Retention: 30 days\n  Durable data: %s/data (8 GiB is an operational target, not a hard quota)\n  Collector buffer: %s/collector-buffer (bounded and excluded from backups)\n' "$summary_observer_root" "$summary_observer_root"
	printf '\nDaily deployments are workflow-driven: push to GitHub and let Woodpecker update the nodes.\n'
	printf 'SSH remains available for recovery, but is not required for routine deployments.\n'
}
print_bootstrap_summary
