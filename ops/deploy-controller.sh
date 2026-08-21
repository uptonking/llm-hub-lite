#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

config_file="${DEPLOY_CONFIG_FILE:-/etc/llm-hub-lite/deploy.env}"
if [[ ! -r "$config_file" ]]; then
  printf 'Missing deployment configuration: %s\n' "$config_file" >&2
  exit 1
fi

# This file is root-owned on the VPS and is mounted read-only into the runner.
# It contains paths and repository metadata, never application credentials.
# shellcheck disable=SC1090
source "$config_file"

: "${APP_ROOT:=/opt/apps/llm-hub-lite}"
: "${REPO_URL:?REPO_URL must be set in $config_file}"
: "${MAIN_BRANCH:=main}"
: "${ENV_FILE:=$APP_ROOT/shared/.env.production}"
: "${RETAIN_RELEASES:=5}"
: "${BACKUP_RETENTION:=10}"
: "${DEPLOY_LOG:=$APP_ROOT/shared/logs/deploy.log}"
: "${PLATFORM_LOCK_FILE:=$APP_ROOT/shared/platform.lock}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

dotenv_value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

validate_path() {
  local name="$1" value="$2"
  [[ "$value" == /* ]] || die "$name must be an absolute path"
  [[ "$value" != *..* ]] || die "$name must not contain '..': $value"
  [[ "$value" != *[[:space:]]* ]] || die "$name must not contain whitespace: $value"
  case "$value" in
    /|/bin|/boot|/dev|/etc|/home|/opt|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "$name points at an unsafe broad path: $value"
      ;;
  esac
}

validate_path APP_ROOT "$APP_ROOT"
validate_path ENV_FILE "$ENV_FILE"
validate_path DEPLOY_LOG "$DEPLOY_LOG"
case "$ENV_FILE" in
  "$APP_ROOT"/shared/*) ;;
  *) die "ENV_FILE must be under APP_ROOT/shared" ;;
esac
case "$DEPLOY_LOG" in
  "$APP_ROOT"/shared/logs/*) ;;
  *) die "DEPLOY_LOG must be under APP_ROOT/shared/logs" ;;
esac
[[ "$MAIN_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$MAIN_BRANCH" != *..* ]] || \
  die "MAIN_BRANCH contains unsafe characters"
[[ "$RETAIN_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "RETAIN_RELEASES must be a positive integer"
[[ "$BACKUP_RETENTION" =~ ^[1-9][0-9]*$ ]] || die "BACKUP_RETENTION must be a positive integer"

shared_root="$APP_ROOT/shared"
releases_dir="$APP_ROOT/releases"
mirror_dir="$shared_root/mirror.git"
backup_dir="$shared_root/backups"
runtime_dir="$shared_root/runtime"
current_link="$APP_ROOT/current"
previous_link="$APP_ROOT/previous"
lock_file="$PLATFORM_LOCK_FILE"
status_file="$shared_root/deploy-status.env"

mkdir -p "$shared_root/logs" "$releases_dir" "$backup_dir"
mkdir -p "$(dirname "$DEPLOY_LOG")"
exec > >(tee -a "$DEPLOY_LOG") 2>&1

usage() {
  cat >&2 <<'EOF'
Usage:
  deploy-controller deploy <40-character-sha>
  deploy-controller rollback <40-character-sha|previous>
  deploy-controller status
EOF
  exit 2
}

validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "expected a full 40-character commit SHA"
}

ensure_mirror() {
  if [[ ! -d "$mirror_dir" ]]; then
    git init --bare "$mirror_dir" >/dev/null
  fi

  if git -C "$mirror_dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$mirror_dir" remote set-url origin "$REPO_URL"
  else
    git -C "$mirror_dir" remote add origin "$REPO_URL"
  fi
}

fetch_main() {
  local attempt=1
  while (( attempt <= 6 )); do
    if git -C "$mirror_dir" fetch --prune origin \
      "+refs/heads/$MAIN_BRANCH:refs/remotes/origin/$MAIN_BRANCH"; then
      return 0
    fi
    log "Git fetch failed; retrying in 5 seconds (attempt $attempt/6)"
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

verify_target() {
  local sha="$1"
  local remote_ref="refs/remotes/origin/$MAIN_BRANCH"
  git -C "$mirror_dir" cat-file -e "$sha^{commit}" || die "SHA is not present in the repository mirror"
  git -C "$mirror_dir" merge-base --is-ancestor "$sha" "$remote_ref" || \
    die "SHA is not reachable from origin/$MAIN_BRANCH"
}

prepare_release() {
  local sha="$1" release_dir="$releases_dir/$sha"
  if [[ -e "$release_dir" ]]; then
    [[ -e "$release_dir/.git" ]] || die "release path exists but is not a Git worktree: $release_dir"
    [[ "$(git -C "$release_dir" rev-parse HEAD)" == "$sha" ]] || die "release worktree has the wrong commit"
  else
    git -C "$mirror_dir" worktree add --detach "$release_dir" "$sha" >/dev/null
  fi
  printf '%s\n' "$release_dir"
}

validate_production_env() {
  [[ -f "$ENV_FILE" ]] || die "missing production environment file: $ENV_FILE"
  local data_root
  data_root="$(dotenv_value "$ENV_FILE" DATA_ROOT)"
  validate_path DATA_ROOT "$data_root"
  case "$data_root" in
    "$APP_ROOT"/shared/data/*) ;;
    *) die "DATA_ROOT must be under APP_ROOT/shared/data" ;;
  esac
  mkdir -p "$data_root"
  local image key
  for key in CADDY_IMAGE NEW_API_IMAGE CLIPROXY_IMAGE; do
    image="$(dotenv_value "$ENV_FILE" "$key")"
    [[ -n "$image" ]] || die "$key is missing from $ENV_FILE"
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || \
      die "$key must use an immutable sha256 digest"
  done
}

validate_release() {
  local release_dir="$1"
  validate_production_env
  STACK_ENV_FILE="$ENV_FILE" "$release_dir/stack.sh" prod validate

  local caddy_image new_api_site cliproxy_site woodpecker_site beszel_site ssl_email
  caddy_image="$(dotenv_value "$ENV_FILE" CADDY_IMAGE)"
  new_api_site="$(dotenv_value "$ENV_FILE" NEW_API_SITE)"
  cliproxy_site="$(dotenv_value "$ENV_FILE" CLIPROXY_SITE)"
  woodpecker_site="$(dotenv_value "$ENV_FILE" WOODPECKER_SITE)"
  beszel_site="$(dotenv_value "$ENV_FILE" BESZEL_SITE)"
  ssl_email="$(dotenv_value "$ENV_FILE" SSL_EMAIL)"
  docker run --rm \
    -e NEW_API_SITE="$new_api_site" \
    -e CLIPROXY_SITE="$cliproxy_site" \
    -e WOODPECKER_SITE="$woodpecker_site" \
    -e BESZEL_SITE="$beszel_site" \
    -e SSL_EMAIL="$ssl_email" \
    -v "$release_dir/config:/etc/caddy:ro" \
    "$caddy_image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

atomic_link() {
  local target="$1" link="$2" tmp
  tmp="$APP_ROOT/.$(basename "$link").tmp.$$"
  ln -s "$target" "$tmp"
  if ! mv -Tf -- "$tmp" "$link"; then
    rm -f -- "$tmp"
    return 1
  fi
}

record_status() {
  local result="$1" sha="$2" previous="$3"
  {
    printf 'result=%q\n' "$result"
    printf 'sha=%q\n' "$sha"
    printf 'previous=%q\n' "$previous"
    printf 'timestamp=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$status_file"
}

backup_shared_data() {
  local data_root backup_file relative_root
  data_root="$(dotenv_value "$ENV_FILE" DATA_ROOT)"
  relative_root="${data_root#/}"
  backup_file="$backup_dir/$(date -u '+%Y%m%dT%H%M%SZ').$$.tar.gz"

  log "Creating persistent-data backup: $backup_file"
  [[ -d "$data_root" ]] || die "DATA_ROOT does not exist: $data_root"
  tar -czf "$backup_file" -C / "$relative_root" 2>&1 || \
    die "persistent-data backup failed"

  local -a backups=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && backups+=("$path")
  done < <(ls -1dt "$backup_dir"/*.tar.gz 2>/dev/null || true)
  local index=0 path
  for path in "${backups[@]}"; do
    index=$((index + 1))
    if (( index > BACKUP_RETENTION )); then
      rm -f -- "$path"
    fi
  done
}

stage_runtime() {
  local release_dir="$1" runtime_config="$runtime_dir/config"
  local required
  for required in stack.sh docker-compose.yml docker-compose.prod.yml; do
    [[ -f "$release_dir/$required" ]] || die "release is missing runtime file: $required"
  done
  [[ -d "$release_dir/config" ]] || die "release is missing Caddy config directory"

  mkdir -p "$runtime_config"
  install -m 700 "$release_dir/stack.sh" "$runtime_dir/stack.sh"
  install -m 600 "$release_dir/docker-compose.yml" "$runtime_dir/docker-compose.yml"
  install -m 600 "$release_dir/docker-compose.prod.yml" "$runtime_dir/docker-compose.prod.yml"

  # Keep the bind-mount source stable between releases. Caddy continues serving
  # its loaded config while these files are replaced, then reloads below.
  find "$runtime_config" -mindepth 1 -delete
  cp -a "$release_dir/config/." "$runtime_config/"
}

compose_up() {
  local release_dir="$1"
  stage_runtime "$release_dir"
  STACK_ENV_FILE="$ENV_FILE" "$runtime_dir/stack.sh" prod up \
    --wait --wait-timeout 180
  STACK_ENV_FILE="$ENV_FILE" "$runtime_dir/stack.sh" prod reload
}

smoke_check() {
  local new_api_site cpa_site
  new_api_site="$(dotenv_value "$ENV_FILE" NEW_API_SITE)"
  cpa_site="$(dotenv_value "$ENV_FILE" CLIPROXY_SITE)"
  new_api_site="${new_api_site%/}"
  cpa_site="${cpa_site%/}"

  curl --fail --silent --show-error --retry 30 --retry-delay 5 --retry-all-errors \
    --max-time 20 "$new_api_site/api/status" | grep -q '"success":true' || {
      log "ERROR: New API smoke check failed"
      return 1
    }
  curl --fail --silent --show-error --retry 30 --retry-delay 5 --retry-all-errors \
    --max-time 20 "$cpa_site/management.html" >/dev/null || {
      log "ERROR: CLIProxyAPI smoke check failed"
      return 1
    }
}

cleanup_releases() {
  local current_target previous_target path
  current_target="$(readlink "$current_link" 2>/dev/null || true)"
  previous_target="$(readlink "$previous_link" 2>/dev/null || true)"
  local -a releases=()
  while IFS= read -r path; do
    [[ -d "$path" ]] && releases+=("$path")
  done < <(ls -1dt "$releases_dir"/* 2>/dev/null || true)

  local kept=0 release_dir
  for release_dir in "${releases[@]}"; do
    if [[ "$release_dir" == "$current_target" || "$release_dir" == "$previous_target" ]]; then
      continue
    fi
    kept=$((kept + 1))
    if (( kept > RETAIN_RELEASES )); then
      git -C "$mirror_dir" worktree remove --force "$release_dir" >/dev/null 2>&1 || true
      rm -rf -- "$release_dir"
    fi
  done
}

deploy() {
  local sha="$1"
  validate_sha "$sha"
  mkdir -p "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  flock -w 300 9 || die "timed out waiting for another platform operation"

  ensure_mirror
  fetch_main || die "unable to fetch origin/$MAIN_BRANCH"
  verify_target "$sha"

  local release_dir old_current
  release_dir="$(prepare_release "$sha")"
  validate_release "$release_dir"
  backup_shared_data
  old_current="$(readlink "$current_link" 2>/dev/null || true)"
  if [[ -n "$old_current" ]]; then
    atomic_link "$old_current" "$previous_link"
  fi
  atomic_link "$release_dir" "$current_link"
  record_status starting "$sha" "$old_current"
  if compose_up "$release_dir" && smoke_check; then
    record_status success "$sha" "$old_current"
    cleanup_releases
    log "Deployment succeeded: $sha"
  else
    record_status failed "$sha" "$old_current"
    log "Deployment failed; current points to $release_dir and previous points to $old_current"
    return 1
  fi
}

rollback() {
  local target="$1" release_dir old_current
  if [[ "$target" == previous ]]; then
    target="$(readlink "$previous_link" 2>/dev/null || true)"
    [[ -n "$target" ]] || die "no previous release is recorded"
    release_dir="$target"
  else
    validate_sha "$target"
    release_dir="$releases_dir/$target"
  fi
  [[ -d "$release_dir" ]] || die "release does not exist: $release_dir"

  mkdir -p "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  flock -w 300 9 || die "timed out waiting for another platform operation"
  validate_release "$release_dir"
  backup_shared_data
  old_current="$(readlink "$current_link" 2>/dev/null || true)"
  [[ -n "$old_current" ]] && atomic_link "$old_current" "$previous_link"
  atomic_link "$release_dir" "$current_link"
  record_status rollback "$(basename "$release_dir")" "$old_current"
  if compose_up "$release_dir" && smoke_check; then
    record_status success "$(basename "$release_dir")" "$old_current"
    log "Rollback succeeded: $release_dir"
  else
    record_status failed "$(basename "$release_dir")" "$old_current"
    log "Rollback failed; current points to $release_dir and previous points to $old_current"
    return 1
  fi
}

status() {
  printf 'current=%s\n' "$(readlink "$current_link" 2>/dev/null || true)"
  printf 'previous=%s\n' "$(readlink "$previous_link" 2>/dev/null || true)"
  if [[ -f "$status_file" ]]; then
    cat "$status_file"
  fi
}

case "${1:-}" in
  deploy)
    [[ $# -eq 2 ]] || usage
    deploy "$2"
    ;;
  rollback)
    [[ $# -eq 2 ]] || usage
    rollback "$2"
    ;;
  status)
    [[ $# -eq 1 ]] || usage
    status
    ;;
  *)
    usage
    ;;
esac
