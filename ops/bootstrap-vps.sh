#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$EUID" -eq 0 ]] || { printf 'Run bootstrap as root.\n' >&2; exit 1; }
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
DOMAIN_NAME="${DOMAIN_NAME:-aichorage.de}"
SSL_EMAIL="${SSL_EMAIL:-admin@$DOMAIN_NAME}"
WOODPECKER_REPO_OWNERS="${WOODPECKER_REPO_OWNERS:-${REPO_SLUG%%/*}}"
WOODPECKER_AGENT_LABELS="${WOODPECKER_AGENT_LABELS:-target=production,repo=$REPO_SLUG}"
WOODPECKER_ADMIN="${WOODPECKER_ADMIN:-${REPO_SLUG%%/*}}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.33.0}"
COMPOSE_SHA256_AMD64="${COMPOSE_SHA256_AMD64:-6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee}"
COMPOSE_SHA256_ARM64="${COMPOSE_SHA256_ARM64:-03a42a0fc0614ffc3c9ebca521cab75e02c427b68e45e3f6867d9510b9a28818}"
COMPOSE_SHA256_OVERRIDE="${COMPOSE_SHA256:-}"
COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid REPO_SLUG: $REPO_SLUG"
ensure_key() { local file="$1" key="$2" value="$3"; grep -q "^${key}=" "$file" 2>/dev/null || printf '%s=%s\n' "$key" "$value" >>"$file"; }
set_key() {
  local file="$1" key="$2" value="$3" tmp
  install -d -m 700 "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  [[ -f "$file" ]] && sed "/^${key}=/d" "$file" >"$tmp"
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$file"
}

install_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  [[ -r /etc/os-release ]] || die 'Docker installation requires /etc/os-release'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "unsupported OS for automatic Docker installation: ${ID:-unknown}" ;; esac
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

need apt-get
bootstrap_packages=()
for pair in curl:curl gpg:gnupg git:git openssl:openssl ufw:ufw tar:tar flock:util-linux; do
  command="${pair%%:*}"; package="${pair#*:}"
  command -v "$command" >/dev/null 2>&1 || bootstrap_packages+=("$package")
done
if (( ${#bootstrap_packages[@]} )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates "${bootstrap_packages[@]}"
fi
for command in git curl openssl install systemctl apt-get sha256sum ufw tar gpg dpkg cmp; do need "$command"; done
install_docker
need docker
missing=(); for package in restic sqlite3 jq; do command -v "$package" >/dev/null 2>&1 || missing+=("$package"); done
if (( ${#missing[@]} )); then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"; fi
need jq
configure_docker_daemon
systemctl enable --now docker.service

install -d -m 700 "$APP_ROOT/shared/data/prod" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/logs" \
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

case "$(uname -m)" in
  x86_64|amd64) compose_arch=x86_64 ;;
  aarch64|arm64) compose_arch=aarch64 ;;
  *) die "unsupported architecture for Docker Compose: $(uname -m)" ;;
esac
if [[ -n "$COMPOSE_SHA256_OVERRIDE" ]]; then
  compose_sha256="$COMPOSE_SHA256_OVERRIDE"
elif [[ "$compose_arch" == x86_64 ]]; then
  compose_sha256="$COMPOSE_SHA256_AMD64"
else
  compose_sha256="$COMPOSE_SHA256_ARM64"
fi
compose_tmp="$(mktemp)"; trap 'rm -f -- "$compose_tmp"' EXIT
if [[ ! -x "$COMPOSE_BIN" ]] || ! echo "$compose_sha256  $COMPOSE_BIN" | sha256sum -c - >/dev/null 2>&1; then
  curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$compose_arch" -o "$compose_tmp"
  echo "$compose_sha256  $compose_tmp" | sha256sum -c - >/dev/null || die 'Compose checksum verification failed'
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
    printf 'RESTIC_REMOTE_ENABLED=false\nRESTIC_REMOTE_REPOSITORY=\nRESTIC_REMOTE_PASSWORD_FILE=%s/restic-remote-password\n' "$CONFIG_ROOT"
    printf 'SERVICE_WOODPECKER_DISABLE=false\nSERVICE_BESZEL_DISABLE=false\nAPP_NEWAPI_DISABLE=false\nAPP_CLIPROXYAPI_DISABLE=false\n'
    printf 'NEW_API_SESSION_SECRET=%s\nCLIPROXY_API_KEY=%s\nCLIPROXY_MANAGEMENT_KEY=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'NEW_API_SITE=https://newapi.%s\nCLIPROXY_SITE=https://cpa.%s\nWOODPECKER_SITE=https://ci.%s\nBESZEL_SITE=https://status.%s\nSESSION_COOKIE_TRUSTED_URL=https://newapi.%s\n' "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME" "$DOMAIN_NAME"
  } >"$app_env"
fi
for pair in "PLATFORM_EDGE_NETWORK=$edge_network" "SERVICE_WOODPECKER_DISABLE=false" "SERVICE_BESZEL_DISABLE=false" "APP_NEWAPI_DISABLE=false" "APP_CLIPROXYAPI_DISABLE=false"; do ensure_key "$app_env" "${pair%%=*}" "${pair#*=}"; done
chmod 600 "$app_env"

woodpecker_env="$FOUNDATION_ROOT/env/woodpecker.env"
if [[ ! -f "$woodpecker_env" ]]; then
  woodpecker_disabled="$(sed -n 's/^SERVICE_WOODPECKER_DISABLE=//p' "$app_env" | tail -n1)"
  if [[ "$woodpecker_disabled" == true || "$woodpecker_disabled" == TRUE || "$woodpecker_disabled" == 1 ]]; then
    oauth_client=disabled
    oauth_secret=disabled
  else
    read -r -p 'GitHub OAuth client ID: ' oauth_client
    read -r -s -p 'GitHub OAuth client secret: ' oauth_secret; printf '\n'
    [[ -n "$oauth_client" && -n "$oauth_secret" ]] || die 'OAuth credentials are required'
  fi
  {
    printf 'WOODPECKER_DATA_ROOT=%s/data\nWOODPECKER_AGENT_CONFIG_ROOT=%s/agent\nWOODPECKER_HOST=https://ci.%s\nWOODPECKER_ADMIN=%s\n' "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/woodpecker" "$DOMAIN_NAME" "$WOODPECKER_ADMIN"
    printf 'WOODPECKER_GITHUB_CLIENT=%s\nWOODPECKER_GITHUB_SECRET=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_GRPC_SECRET=%s\n' "$oauth_client" "$oauth_secret" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
    printf 'WOODPECKER_REPO_OWNERS=%s\nWOODPECKER_AGENT_LABELS=%s\nWOODPECKER_MAX_WORKFLOWS=1\nWOODPECKER_DATABASE_MAX_CONNECTIONS=1\nWOODPECKER_DATABASE_IDLE_CONNECTIONS=1\nWOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false\n' "$WOODPECKER_REPO_OWNERS" "$WOODPECKER_AGENT_LABELS"
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
woodpecker_disabled="$(sed -n 's/^SERVICE_WOODPECKER_DISABLE=//p' "$app_env" | tail -n1)"
for pair in \
  "WOODPECKER_DATA_ROOT=$PLATFORM_ROOT/woodpecker/data" "WOODPECKER_AGENT_CONFIG_ROOT=$PLATFORM_ROOT/woodpecker/agent" \
  "WOODPECKER_HOST=https://ci.$DOMAIN_NAME" "WOODPECKER_ADMIN=$WOODPECKER_ADMIN" \
  "WOODPECKER_REPO_OWNERS=$WOODPECKER_REPO_OWNERS" "WOODPECKER_AGENT_LABELS=$WOODPECKER_AGENT_LABELS" \
  "WOODPECKER_MAX_WORKFLOWS=1" "WOODPECKER_DATABASE_MAX_CONNECTIONS=1" "WOODPECKER_DATABASE_IDLE_CONNECTIONS=1" \
  "WOODPECKER_FORCE_IGNORE_SERVICE_FAILURE=false"; do
  ensure_key "$woodpecker_env" "${pair%%=*}" "${pair#*=}"
done
if [[ "$woodpecker_disabled" != true && "$woodpecker_disabled" != TRUE && "$woodpecker_disabled" != 1 ]]; then
  if [[ -z "$(sed -n 's/^WOODPECKER_GITHUB_CLIENT=//p' "$woodpecker_env" | tail -n1)" || "$(sed -n 's/^WOODPECKER_GITHUB_CLIENT=//p' "$woodpecker_env" | tail -n1)" == disabled ]]; then
    read -r -p 'GitHub OAuth client ID: ' oauth_client
    [[ -n "$oauth_client" ]] || die 'OAuth client ID is required'
    set_key "$woodpecker_env" WOODPECKER_GITHUB_CLIENT "$oauth_client"
  fi
  if [[ -z "$(sed -n 's/^WOODPECKER_GITHUB_SECRET=//p' "$woodpecker_env" | tail -n1)" || "$(sed -n 's/^WOODPECKER_GITHUB_SECRET=//p' "$woodpecker_env" | tail -n1)" == disabled ]]; then
    read -r -s -p 'GitHub OAuth client secret: ' oauth_secret; printf '\n'
    [[ -n "$oauth_secret" ]] || die 'OAuth client secret is required'
    set_key "$woodpecker_env" WOODPECKER_GITHUB_SECRET "$oauth_secret"
  fi
fi
for pair in "WOODPECKER_AGENT_SECRET=$(openssl rand -hex 32)" "WOODPECKER_GRPC_SECRET=$(openssl rand -hex 32)"; do
  ensure_key "$woodpecker_env" "${pair%%=*}" "${pair#*=}"
done
chmod 600 "$beszel_env"

beszel_credentials="$CONFIG_ROOT/beszel-initial-credentials"
beszel_key_exists=0; beszel_token_exists=0
[[ -s "$PLATFORM_ROOT/beszel/secrets/key" ]] && beszel_key_exists=1
[[ -s "$PLATFORM_ROOT/beszel/secrets/token" ]] && beszel_token_exists=1
if (( beszel_key_exists != beszel_token_exists )); then
  # enrollment will quarantine the orphan and issue a fresh pair after the
  # hub is available; never discard it during an idempotent bootstrap.
  install -d -m 700 "$PLATFORM_ROOT/beszel/secrets/orphaned"
  orphan_stamp="$(date -u '+%Y%m%dT%H%M%SZ').$$"
  [[ -e "$PLATFORM_ROOT/beszel/secrets/key" ]] && mv -f -- "$PLATFORM_ROOT/beszel/secrets/key" "$PLATFORM_ROOT/beszel/secrets/orphaned/key.$orphan_stamp" || true
  [[ -e "$PLATFORM_ROOT/beszel/secrets/token" ]] && mv -f -- "$PLATFORM_ROOT/beszel/secrets/token" "$PLATFORM_ROOT/beszel/secrets/orphaned/token.$orphan_stamp" || true
  beszel_key_exists=0; beszel_token_exists=0
fi
if (( beszel_key_exists == 0 )); then
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
[[ -s "$CONFIG_ROOT/images.foundation.env" ]] || install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.foundation.prod.env" "$CONFIG_ROOT/images.foundation.env"
[[ -s "$CONFIG_ROOT/images.apps.env" ]] || install -o root -g root -m 600 "$SOURCE_ROOT/ops/images.apps.prod.env" "$CONFIG_ROOT/images.apps.env"

sha="$(git -C "$SOURCE_ROOT" rev-parse "origin/$MAIN_BRANCH" 2>/dev/null || git -C "$SOURCE_ROOT" rev-parse HEAD)"
release="$CONTROL_ROOT/releases/$sha"; [[ -e "$release" ]] || { install -d -m 700 "$release"; git -C "$SOURCE_ROOT" archive "$sha" | tar -x -C "$release"; }
ln -sfn "$release" "$CONTROL_ROOT/current"
install -d -m 700 "$CONTROL_ROOT/descriptors"
for descriptor in "$release"/apps/*; do
  [[ -f "$descriptor/manifest.env" ]] || continue
  descriptor_id="$(basename "$descriptor")"
  install -d -m 700 "$CONTROL_ROOT/descriptors/$descriptor_id"
  install -m 600 "$descriptor/manifest.env" "$CONTROL_ROOT/descriptors/$descriptor_id/manifest.env"
done
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/woodpecker.yml" "$FOUNDATION_ROOT/woodpecker.yml"
install -o root -g root -m 600 "$SOURCE_ROOT/compose/foundation/beszel.yml" "$FOUNDATION_ROOT/beszel.yml"

install -d -m 700 /usr/local/libexec
for script in platformctl restart-platform backup-platform restore-platform configure-beszel enroll-beszel upgrade-runner platform-submit deploy-controller; do
  cat >"/usr/local/bin/$script" <<EOF
#!/bin/sh
exec /opt/platform/control/current/ops/$script.sh "\$@"
EOF
  chmod 700 "/usr/local/bin/$script"
done

platform_env="$CONFIG_ROOT/platform.env"
for pair in \
  "APP_ROOT=$APP_ROOT" "PLATFORM_ROOT=$PLATFORM_ROOT" "CONTROL_ROOT=$CONTROL_ROOT" "FOUNDATION_ROOT=$FOUNDATION_ROOT" \
  "REPO_URL=$REPO_URL" "MAIN_BRANCH=$MAIN_BRANCH" "APP_ENV=$app_env" "APP_IMAGE_ENV=$CONFIG_ROOT/images.apps.env" \
  "FOUNDATION_IMAGE_ENV=$CONFIG_ROOT/images.foundation.env" "FOUNDATION_ENV_ROOT=$FOUNDATION_ROOT/env" \
  "RUNTIME_ROOT=$APP_ROOT/shared/runtime" "PLATFORM_EDGE_NETWORK=$edge_network" \
  "PLATFORM_LOCK_FILE=/run/lock/llm-hub-lite/platform.lock" "PLATFORM_RUNNER_IMAGE=llm-hub-lite/deploy-runner:current"; do
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
beszel_disabled="$(sed -n 's/^SERVICE_BESZEL_DISABLE=//p' "$app_env" | tail -n1)"
if [[ "$beszel_disabled" != true && "$beszel_disabled" != TRUE && "$beszel_disabled" != 1 ]]; then
  PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl start beszel
fi
if [[ "$beszel_disabled" != true && "$beszel_disabled" != TRUE && "$beszel_disabled" != 1 ]]; then
  /usr/local/bin/enroll-beszel || printf 'Beszel enrollment deferred; platform-beszel-enroll.timer will retry it\n' >&2
fi
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl sync all
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl recover --quiet

systemctl enable platform.target platform-recovery.timer platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer platform-beszel-enroll.timer >/dev/null
systemctl restart platform.target platform-recovery.timer platform-health.timer platform-backup.timer platform-backup-prune.timer platform-backup-check.timer platform-beszel-enroll.timer
PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl backup snapshot post-bootstrap

curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://ci.$DOMAIN_NAME/" >/dev/null || printf 'Woodpecker endpoint not ready yet\n' >&2
curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://status.$DOMAIN_NAME/api/health" >/dev/null || printf 'Beszel endpoint not ready yet\n' >&2
printf 'Bootstrap complete. Daily deployments are workflow-driven; SSH is not required after this step.\n'
