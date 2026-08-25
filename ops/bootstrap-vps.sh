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
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/source}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
NODE_ID="${NODE_ID:-}"
LEADER_PUBLIC_IP="${LEADER_PUBLIC_IP:-}"
BESZEL_ENROLLMENT_BUNDLE_B64="${BESZEL_ENROLLMENT_BUNDLE_B64:-}"
NEW_API_SESSION_SECRET="${NEW_API_SESSION_SECRET:-}"
NEW_API_CRYPTO_SECRET="${NEW_API_CRYPTO_SECRET:-}"
NEW_API_SQL_DSN="${NEW_API_SQL_DSN:-}"
AICHOROUTER_SESSION_SECRET="${AICHOROUTER_SESSION_SECRET:-}"
AICHOROUTER_CRYPTO_SECRET="${AICHOROUTER_CRYPTO_SECRET:-}"
CPAPI_API_KEY="${CPAPI_API_KEY:-}"
CPAPI_MANAGEMENT_KEY="${CPAPI_MANAGEMENT_KEY:-}"
LIBRECHAT_MONGO_URI="${LIBRECHAT_MONGO_URI:-}"
LIBRECHAT_REDIS_URI="${LIBRECHAT_REDIS_URI:-}"
LIBRECHAT_JWT_SECRET="${LIBRECHAT_JWT_SECRET:-}"
LIBRECHAT_JWT_REFRESH_SECRET="${LIBRECHAT_JWT_REFRESH_SECRET:-}"
LIBRECHAT_ADMIN_PANEL_SESSION_SECRET="${LIBRECHAT_ADMIN_PANEL_SESSION_SECRET:-}"
LIBRECHAT_AWS_ENDPOINT_URL="${LIBRECHAT_AWS_ENDPOINT_URL:-}"
LIBRECHAT_AWS_ACCESS_KEY_ID="${LIBRECHAT_AWS_ACCESS_KEY_ID:-}"
LIBRECHAT_AWS_SECRET_ACCESS_KEY="${LIBRECHAT_AWS_SECRET_ACCESS_KEY:-}"
LIBRECHAT_AWS_REGION="${LIBRECHAT_AWS_REGION:-auto}"
LIBRECHAT_AWS_BUCKET_NAME="${LIBRECHAT_AWS_BUCKET_NAME:-}"
LIBRECHAT_AWS_FORCE_PATH_STYLE="${LIBRECHAT_AWS_FORCE_PATH_STYLE:-true}"
AICHOROUTER_MEMORY_LIMIT="${AICHOROUTER_MEMORY_LIMIT:-768m}"
AICHOROUTER_CPUS="${AICHOROUTER_CPUS:-0.9}"
AICHOROUTER_PIDS_LIMIT="${AICHOROUTER_PIDS_LIMIT:-256}"
AICHOROUTER_GOMAXPROCS="${AICHOROUTER_GOMAXPROCS:-1}"
AICHOROUTER_GOMEMLIMIT="${AICHOROUTER_GOMEMLIMIT:-500MiB}"
AICHOROUTER_MEMORY_CACHE_ENABLED="${AICHOROUTER_MEMORY_CACHE_ENABLED:-false}"
AICHOROUTER_ERROR_LOG_ENABLED="${AICHOROUTER_ERROR_LOG_ENABLED:-false}"
AICHOROUTER_BATCH_UPDATE_ENABLED="${AICHOROUTER_BATCH_UPDATE_ENABLED:-false}"
AICHOROUTER_SQL_MAX_IDLE_CONNS="${AICHOROUTER_SQL_MAX_IDLE_CONNS:-1}"
AICHOROUTER_SQL_MAX_OPEN_CONNS="${AICHOROUTER_SQL_MAX_OPEN_CONNS:-4}"
AICHOROUTER_SQL_MAX_LIFETIME="${AICHOROUTER_SQL_MAX_LIFETIME:-60}"
AICHOROUTER_RELAY_MAX_IDLE_CONNS="${AICHOROUTER_RELAY_MAX_IDLE_CONNS:-32}"
AICHOROUTER_RELAY_MAX_IDLE_CONNS_PER_HOST="${AICHOROUTER_RELAY_MAX_IDLE_CONNS_PER_HOST:-8}"
AICHOROUTER_RELAY_IDLE_CONN_TIMEOUT="${AICHOROUTER_RELAY_IDLE_CONN_TIMEOUT:-30}"
AICHOROUTER_MAX_REQUEST_BODY_MB="${AICHOROUTER_MAX_REQUEST_BODY_MB:-16}"
AICHOROUTER_STREAM_SCANNER_MAX_BUFFER_MB="${AICHOROUTER_STREAM_SCANNER_MAX_BUFFER_MB:-32}"
AICHOROUTER_MAX_FILE_DOWNLOAD_MB="${AICHOROUTER_MAX_FILE_DOWNLOAD_MB:-32}"
AICHOROUTER_SHUTDOWN_TIMEOUT_SECONDS="${AICHOROUTER_SHUTDOWN_TIMEOUT_SECONDS:-120}"
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
RESTIC_REMOTE_ENABLED="${RESTIC_REMOTE_ENABLED:-true}"
RESTIC_REMOTE_REPOSITORY="${RESTIC_REMOTE_REPOSITORY:-}"
RESTIC_REMOTE_PASSWORD_FILE="${RESTIC_REMOTE_PASSWORD_FILE:-$CONFIG_ROOT/restic-remote-password}"
RESTIC_REMOTE_ENV_FILE="${RESTIC_REMOTE_ENV_FILE:-$CONFIG_ROOT/restic-remote.env}"
RESTIC_REMOTE_ENV_SOURCE_FILE="${RESTIC_REMOTE_ENV_SOURCE_FILE:-}"
PRODUCTION_REQUIRE_REMOTE_BACKUP="${PRODUCTION_REQUIRE_REMOTE_BACKUP:-true}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/llm-hub-lite/restic}"
RESTIC_READ_CONCURRENCY="${RESTIC_READ_CONCURRENCY:-1}"
RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-fastest}"
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
SSH_PORT="${SSH_PORT:-}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
truthy() { [[ "$1" == true || "$1" == TRUE || "$1" == 1 ]]; }
remote_enabled() { truthy "$RESTIC_REMOTE_ENABLED"; }
csv_contains() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
bootstrap_foundation_enabled() {
	local foundations disabled
	[[ "$1" == caddy ]] && return 0
	if [[ "$NODE_ROLE" == leader ]]; then
		foundations="$(sed -n 's/^FOUNDATION_LEADER=//p' "$policy_file" | tail -n1)"
	else
		foundations="$(sed -n 's/^FOUNDATION_FOLLOWER=//p' "$policy_file" | tail -n1)"
	fi
	disabled="$(sed -n 's/^DISABLED_FOUNDATION=//p' "$policy_file" | tail -n1)"
	csv_contains "$foundations" "$1" && ! csv_contains "$disabled" "$1"
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
image_required() {
	local key="$1" manifest image_key app_id
	case "$key" in
	CADDY_IMAGE) return 0 ;;
	WOODPECKER_SERVER_IMAGE) bootstrap_foundation_enabled woodpecker-controller ;;
	WOODPECKER_AGENT_IMAGE) bootstrap_foundation_enabled woodpecker-worker || bootstrap_foundation_enabled woodpecker-deployer ;;
	BESZEL_HUB_IMAGE) bootstrap_foundation_enabled beszel-controller ;;
	BESZEL_AGENT_IMAGE | BESZEL_SOCKET_PROXY_IMAGE) bootstrap_foundation_enabled beszel-worker ;;
	NEW_API_IMAGE) ((newapi_enabled)) && [[ "$NODE_ROLE" == follower ]] ;;
	LIBRECHAT_API_IMAGE | LIBRECHAT_ADMIN_IMAGE | LIBRECHAT_CLIENT_IMAGE) ((librechat_enabled)) && [[ "$NODE_ROLE" == follower ]] ;;
	*)
		while IFS= read -r manifest; do
			while IFS= read -r image_key; do
				[[ "$image_key" == "$key" ]] || continue
				app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
				app_enabled "$app_id" || return 1
				[[ "$NODE_ROLE" == follower ]] || return 1
				[[ "$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)" != single-follower || "$(app_target "$app_id")" == "$NODE_ID" ]] || return 1
				return 0
			done < <(sed -n 's/^IMAGE_KEYS=//p' "$manifest" | tail -n1 | tr ' ' '\n')
		done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
		return 1
		;;
	esac
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
ensure_key() {
	local file="$1" key="$2" value="$3"
	grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"
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
	case "$value" in replace-with-* | example.invalid | *'<'* | *'>'* | *example.* | *your-upstash* | *account-id*) printf -v "$key" '%s' '' ;; esac
}
valid_input_value() {
	local key="$1" value="$2"
	[[ -n "$value" ]] || {
		printf '%s is required and cannot be empty\n' "$key" >&2
		return 1
	}
	# Secrets and connection strings must never contain C0 controls or DEL.
	# In particular, an arrow key pasted into a prompt can introduce ESC.
	# Use printf rather than a here-string: Bash here-strings append a newline,
	# which would make every otherwise valid value look invalid.
	if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then
		printf '%s contains control characters; enter a clean single-line value\n' "$key" >&2
		return 1
	fi
}
prompt_required() {
	local key="$1" prompt="$2" secret="${3:-0}" value
	while :; do
		value="${!key:-}"
		if [[ -n "$value" ]]; then
			if valid_input_value "$key" "$value"; then
				return 0
			fi
			[[ -t 0 ]] || die "$key is invalid; provide a clean replacement through the environment or shared secret bundle"
			printf 'Please replace %s with a value containing no control characters.\n' "$key" >&2
			printf -v "$key" '%s' ''
		fi
		[[ -t 0 ]] || die "$key is required; provide it through the environment or shared secret bundle"
		if [[ "$secret" == 1 ]]; then
			if ! read -r -s -p "$prompt: " value; then die "$key input was not received"; fi
			printf '\n'
		else
			if ! read -r -p "$prompt: " value; then die "$key input was not received"; fi
		fi
		if valid_input_value "$key" "$value"; then
			printf -v "$key" '%s' "$value"
			return 0
		fi
		printf 'Please enter %s again.\n' "$key" >&2
		test -n "$value" || printf 'The value cannot be empty.\n' >&2
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
if truthy "$PRODUCTION_REQUIRE_REMOTE_BACKUP"; then
	truthy "$RESTIC_REMOTE_ENABLED" || die 'production bootstrap requires RESTIC_REMOTE_ENABLED=true'
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
fi
generate_shared_secret() {
	local key="$1"
	[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(openssl rand -hex 32)"
}
if [[ -z "$LEADER_PUBLIC_IP" && -r "$CONFIG_ROOT/node.env" ]]; then
	LEADER_PUBLIC_IP="$(sed -n 's/^LEADER_PUBLIC_IP=//p' "$CONFIG_ROOT/node.env" 2>/dev/null | tail -n1)"
fi
for shared_key in LEADER_PUBLIC_IP NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
	load_bundle_value "$shared_key"
done
for shared_key in LEADER_PUBLIC_IP NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET; do
	clear_placeholder "$shared_key"
done
for runtime_key in NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN; do
	load_runtime_value "$runtime_key" "$app_env"
done
for runtime_key in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET; do
	load_runtime_value "$runtime_key" "$app_env"
done
for runtime_key in LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE; do
	load_runtime_value "$runtime_key" "$app_env"
done
for runtime_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET; do
	load_runtime_value "$runtime_key" "$woodpecker_env"
done
if [[ -z "$NODE_ID" ]]; then read -r -p 'Stable cluster node ID (for example leader, worker-1): ' NODE_ID; fi
[[ "$NODE_ID" =~ ^[a-z][a-z0-9-]*$ ]] || die 'invalid NODE_ID'

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
if remote_enabled; then
	export RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_REMOTE_PASSWORD_FILE"
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
		if git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"; then
			return 0
		fi
		((attempt < 5)) || die "unable to fetch $MAIN_BRANCH after $attempt attempts"
		printf 'Git fetch failed; retrying in %s seconds (attempt %s/5)\n' "$((attempt * 5))" "$attempt" >&2
		sleep "$((attempt * 5))"
	done
}
git_clone_bootstrap() {
	local attempt clone_root="${SOURCE_ROOT}.bootstrap.$$"
	[[ ! -e "$SOURCE_ROOT" ]] || die "source root already exists but is not a Git checkout: $SOURCE_ROOT"
	for attempt in 1 2 3 4 5; do
		rm -rf -- "$clone_root"
		if git clone --branch "$MAIN_BRANCH" --single-branch "$source_repo_url" "$clone_root"; then
			mv -- "$clone_root" "$SOURCE_ROOT"
			return 0
		fi
		((attempt < 5)) || die "unable to clone $MAIN_BRANCH after $attempt attempts"
		printf 'Git clone failed; retrying in %s seconds (attempt %s/5)\n' "$((attempt * 5))" "$attempt" >&2
		sleep "$((attempt * 5))"
	done
}

if [[ "${BOOTSTRAP_SKIP_SOURCE_UPDATE:-0}" == 1 ]]; then
	[[ -d "$SOURCE_ROOT/.git" ]] || die "SOURCE_ROOT is not a Git checkout: $SOURCE_ROOT"
else
	if [[ ! -d "$SOURCE_ROOT/.git" ]]; then git_clone_bootstrap; else
		git -C "$SOURCE_ROOT" remote set-url origin "$source_repo_url"
		git_fetch_bootstrap
		git -C "$SOURCE_ROOT" checkout --quiet "$MAIN_BRANCH"
		git -C "$SOURCE_ROOT" reset --hard --quiet "origin/$MAIN_BRANCH"
	fi
fi

policy_file="$SOURCE_ROOT/config/cluster/policy.env"
[[ -f "$policy_file" ]] || die "missing cluster policy: $policy_file"
leader_node_id="$(sed -n 's/^LEADER_NODE_ID=//p' "$policy_file" | tail -n1)"
[[ -n "$leader_node_id" ]] || die 'cluster policy is missing LEADER_NODE_ID'
NODE_ROLE=leader
[[ "$NODE_ID" == "$leader_node_id" ]] || NODE_ROLE=follower
app_policy_file() {
	local app="$1" rel
	rel="$(sed -n 's/^POLICY_FILE=//p' "$SOURCE_ROOT/apps/$app/manifest.env" | tail -n1)"
	printf '%s/config/%s\n' "$SOURCE_ROOT" "$rel"
}
app_enabled() {
	local app="$1" file
	file="$(app_policy_file "$app")"
	[[ "$(sed -n 's/^ENABLED=//p' "$file" | tail -n1)" != false ]]
}
app_target() {
	local app="$1" key
	key="$(sed -n 's/^TARGET_NODE_KEY=//p' "$SOURCE_ROOT/apps/$app/manifest.env" | tail -n1)"
	sed -n "s/^$key=//p" "$(app_policy_file "$app")" | tail -n1
}
newapi_enabled=0
app_enabled newapi && newapi_enabled=1
librechat_enabled=0
app_enabled librechat && librechat_enabled=1
inventory_file="$SOURCE_ROOT/config/cluster/nodes/$NODE_ID.env"
[[ -f "$inventory_file" ]] || die "node is absent from cluster inventory: $NODE_ID"
prompt_required LEADER_PUBLIC_IP 'Leader public IPv4 address'
valid_ipv4 "$LEADER_PUBLIC_IP" || die 'LEADER_PUBLIC_IP must be a valid IPv4 address'
printf 'Derived node role: %s (Leader node ID: %s)\n' "$NODE_ROLE" "$leader_node_id"
[[ "$WOODPECKER_AGENT_LABELS" == node=unknown,* ]] && WOODPECKER_AGENT_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"
[[ "$WOODPECKER_DEPLOYER_LABELS" == node=unknown,* ]] && WOODPECKER_DEPLOYER_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"
if [[ "${BOOTSTRAP_ASSUME_YES:-0}" != 1 && -t 0 ]]; then
	if ! read -r -p "Continue bootstrapping $NODE_ID as $NODE_ROLE? [y/N]: " confirm; then
		die 'bootstrap confirmation was not received; rerun with ssh -tt or set BOOTSTRAP_ASSUME_YES=1'
	fi
	[[ "$confirm" =~ ^[Yy]$ ]] || die 'bootstrap cancelled'
fi
if ((newapi_enabled)); then
	prompt_required NEW_API_SQL_DSN 'Shared Neon PostgreSQL DSN'
	[[ "$NEW_API_SQL_DSN" =~ ^postgres(ql)?:// ]] || die 'New API requires a postgres:// or postgresql:// DSN'
	if [[ "$NODE_ROLE" == leader ]]; then
		generate_shared_secret NEW_API_SESSION_SECRET
		generate_shared_secret NEW_API_CRYPTO_SECRET
	else
		prompt_required NEW_API_SESSION_SECRET 'Shared New API SESSION_SECRET' 1
		prompt_required NEW_API_CRYPTO_SECRET 'Shared New API CRYPTO_SECRET' 1
	fi
fi
if ((librechat_enabled)); then
	prompt_required LIBRECHAT_MONGO_URI 'Shared LibreChat MongoDB Atlas URI' 1
	[[ "$LIBRECHAT_MONGO_URI" =~ ^mongodb(\+srv)?:// ]] || die 'LibreChat requires a mongodb:// or mongodb+srv:// URI'
	prompt_required LIBRECHAT_REDIS_URI 'Shared LibreChat Upstash Redis URI' 1
	[[ "$LIBRECHAT_REDIS_URI" =~ ^rediss:// ]] || die 'LibreChat Upstash requires a TLS rediss:// URI'
	prompt_required LIBRECHAT_AWS_ENDPOINT_URL 'Shared Cloudflare R2 endpoint URL' 0
	prompt_required LIBRECHAT_AWS_ACCESS_KEY_ID 'Shared Cloudflare R2 access key ID' 1
	prompt_required LIBRECHAT_AWS_SECRET_ACCESS_KEY 'Shared Cloudflare R2 secret access key' 1
	prompt_required LIBRECHAT_AWS_BUCKET_NAME 'Shared Cloudflare R2 bucket name' 0
	[[ "$LIBRECHAT_AWS_ENDPOINT_URL" =~ ^https:// ]] || die 'LibreChat R2 endpoint must use https://'
	if [[ "$NODE_ROLE" == leader ]]; then
		generate_shared_secret LIBRECHAT_JWT_SECRET
		generate_shared_secret LIBRECHAT_JWT_REFRESH_SECRET
		generate_shared_secret LIBRECHAT_ADMIN_PANEL_SESSION_SECRET
	else
		prompt_required LIBRECHAT_JWT_SECRET 'Shared LibreChat JWT secret' 1
		prompt_required LIBRECHAT_JWT_REFRESH_SECRET 'Shared LibreChat JWT refresh secret' 1
		prompt_required LIBRECHAT_ADMIN_PANEL_SESSION_SECRET 'Shared LibreChat admin panel session secret' 1
	fi
fi
for manifest in "$SOURCE_ROOT"/apps/*/manifest.env; do
	[[ -f "$manifest" ]] || continue
	[[ "$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)" == single-follower ]] || continue
	app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
	app_enabled "$app_id" || continue
	[[ "$NODE_ROLE" == follower && "$(app_target "$app_id")" == "$NODE_ID" ]] || continue
	secret_keys="$(sed -n 's/^SECRET_KEYS=//p' "$manifest" | tail -n1)"
	runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$manifest" | tail -n1)"
	runtime_file="$CONFIG_ROOT/$runtime_rel"
	old_ifs="$IFS"
	IFS=,
	for secret_key in $secret_keys; do
		[[ -n "$secret_key" ]] || continue
		load_runtime_value "$secret_key" "$runtime_file"
		clear_placeholder "$secret_key"
		prompt_required "$secret_key" "$app_id $secret_key" 1
	done
	IFS="$old_ifs"
done
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

edge_network="${PLATFORM_EDGE_NETWORK:-platform_edge}"
docker network inspect "$edge_network" >/dev/null 2>&1 || docker network create "$edge_network" >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT"/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw --force enable >/dev/null

app_env="$APP_ROOT/shared/.env.prod"
if [[ ! -f "$app_env" ]]; then
	{
		printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=%s\nPLATFORM_EDGE_NETWORK=%s\n' "$DOMAIN_NAME" "$SSL_EMAIL" "$edge_network" "$edge_network"
		printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
		printf 'RESTIC_REMOTE_ENABLED=%s\nRESTIC_REMOTE_REPOSITORY=%s\nRESTIC_REMOTE_PASSWORD_FILE=%s\nRESTIC_REMOTE_ENV_FILE=%s\nRESTIC_CACHE_DIR=%s\nRESTIC_READ_CONCURRENCY=%s\nRESTIC_COMPRESSION=%s\nRESTIC_SKIP_IF_UNCHANGED=%s\nRESTIC_NICE_LEVEL=%s\nRESTIC_IONICE_ENABLED=%s\nRESTIC_IONICE_CLASS=%s\nRESTIC_IONICE_LEVEL=%s\nRESTIC_SCHEDULE_INTERVAL=%s\nPRODUCTION_REQUIRE_REMOTE_BACKUP=%s\n' "$RESTIC_REMOTE_ENABLED" "$RESTIC_REMOTE_REPOSITORY" "$RESTIC_REMOTE_PASSWORD_FILE" "$RESTIC_REMOTE_ENV_FILE" "$RESTIC_CACHE_DIR" "$RESTIC_READ_CONCURRENCY" "$RESTIC_COMPRESSION" "$RESTIC_SKIP_IF_UNCHANGED" "$RESTIC_NICE_LEVEL" "$RESTIC_IONICE_ENABLED" "$RESTIC_IONICE_CLASS" "$RESTIC_IONICE_LEVEL" "$RESTIC_SCHEDULE_INTERVAL" "$PRODUCTION_REQUIRE_REMOTE_BACKUP"
		printf 'NODE_ID=%s\nCLUSTER_POLICY_FILE=%s\nNODE_CONFIG_FILE=%s/node.env\n' "$NODE_ID" "$CONTROL_ROOT/current/config/cluster/policy.env" "$CONFIG_ROOT"
		printf 'NEW_API_SESSION_SECRET=%s\nNEW_API_CRYPTO_SECRET=%s\nNEW_API_SQL_DSN=%s\n' "${NEW_API_SESSION_SECRET:-}" "${NEW_API_CRYPTO_SECRET:-}" "${NEW_API_SQL_DSN:-}"
		printf 'LIBRECHAT_MONGO_URI=%s\nLIBRECHAT_REDIS_URI=%s\nLIBRECHAT_JWT_SECRET=%s\nLIBRECHAT_JWT_REFRESH_SECRET=%s\nLIBRECHAT_ADMIN_PANEL_SESSION_SECRET=%s\nLIBRECHAT_AWS_ENDPOINT_URL=%s\nLIBRECHAT_AWS_ACCESS_KEY_ID=%s\nLIBRECHAT_AWS_SECRET_ACCESS_KEY=%s\nLIBRECHAT_AWS_REGION=%s\nLIBRECHAT_AWS_BUCKET_NAME=%s\nLIBRECHAT_AWS_FORCE_PATH_STYLE=%s\n' "$LIBRECHAT_MONGO_URI" "$LIBRECHAT_REDIS_URI" "$LIBRECHAT_JWT_SECRET" "$LIBRECHAT_JWT_REFRESH_SECRET" "$LIBRECHAT_ADMIN_PANEL_SESSION_SECRET" "$LIBRECHAT_AWS_ENDPOINT_URL" "$LIBRECHAT_AWS_ACCESS_KEY_ID" "$LIBRECHAT_AWS_SECRET_ACCESS_KEY" "$LIBRECHAT_AWS_REGION" "$LIBRECHAT_AWS_BUCKET_NAME" "$LIBRECHAT_AWS_FORCE_PATH_STYLE"
		printf 'NEW_API_SITE=https://newapi.%s\nLIBRECHAT_DOMAIN_CLIENT=https://chat.%s\nLIBRECHAT_DOMAIN_SERVER=https://chat.%s\nLIBRECHAT_ADMIN_PANEL_URL=https://chat-admin.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\nSESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
		printf 'WOODPECKER_GRPC_SITE=https://ci-grpc.%s\n' "$DOMAIN_NAME"
		while IFS= read -r manifest; do
			public_key="$(sed -n 's/^PUBLIC_URL_KEY=//p' "$manifest" | tail -n1)"
			public_host="$(sed -n 's/^PUBLIC_HOST=//p' "$manifest" | tail -n1)"
			[[ -n "$public_key" && -n "$public_host" ]] || continue
			printf '%s=https://%s.%s\n' "$public_key" "$public_host" "$DOMAIN_NAME"
		done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
	} >"$app_env"
fi
for pair in "PLATFORM_EDGE_NETWORK=$edge_network" "NODE_ID=$NODE_ID" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env" "RESTIC_REMOTE_ENV_FILE=$RESTIC_REMOTE_ENV_FILE" "RESTIC_CACHE_DIR=$RESTIC_CACHE_DIR" "RESTIC_READ_CONCURRENCY=$RESTIC_READ_CONCURRENCY" "RESTIC_COMPRESSION=$RESTIC_COMPRESSION" "RESTIC_SKIP_IF_UNCHANGED=$RESTIC_SKIP_IF_UNCHANGED" "RESTIC_NICE_LEVEL=$RESTIC_NICE_LEVEL" "RESTIC_IONICE_ENABLED=$RESTIC_IONICE_ENABLED" "RESTIC_IONICE_CLASS=$RESTIC_IONICE_CLASS" "RESTIC_IONICE_LEVEL=$RESTIC_IONICE_LEVEL" "RESTIC_SCHEDULE_INTERVAL=$RESTIC_SCHEDULE_INTERVAL" "PRODUCTION_REQUIRE_REMOTE_BACKUP=true"; do ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"; done
remove_key "$app_env" NODE_ROLE
remove_key "$app_env" LEADER_PUBLIC_IP
ensure_key "$app_env" WOODPECKER_GRPC_SITE "https://ci-grpc.$DOMAIN_NAME"
while IFS= read -r manifest; do
	public_key="$(sed -n 's/^PUBLIC_URL_KEY=//p' "$manifest" | tail -n1)"
	public_host="$(sed -n 's/^PUBLIC_HOST=//p' "$manifest" | tail -n1)"
	[[ -n "$public_key" && -n "$public_host" ]] || continue
	ensure_key "$app_env" "$public_key" "https://$public_host.$DOMAIN_NAME"
done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)

while IFS= read -r manifest; do
	[[ -f "$manifest" ]] || continue
	while IFS= read -r config_key; do
		[[ -n "$config_key" ]] || continue
		load_runtime_value "$config_key" "$app_env"
		config_value="${!config_key:-}"
		[[ -n "$config_value" ]] && ensure_key "$app_env" "$config_key" "$config_value"
	done < <(sed -n 's/^ENV_KEYS=//p' "$manifest" | tail -n1 | tr ',' '\n')
done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)

for pair in \
	"LIBRECHAT_MONGO_URI=$LIBRECHAT_MONGO_URI" "LIBRECHAT_REDIS_URI=$LIBRECHAT_REDIS_URI" \
	"LIBRECHAT_JWT_SECRET=$LIBRECHAT_JWT_SECRET" "LIBRECHAT_JWT_REFRESH_SECRET=$LIBRECHAT_JWT_REFRESH_SECRET" \
	"LIBRECHAT_ADMIN_PANEL_SESSION_SECRET=$LIBRECHAT_ADMIN_PANEL_SESSION_SECRET" "LIBRECHAT_FILE_STRATEGY=s3" \
	"LIBRECHAT_AWS_ENDPOINT_URL=$LIBRECHAT_AWS_ENDPOINT_URL" "LIBRECHAT_AWS_ACCESS_KEY_ID=$LIBRECHAT_AWS_ACCESS_KEY_ID" "LIBRECHAT_AWS_SECRET_ACCESS_KEY=$LIBRECHAT_AWS_SECRET_ACCESS_KEY" "LIBRECHAT_AWS_REGION=$LIBRECHAT_AWS_REGION" "LIBRECHAT_AWS_BUCKET_NAME=$LIBRECHAT_AWS_BUCKET_NAME" "LIBRECHAT_AWS_FORCE_PATH_STYLE=$LIBRECHAT_AWS_FORCE_PATH_STYLE" \
	"LIBRECHAT_DOMAIN_CLIENT=https://chat.$DOMAIN_NAME" "LIBRECHAT_DOMAIN_SERVER=https://chat.$DOMAIN_NAME" \
	"LIBRECHAT_ADMIN_PANEL_URL=https://chat-admin.$DOMAIN_NAME" "LIBRECHAT_SITE=https://chat.$DOMAIN_NAME" "LIBRECHAT_ADMIN_SITE=https://chat-admin.$DOMAIN_NAME" "LIBRECHAT_ALLOW_REGISTRATION=true" \
	"LIBRECHAT_USE_REDIS=true" "LIBRECHAT_USE_REDIS_STREAMS=true" "LIBRECHAT_SEARCH=false" "LIBRECHAT_MONGO_BACKUP_ENABLED=false" "LIBRECHAT_MONGO_BACKUP_NODE_ID=worker-1" \
	"LIBRECHAT_API_MEMORY_LIMIT=512m" "LIBRECHAT_API_CPUS=0.75" "LIBRECHAT_API_PIDS_LIMIT=256" "LIBRECHAT_API_NODE_OPTIONS=--max-old-space-size=384" \
	"LIBRECHAT_ADMIN_MEMORY_LIMIT=128m" "LIBRECHAT_ADMIN_CPUS=0.25" "LIBRECHAT_ADMIN_PIDS_LIMIT=128" "LIBRECHAT_ADMIN_NODE_OPTIONS=--max-old-space-size=96" \
	"LIBRECHAT_CLIENT_MEMORY_LIMIT=32m" "LIBRECHAT_CLIENT_CPUS=0.10" "LIBRECHAT_CLIENT_PIDS_LIMIT=64" \
	"LIBRECHAT_MONGO_MAX_POOL_SIZE=5" "LIBRECHAT_MONGO_MIN_POOL_SIZE=1" "LIBRECHAT_MONGO_MAX_CONNECTING=1" "LIBRECHAT_MONGO_MAX_IDLE_TIME_MS=60000" "LIBRECHAT_MONGO_WAIT_QUEUE_TIMEOUT_MS=5000" "LIBRECHAT_MONGO_AUTO_INDEX=false" "LIBRECHAT_MONGO_AUTO_CREATE=false" \
	"LIBRECHAT_REDIS_KEY_PREFIX=aichorage-librechat-prod" "LIBRECHAT_REDIS_MAX_LISTENERS=20" "LIBRECHAT_REDIS_RETRY_MAX_DELAY=2000" "LIBRECHAT_REDIS_RETRY_MAX_ATTEMPTS=0" "LIBRECHAT_REDIS_CONNECT_TIMEOUT=5000" "LIBRECHAT_REDIS_ENABLE_OFFLINE_QUEUE=false" "LIBRECHAT_USE_REDIS_CLUSTER=false" \
	"LIBRECHAT_REDIS_DELETE_CHUNK_SIZE=100" "LIBRECHAT_REDIS_UPDATE_CHUNK_SIZE=100" "LIBRECHAT_REDIS_SCAN_COUNT=100" "LIBRECHAT_FORCED_IN_MEMORY_CACHE_NAMESPACES=CONFIG_STORE,APP_CONFIG" "LIBRECHAT_MCP_REGISTRY_CACHE_TTL=30000" "LIBRECHAT_STREAM_DELTA_COALESCE_MS=25" \
	"LIBRECHAT_SCHEDULES_DISABLED=true" "LIBRECHAT_DEPLOYMENT_PLUGIN_HOOKS=false" "LIBRECHAT_CODE_SANDBOX_PREWARM=false" "LIBRECHAT_FILE_UPLOAD_SSE_ENABLED=false" "LIBRECHAT_CONVERSATION_IMPORT_MAX_FILE_SIZE_BYTES=16777216"; do
	ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"
done
chmod 600 "$app_env"

while IFS= read -r manifest; do
	[[ -f "$manifest" ]] || continue
	[[ "$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)" == single-follower ]] || continue
	app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
	app_enabled "$app_id" || continue
	[[ "$NODE_ROLE" == follower && "$(app_target "$app_id")" == "$NODE_ID" ]] || continue
	runtime_rel="$(sed -n 's/^RUNTIME_ENV_FILE=//p' "$manifest" | tail -n1)"
	runtime_file="$CONFIG_ROOT/$runtime_rel"
	secret_keys="$(sed -n 's/^SECRET_KEYS=//p' "$manifest" | tail -n1)"
	while IFS= read -r secret_key; do
		[[ -n "$secret_key" ]] || continue
		set_key "$runtime_file" "$secret_key" "${!secret_key}"
	done < <(printf '%s\n' "$secret_keys" | tr ',' '\n')
	chmod 600 "$runtime_file"
done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
for shared_key in NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE; do
	shared_value="${!shared_key:-}"
	[[ -n "$shared_value" ]] || continue
	existing_value="$(sed -n "s/^${shared_key}=//p" "$app_env" | tail -n1)"
	if [[ -n "$existing_value" && "$existing_value" != "$shared_value" && "$existing_value" != replace-with-* && "$existing_value" != file:* ]]; then
		die "$shared_key already differs from the supplied shared secret bundle"
	fi
	set_key "$app_env" "$shared_key" "$shared_value"
done

woodpecker_env="$FOUNDATION_ROOT/env/woodpecker.env"
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
if [[ ! -f "$beszel_env" ]]; then
	{
		printf 'BESZEL_APP_URL=https://status.%s\nBESZEL_DATA_ROOT=%s/hub\nBESZEL_AGENT_DATA_ROOT=%s/agent\n' "$DOMAIN_NAME" "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel"
		printf 'BESZEL_KEY_FILE=%s/secrets/key\nBESZEL_TOKEN_FILE=%s/secrets/token\nBESZEL_SYSTEM_NAME=%s\n' "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel" "$(hostname -f)"
		printf 'BESZEL_CONTAINER_DETAILS=false\nBESZEL_SOCKET_PROXY_PORT=2375\nBESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service\nBESZEL_HEARTBEAT_URL=\nBESZEL_HEARTBEAT_METHOD=POST\nBESZEL_HEARTBEAT_INTERVAL=60\nBESZEL_MFA_OTP=false\nBESZEL_DISABLE_PASSWORD_AUTH=false\nBESZEL_USER_CREATION=false\n'
	} >"$beszel_env"
fi
for pair in \
	"BESZEL_APP_URL=https://status.$DOMAIN_NAME" "BESZEL_DATA_ROOT=$PLATFORM_ROOT/beszel/hub" \
	"BESZEL_AGENT_DATA_ROOT=$PLATFORM_ROOT/beszel/agent" "BESZEL_KEY_FILE=$PLATFORM_ROOT/beszel/secrets/key" \
	"BESZEL_TOKEN_FILE=$PLATFORM_ROOT/beszel/secrets/token" "BESZEL_SYSTEM_NAME=$(hostname -f)" \
	"BESZEL_CONTAINER_DETAILS=false" "BESZEL_SOCKET_PROXY_PORT=2375" \
	"BESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service" "BESZEL_SYSTEMD_PRIVATE_SOCKET=/run/systemd/private" \
	"BESZEL_HEARTBEAT_METHOD=POST" "BESZEL_HEARTBEAT_INTERVAL=60" \
	"BESZEL_MFA_OTP=false" "BESZEL_DISABLE_PASSWORD_AUTH=false" "BESZEL_USER_CREATION=false"; do
	ensure_key "$beszel_env" "${pair%%=*}" "${pair#*=}"
done
ensure_key "$beszel_env" BESZEL_AGENT_APPARMOR unconfined
ensure_key "$beszel_env" BESZEL_HUB_URL "https://status.$DOMAIN_NAME"
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
	ensure_key "$woodpecker_env" "$shared_key" "$shared_value"
done
for shared_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
	shared_value="${!shared_key:-}"
	if [[ -n "$shared_value" ]]; then
		existing_value="$(sed -n "s/^${shared_key}=//p" "$woodpecker_env" | tail -n1)"
		if [[ -n "$existing_value" && "$existing_value" != "$shared_value" && "$existing_value" != replace-with-* ]]; then
			die "$shared_key already differs from the supplied shared secret bundle"
		fi
		set_key "$woodpecker_env" "$shared_key" "$shared_value"
	fi
done
chmod 600 "$woodpecker_env" "$beszel_env"

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
		read -r -p 'Path to the Leader-generated Beszel enrollment bundle (or leave empty to defer): ' bundle_source
		if [[ -n "$bundle_source" ]]; then install -m 600 "$bundle_source" "$bundle_file"; fi
	fi
fi

restic_password="$CONFIG_ROOT/restic-password"
[[ -s "$restic_password" ]] || openssl rand -base64 48 >"$restic_password"
chmod 600 "$restic_password"
if [[ -n "$SHARED_SECRET_BUNDLE_FILE" && -s "$SHARED_SECRET_BUNDLE_FILE" && "$SHARED_SECRET_BUNDLE_FILE" != "$CONFIG_ROOT/shared-secrets.env" ]]; then
	install -o root -g root -m 600 "$SHARED_SECRET_BUNDLE_FILE" "$CONFIG_ROOT/shared-secrets.env"
	SHARED_SECRET_BUNDLE_FILE="$CONFIG_ROOT/shared-secrets.env"
fi
merge_image_manifest "$SOURCE_ROOT/ops/images.foundation.prod.env" "$CONFIG_ROOT/images.foundation.env"
merge_image_manifest "$SOURCE_ROOT/ops/images.apps.prod.env" "$CONFIG_ROOT/images.apps.env"

# Persist the shared values generated or supplied on the Leader so the exact
# same bundle can be copied to every Follower during first deployment.
if [[ "$NODE_ROLE" == leader && ! -s "$CONFIG_ROOT/shared-secrets.env" ]]; then
	{
		printf 'NEW_API_SESSION_SECRET=%s\n' "$(sed -n 's/^NEW_API_SESSION_SECRET=//p' "$app_env" | tail -n1)"
		printf 'NEW_API_CRYPTO_SECRET=%s\n' "$(sed -n 's/^NEW_API_CRYPTO_SECRET=//p' "$app_env" | tail -n1)"
		printf 'NEW_API_SQL_DSN=%s\n' "$(sed -n 's/^NEW_API_SQL_DSN=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_MONGO_URI=%s\n' "$(sed -n 's/^LIBRECHAT_MONGO_URI=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_REDIS_URI=%s\n' "$(sed -n 's/^LIBRECHAT_REDIS_URI=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_AWS_ENDPOINT_URL=%s\nLIBRECHAT_AWS_ACCESS_KEY_ID=%s\nLIBRECHAT_AWS_SECRET_ACCESS_KEY=%s\nLIBRECHAT_AWS_REGION=%s\nLIBRECHAT_AWS_BUCKET_NAME=%s\nLIBRECHAT_AWS_FORCE_PATH_STYLE=%s\n' "$(sed -n 's/^LIBRECHAT_AWS_ENDPOINT_URL=//p' "$app_env" | tail -n1)" "$(sed -n 's/^LIBRECHAT_AWS_ACCESS_KEY_ID=//p' "$app_env" | tail -n1)" "$(sed -n 's/^LIBRECHAT_AWS_SECRET_ACCESS_KEY=//p' "$app_env" | tail -n1)" "$(sed -n 's/^LIBRECHAT_AWS_REGION=//p' "$app_env" | tail -n1)" "$(sed -n 's/^LIBRECHAT_AWS_BUCKET_NAME=//p' "$app_env" | tail -n1)" "$(sed -n 's/^LIBRECHAT_AWS_FORCE_PATH_STYLE=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_JWT_SECRET=%s\n' "$(sed -n 's/^LIBRECHAT_JWT_SECRET=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_JWT_REFRESH_SECRET=%s\n' "$(sed -n 's/^LIBRECHAT_JWT_REFRESH_SECRET=//p' "$app_env" | tail -n1)"
		printf 'LIBRECHAT_ADMIN_PANEL_SESSION_SECRET=%s\n' "$(sed -n 's/^LIBRECHAT_ADMIN_PANEL_SESSION_SECRET=//p' "$app_env" | tail -n1)"
		printf 'WOODPECKER_AGENT_SECRET=%s\n' "$(sed -n 's/^WOODPECKER_AGENT_SECRET=//p' "$woodpecker_env" | tail -n1)"
		printf 'WOODPECKER_GRPC_SECRET=%s\n' "$(sed -n 's/^WOODPECKER_GRPC_SECRET=//p' "$woodpecker_env" | tail -n1)"
	} >"$CONFIG_ROOT/shared-secrets.env"
	chmod 600 "$CONFIG_ROOT/shared-secrets.env"
fi
if [[ "$NODE_ROLE" == leader ]]; then
	set_key "$CONFIG_ROOT/shared-secrets.env" LEADER_PUBLIC_IP "$LEADER_PUBLIC_IP"
fi

sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH" 2>/dev/null || git -C "$SOURCE_ROOT" rev-parse HEAD)"
release="$CONTROL_ROOT/releases/$sha"
[[ -e "$release" ]] || {
	install -d -m 700 "$release"
	git -C "$SOURCE_ROOT" archive "$sha" | tar -x -C "$release"
}
ln -sfn "$release" "$CONTROL_ROOT/current"
install -o root -g root -m 600 "$release/config/cluster/nodes/$NODE_ID.env" "$CONFIG_ROOT/node.env"
set_key "$CONFIG_ROOT/node.env" LEADER_PUBLIC_IP "$LEADER_PUBLIC_IP"
install -d -m 700 "$CONTROL_ROOT/descriptors"
for descriptor in "$release"/apps/*; do
	[[ -f "$descriptor/manifest.env" ]] || continue
	descriptor_id="$(basename "$descriptor")"
	install -d -m 700 "$CONTROL_ROOT/descriptors/$descriptor_id"
	install -m 600 "$descriptor/manifest.env" "$CONTROL_ROOT/descriptors/$descriptor_id/manifest.env"
done
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
for foundation_file in woodpecker-controller.yml woodpecker-worker.yml woodpecker-deployer.yml beszel-controller.yml beszel-worker.yml; do
	install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/$foundation_file" "$FOUNDATION_ROOT/$foundation_file"
done

install -d -m 700 /usr/local/libexec
for script in platformctl restart-platform backup-platform restore-platform configure-beszel configure-firewall configure-app-secrets enroll-beszel upgrade-runner platform-submit deploy-controller generate-woodpecker-workflows; do
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
	"RUNTIME_ROOT=$APP_ROOT/shared/runtime" "PLATFORM_EDGE_NETWORK=$edge_network" "NODE_ID=$NODE_ID" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" \
	"PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock" "GITHUB_TOKEN_FILE=${GITHUB_TOKEN_FILE:-$CONFIG_ROOT/github-token}" "PLATFORM_RUNNER_IMAGE=llm-hub-lite/deploy-runner:current"; do
	set_key "$platform_env" "${pair%%=*}" "${pair#*=}"
done

for unit in "$SOURCE_ROOT"/ops/systemd/*; do install -o root -g root -m 644 "$unit" /etc/systemd/system/; done
systemctl daemon-reload
while IFS='=' read -r image_key image_ref; do
	[[ -n "$image_key" && "$image_key" != \#* ]] || continue
	image_required "$image_key" || {
		printf 'Skipping image for disabled or inactive service: %s\n' "$image_key"
		continue
	}
	pull_image "$image_ref"
done < <(cat "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/images.apps.env")
runner_base_image="$(sed -n 's/^FROM \([^ ]*\).*$/\1/p' "$SOURCE_ROOT/ops/deploy-runner/Dockerfile" | head -n1)"
[[ -n "$runner_base_image" ]] || die 'unable to determine deployment runner base image'
pull_image "$runner_base_image"
docker build --pull=false --build-arg COMPOSE_ARCH="$compose_arch" --build-arg COMPOSE_SHA256="$compose_sha256" \
	--build-arg APK_LOCK_SHA256_AMD64="$(sha256sum "$SOURCE_ROOT/ops/deploy-runner/apk-packages.lock.amd64" | awk '{print $1}')" \
	--build-arg APK_LOCK_SHA256_ARM64="$(sha256sum "$SOURCE_ROOT/ops/deploy-runner/apk-packages.lock.arm64" | awk '{print $1}')" \
	-t llm-hub-lite/deploy-runner:current "$SOURCE_ROOT/ops/deploy-runner"
runner_image_id="$(docker image inspect --format '{{.Id}}' llm-hub-lite/deploy-runner:current)"
[[ -n "$runner_image_id" ]] || die 'deployment runner image was not created'
set_key "$platform_env" PLATFORM_RUNNER_IMAGE_ID "$runner_image_id"
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl validate
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
fi
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl sync all
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl recover --quiet

systemctl enable platform.target platform-firewall.service platform-firewall.timer platform-firewall.path platform-recovery.timer platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer platform-beszel-enroll.timer >/dev/null
systemctl restart platform-firewall.service platform.target platform-firewall.timer platform-firewall.path platform-recovery.timer platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer platform-beszel-enroll.timer
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl backup snapshot post-bootstrap

curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null || printf 'Woodpecker endpoint not ready yet\n' >&2
curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://status.$DOMAIN_NAME/api/health" >/dev/null || printf 'Beszel endpoint not ready yet\n' >&2
print_bootstrap_summary() {
	local foundation consumers disabled manifest app_id display_name placement origin_key public_key public_host route_label route_index groups availability_note
	local -a local_consumers=()
	foundation='Caddy, Beszel Agent'
	consumers='none'
	disabled='none'
	if [[ "$NODE_ROLE" == leader ]]; then
		foundation='Caddy, Beszel Hub, Beszel Agent, Woodpecker Server, Woodpecker Deployer'
	else
		foundation='Caddy, Beszel Agent, Woodpecker Agent'
	fi
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
		placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
		case "$placement" in follower | single-follower) ;; *) continue ;; esac
		display_name="$(sed -n 's/^DISPLAY_NAME=//p' "$manifest" | tail -n1)"
		display_name="${display_name:-$app_id}"
		if ! app_enabled "$app_id"; then
			[[ "$disabled" == none ]] && disabled="$display_name (disabled by policy)" || disabled+=", $display_name (disabled by policy)"
			continue
		fi
		if [[ "$NODE_ROLE" == follower && ("$placement" == follower || ("$placement" == single-follower && "$(app_target "$app_id")" == "$NODE_ID")) ]]; then
			local_consumers+=("$display_name")
		else
			[[ "$disabled" == none ]] && disabled="$display_name (not on this node)" || disabled+=", $display_name (not on this node)"
		fi
	done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
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
		while IFS= read -r manifest; do
			[[ -f "$manifest" ]] || continue
			app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
			app_enabled "$app_id" || continue
			placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
			case "$placement" in follower | single-follower) ;; *) continue ;; esac
			display_name="$(sed -n 's/^DISPLAY_NAME=//p' "$manifest" | tail -n1)"
			display_name="${display_name:-$app_id}"
			groups="$(sed -n 's/^ROUTE_GROUPS=//p' "$manifest" | tail -n1)"
			availability_note='available after a Follower is healthy'
			[[ "$placement" == single-follower ]] && availability_note='available after its selected Follower is healthy'
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
		done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
	else
		if [[ "$consumers" != none ]]; then
			while IFS= read -r manifest; do
				[[ -f "$manifest" ]] || continue
				app_id="$(sed -n 's/^APP_ID=//p' "$manifest" | tail -n1)"
				app_enabled "$app_id" || continue
				placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
				[[ "$placement" == follower || ("$placement" == single-follower && "$(app_target "$app_id")" == "$NODE_ID") ]] || continue
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
			done < <(find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort)
		else
			printf '  No consumer endpoints are enabled on this node.\n'
		fi
	fi

	printf '\nNext tasks\n'
	if [[ "$NODE_ROLE" == leader ]]; then
		printf '  1. Transfer %s/shared-secrets.env and %s/beszel-enrollment.env to each Follower.\n' "$CONFIG_ROOT" "$CONFIG_ROOT"
		printf '  2. Bootstrap worker-1, then worker-2.\n'
		printf '  3. Sign in to Woodpecker and enable this repository as trusted.\n'
		printf '  4. Verify cluster health after both Followers join.\n'
	else
		printf '  1. Verify this node\047s origin endpoints from the Leader.\n'
		printf '  2. Verify https://chat.%s and https://chat-admin.%s.\n' "$DOMAIN_NAME" "$DOMAIN_NAME"
		printf '  3. Bootstrap the remaining Follower, or verify the full cluster if this is the final node.\n'
	fi

	printf '\nOperations\n'
	printf '  platformctl status\n  platformctl health\n  docker ps\n  systemctl --failed\n'
	printf '\nDaily deployments are workflow-driven: push to GitHub and let Woodpecker update the nodes.\n'
	printf 'SSH remains available for recovery, but is not required for routine deployments.\n'
}
print_bootstrap_summary
