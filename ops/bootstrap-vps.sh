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
CLIPROXY_API_KEY="${CLIPROXY_API_KEY:-}"
CLIPROXY_MANAGEMENT_KEY="${CLIPROXY_MANAGEMENT_KEY:-}"
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
LOW_MEMORY_SWAP_ENABLED="${LOW_MEMORY_SWAP_ENABLED:-true}"
LOW_MEMORY_SWAPFILE="${LOW_MEMORY_SWAPFILE:-/swapfile}"
LOW_MEMORY_SWAP_SIZE="${LOW_MEMORY_SWAP_SIZE:-1G}"
LOW_MEMORY_SWAP_SWAPPINESS="${LOW_MEMORY_SWAP_SWAPPINESS:-10}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
truthy() { [[ "$1" == true || "$1" == TRUE || "$1" == 1 ]]; }
remote_enabled() { truthy "$RESTIC_REMOTE_ENABLED"; }
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
prompt_required() {
	local key="$1" prompt="$2" secret="${3:-0}"
	[[ -n "${!key:-}" ]] && return 0
	[[ -t 0 ]] || die "$key is required; provide it through the environment or shared secret bundle"
	if [[ "$secret" == 1 ]]; then
		read -r -s -p "$prompt: " value
		printf '\n'
	else
		read -r -p "$prompt: " value
	fi
	[[ -n "${value:-}" ]] || die "$key is required and cannot be empty"
	printf -v "$key" '%s' "$value"
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
		[[ -t 0 ]] || die "production bootstrap requires remote Restic password file: $RESTIC_REMOTE_PASSWORD_FILE"
		read -r -s -p 'Remote Restic password: ' restic_remote_password
		printf '\n'
		[[ -n "$restic_remote_password" ]] || die 'remote Restic password cannot be empty'
		install -d -m 700 "$(dirname "$RESTIC_REMOTE_PASSWORD_FILE")"
		printf '%s\n' "$restic_remote_password" >"$RESTIC_REMOTE_PASSWORD_FILE"
		chmod 600 "$RESTIC_REMOTE_PASSWORD_FILE"
	fi
fi
generate_shared_secret() {
	local key="$1"
	[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(openssl rand -hex 32)"
}
if [[ -z "$LEADER_PUBLIC_IP" ]]; then
	LEADER_PUBLIC_IP="$(sed -n 's/^LEADER_PUBLIC_IP=//p' "$CONFIG_ROOT/node.env" 2>/dev/null | tail -n1)"
fi
for shared_key in LEADER_PUBLIC_IP NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
	load_bundle_value "$shared_key"
done
for shared_key in LEADER_PUBLIC_IP NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET; do
	clear_placeholder "$shared_key"
done
for runtime_key in NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY; do
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

need apt-get
bootstrap_packages=()
for pair in curl:curl gpg:gnupg git:git openssl:openssl ufw:ufw iptables:iptables tar:tar flock:util-linux; do
	command="${pair%%:*}"
	package="${pair#*:}"
	command -v "$command" >/dev/null 2>&1 || bootstrap_packages+=("$package")
done
if ((${#bootstrap_packages[@]})); then
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates "${bootstrap_packages[@]}"
fi
for command in git curl openssl install systemctl apt-get sha256sum ufw iptables base64 tar gpg dpkg cmp; do need "$command"; done
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

install -d -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/data/prod/librechat/uploads" "$APP_ROOT/shared/data/prod/librechat/images" "$APP_ROOT/shared/data/prod/librechat/skills" "$APP_ROOT/shared/data/prod/librechat/logs" "$APP_ROOT/shared/data/prod/librechat/data" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/logs" \
	"$PLATFORM_ROOT" "$PLATFORM_ROOT/caddy/data" "$PLATFORM_ROOT/caddy/config" \
	"$PLATFORM_ROOT/woodpecker/data" "$PLATFORM_ROOT/woodpecker/agent" \
	"$PLATFORM_ROOT/beszel/hub" "$PLATFORM_ROOT/beszel/agent" "$PLATFORM_ROOT/beszel/secrets" \
	"$CONTROL_ROOT/releases" "$FOUNDATION_ROOT/env" "$CONFIG_ROOT/image-history" \
	/opt/backups/llm-hub-lite/repository /opt/backups/llm-hub-lite/restores /run/lock/llm-hub-lite

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

if [[ "${BOOTSTRAP_SKIP_SOURCE_UPDATE:-0}" == 1 ]]; then
	[[ -d "$SOURCE_ROOT/.git" ]] || die "SOURCE_ROOT is not a Git checkout: $SOURCE_ROOT"
else
	if [[ ! -d "$SOURCE_ROOT/.git" ]]; then git clone --branch "$MAIN_BRANCH" --single-branch "$source_repo_url" "$SOURCE_ROOT"; else
		git -C "$SOURCE_ROOT" remote set-url origin "$source_repo_url"
		git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"
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
disabled_apps=",$(sed -n 's/^DISABLED_APPS=//p' "$policy_file" | tail -n1 | tr -d '[:space:]'),"
app_enabled() { [[ "$disabled_apps" != *",$1,"* ]]; }
newapi_enabled=0
app_enabled newapi && newapi_enabled=1
cliproxy_enabled=0
app_enabled cliproxyapi && cliproxy_enabled=1
librechat_enabled=0
app_enabled librechat && librechat_enabled=1
inventory_file="$SOURCE_ROOT/config/cluster/nodes/$NODE_ID.env"
[[ -f "$inventory_file" ]] || die "node is absent from cluster inventory: $NODE_ID"
prompt_required LEADER_PUBLIC_IP 'Leader public IPv4 address'
valid_ipv4 "$LEADER_PUBLIC_IP" || die 'LEADER_PUBLIC_IP must be a valid IPv4 address'
printf 'Derived node role: %s (Leader node ID: %s)\n' "$NODE_ROLE" "$leader_node_id"
[[ "$WOODPECKER_AGENT_LABELS" == node=unknown,* ]] && WOODPECKER_AGENT_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"
[[ "$WOODPECKER_DEPLOYER_LABELS" == node=unknown,* ]] && WOODPECKER_DEPLOYER_LABELS="node=$NODE_ID,deployment=true,target=production,repo=$REPO_SLUG"
if [[ -t 0 ]]; then
	read -r -p "Continue bootstrapping $NODE_ID as $NODE_ROLE? [y/N]: " confirm
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
if ((cliproxy_enabled)); then
	if [[ "$NODE_ROLE" == leader ]]; then
		generate_shared_secret CLIPROXY_API_KEY
		generate_shared_secret CLIPROXY_MANAGEMENT_KEY
	else
		prompt_required CLIPROXY_API_KEY 'Shared CLIProxyAPI API key' 1
		prompt_required CLIPROXY_MANAGEMENT_KEY 'Shared CLIProxyAPI management key' 1
	fi
fi
if ((librechat_enabled)); then
	prompt_required LIBRECHAT_MONGO_URI 'Shared LibreChat MongoDB Atlas URI' 1
	[[ "$LIBRECHAT_MONGO_URI" =~ ^mongodb(\+srv)?:// ]] || die 'LibreChat requires a mongodb:// or mongodb+srv:// URI'
	prompt_required LIBRECHAT_REDIS_URI 'Shared LibreChat Upstash Redis URI' 1
	[[ "$LIBRECHAT_REDIS_URI" =~ ^rediss?:// ]] || die 'LibreChat requires a redis:// or rediss:// URI'
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
ufw allow 22/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
if [[ "$NODE_ROLE" == leader ]]; then
	ufw allow 443/tcp comment 'HTTPS' >/dev/null
	ufw allow 443/udp comment 'HTTP/3' >/dev/null
else
	ufw allow from "$LEADER_PUBLIC_IP" to any port 443 proto tcp comment 'Leader to follower HTTPS' >/dev/null
	ufw allow from "$LEADER_PUBLIC_IP" to any port 443 proto udp comment 'Leader to follower HTTP/3' >/dev/null
fi
ufw --force enable >/dev/null

app_env="$APP_ROOT/shared/.env.prod"
if [[ ! -f "$app_env" ]]; then
	{
		printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=%s\nPLATFORM_EDGE_NETWORK=%s\n' "$DOMAIN_NAME" "$SSL_EMAIL" "$edge_network" "$edge_network"
		printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
		printf 'RESTIC_REMOTE_ENABLED=%s\nRESTIC_REMOTE_REPOSITORY=%s\nRESTIC_REMOTE_PASSWORD_FILE=%s\nRESTIC_REMOTE_ENV_FILE=%s\nPRODUCTION_REQUIRE_REMOTE_BACKUP=%s\n' "$RESTIC_REMOTE_ENABLED" "$RESTIC_REMOTE_REPOSITORY" "$RESTIC_REMOTE_PASSWORD_FILE" "$RESTIC_REMOTE_ENV_FILE" "$PRODUCTION_REQUIRE_REMOTE_BACKUP"
		printf 'NODE_ID=%s\nCLUSTER_POLICY_FILE=%s\nNODE_CONFIG_FILE=%s/node.env\n' "$NODE_ID" "$CONTROL_ROOT/current/config/cluster/policy.env" "$CONFIG_ROOT"
		printf 'NEW_API_SESSION_SECRET=%s\nNEW_API_CRYPTO_SECRET=%s\nNEW_API_SQL_DSN=%s\nCLIPROXY_API_KEY=%s\nCLIPROXY_MANAGEMENT_KEY=%s\n' "${NEW_API_SESSION_SECRET:-}" "${NEW_API_CRYPTO_SECRET:-}" "${NEW_API_SQL_DSN:-}" "${CLIPROXY_API_KEY:-}" "${CLIPROXY_MANAGEMENT_KEY:-}"
		printf 'LIBRECHAT_MONGO_URI=%s\nLIBRECHAT_REDIS_URI=%s\nLIBRECHAT_JWT_SECRET=%s\nLIBRECHAT_JWT_REFRESH_SECRET=%s\nLIBRECHAT_ADMIN_PANEL_SESSION_SECRET=%s\nLIBRECHAT_AWS_ENDPOINT_URL=%s\nLIBRECHAT_AWS_ACCESS_KEY_ID=%s\nLIBRECHAT_AWS_SECRET_ACCESS_KEY=%s\nLIBRECHAT_AWS_REGION=%s\nLIBRECHAT_AWS_BUCKET_NAME=%s\nLIBRECHAT_AWS_FORCE_PATH_STYLE=%s\n' "$LIBRECHAT_MONGO_URI" "$LIBRECHAT_REDIS_URI" "$LIBRECHAT_JWT_SECRET" "$LIBRECHAT_JWT_REFRESH_SECRET" "$LIBRECHAT_ADMIN_PANEL_SESSION_SECRET" "$LIBRECHAT_AWS_ENDPOINT_URL" "$LIBRECHAT_AWS_ACCESS_KEY_ID" "$LIBRECHAT_AWS_SECRET_ACCESS_KEY" "$LIBRECHAT_AWS_REGION" "$LIBRECHAT_AWS_BUCKET_NAME" "$LIBRECHAT_AWS_FORCE_PATH_STYLE"
		printf 'NEW_API_SITE=https://newapi.%s\nCLIPROXY_SITE=https://cpa.%s\nLIBRECHAT_DOMAIN_CLIENT=https://chat.%s\nLIBRECHAT_DOMAIN_SERVER=https://chat.%s\nLIBRECHAT_ADMIN_PANEL_URL=https://chat-admin.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\nSESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
		printf 'WOODPECKER_GRPC_SITE=https://ci-grpc.%s\n' "$DOMAIN_NAME"
	} >"$app_env"
fi
for pair in "PLATFORM_EDGE_NETWORK=$edge_network" "NODE_ID=$NODE_ID" "CLUSTER_POLICY_FILE=$CONTROL_ROOT/current/config/cluster/policy.env" "NODE_CONFIG_FILE=$CONFIG_ROOT/node.env" "RESTIC_REMOTE_ENV_FILE=$RESTIC_REMOTE_ENV_FILE" "PRODUCTION_REQUIRE_REMOTE_BACKUP=true"; do ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"; done
remove_key "$app_env" NODE_ROLE
remove_key "$app_env" LEADER_PUBLIC_IP
ensure_key "$app_env" WOODPECKER_GRPC_SITE "https://ci-grpc.$DOMAIN_NAME"
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
for shared_key in NEW_API_SESSION_SECRET NEW_API_CRYPTO_SECRET NEW_API_SQL_DSN CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_REGION LIBRECHAT_AWS_BUCKET_NAME LIBRECHAT_AWS_FORCE_PATH_STYLE; do
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
	if [[ "$NODE_ROLE" == leader && -z "$oauth_client" ]]; then
		read -r -p 'GitHub OAuth client ID: ' oauth_client
	fi
	if [[ "$NODE_ROLE" == leader && -z "$oauth_secret" ]]; then
		read -r -s -p 'GitHub OAuth client secret: ' oauth_secret
		printf '\n'
	fi
	if [[ "$NODE_ROLE" == leader ]]; then
		[[ -n "$oauth_client" && -n "$oauth_secret" ]] || die 'OAuth credentials are required'
	fi
	{
		printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/woodpecker" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
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
	"WOODPECKER_DATA_ROOT=$PLATFORM_ROOT/woodpecker/data" "WOODPECKER_AGENT_CONFIG_ROOT=$PLATFORM_ROOT/woodpecker/agent" \
	"WOODPECKER_HOST=https://ci.$DOMAIN_NAME" "WOODPECKER_ADMIN=$WOODPECKER_ADMIN" \
	"WOODPECKER_REPO_OWNERS=$WOODPECKER_REPO_OWNERS" "WOODPECKER_AGENT_LABELS=$WOODPECKER_AGENT_LABELS" \
	"WOODPECKER_DEPLOYER_LABELS=$WOODPECKER_DEPLOYER_LABELS" "WOODPECKER_AGENT_SERVER=ci-grpc.$DOMAIN_NAME:443" \
	"WOODPECKER_DEPLOYER_SERVER=ci-grpc.$DOMAIN_NAME:443" "WOODPECKER_GRPC_SECURE=true" "WOODPECKER_GRPC_SKIP_VERIFY=false" \
	"WOODPECKER_MAX_WORKFLOWS=1" "WOODPECKER_DATABASE_MAX_CONNECTIONS=1" "WOODPECKER_DATABASE_IDLE_CONNECTIONS=1" \
	"WOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false"; do
	ensure_key "$woodpecker_env" "${pair%%=*}" "${pair#*=}"
done
if [[ "$NODE_ROLE" == leader ]]; then
	if [[ -z "$(sed -n 's/^WOODPECKER_GITHUB_CLIENT=//p' "$woodpecker_env" | tail -n1)" ]]; then
		read -r -p 'GitHub OAuth client ID: ' oauth_client
		[[ -n "$oauth_client" ]] || die 'OAuth client ID is required'
		set_key "$woodpecker_env" WOODPECKER_GITHUB_CLIENT "$oauth_client"
	fi
	if [[ -z "$(sed -n 's/^WOODPECKER_GITHUB_SECRET=//p' "$woodpecker_env" | tail -n1)" ]]; then
		read -r -s -p 'GitHub OAuth client secret: ' oauth_secret
		printf '\n'
		[[ -n "$oauth_secret" ]] || die 'OAuth client secret is required'
		set_key "$woodpecker_env" WOODPECKER_GITHUB_SECRET "$oauth_secret"
	fi
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
	[[ -e "$PLATFORM_ROOT/beszel/secrets/key" ]] && mv -f -- "$PLATFORM_ROOT/beszel/secrets/key" "$PLATFORM_ROOT/beszel/secrets/orphaned/key.$orphan_stamp" || true
	[[ -e "$PLATFORM_ROOT/beszel/secrets/token" ]] && mv -f -- "$PLATFORM_ROOT/beszel/secrets/token" "$PLATFORM_ROOT/beszel/secrets/orphaned/token.$orphan_stamp" || true
	beszel_key_exists=0
	beszel_token_exists=0
fi
if ((beszel_key_exists == 0)); then
	install -d -m 700 "$PLATFORM_ROOT/beszel/secrets" "$PLATFORM_ROOT/beszel/hub" "$PLATFORM_ROOT/beszel/agent"
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
[[ -s "$CONFIG_ROOT/images.foundation.env" ]] || install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.foundation.prod.env" "$CONFIG_ROOT/images.foundation.env"
[[ -s "$CONFIG_ROOT/images.apps.env" ]] || install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.apps.prod.env" "$CONFIG_ROOT/images.apps.env"

# Persist the shared values generated or supplied on the Leader so the exact
# same bundle can be copied to every Follower during first deployment.
if [[ "$NODE_ROLE" == leader && ! -s "$CONFIG_ROOT/shared-secrets.env" ]]; then
	{
		printf 'NEW_API_SESSION_SECRET=%s\n' "$(sed -n 's/^NEW_API_SESSION_SECRET=//p' "$app_env" | tail -n1)"
		printf 'NEW_API_CRYPTO_SECRET=%s\n' "$(sed -n 's/^NEW_API_CRYPTO_SECRET=//p' "$app_env" | tail -n1)"
		printf 'NEW_API_SQL_DSN=%s\n' "$(sed -n 's/^NEW_API_SQL_DSN=//p' "$app_env" | tail -n1)"
		printf 'CLIPROXY_API_KEY=%s\n' "$(sed -n 's/^CLIPROXY_API_KEY=//p' "$app_env" | tail -n1)"
		printf 'CLIPROXY_MANAGEMENT_KEY=%s\n' "$(sed -n 's/^CLIPROXY_MANAGEMENT_KEY=//p' "$app_env" | tail -n1)"
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
for script in platformctl restart-platform backup-platform restore-platform configure-beszel enroll-beszel upgrade-runner platform-submit deploy-controller generate-woodpecker-workflows; do
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
	docker pull "$image_ref"
done < <(cat "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/images.apps.env")
runner_base_image="$(sed -n 's/^FROM \([^ ]*\).*$/\1/p' "$SOURCE_ROOT/ops/deploy-runner/Dockerfile" | head -n1)"
[[ -n "$runner_base_image" ]] || die 'unable to determine deployment runner base image'
docker pull "$runner_base_image"
docker build --pull=false --build-arg COMPOSE_ARCH="$compose_arch" --build-arg COMPOSE_SHA256="$compose_sha256" \
	--build-arg APK_LOCK_SHA256_AMD64="$(sha256sum "$SOURCE_ROOT/ops/deploy-runner/apk-packages.lock.amd64" | awk '{print $1}')" \
	--build-arg APK_LOCK_SHA256_ARM64="$(sha256sum "$SOURCE_ROOT/ops/deploy-runner/apk-packages.lock.arm64" | awk '{print $1}')" \
	-t llm-hub-lite/deploy-runner:current "$SOURCE_ROOT/ops/deploy-runner"
runner_image_id="$(docker image inspect --format '{{.Id}}' llm-hub-lite/deploy-runner:current)"
[[ -n "$runner_image_id" ]] || die 'deployment runner image was not created'
set_key "$platform_env" PLATFORM_RUNNER_IMAGE_ID "$runner_image_id"
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl validate
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
printf 'Bootstrap complete. Daily deployments are workflow-driven; SSH is not required after this step.\n'
