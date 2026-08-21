#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2097,SC2098,SC2318
set -Eeuo pipefail

umask 077
config_file="${DEPLOY_CONFIG_FILE:-/etc/llm-hub-lite/platform.env}"
[[ -r "$config_file" ]] || { printf 'missing platform configuration: %s\n' "$config_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$config_file"

: "${APP_ROOT:=/opt/apps/llm-hub-lite}"
: "${PLATFORM_ROOT:=/opt/platform}"
: "${CONTROL_ROOT:=$PLATFORM_ROOT/control}"
: "${FOUNDATION_ROOT:=$PLATFORM_ROOT/foundation}"
: "${REPO_URL:?REPO_URL must be set}"
: "${MAIN_BRANCH:=main}"
: "${APP_ENV:=$APP_ROOT/shared/.env.prod}"
: "${APP_IMAGE_ENV:=/etc/llm-hub-lite/images.apps.env}"
: "${FOUNDATION_IMAGE_ENV:=/etc/llm-hub-lite/images.foundation.env}"
: "${DEPLOY_LOG:=$APP_ROOT/shared/logs/deploy.log}"
: "${PLATFORM_LOCK_FILE:=/run/lock/llm-hub-lite/platform.lock}"
: "${RETAIN_RELEASES:=5}"
: "${PLATFORMCTL_SCRIPT:=/usr/local/bin/platformctl}"
: "${BACKUP_SCRIPT:=/usr/local/bin/backup-platform}"

SOURCE_MIRROR="$CONTROL_ROOT/mirror.git"
RELEASES="$CONTROL_ROOT/releases"
CURRENT="$CONTROL_ROOT/current"
PREVIOUS="$CONTROL_ROOT/previous"
APP_CURRENT="$APP_ROOT/current"
APP_PREVIOUS="$APP_ROOT/previous"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
sha_valid() { [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die 'expected a full 40-character commit SHA'; }

atomic_link() {
  local target="$1" link="$2" directory tmp
  directory="$(dirname "$link")"
  install -d -m 700 "$directory"
  tmp="$directory/.$(basename "$link").tmp.$$"
  rm -f -- "$tmp"
  ln -s "$target" "$tmp"
  rm -f -- "$link"
  mv -- "$tmp" "$link"
}

mkdir -p "$APP_ROOT/shared/logs" "$RELEASES" "$(dirname "$PLATFORM_LOCK_FILE")"
exec > >(tee -a "$DEPLOY_LOG") 2>&1

ensure_mirror() {
  if [[ ! -d "$SOURCE_MIRROR" ]]; then git init --bare "$SOURCE_MIRROR" >/dev/null; fi
  if git -C "$SOURCE_MIRROR" remote get-url origin >/dev/null 2>&1; then
    git -C "$SOURCE_MIRROR" remote set-url origin "$REPO_URL"
  else
    git -C "$SOURCE_MIRROR" remote add origin "$REPO_URL"
  fi
}

fetch_main() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if git -C "$SOURCE_MIRROR" fetch --prune origin "+refs/heads/$MAIN_BRANCH:refs/remotes/origin/$MAIN_BRANCH"; then return 0; fi
    log "git fetch retry $attempt"; sleep 5
  done
  return 1
}

verify_target() {
  local sha="$1"
  git -C "$SOURCE_MIRROR" cat-file -e "$sha^{commit}" || die 'target is not in mirror'
  git -C "$SOURCE_MIRROR" merge-base --is-ancestor "$sha" "refs/remotes/origin/$MAIN_BRANCH" || die 'target is not reachable from main'
}

prepare_release() {
  local sha="$1" release="$RELEASES/$sha"
  if [[ ! -e "$release" ]]; then git -C "$SOURCE_MIRROR" worktree add --detach "$release" "$sha" >/dev/null; fi
  printf '%s\n' "$release"
}

validate_release() {
  local release="$1" runtime foundation_validate control_validate image_apps image_foundation
  [[ -f "$release/ops/platformctl.sh" && -d "$release/apps" && -d "$release/config" ]] || die 'release is missing platform files'
  install -d -m 700 "$APP_ROOT/shared/runtime"
  runtime="$(mktemp -d "$APP_ROOT/shared/runtime/validate.XXXXXX")"
  foundation_validate="$(mktemp -d "$APP_ROOT/shared/runtime/foundation-validate.XXXXXX")"
  control_validate="$(mktemp -d "$APP_ROOT/shared/runtime/control-validate.XXXXXX")"
  image_apps="$control_validate/images.apps.env"
  image_foundation="$control_validate/images.foundation.env"
  ln -s "$release" "$control_validate/current"
  install -m 600 "$release/ops/images.apps.prod.env" "$image_apps"
  install -m 600 "$release/ops/images.foundation.prod.env" "$image_foundation"
  install -d -m 700 "$foundation_validate/env"
  cp -a "$FOUNDATION_ROOT/env/." "$foundation_validate/env/" 2>/dev/null || true
  install -m 600 "$release/compose/foundation/caddy.yml" "$foundation_validate/caddy.yml"
  install -m 600 "$release/compose/foundation/woodpecker.yml" "$foundation_validate/woodpecker.yml"
  install -m 600 "$release/compose/foundation/beszel.yml" "$foundation_validate/beszel.yml"
  if ! CONTROL_ROOT="$control_validate" APPS_ROOT="$release/apps" RUNTIME_ROOT="$runtime" \
    APP_ENV="$APP_ENV" APP_IMAGE_ENV="$image_apps" FOUNDATION_IMAGE_ENV="$image_foundation" \
    FOUNDATION_ROOT="$foundation_validate" FOUNDATION_ENV_ROOT="$foundation_validate/env" \
    PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
    "$release/ops/platformctl.sh" validate; then
    rm -rf -- "$runtime" "$foundation_validate" "$control_validate"; return 1
  fi
  rm -rf -- "$runtime" "$foundation_validate" "$control_validate"
}

backup() {
  [[ -x "$BACKUP_SCRIPT" ]] || die "backup script is not executable: $BACKUP_SCRIPT"
  log 'Creating verified pre-change snapshot'
  PLATFORM_LOCK_HELD=1 "$BACKUP_SCRIPT" snapshot "${1:-pre-deploy}" || die 'verified backup failed'
}

install_foundation_files() {
  local release="$1"
  install -d -m 700 "$FOUNDATION_ROOT/env"
  install -m 600 "$release/compose/foundation/caddy.yml" "$FOUNDATION_ROOT/caddy.yml"
  install -m 600 "$release/compose/foundation/woodpecker.yml" "$FOUNDATION_ROOT/woodpecker.yml"
  install -m 600 "$release/compose/foundation/beszel.yml" "$FOUNDATION_ROOT/beszel.yml"
}

reconcile() {
  CONTROL_ROOT="$CONTROL_ROOT" APPS_ROOT="$CONTROL_ROOT/current/apps" FOUNDATION_ROOT="$FOUNDATION_ROOT" \
    APP_ENV="$APP_ENV" APP_IMAGE_ENV="$APP_IMAGE_ENV" FOUNDATION_IMAGE_ENV="$FOUNDATION_IMAGE_ENV" \
    PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
    "$PLATFORMCTL_SCRIPT" recover --quiet
}

smoke_apps() {
  local descriptor id disable_key disable_value
  for descriptor in "$CONTROL_ROOT/current"/apps/*; do
    [[ -f "$descriptor/manifest.env" ]] || continue
    id="$(basename "$descriptor")"
    disable_key="$(sed -n 's/^DISABLE_ENV=//p' "$descriptor/manifest.env" | tail -n1)"
    disable_value="$(sed -n "s/^${disable_key}=//p" "$APP_ENV" | tail -n1)"
    [[ "$disable_value" == true || "$disable_value" == TRUE || "$disable_value" == 1 ]] && continue
    APP_ENV="$APP_ENV" PLATFORM_COMPOSE_BIN="${PLATFORM_COMPOSE_BIN:-/usr/local/bin/platform-compose}" \
      "$PLATFORMCTL_SCRIPT" smoke "app:$descriptor" || die "smoke failed: $id"
  done
}

cleanup() {
  local path kept=0 current_target previous_target
  current_target="$(readlink "$CURRENT" 2>/dev/null || true)"
  previous_target="$(readlink "$PREVIOUS" 2>/dev/null || true)"
  while IFS= read -r path; do
    [[ -d "$path" && "$path" != "$current_target" && "$path" != "$previous_target" ]] || continue
    kept=$((kept + 1))
    if (( kept > RETAIN_RELEASES )); then
      git -C "$SOURCE_MIRROR" worktree remove --force "$path" >/dev/null 2>&1 || true
    fi
  done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r)
}

apply() {
  local sha="$1" mode="${2:-app}" release old_current old_previous tx foundation_changed=0
  sha_valid "$sha"
  exec 9>"$PLATFORM_LOCK_FILE"; flock -w 300 9 || die 'timed out waiting for deployment lock'
  ensure_mirror; fetch_main || die 'unable to fetch repository'; verify_target "$sha"
  release="$(prepare_release "$sha")"; validate_release "$release"; backup "pre-$mode"
  old_current="$(readlink "$CURRENT" 2>/dev/null || true)"
  old_previous="$(readlink "$PREVIOUS" 2>/dev/null || true)"
  tx="$(mktemp -d "$APP_ROOT/shared/runtime/transaction.XXXXXX")"
  cp -f "$APP_IMAGE_ENV" "$tx/images.apps" 2>/dev/null || true
  cp -f "$FOUNDATION_IMAGE_ENV" "$tx/images.foundation" 2>/dev/null || true
  for file in caddy.yml woodpecker.yml beszel.yml; do cp -f "$FOUNDATION_ROOT/$file" "$tx/$file" 2>/dev/null || true; done
  if [[ -n "$old_current" ]]; then atomic_link "$old_current" "$PREVIOUS"; atomic_link "$old_current" "$APP_PREVIOUS"; fi
  atomic_link "$release" "$CURRENT"; atomic_link "$release" "$APP_CURRENT"
  if [[ "$mode" != foundation ]]; then
    install -m 600 "$release/ops/images.apps.prod.env" "$APP_IMAGE_ENV"
  fi
  if [[ "$mode" == foundation ]]; then
    foundation_changed=1
    install_foundation_files "$release"
    install -m 600 "$release/ops/images.foundation.prod.env" "$FOUNDATION_IMAGE_ENV"
  fi
  if reconcile && smoke_apps; then
    cleanup; rm -rf -- "$tx"; log "deployment succeeded: $sha ($mode)"; return 0
  fi
  log 'deployment failed; restoring previous complete bundle'
  [[ -n "$old_current" ]] && { atomic_link "$old_current" "$CURRENT"; atomic_link "$old_current" "$APP_CURRENT"; } || { rm -f -- "$CURRENT" "$APP_CURRENT"; }
  [[ -n "$old_previous" ]] && atomic_link "$old_previous" "$PREVIOUS" || rm -f -- "$PREVIOUS"
  if [[ -f "$tx/images.apps" ]]; then install -m 600 "$tx/images.apps" "$APP_IMAGE_ENV"; else rm -f -- "$APP_IMAGE_ENV"; fi
  if [[ -f "$tx/images.foundation" ]]; then install -m 600 "$tx/images.foundation" "$FOUNDATION_IMAGE_ENV"; fi
  if (( foundation_changed )); then
    for file in caddy.yml woodpecker.yml beszel.yml; do
      [[ -f "$tx/$file" ]] && install -m 600 "$tx/$file" "$FOUNDATION_ROOT/$file"
    done
  fi
  rm -rf -- "$tx"
  reconcile || true
  return 1
}

rollback() {
  local target="${1:-previous}"
  [[ "$target" == previous ]] && target="$(readlink "$PREVIOUS" 2>/dev/null || true)"
  [[ -n "$target" ]] || die 'no rollback target'
  apply "$(basename "$target")" rollback
}

case "${1:-}" in
  deploy) [[ $# -eq 2 ]] || die 'usage: deploy <sha>'; apply "$2" app ;;
  foundation-upgrade) [[ $# -eq 2 ]] || die 'usage: deploy-controller foundation-upgrade <sha>'; apply "$2" foundation ;;
  app-upgrade) [[ $# -eq 2 ]] || die 'usage: deploy-controller app-upgrade <sha>'; apply "$2" app-upgrade ;;
  rollback) rollback "${2:-previous}" ;;
  status) printf 'current=%s\nprevious=%s\n' "$(readlink "$CURRENT" 2>/dev/null || true)" "$(readlink "$PREVIOUS" 2>/dev/null || true)" ;;
  *) die 'usage: deploy-controller {deploy|foundation-upgrade|app-upgrade|rollback|status} <sha>' ;;
esac
