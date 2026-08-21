#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then printf 'Run this bootstrap as root on the VPS.\n' >&2; exit 1; fi
umask 077

REPO_URL="${REPO_URL:-https://github.com/uptonking/llm-hub-lite.git}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
WOODPECKER_ROOT="${WOODPECKER_ROOT:-$PLATFORM_ROOT/woodpecker}"
BESZEL_ROOT="${BESZEL_ROOT:-$PLATFORM_ROOT/beszel}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/llm-hub-lite-bootstrap}"
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-jinyaoo86@gmail.com}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-uptonking}"
BESZEL_ADMIN_EMAIL="${BESZEL_ADMIN_EMAIL:-admin@$DOMAIN_NAME}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
ensure_env_key() { local file="$1" key="$2" value="$3"; grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"; }

for command in git docker openssl curl ufw install systemctl apt-get; do need "$command"; done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'
[[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die 'DOMAIN_NAME contains unsafe characters'
[[ "$MAIN_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$MAIN_BRANCH" != *..* ]] || die 'MAIN_BRANCH contains unsafe characters'

missing_packages=()
command -v restic >/dev/null 2>&1 || missing_packages+=(restic)
command -v sqlite3 >/dev/null 2>&1 || missing_packages+=(sqlite3)
command -v jq >/dev/null 2>&1 || missing_packages+=(jq)
if (( ${#missing_packages[@]} )); then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"; fi

install -d -o root -g root -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/logs" "$APP_ROOT/releases" \
  "$WOODPECKER_ROOT/agent" "$BESZEL_ROOT/hub" "$BESZEL_ROOT/agent" "$BESZEL_ROOT/secrets" "$SOURCE_ROOT" \
  /etc/llm-hub-lite /opt/backups/llm-hub-lite /run/lock/llm-hub-lite
install -d -o 1000 -g 1000 -m 700 "$WOODPECKER_ROOT/data"

if [[ ! -d "$SOURCE_ROOT/.git" ]]; then rmdir "$SOURCE_ROOT" 2>/dev/null || true; git clone --branch "$MAIN_BRANCH" --single-branch "$REPO_URL" "$SOURCE_ROOT"; else git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"; git -C "$SOURCE_ROOT" checkout --quiet "$MAIN_BRANCH"; git -C "$SOURCE_ROOT" reset --hard --quiet "origin/$MAIN_BRANCH"; fi
docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null

ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null; ufw allow 443/udp comment 'HTTP/3' >/dev/null; ufw --force enable >/dev/null

deploy_env=/etc/llm-hub-lite/deploy.env
restic_password=/etc/llm-hub-lite/restic-password
beszel_credentials=/etc/llm-hub-lite/beszel-initial-credentials
production_env="$APP_ROOT/shared/.env.production"
woodpecker_env="$WOODPECKER_ROOT/.env"
beszel_env="$BESZEL_ROOT/.env"

if [[ ! -f "$production_env" ]]; then
  {
    printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=shared_network\n' "$DOMAIN_NAME" "$SSL_EMAIL"
    printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
    printf 'NEW_API_SESSION_SECRET=%s\nCLIPROXY_API_KEY=%s\nCLIPROXY_MANAGEMENT_KEY=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'NEW_API_SITE=https://newapi.%s\nCLIPROXY_SITE=https://cpa.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
    printf 'SESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME"
    printf 'CADDY_IMAGE=caddy:2.10.0@sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de\nNEW_API_IMAGE=calciumion/new-api:v1.0.0-rc.25@sha256:54a0b10924aa75fa5b5947208b820ced66b6ef4b445b35f122b31d80676aba2b\nCLIPROXY_IMAGE=eceasy/cli-proxy-api:v7.2.137@sha256:591a09c19de769be09a2e56277365cd568b83fc7d98c94d2e7e7bef7069f7422\n'
  } >"$production_env"
fi
ensure_env_key "$production_env" BESZEL_SITE "https://status.$DOMAIN_NAME"; chmod 600 "$production_env"

if [[ ! -f "$woodpecker_env" ]]; then
  read -r -p 'GitHub OAuth client ID: ' github_client; read -r -s -p 'GitHub OAuth client secret: ' github_secret; printf '\n'
  [[ -n "$github_client" && -n "$github_secret" ]] || die 'OAuth credentials are required'
  {
    printf 'WOODPECKER_SERVER_IMAGE=woodpeckerci/woodpecker-server:v3.17.0@sha256:23bdea05bc35ce150d9ba768889c3f00b3a618785c85b268e8fbf9b06d5a21e0\nWOODPECKER_AGENT_IMAGE=woodpeckerci/woodpecker-agent:v3.17.0@sha256:03c7b1f7b2156d00fdf4c30da77ac2bfe88d09ed818ea4627f82835ad81a98c9\n'
    printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' "$WOODPECKER_ROOT" "$WOODPECKER_ROOT" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
    printf 'WOODPECKER_GITHUB_CLIENT=%s\nWOODPECKER_GITHUB_SECRET=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_GRPC_SECRET=%s\n' "$github_client" "$github_secret" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'WOODPECKER_REPO_OWNERS=uptonking\nWOODPECKER_AGENT_LABELS=target=production,repo=uptonking/llm-hub-lite\nWOODPECKER_MAX_WORKFLOWS=1\nWOODPECKER_DATABASE_MAX_CONNECTIONS=1\nWOODPECKER_DATABASE_IDLE_CONNECTIONS=1\nWOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false\nSHARED_NETWORK_NAME=shared_network\n'
  } >"$woodpecker_env"
fi
chmod 600 "$woodpecker_env"

beszel_needs_enrollment=false
if [[ ! -f "$beszel_env" ]]; then
  {
    printf 'BESZEL_HUB_IMAGE=henrygd/beszel:0.18.7@sha256:a849ad80814b6a1a3be665304dcace5d4854b3bed7bde4dd1227e8ce1b82d477\nBESZEL_AGENT_IMAGE=henrygd/beszel-agent:0.18.7@sha256:8874e2c53f9de5e063a6a80d6b617e20fa593ac5dc4eb4c6ce1f912f510f38f8\n'
    printf 'BESZEL_APP_URL=https://status.%s\nBESZEL_DATA_ROOT=%s/hub\nBESZEL_AGENT_DATA_ROOT=%s/agent\n' "$DOMAIN_NAME" "$BESZEL_ROOT" "$BESZEL_ROOT"
    printf 'BESZEL_KEY_FILE=%s/secrets/key\nBESZEL_TOKEN_FILE=%s/secrets/token\nBESZEL_SYSTEM_NAME=%s\nSHARED_NETWORK_NAME=shared_network\n' "$BESZEL_ROOT" "$BESZEL_ROOT" "$(hostname -f)"
    printf 'BESZEL_MFA_OTP=false\nBESZEL_DISABLE_PASSWORD_AUTH=false\nBESZEL_USER_CREATION=false\n'
  } >"$beszel_env"
fi
if [[ ! -s "$BESZEL_ROOT/secrets/key" || ! -s "$BESZEL_ROOT/secrets/token" ]]; then
  if [[ ! -e "$BESZEL_ROOT/hub/data.db" ]]; then
    beszel_password="$(openssl rand -base64 36 | tr -d '=+/')"
    printf 'email=%s\npassword=%s\n' "$BESZEL_ADMIN_EMAIL" "$beszel_password" >"$beszel_credentials"; chmod 600 "$beszel_credentials"
    ensure_env_key "$beszel_env" BESZEL_USER_EMAIL "$BESZEL_ADMIN_EMAIL"; ensure_env_key "$beszel_env" BESZEL_USER_PASSWORD "$beszel_password"; beszel_needs_enrollment=true
  else printf 'Beszel data exists but agent secrets are absent; leaving the hub running for manual enrollment.\n' >&2; fi
fi
chmod 600 "$beszel_env"
if [[ ! -s "$restic_password" ]]; then openssl rand -base64 48 >"$restic_password"; fi; chmod 600 "$restic_password"

install -o root -g root -m 600 "$SOURCE_ROOT/ops/woodpecker/docker-compose.yml" "$WOODPECKER_ROOT/docker-compose.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/ops/beszel/docker-compose.yml" "$BESZEL_ROOT/docker-compose.yml"
install -o root -g root -m 700 "$SOURCE_ROOT/ops/deploy-controller.sh" /usr/local/bin/deploy-controller
install -o root -g root -m 700 "$SOURCE_ROOT/ops/platformctl.sh" /usr/local/bin/platformctl
install -o root -g root -m 700 "$SOURCE_ROOT/ops/backup-platform.sh" /usr/local/bin/backup-platform
install -o root -g root -m 700 "$SOURCE_ROOT/ops/restore-platform.sh" /usr/local/bin/restore-platform
install -o root -g root -m 644 "$SOURCE_ROOT"/ops/systemd/* /etc/systemd/system/

cat >"$deploy_env" <<EOF
APP_ROOT=$APP_ROOT
REPO_URL=$REPO_URL
MAIN_BRANCH=$MAIN_BRANCH
ENV_FILE=$production_env
RETAIN_RELEASES=5
BACKUP_RETENTION=10
DEPLOY_LOG=$APP_ROOT/shared/logs/deploy.log
PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock
EOF
chmod 600 "$deploy_env"

docker build --pull=false -t llm-hub-lite/deploy-runner:0.1.0 "$SOURCE_ROOT/ops/deploy-runner"
sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH")"
DEPLOY_CONFIG_FILE="$deploy_env" /usr/local/bin/deploy-controller deploy "$sha"
/usr/local/bin/platformctl start beszel

if [[ "$beszel_needs_enrollment" == true ]]; then
  beszel_url="https://status.$DOMAIN_NAME"
  auth_payload="$(jq -n --arg identity "$BESZEL_ADMIN_EMAIL" --arg password "$beszel_password" '{identity:$identity,password:$password}')"
  auth_response="$(curl --fail --silent --show-error --retry 24 --retry-delay 5 --retry-all-errors --max-time 20 -H 'Content-Type: application/json' -d "$auth_payload" "$beszel_url/api/collections/users/auth-with-password")"
  auth_token="$(jq -er '.token' <<<"$auth_response")"
  hub_key="$(curl --fail --silent --show-error -H "Authorization: $auth_token" "$beszel_url/api/beszel/info" | jq -er '.key')"
  agent_token="$(openssl rand -hex 24)"
  curl --fail --silent --show-error -H "Authorization: $auth_token" "$beszel_url/api/beszel/universal-token?enable=1&permanent=1&token=$agent_token" | jq -e '.active == true and .permanent == true' >/dev/null
  printf '%s\n' "$hub_key" >"$BESZEL_ROOT/secrets/key"; printf '%s\n' "$agent_token" >"$BESZEL_ROOT/secrets/token"; chmod 600 "$BESZEL_ROOT/secrets/key" "$BESZEL_ROOT/secrets/token"
  sed -i '/^BESZEL_USER_EMAIL=/d;/^BESZEL_USER_PASSWORD=/d' "$beszel_env"
  /usr/local/bin/platformctl restart beszel
fi

/usr/local/bin/platformctl start woodpecker
/usr/local/bin/platformctl recover
/usr/local/bin/platformctl backup post-bootstrap
systemctl daemon-reload
systemctl enable platform.target platform-health.timer platform-backup.timer >/dev/null
systemctl start platform.target platform-health.timer platform-backup.timer
curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null
curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://status.$DOMAIN_NAME/api/health" >/dev/null

printf '\nBootstrap complete.\nWoodpecker: https://ci.%s/\nBeszel: https://status.%s/\n' "$DOMAIN_NAME" "$DOMAIN_NAME"
[[ -f "$beszel_credentials" ]] && printf 'Beszel initial login file: %s\n' "$beszel_credentials"
printf 'OAuth callback: https://ci.%s/authorize\nBackups: /opt/backups/llm-hub-lite/repository\n' "$DOMAIN_NAME"
