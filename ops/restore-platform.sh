#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_ROOT/restic-password}"
RESTORE_ROOT="${RESTORE_ROOT:-/opt/backups/llm-hub-lite/restores}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
PLATFORMCTL_SCRIPT="${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}"
operation="${1:-extract}"
snapshot="${2:-latest}"
requested_target="${3:-}"
die() { printf 'restore-platform: %s\n' "$*" >&2; exit 1; }

command -v restic >/dev/null 2>&1 || { printf 'restic is required\n' >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is required\n' >&2; exit 1; }
[[ -s "$PASSWORD_FILE" ]] || { printf 'missing Restic password file\n' >&2; exit 1; }
env_value() { local key="$1"; [[ -f "$APP_ENV" ]] || return 0; sed -n "s/^${key}=//p" "$APP_ENV" | tail -n1; }
DATA_ROOT="${DATA_ROOT:-$(env_value DATA_ROOT)}"; DATA_ROOT="${DATA_ROOT:-$APP_ROOT/shared/data/prod}"
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

safe_target() { [[ "$1" == "$RESTORE_ROOT"/* && "$1" != *..* ]] || { printf 'restore target must be below %s\n' "$RESTORE_ROOT" >&2; exit 1; }; }

validate_extract() {
  local target="$1" database count=0
  while IFS= read -r database; do
    sqlite3 "$database" 'PRAGMA integrity_check;' | grep -qx ok || { printf 'restored SQLite integrity check failed: %s\n' "$database" >&2; return 1; }
    count=$((count + 1))
  done < <(find "$target/run/llm-hub-lite/backup/sqlite" -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | sort)
  # A newly bootstrapped instance may not have created every optional database.
  (( count > 0 )) || printf 'snapshot contains no SQLite copies; continuing (optional databases may be empty)\n' >&2
}

extract_snapshot() {
  local target="$1"
  safe_target "$target"; [[ ! -e "$target" ]] || { printf 'restore target already exists: %s\n' "$target" >&2; exit 1; }
  install -d -m 700 "$target"; restic restore "$snapshot" --target "$target" --tag platform
  validate_extract "$target"; printf '%s\n' "$target"
}

install_verified_databases() {
  local target="$1" staged database base
  staged="$target/run/llm-hub-lite/backup/sqlite"
  install -d -m 700 "$target$DATA_ROOT/new-api" "$target$PLATFORM_ROOT/woodpecker/data" "$target$PLATFORM_ROOT/beszel/hub"
  [[ -f "$staged/new-api.db" ]] && install -m 600 "$staged/new-api.db" "$target$DATA_ROOT/new-api/one-api.db"
  [[ -f "$staged/woodpecker.sqlite" ]] && install -m 600 "$staged/woodpecker.sqlite" "$target$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite"
  while IFS= read -r database; do
    base="${database##*/beszel-}"; install -m 600 "$database" "$target$PLATFORM_ROOT/beszel/hub/$base"
  done < <(find "$staged" -maxdepth 1 -type f -name 'beszel-*.db' -print 2>/dev/null | sort)
}

rollback_swaps() {
  local manifest="$1" count=0 live saved i
  local -a lives=() saveds=()
  while IFS=$'\t' read -r live saved; do
    [[ -n "$live" && -e "$saved" ]] || continue
    lives+=("$live"); saveds+=("$saved"); count=$((count + 1))
  done <"$manifest"
  for ((i = count - 1; i >= 0; i--)); do
    live="${lives[$i]}"; saved="${saveds[$i]}"
    [[ -e "$live" || -L "$live" ]] && mv "$live" "$live.failed-$(date -u +%s)"
    mv "$saved" "$live"
  done
}

swap_path() {
  local restored="$1" live="$2" rollback_root="$3" manifest="$4" saved
  [[ -e "$restored" || -L "$restored" ]] || return 0
  saved="$rollback_root$live"; install -d -m 700 "$(dirname "$saved")" "$(dirname "$live")"
  if [[ -e "$live" || -L "$live" ]]; then mv "$live" "$saved"; fi
  if ! mv "$restored" "$live"; then
    [[ -e "$saved" || -L "$saved" ]] && mv "$saved" "$live"; return 1
  fi
  printf '%s\t%s\n' "$live" "$saved" >>"$manifest"
}

apply_snapshot() {
  [[ "$EUID" -eq 0 ]] || { printf 'restore apply must run as root\n' >&2; exit 1; }
  local stamp target rollback_root manifest path
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; target="${requested_target:-$RESTORE_ROOT/apply-$stamp}"
  extract_snapshot "$target" >/dev/null; install_verified_databases "$target"; "$BACKUP_SCRIPT" snapshot pre-restore
  install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
  printf 'started_utc=%s\nreason=restore %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$snapshot" >"$MAINTENANCE_FILE"
  PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all
  rollback_root="$RESTORE_ROOT/rollback-$stamp"; manifest="$rollback_root/manifest.tsv"; install -d -m 700 "$rollback_root"; : >"$manifest"
  for path in "$DATA_ROOT" "$APP_ROOT/shared/runtime" "$APP_ROOT/shared/.env.prod" "$APP_ROOT/current" "$APP_ROOT/previous" \
    "$CONTROL_ROOT/current" "$CONTROL_ROOT/previous" "$CONTROL_ROOT/releases" "$FOUNDATION_ROOT" \
    "$PLATFORM_ROOT/caddy" "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/beszel" \
    "$CONFIG_ROOT/platform.env" "$CONFIG_ROOT/images.apps.env" "$CONFIG_ROOT/images.foundation.env"; do
    if ! swap_path "$target$path" "$path" "$rollback_root" "$manifest"; then
      rollback_swaps "$manifest"; PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all || true; rm -f -- "$MAINTENANCE_FILE"; die 'restore swap failed; prior paths restored'
    fi
  done
  if PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" validate && PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all && "$PLATFORMCTL_SCRIPT" health true; then
    rm -f -- "$MAINTENANCE_FILE"; printf 'restore applied successfully; rollback data retained at %s\n' "$rollback_root"
  else
    PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all || true; rollback_swaps "$manifest"; PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all || true; rm -f -- "$MAINTENANCE_FILE"; printf 'restore validation failed; prior data restored from %s\n' "$rollback_root" >&2; exit 1
  fi
}

case "$operation" in
  extract) target="${requested_target:-$RESTORE_ROOT/extract-$(date -u +%Y%m%dT%H%M%SZ)}"; extract_snapshot "$target" >/dev/null; printf 'restore extracted and validated at %s\n' "$target" ;;
  apply) apply_snapshot ;;
  rollback)
    [[ -n "$requested_target" && -f "$requested_target/manifest.tsv" ]] || { printf 'rollback requires a rollback directory\n' >&2; exit 2; }
    install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
    printf 'started_utc=%s\nreason=restore rollback\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$MAINTENANCE_FILE"
    PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" stop all
    rollback_swaps "$requested_target/manifest.tsv"
    PLATFORM_LOCK_HELD=1 "$PLATFORMCTL_SCRIPT" start all
    rm -f -- "$MAINTENANCE_FILE"
    ;;
  *) printf 'usage: restore-platform {extract|apply|rollback} [snapshot] [target]\n' >&2; exit 2 ;;
esac
