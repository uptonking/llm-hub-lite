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
STAGE_ROOT="${BACKUP_STAGE_ROOT:-/run/llm-hub-lite/backup}"
MIN_FREE_BYTES="${BACKUP_MIN_FREE_BYTES:-5368709120}"
MIN_FREE_PERCENT="${BACKUP_MIN_FREE_PERCENT:-10}"
operation="${1:-snapshot}"
reason="${2:-manual}"

command -v restic >/dev/null 2>&1 || { printf 'restic is required\n' >&2; exit 1; }
[[ -s "$PASSWORD_FILE" ]] || { printf 'missing Restic password file: %s\n' "$PASSWORD_FILE" >&2; exit 1; }
env_value() { local key="$1"; [[ -f "$APP_ENV" ]] || return 0; sed -n "s/^${key}=//p" "$APP_ENV" | tail -n1; }
DATA_ROOT="${DATA_ROOT:-$(env_value DATA_ROOT)}"
DATA_ROOT="${DATA_ROOT:-$APP_ROOT/shared/data/prod}"
WOODPECKER_DATA_ROOT="${WOODPECKER_DATA_ROOT:-$PLATFORM_ROOT/woodpecker/data}"
BESZEL_DATA_ROOT="${BESZEL_DATA_ROOT:-$PLATFORM_ROOT/beszel/hub}"
CADDY_DATA_ROOT="${CADDY_DATA_ROOT:-$PLATFORM_ROOT/caddy}"

install -d -m 700 "$REPO"
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
if [[ ! -f "$REPO/config" ]]; then restic init >/dev/null; fi

check_space() {
  local available_kb total_kb available total percent_guard required
  read -r total_kb available_kb < <(df -Pk "$REPO" | awk 'NR == 2 { print $2, $4 }')
  [[ "$available_kb" =~ ^[0-9]+$ && "$total_kb" =~ ^[0-9]+$ ]] || { printf 'unable to determine backup free-space\n' >&2; return 1; }
  available=$((available_kb * 1024)); total=$((total_kb * 1024))
  percent_guard=$((total * MIN_FREE_PERCENT / 100)); required="$MIN_FREE_BYTES"
  (( percent_guard > required )) && required="$percent_guard"
  (( available >= required )) || { printf 'backup free-space guard failed: available=%s required=%s\n' "$available" "$required" >&2; return 1; }
}

backup_sqlite() {
  local source="$1" target="$2" attempt delay
  [[ -f "$source" ]] || return 0
  for attempt in 1 2 3 4 5; do
    rm -f -- "$target"
    if sqlite3 -cmd '.timeout 30000' "$source" ".backup '$target'" && \
      sqlite3 "$target" 'PRAGMA integrity_check;' | grep -qx ok; then return 0; fi
    delay=$((attempt * 2)); printf 'SQLite backup retry %s/5 for %s in %s seconds\n' "$attempt" "$source" "$delay" >&2; sleep "$delay"
  done
  printf 'SQLite backup failed after retries: %s\n' "$source" >&2; return 1
}

snapshot() {
  command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is required\n' >&2; exit 1; }
  check_space
  install -d -m 700 "$STAGE_ROOT"
  find "$STAGE_ROOT" -mindepth 1 -delete 2>/dev/null || true
  install -d -m 700 "$STAGE_ROOT/sqlite"
  trap 'find "$STAGE_ROOT" -mindepth 1 -delete' EXIT

  backup_sqlite "$DATA_ROOT/new-api/one-api.db" "$STAGE_ROOT/sqlite/new-api.db"
  backup_sqlite "$WOODPECKER_DATA_ROOT/woodpecker.sqlite" "$STAGE_ROOT/sqlite/woodpecker.sqlite"
  while IFS= read -r database; do
    backup_sqlite "$database" "$STAGE_ROOT/sqlite/beszel-$(basename "$database")"
  done < <(find "$BESZEL_DATA_ROOT" -type f \( -name '*.db' -o -name '*.sqlite' \) -print 2>/dev/null | sort)

  printf 'created_utc=%s\nreason=%s\nrelease=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason" "$(readlink "$APP_ROOT/current" 2>/dev/null || true)" >"$STAGE_ROOT/manifest.txt"

  local -a paths existing excludes
  paths=(
    "$DATA_ROOT" "$APP_ROOT/shared/.env.prod" "$APP_ROOT/shared/runtime"
    "$APP_ROOT/current" "$APP_ROOT/previous" "$CONTROL_ROOT/current" "$CONTROL_ROOT/previous"
    "$CONTROL_ROOT/releases" "$FOUNDATION_ROOT" "$CADDY_DATA_ROOT"
    "$PLATFORM_ROOT/woodpecker" "$PLATFORM_ROOT/beszel" "$CONFIG_ROOT/platform.env"
    "$CONFIG_ROOT/images.apps.env" "$CONFIG_ROOT/images.foundation.env"
    "$CONFIG_ROOT/images.apps.previous.env" "$CONFIG_ROOT/images.foundation.previous.env"
    "$CONFIG_ROOT/image-history" "$STAGE_ROOT/sqlite" "$STAGE_ROOT/manifest.txt"
  )
  existing=(); for path in "${paths[@]}"; do [[ -e "$path" || -L "$path" ]] && existing+=("$path"); done
  excludes=(
    --exclude "$DATA_ROOT/new-api/one-api.db*"
    --exclude "$WOODPECKER_DATA_ROOT/*.db*" --exclude "$WOODPECKER_DATA_ROOT/*.sqlite*"
    --exclude "$BESZEL_DATA_ROOT/*.db*" --exclude "$BESZEL_DATA_ROOT/*.sqlite*"
  )
  restic backup --tag platform --tag "$reason" "${excludes[@]}" "${existing[@]}"
  printf 'backup snapshot complete: repository=%s reason=%s\n' "$REPO" "$reason"
}

case "$operation" in
  snapshot) snapshot ;;
  prune) restic forget --tag platform --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune; printf 'backup retention/prune complete\n' ;;
  check) restic check; printf 'backup repository check complete\n' ;;
  *) printf 'usage: backup-platform {snapshot [reason]|prune|check}\n' >&2; exit 2 ;;
esac
