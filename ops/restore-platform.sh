#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_ROOT/restic-password}"
RESTORE_ROOT="${RESTORE_ROOT:-/opt/backups/llm-hub-lite/restores}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
operation="${1:-extract}"
snapshot="${2:-latest}"
requested_target="${3:-}"

command -v restic >/dev/null 2>&1 || { printf 'restic is required\n' >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is required\n' >&2; exit 1; }
[[ -s "$PASSWORD_FILE" ]] || { printf 'missing Restic password file\n' >&2; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

safe_target() {
  [[ "$1" == "$RESTORE_ROOT"/* && "$1" != *..* ]] || { printf 'restore target must be below %s\n' "$RESTORE_ROOT" >&2; exit 1; }
}

validate_extract() {
  local target="$1" database count=0
  while IFS= read -r database; do
    sqlite3 "$database" 'PRAGMA integrity_check;' | grep -qx ok || { printf 'restored SQLite integrity check failed: %s\n' "$database" >&2; return 1; }
    count=$((count + 1))
  done < <(find "$target/run/llm-hub-lite/backup/sqlite" -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | sort)
  (( count > 0 )) || { printf 'snapshot contains no verified SQLite copies\n' >&2; return 1; }
}

extract_snapshot() {
  local target="$1"
  safe_target "$target"
  [[ ! -e "$target" ]] || { printf 'restore target already exists: %s\n' "$target" >&2; exit 1; }
  install -d -m 700 "$target"
  restic restore "$snapshot" --target "$target" --tag platform
  validate_extract "$target"
  printf '%s\n' "$target"
}

install_verified_databases() {
  local target="$1" staged database base
  staged="$target/run/llm-hub-lite/backup/sqlite"
  install -d -m 700 "$target$APP_ROOT/shared/data/prod/new-api" "$target$PLATFORM_ROOT/woodpecker/data" "$target$PLATFORM_ROOT/beszel/hub"
  [[ -f "$staged/new-api.db" ]] && install -m 600 "$staged/new-api.db" "$target$APP_ROOT/shared/data/prod/new-api/one-api.db"
  [[ -f "$staged/woodpecker.sqlite" ]] && install -m 600 "$staged/woodpecker.sqlite" "$target$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite"
  while IFS= read -r database; do
    base="${database##*/beszel-}"
    install -m 600 "$database" "$target$PLATFORM_ROOT/beszel/hub/$base"
  done < <(find "$staged" -maxdepth 1 -type f -name 'beszel-*.db' -print | sort)
}

rollback_swaps() {
  local manifest="$1" live saved
  tac "$manifest" | while IFS=$'\t' read -r live saved; do
    [[ -n "$live" && -e "$saved" ]] || continue
    [[ -e "$live" ]] && mv "$live" "$live.failed-$(date -u +%s)"
    mv "$saved" "$live"
  done
}

swap_path() {
  local restored="$1" live="$2" rollback_root="$3" manifest="$4" saved
  [[ -e "$restored" || -L "$restored" ]] || return 0
  saved="$rollback_root${live}"
  install -d -m 700 "$(dirname "$saved")" "$(dirname "$live")"
  if [[ -e "$live" || -L "$live" ]]; then mv "$live" "$saved"; fi
  if ! mv "$restored" "$live"; then
    [[ -e "$saved" || -L "$saved" ]] && mv "$saved" "$live"
    return 1
  fi
  printf '%s\t%s\n' "$live" "$saved" >>"$manifest"
}

apply_snapshot() {
  [[ "$EUID" -eq 0 ]] || { printf 'restore apply must run as root\n' >&2; exit 1; }
  local target rollback_root manifest stamp path
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="${requested_target:-$RESTORE_ROOT/apply-$stamp}"
  extract_snapshot "$target" >/dev/null
  install_verified_databases "$target"
  "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" snapshot pre-restore
  printf 'started_utc=%s\nreason=restore %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$snapshot" >"$MAINTENANCE_FILE"
  PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl stop all

  rollback_root="$RESTORE_ROOT/rollback-$stamp"
  manifest="$rollback_root/manifest.tsv"
  install -d -m 700 "$rollback_root"
  : >"$manifest"
  for path in \
    "$APP_ROOT/shared/data/prod" \
    "$APP_ROOT/shared/runtime" \
    "$APP_ROOT/shared/.env.prod" \
    "$PLATFORM_ROOT/woodpecker/data" \
    "$PLATFORM_ROOT/woodpecker/agent" \
    "$PLATFORM_ROOT/woodpecker/.env" \
    "$PLATFORM_ROOT/beszel/hub" \
    "$PLATFORM_ROOT/beszel/agent" \
    "$PLATFORM_ROOT/beszel/secrets" \
    "$PLATFORM_ROOT/beszel/.env" \
    "$CONFIG_ROOT/deploy.env" \
    "$CONFIG_ROOT/images.env"; do
    if ! swap_path "$target$path" "$path" "$rollback_root" "$manifest"; then
      rollback_swaps "$manifest"
      PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl start all || true
      rm -f -- "$MAINTENANCE_FILE"
      printf 'restore swap failed; prior paths restored\n' >&2
      exit 1
    fi
  done

  if PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl validate && \
    PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl start all && \
    /usr/local/bin/platformctl health true; then
    rm -f -- "$MAINTENANCE_FILE"
    printf 'restore applied successfully; rollback data retained at %s\n' "$rollback_root"
  else
    PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl stop all || true
    rollback_swaps "$manifest"
    if PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl start all; then rm -f -- "$MAINTENANCE_FILE"; fi
    printf 'restore validation failed; prior data restored from %s\n' "$rollback_root" >&2
    exit 1
  fi
}

case "$operation" in
  extract)
    target="${requested_target:-$RESTORE_ROOT/extract-$(date -u +%Y%m%dT%H%M%SZ)}"
    extract_snapshot "$target" >/dev/null
    printf 'restore extracted and validated at %s\n' "$target"
    ;;
  apply) apply_snapshot ;;
  rollback)
    [[ -n "$requested_target" ]] || { printf 'rollback requires a rollback directory\n' >&2; exit 2; }
    safe_target "$requested_target"
    [[ -f "$requested_target/manifest.tsv" ]] || { printf 'missing rollback manifest\n' >&2; exit 1; }
    printf 'started_utc=%s\nreason=restore rollback\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$MAINTENANCE_FILE"
    PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl stop all
    rollback_swaps "$requested_target/manifest.tsv"
    PLATFORM_LOCK_HELD=1 /usr/local/bin/platformctl start all
    rm -f -- "$MAINTENANCE_FILE"
    ;;
  *) printf 'usage: restore-platform {extract|apply|rollback} [snapshot] [target]\n' >&2; exit 2 ;;
esac
