#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Run this bootstrap as root on the VPS.\n' >&2
  exit 1
fi

umask 077

REPO_URL="${REPO_URL:-https://github.com/uptonking/llm-hub-lite.git}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform/woodpecker}"
SOURCE_ROOT="${SOURCE_ROOT:-/opt/platform/llm-hub-lite-bootstrap}"
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-jinyaoo86@gmail.com}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-uptonking}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

for command in git docker openssl curl ufw install; do
  need "$command"
done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'

[[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die 'DOMAIN_NAME contains unsafe characters'
[[ "$MAIN_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$MAIN_BRANCH" != *..* ]] || die 'MAIN_BRANCH contains unsafe characters'

install -d -o root -g root -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/logs" \
  "$APP_ROOT/releases" "$PLATFORM_ROOT/agent" "$SOURCE_ROOT"
# The distroless server image runs as woodpecker (UID/GID 1000).
install -d -o 1000 -g 1000 -m 700 "$PLATFORM_ROOT/data"

if [[ ! -d "$SOURCE_ROOT/.git" ]]; then
  rmdir "$SOURCE_ROOT" 2>/dev/null || true
  git clone --branch "$MAIN_BRANCH" --single-branch "$REPO_URL" "$SOURCE_ROOT"
else
  git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"
  git -C "$SOURCE_ROOT" checkout --quiet "$MAIN_BRANCH"
  git -C "$SOURCE_ROOT" reset --hard --quiet "origin/$MAIN_BRANCH"
fi

docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw --force enable >/dev/null

deploy_env=/etc/llm-hub-lite/deploy.env
production_env="$APP_ROOT/shared/.env.production"
woodpecker_env="$PLATFORM_ROOT/.env"
install -d -o root -g root -m 700 /etc/llm-hub-lite

if [[ ! -f "$production_env" ]]; then
  new_api_session_secret="$(openssl rand -hex 32)"
  cliproxy_api_key="$(openssl rand -hex 32)"
  cliproxy_management_key="$(openssl rand -hex 32)"
  {
    printf 'DOMAIN_NAME=%s\n' "$DOMAIN_NAME"
    printf 'SSL_EMAIL=%s\n' "$SSL_EMAIL"
    printf 'SHARED_NETWORK_NAME=shared_network\n'
    printf 'DATA_ROOT=%s/shared/data/prod\n' "$APP_ROOT"
    printf 'TZ=Asia/Shanghai\n'
    printf 'NEW_API_SESSION_SECRET=%s\n' "$new_api_session_secret"
    printf 'CLIPROXY_API_KEY=%s\n' "$cliproxy_api_key"
    printf 'CLIPROXY_MANAGEMENT_KEY=%s\n' "$cliproxy_management_key"
    printf 'NEW_API_SITE=https://newapi.%s\n' "$DOMAIN_NAME"
    printf 'CLIPROXY_SITE=https://cpa.%s\n' "$DOMAIN_NAME"
    printf 'WOODPECKER_SITE=https://ci.%s\n' "$DOMAIN_NAME"
    printf 'SESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME"
    printf 'CADDY_IMAGE=caddy:2.10.0@sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de\n'
    printf 'NEW_API_IMAGE=calciumion/new-api:v1.0.0-rc.25@sha256:54a0b10924aa75fa5b5947208b820ced66b6ef4b445b35f122b31d80676aba2b\n'
    printf 'CLIPROXY_IMAGE=eceasy/cli-proxy-api:v7.2.137@sha256:591a09c19de769be09a2e56277365cd568b83fc7d98c94d2e7e7bef7069f7422\n'
  } >"$production_env"
  chmod 600 "$production_env"
fi

if [[ ! -f "$woodpecker_env" ]]; then
  read -r -p 'GitHub OAuth client ID: ' github_client
  read -r -s -p 'GitHub OAuth client secret: ' github_secret
  printf '\n'
  [[ -n "$github_client" && -n "$github_secret" ]] || die 'OAuth credentials are required'
  agent_secret="$(openssl rand -hex 32)"
  {
    printf 'WOODPECKER_SERVER_IMAGE=woodpeckerci/woodpecker-server:v3.17.0@sha256:23bdea05bc35ce150d9ba768889c3f00b3a618785c85b268e8fbf9b06d5a21e0\n'
    printf 'WOODPECKER_AGENT_IMAGE=woodpeckerci/woodpecker-agent:v3.17.0@sha256:03c7b1f7b2156d00fdf4c30da77ac2bfe88d09ed818ea4627f82835ad81a98c9\n'
    printf 'WOODPECKER_DATA_ROOT=%s/data\n' "$PLATFORM_ROOT"
    printf 'WOODPECKER_AGENT_CONFIG_ROOT=%s/agent\n' "$PLATFORM_ROOT"
    printf 'WOODPECKER_HOST=https://ci.%s\n' "$DOMAIN_NAME"
    printf 'WOODPECKER_ADMIN=%s\n' "$WOODPECKER_ADMIN"
    printf 'WOODPECKER_GITHUB_CLIENT=%s\n' "$github_client"
    printf 'WOODPECKER_GITHUB_SECRET=%s\n' "$github_secret"
    printf 'WOODPECKER_AGENT_SECRET=%s\n' "$agent_secret"
    printf 'WOODPECKER_REPO_OWNERS=uptonking\n'
    printf 'WOODPECKER_AGENT_LABELS=target=production,repo=uptonking/llm-hub-lite\n'
    printf 'WOODPECKER_MAX_WORKFLOWS=1\n'
    printf 'SHARED_NETWORK_NAME=shared_network\n'
  } >"$woodpecker_env"
  chmod 600 "$woodpecker_env"
fi

cat >"$deploy_env" <<EOF
APP_ROOT=$APP_ROOT
REPO_URL=$REPO_URL
MAIN_BRANCH=$MAIN_BRANCH
ENV_FILE=$production_env
RETAIN_RELEASES=5
BACKUP_RETENTION=10
DEPLOY_LOG=$APP_ROOT/shared/logs/deploy.log
EOF
chmod 600 "$deploy_env"
install -o root -g root -m 700 "$SOURCE_ROOT/ops/deploy-controller.sh" /usr/local/bin/deploy-controller

docker build --pull=false -t llm-hub-lite/deploy-runner:0.1.0 "$SOURCE_ROOT/ops/deploy-runner"

sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH")"
DEPLOY_CONFIG_FILE="$deploy_env" /usr/local/bin/deploy-controller deploy "$sha"

docker compose --env-file "$woodpecker_env" \
  -f "$SOURCE_ROOT/ops/woodpecker/docker-compose.yml" up -d

current_release="$(readlink "$APP_ROOT/current")"
STACK_ENV_FILE="$production_env" "$current_release/stack.sh" prod reload

curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-all-errors \
  --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null

printf '\nBootstrap complete.\n'
printf 'Woodpecker: https://ci.%s/\n' "$DOMAIN_NAME"
printf 'OAuth callback: https://ci.%s/authorize\n' "$DOMAIN_NAME"
printf 'Next: activate %s in Woodpecker, disable PR/fork events, and mark it trusted.\n' "$REPO_URL"
