#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$EUID" -eq 0 ]] || { printf 'Run this bootstrap as root on the VPS.\n' >&2; exit 1; }
umask 077

REPO_URL="${REPO_URL:-https://github.com/uptonking/llm-hub-lite.git}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
WOODPECKER_ROOT="${WOODPECKER_ROOT:-$PLATFORM_ROOT/woodpecker}"
BESZEL_ROOT="${BESZEL_ROOT:-$PLATFORM_ROOT/beszel}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/llm-hub-lite-bootstrap}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-jinyaoo86@gmail.com}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-uptonking}"
BESZEL_ADMIN_EMAIL="${BESZEL_ADMIN_EMAIL:-admin@$DOMAIN_NAME}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.33.0}"
COMPOSE_SHA256="${COMPOSE_SHA256:-6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee}"
COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}"
BOOTSTRAP_SKIP_SOURCE_UPDATE="${BOOTSTRAP_SKIP_SOURCE_UPDATE:-0}"
BOOTSTRAP_SKIP_APP_DEPLOY="${BOOTSTRAP_SKIP_APP_DEPLOY:-0}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
ensure_env_key() { local file="$1" key="$2" value="$3"; grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"; }

for command in git docker openssl curl ufw install systemctl apt-get sha256sum; do need "$command"; done
[[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die 'DOMAIN_NAME contains unsafe characters'
[[ "$MAIN_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$MAIN_BRANCH" != *..* ]] || die 'MAIN_BRANCH contains unsafe characters'

missing_packages=()
for package in restic sqlite3 jq; do command -v "$package" >/dev/null 2>&1 || missing_packages+=("$package"); done
if (( ${#missing_packages[@]} )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

install -d -o root -g root -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/logs" "$APP_ROOT/releases" \
  "$WOODPECKER_ROOT/agent" "$BESZEL_ROOT/hub" "$BESZEL_ROOT/agent" "$BESZEL_ROOT/secrets" \
  "$CONFIG_ROOT/image-history" /opt/backups/llm-hub-lite /opt/backups/llm-hub-lite/restores /run/lock/llm-hub-lite
install -d -o 1000 -g 1000 -m 700 "$WOODPECKER_ROOT/data"

if [[ "$BOOTSTRAP_SKIP_SOURCE_UPDATE" == 1 ]]; then
  [[ -f "$SOURCE_ROOT/ops/platformctl.sh" && -f "$SOURCE_ROOT/docker-compose.base.yml" ]] || die 'offline SOURCE_ROOT is incomplete'
elif [[ ! -d "$SOURCE_ROOT/.git" ]]; then
  git clone --branch "$MAIN_BRANCH" --single-branch "$REPO_URL" "$SOURCE_ROOT"
else
  git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"
  git -C "$SOURCE_ROOT" checkout --quiet "$MAIN_BRANCH"
  git -C "$SOURCE_ROOT" reset --hard --quiet "origin/$MAIN_BRANCH"
fi

compose_tmp="$(mktemp)"
trap 'rm -f -- "$compose_tmp"' EXIT
if [[ ! -x "$COMPOSE_BIN" ]] || ! echo "$COMPOSE_SHA256  $COMPOSE_BIN" | sha256sum -c - >/dev/null 2>&1; then
  curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-x86_64" -o "$compose_tmp"
  echo "$COMPOSE_SHA256  $compose_tmp" | sha256sum -c - >/dev/null || die 'Docker Compose checksum verification failed'
  install -o root -g root -m 755 "$compose_tmp" "$COMPOSE_BIN"
fi
"$COMPOSE_BIN" version >/dev/null

docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw --force enable >/dev/null

deploy_env="$CONFIG_ROOT/deploy.env"
image_env="$CONFIG_ROOT/images.env"
restic_password="$CONFIG_ROOT/restic-password"
beszel_credentials="$CONFIG_ROOT/beszel-initial-credentials"
production_env="$APP_ROOT/shared/.env.prod"
woodpecker_env="$WOODPECKER_ROOT/.env"
beszel_env="$BESZEL_ROOT/.env"

if [[ ! -f "$production_env" ]]; then
  {
    printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=shared_network\n' "$DOMAIN_NAME" "$SSL_EMAIL"
    printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
    printf 'NEW_API_SESSION_SECRET=%s\nCLIPROXY_API_KEY=%s\nCLIPROXY_MANAGEMENT_KEY=%s\n' \
      "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'NEW_API_SITE=https://newapi.%s\nCLIPROXY_SITE=https://cpa.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\n' \
      "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
    printf 'SESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME"
  } >"$production_env"
fi
ensure_env_key "$production_env" BESZEL_SITE "https://status.$DOMAIN_NAME"
chmod 600 "$production_env"

if [[ ! -f "$woodpecker_env" ]]; then
  read -r -p 'GitHub OAuth client ID: ' github_client
  read -r -s -p 'GitHub OAuth client secret: ' github_secret
  printf '\n'
  [[ -n "$github_client" && -n "$github_secret" ]] || die 'OAuth credentials are required'
  {
    printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' \
      "$WOODPECKER_ROOT" "$WOODPECKER_ROOT" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
    printf 'WOODPECKER_GITHUB_CLIENT=%s\nWOODPECKER_GITHUB_SECRET=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_GRPC_SECRET=%s\n' \
      "$github_client" "$github_secret" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'WOODPECKER_REPO_OWNERS=uptonking\nWOODPECKER_AGENT_LABELS=target=production,repo=uptonking/llm-hub-lite\n'
    printf 'WOODPECKER_MAX_WORKFLOWS=1\nWOODPECKER_DATABASE_MAX_CONNECTIONS=1\nWOODPECKER_DATABASE_IDLE_CONNECTIONS=1\n'
    printf 'WOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false\nSHARED_NETWORK_NAME=shared_network\n'
  } >"$woodpecker_env"
fi
chmod 600 "$woodpecker_env"

beszel_needs_enrollment=false
if [[ ! -f "$beszel_env" ]]; then
  {
    printf 'BESZEL_APP_URL=https://status.%s\nBESZEL_DATA_ROOT=%s/hub\nBESZEL_AGENT_DATA_ROOT=%s/agent\n' "$DOMAIN_NAME" "$BESZEL_ROOT" "$BESZEL_ROOT"
    printf 'BESZEL_KEY_FILE=%s/secrets/key\nBESZEL_TOKEN_FILE=%s/secrets/token\nBESZEL_SYSTEM_NAME=%s\n' \
      "$BESZEL_ROOT" "$BESZEL_ROOT" "$(hostname -f)"
    printf 'BESZEL_CONTAINER_DETAILS=false\nBESZEL_SOCKET_PROXY_PORT=2375\n'
    printf 'BESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service\n'
    printf 'BESZEL_HEARTBEAT_URL=\nBESZEL_HEARTBEAT_METHOD=POST\nBESZEL_HEARTBEAT_INTERVAL=60\n'
    printf 'BESZEL_MFA_OTP=false\nBESZEL_DISABLE_PASSWORD_AUTH=false\nBESZEL_USER_CREATION=false\nSHARED_NETWORK_NAME=shared_network\n'
  } >"$beszel_env"
fi
for entry in \
  'BESZEL_CONTAINER_DETAILS=false' \
  'BESZEL_SOCKET_PROXY_PORT=2375' \
  'BESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service' \
  'BESZEL_HEARTBEAT_URL=' \
  'BESZEL_HEARTBEAT_METHOD=POST' \
  'BESZEL_HEARTBEAT_INTERVAL=60'; do
  ensure_env_key "$beszel_env" "${entry%%=*}" "${entry#*=}"
done

if [[ ! -s "$BESZEL_ROOT/secrets/key" || ! -s "$BESZEL_ROOT/secrets/token" ]]; then
  if [[ ! -e "$BESZEL_ROOT/hub/data.db" ]]; then
    beszel_password="$(openssl rand -base64 36 | tr -d '=+/')"
    printf 'email=%s\npassword=%s\n' "$BESZEL_ADMIN_EMAIL" "$beszel_password" >"$beszel_credentials"
    chmod 600 "$beszel_credentials"
    ensure_env_key "$beszel_env" BESZEL_USER_EMAIL "$BESZEL_ADMIN_EMAIL"
    ensure_env_key "$beszel_env" BESZEL_USER_PASSWORD "$beszel_password"
    beszel_needs_enrollment=true
  else
    printf 'Beszel data exists but agent secrets are absent; leaving the hub running for manual enrollment.\n' >&2
  fi
fi
chmod 600 "$beszel_env"

if [[ ! -s "$restic_password" ]]; then openssl rand -base64 48 >"$restic_password"; fi
chmod 600 "$restic_password"
if [[ ! -f "$image_env" ]]; then install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.prod.env" "$image_env"; fi

# Image selection belongs exclusively to the reviewed manifest.
for env_file in "$production_env" "$woodpecker_env" "$beszel_env"; do
  sed -i '/^CADDY_IMAGE=/d;/^NEW_API_IMAGE=/d;/^CLIPROXY_IMAGE=/d;/^WOODPECKER_SERVER_IMAGE=/d;/^WOODPECKER_AGENT_IMAGE=/d;/^BESZEL_HUB_IMAGE=/d;/^BESZEL_AGENT_IMAGE=/d;/^BESZEL_SOCKET_PROXY_IMAGE=/d' "$env_file"
done

install -o root -g root -m 600 "$SOURCE_ROOT/ops/woodpecker/docker-compose.yml" "$WOODPECKER_ROOT/docker-compose.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/ops/beszel/docker-compose.yml" "$BESZEL_ROOT/docker-compose.yml"
for script in deploy-controller platformctl backup-platform restore-platform configure-beszel; do
  install -o root -g root -m 700 "$SOURCE_ROOT/ops/$script.sh" "/usr/local/bin/$script"
done

install -o root -g root -m 644 "$SOURCE_ROOT"/ops/systemd/* /etc/systemd/system/

cat >"$deploy_env" <<EOF
APP_ROOT=$APP_ROOT
REPO_URL=$REPO_URL
MAIN_BRANCH=$MAIN_BRANCH
ENV_FILE=$production_env
IMAGE_ENV_FILE=$image_env
RETAIN_RELEASES=5
DEPLOY_LOG=$APP_ROOT/shared/logs/deploy.log
PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock
EOF
chmod 600 "$deploy_env"

docker build --pull=false -t llm-hub-lite/deploy-runner:0.2.0 "$SOURCE_ROOT/ops/deploy-runner"
if [[ "$BOOTSTRAP_SKIP_APP_DEPLOY" == 1 ]]; then
  install -d -m 700 "$APP_ROOT/shared/runtime/config"
  install -m 700 "$SOURCE_ROOT/stack.sh" "$APP_ROOT/shared/runtime/stack.sh"
  install -m 600 "$SOURCE_ROOT/docker-compose.base.yml" "$APP_ROOT/shared/runtime/docker-compose.base.yml"
  install -m 600 "$SOURCE_ROOT/docker-compose.prod.yml" "$APP_ROOT/shared/runtime/docker-compose.prod.yml"
  find "$APP_ROOT/shared/runtime/config" -mindepth 1 -delete
  cp -a "$SOURCE_ROOT/config/." "$APP_ROOT/shared/runtime/config/"
else
  sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH")"
  current_sha="$(basename "$(readlink "$APP_ROOT/current" 2>/dev/null || true)")"
  if [[ "$current_sha" != "$sha" || ! -f "$APP_ROOT/shared/runtime/docker-compose.base.yml" ]]; then
    DEPLOY_CONFIG_FILE="$deploy_env" /usr/local/bin/deploy-controller deploy "$sha"
  else
    printf 'Application release %s is already current; skipping duplicate deployment.\n' "$sha"
  fi
fi

"$COMPOSE_BIN" --env-file "$beszel_env" --env-file "$image_env" -f "$BESZEL_ROOT/docker-compose.yml" pull
"$COMPOSE_BIN" --env-file "$woodpecker_env" --env-file "$image_env" -f "$WOODPECKER_ROOT/docker-compose.yml" pull
"$COMPOSE_BIN" --env-file "$production_env" --env-file "$image_env" \
  -f "$APP_ROOT/shared/runtime/docker-compose.base.yml" -f "$APP_ROOT/shared/runtime/docker-compose.prod.yml" pull

PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel
if [[ "$beszel_needs_enrollment" == true ]]; then
  beszel_url="https://status.$DOMAIN_NAME"
  auth_payload="$(jq -n --arg identity "$BESZEL_ADMIN_EMAIL" --arg password "$beszel_password" '{identity:$identity,password:$password}')"
  auth_response="$(curl -fsS --retry 24 --retry-delay 5 --retry-all-errors --max-time 20 -H 'Content-Type: application/json' -d "$auth_payload" "$beszel_url/api/collections/users/auth-with-password")"
  auth_token="$(jq -er '.token' <<<"$auth_response")"
  hub_key="$(curl -fsS -H "Authorization: $auth_token" "$beszel_url/api/beszel/info" | jq -er '.key')"
  agent_token="$(openssl rand -hex 24)"
  curl -fsS -H "Authorization: $auth_token" "$beszel_url/api/beszel/universal-token?enable=1&permanent=1&token=$agent_token" | jq -e '.active == true and .permanent == true' >/dev/null
  printf '%s\n' "$hub_key" >"$BESZEL_ROOT/secrets/key"
  printf '%s\n' "$agent_token" >"$BESZEL_ROOT/secrets/token"
  chmod 600 "$BESZEL_ROOT/secrets/key" "$BESZEL_ROOT/secrets/token"
  sed -i '/^BESZEL_USER_EMAIL=/d;/^BESZEL_USER_PASSWORD=/d' "$beszel_env"
  PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel
fi

PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start woodpecker
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl recover
/usr/local/bin/configure-beszel || printf 'Beszel alert configuration deferred\n' >&2
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl backup snapshot post-bootstrap

systemctl daemon-reload
systemctl reset-failed
systemctl enable platform.target platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer >/dev/null
systemctl restart platform.target platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer

curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null
curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://status.$DOMAIN_NAME/api/health" >/dev/null

printf '\nBootstrap complete.\nWoodpecker: https://ci.%s/\nBeszel: https://status.%s/\n' "$DOMAIN_NAME" "$DOMAIN_NAME"
[[ -f "$beszel_credentials" ]] && printf 'Save then remove the Beszel initial login file: %s\n' "$beszel_credentials"
printf 'OAuth callback: https://ci.%s/authorize\nBackups: /opt/backups/llm-hub-lite/repository\n' "$DOMAIN_NAME"
