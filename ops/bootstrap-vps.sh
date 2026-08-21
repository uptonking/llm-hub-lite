#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$EUID" -eq 0 ]] || { printf 'Run bootstrap as root.\n' >&2; exit 1; }
umask 077

REPO_URL="${REPO_URL:-https://github.com/uptonking/llm-hub-lite.git}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/source}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-jinyaoo86@gmail.com}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-uptonking}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.33.0}"
COMPOSE_SHA256="${COMPOSE_SHA256:-6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee}"
COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
ensure_key() { local file="$1" key="$2" value="$3"; grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"; }

for command in git docker curl openssl install systemctl apt-get sha256sum ufw tar; do need "$command"; done
missing=(); for package in restic sqlite3 jq; do command -v "$package" >/dev/null 2>&1 || missing+=("$package"); done
if (( ${#missing[@]} )); then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"; fi

install -d -m 700 "$APP_ROOT/shared/data/prod/new-api" "$APP_ROOT/shared/data/prod/cliproxy" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/logs" \
  "$PLATFORM_ROOT" "$PLATFORM_ROOT/caddy/data" "$PLATFORM_ROOT/caddy/config" \
  "$PLATFORM_ROOT/woodpecker/data" "$PLATFORM_ROOT/woodpecker/agent" \
  "$PLATFORM_ROOT/beszel/hub" "$PLATFORM_ROOT/beszel/agent" "$PLATFORM_ROOT/beszel/secrets" \
  "$CONTROL_ROOT/releases" "$FOUNDATION_ROOT/env" "$CONFIG_ROOT/image-history" \
  /opt/backups/llm-hub-lite/repository /opt/backups/llm-hub-lite/restores /run/lock/llm-hub-lite

if [[ "${BOOTSTRAP_SKIP_SOURCE_UPDATE:-0}" == 1 ]]; then
  [[ -d "$SOURCE_ROOT/.git" ]] || die "SOURCE_ROOT is not a Git checkout: $SOURCE_ROOT"
else
  if [[ ! -d "$SOURCE_ROOT/.git" ]]; then git clone --branch "$MAIN_BRANCH" --single-branch "$REPO_URL" "$SOURCE_ROOT"; else git -C "$SOURCE_ROOT" fetch --prune origin "$MAIN_BRANCH"; git -C "$SOURCE_ROOT" checkout --quiet "$MAIN_BRANCH"; git -C "$SOURCE_ROOT" reset --hard --quiet "origin/$MAIN_BRANCH"; fi
fi

compose_tmp="$(mktemp)"; trap 'rm -f -- "$compose_tmp"' EXIT
if [[ ! -x "$COMPOSE_BIN" ]] || ! echo "$COMPOSE_SHA256  $COMPOSE_BIN" | sha256sum -c - >/dev/null 2>&1; then
  curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-x86_64" -o "$compose_tmp"
  echo "$COMPOSE_SHA256  $compose_tmp" | sha256sum -c - >/dev/null || die 'Compose checksum verification failed'
  install -o root -g root -m 755 "$compose_tmp" "$COMPOSE_BIN"
fi
"$COMPOSE_BIN" version >/dev/null

edge_network="${PLATFORM_EDGE_NETWORK:-platform_edge}"
docker network inspect "$edge_network" >/dev/null 2>&1 || docker network create "$edge_network" >/dev/null
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH bootstrap and recovery' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME and redirect' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw --force enable >/dev/null

app_env="$APP_ROOT/shared/.env.prod"
if [[ ! -f "$app_env" ]]; then
  {
    printf 'DOMAIN_NAME=%s\nSSL_EMAIL=%s\nSHARED_NETWORK_NAME=%s\nPLATFORM_EDGE_NETWORK=%s\n' "$DOMAIN_NAME" "$SSL_EMAIL" "$edge_network" "$edge_network"
    printf 'DATA_ROOT=%s/shared/data/prod\nTZ=Asia/Shanghai\n' "$APP_ROOT"
    printf 'SERVICE_WOODPECKER_DISABLE=false\nSERVICE_BESZEL_DISABLE=false\nAPP_NEWAPI_DISABLE=false\nAPP_CLIPROXYAPI_DISABLE=false\n'
    printf 'NEW_API_SESSION_SECRET=%s\nCLIPROXY_API_KEY=%s\nCLIPROXY_MANAGEMENT_KEY=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'NEW_API_SITE=https://newapi.%s\nCLIPROXY_SITE=https://cpa.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\nSESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
  } >"$app_env"
fi
for pair in "PLATFORM_EDGE_NETWORK=$edge_network" "SERVICE_WOODPECKER_DISABLE=false" "SERVICE_BESZEL_DISABLE=false" "APP_NEWAPI_DISABLE=false" "APP_CLIPROXYAPI_DISABLE=false"; do ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"; done
chmod 600 "$app_env"

woodpecker_env="$FOUNDATION_ROOT/env/woodpecker.env"
if [[ ! -f "$woodpecker_env" ]]; then
  read -r -p 'GitHub OAuth client ID: ' oauth_client
  read -r -s -p 'GitHub OAuth client secret: ' oauth_secret; printf '\n'
  [[ -n "$oauth_client" && -n "$oauth_secret" ]] || die 'OAuth credentials are required'
  {
    printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/woodpecker" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
    printf 'WOODPECKER_GITHUB_CLIENT=%s\nWOODPECKER_GITHUB_SECRET=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_GRPC_SECRET=%s\n' "$oauth_client" "$oauth_secret" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'WOODPECKER_REPO_OWNERS=uptonking\nWOODPECKER_AGENT_LABELS=target=production,repo=uptonking/llm-hub-lite\nWOODPECKER_MAX_WORKFLOWS=1\nWOODPECKER_DATABASE_MAX_CONNECTIONS=1\nWOODPECKER_DATABASE_IDLE_CONNECTIONS=1\nWOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false\n'
  } >"$woodpecker_env"
fi
chmod 600 "$woodpecker_env"

caddy_env="$FOUNDATION_ROOT/env/caddy.env"
{
  printf 'CADDY_DATA_ROOT=%s\nCADDY_CONFIG_ROOT=%s\nCADDY_HTTP_BIND=0.0.0.0\nCADDY_HTTPS_BIND=0.0.0.0\n' "$PLATFORM_ROOT/caddy" "$APP_ROOT/shared/runtime/config"
} >"$caddy_env"; chmod 600 "$caddy_env"

beszel_env="$FOUNDATION_ROOT/env/beszel.env"
if [[ ! -f "$beszel_env" ]]; then
  {
    printf 'BESZEL_APP_URL=https://status.%s\nBESZEL_DATA_ROOT=%s/hub\nBESZEL_AGENT_DATA_ROOT=%s/agent\n' "$DOMAIN_NAME" "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel"
    printf 'BESZEL_KEY_FILE=%s/secrets/key\nBESZEL_TOKEN_FILE=%s/secrets/token\nBESZEL_SYSTEM_NAME=%s\n' "$PLATFORM_ROOT/beszel" "$PLATFORM_ROOT/beszel" "$(hostname -f)"
    printf 'BESZEL_CONTAINER_DETAILS=false\nBESZEL_SOCKET_PROXY_PORT=2375\nBESZEL_SERVICE_PATTERNS=platform-*,docker.service,containerd.service,ssh.service\nBESZEL_HEARTBEAT_URL=\nBESZEL_HEARTBEAT_METHOD=POST\nBESZEL_HEARTBEAT_INTERVAL=60\nBESZEL_MFA_OTP=false\nBESZEL_DISABLE_PASSWORD_AUTH=false\nBESZEL_USER_CREATION=false\n'
  } >"$beszel_env"
fi
chmod 600 "$beszel_env"

beszel_credentials="$CONFIG_ROOT/beszel-initial-credentials"
if [[ ! -s "$PLATFORM_ROOT/beszel/secrets/key" || ! -s "$PLATFORM_ROOT/beszel/secrets/token" ]]; then
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

restic_password="$CONFIG_ROOT/restic-password"; [[ -s "$restic_password" ]] || openssl rand -base64 48 >"$restic_password"; chmod 600 "$restic_password"
install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.foundation.prod.env" "$CONFIG_ROOT/images.foundation.env"
install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.apps.prod.env" "$CONFIG_ROOT/images.apps.env"

sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH" 2>/dev/null || git -C "$SOURCE_ROOT" rev-parse HEAD)"
release="$CONTROL_ROOT/releases/$sha"; [[ -e "$release" ]] || { install -d -m 700 "$release"; git -C "$SOURCE_ROOT" archive "$sha" | tar -x -C "$release"; }
ln -sfn "$release" "$CONTROL_ROOT/current"
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/woodpecker.yml" "$FOUNDATION_ROOT/woodpecker.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/beszel.yml" "$FOUNDATION_ROOT/beszel.yml"

install -d -m 700 /usr/local/libexec
for script in platformctl backup-platform restore-platform configure-beszel platform-submit deploy-controller; do
  cat >"/usr/local/bin/$script" <<EOF
#!/bin/sh
exec /opt/platform/control/current/ops/$script.sh "\$@"
EOF
  chmod 700 "/usr/local/bin/$script"
done

cat >"$CONFIG_ROOT/platform.env" <<EOF
APP_ROOT=$APP_ROOT
PLATFORM_ROOT=$PLATFORM_ROOT
CONTROL_ROOT=$CONTROL_ROOT
FOUNDATION_ROOT=$FOUNDATION_ROOT
REPO_URL=$REPO_URL
MAIN_BRANCH=$MAIN_BRANCH
APP_ENV=$app_env
APP_IMAGE_ENV=$CONFIG_ROOT/images.apps.env
FOUNDATION_IMAGE_ENV=$CONFIG_ROOT/images.foundation.env
FOUNDATION_ENV_ROOT=$FOUNDATION_ROOT/env
RUNTIME_ROOT=$APP_ROOT/shared/runtime
PLATFORM_EDGE_NETWORK=$edge_network
PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock
EOF
chmod 600 "$CONFIG_ROOT/platform.env"

for unit in "$SOURCE_ROOT"/ops/systemd/*; do install -o root -g root -m 644 "$unit" /etc/systemd/system/; done
systemctl daemon-reload
docker build --pull=false -t llm-hub-lite/deploy-runner:0.3.0 "$SOURCE_ROOT/ops/deploy-runner"
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl validate
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start caddy
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel
if [[ ! -s "$PLATFORM_ROOT/beszel/secrets/key" || ! -s "$PLATFORM_ROOT/beszel/secrets/token" ]]; then
  beszel_url="https://status.$DOMAIN_NAME"
  auth_payload="$(jq -n --arg identity "admin@$DOMAIN_NAME" --arg password "$beszel_password" '{identity:$identity,password:$password}')"
  auth_response="$(curl -fsS --retry 24 --retry-delay 5 --retry-all-errors --max-time 20 -H 'Content-Type: application/json' -d "$auth_payload" "$beszel_url/api/collections/users/auth-with-password")"
  auth_token="$(jq -er '.token' <<<"$auth_response")"
  hub_key="$(curl -fsS -H "Authorization: $auth_token" "$beszel_url/api/beszel/info" | jq -er '.key')"
  agent_token="$(openssl rand -hex 24)"
  curl -fsS -H "Authorization: $auth_token" "$beszel_url/api/beszel/universal-token?enable=1&permanent=1&token=$agent_token" | jq -e '.active == true and .permanent == true' >/dev/null
  printf '%s\n' "$hub_key" >"$PLATFORM_ROOT/beszel/secrets/key"
  printf '%s\n' "$agent_token" >"$PLATFORM_ROOT/beszel/secrets/token"
  chmod 600 "$PLATFORM_ROOT/beszel/secrets/key" "$PLATFORM_ROOT/beszel/secrets/token"
  sed -i '/^BESZEL_USER_EMAIL=/d;/^BESZEL_USER_PASSWORD=/d' "$beszel_env"
fi
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start woodpecker
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start all
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl recover --quiet

systemctl enable platform.target platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer >/dev/null
systemctl restart platform.target platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl backup snapshot post-bootstrap

curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null || printf 'Woodpecker endpoint not ready yet\n' >&2
curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://status.$DOMAIN_NAME/api/health" >/dev/null || printf 'Beszel endpoint not ready yet\n' >&2
printf 'Bootstrap complete. Daily deployments are workflow-driven; SSH is not required after this step.\n'
