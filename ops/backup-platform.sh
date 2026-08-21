#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/llm-hub-lite/restic-password}"
STAGE_ROOT="${BACKUP_STAGE_ROOT:-/run/llm-hub-lite/backup}"
MIN_FREE_BYTES="${BACKUP_MIN_FREE_BYTES:-536870912}"
CHECK_MAX_AGE_DAYS="${RESTIC_CHECK_MAX_AGE_DAYS:-7}"
reason="${1:-manual}"

command -v restic >/dev/null 2>&1 || { printf 'restic is required\n' >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is required\n' >&2; exit 1; }
[[ -s "$PASSWORD_FILE" ]] || { printf 'missing Restic password file: %s\n' "$PASSWORD_FILE" >&2; exit 1; }
install -d -m 700 "$REPO"
available_bytes="$(df --output=avail -B1 "$REPO" | tail -n 1 | tr -d ' ')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || { printf 'unable to determine backup free space\n' >&2; exit 1; }
(( available_bytes >= MIN_FREE_BYTES )) || { printf 'backup filesystem free space is below the configured guard\n' >&2; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
if [[ ! -f "$REPO/config" ]]; then restic init >/dev/null; fi

stage="$STAGE_ROOT"
install -d -m 700 "$stage"
find "$stage" -mindepth 1 -delete
trap 'find "$stage" -mindepth 1 -delete' EXIT
install -d -m 700 "$stage/sqlite"

backup_sqlite() {
  local source="$1" target="$2" attempt delay
  [[ -f "$source" ]] || return 0
  for attempt in 1 2 3 4 5; do
    rm -f -- "$target"
    if sqlite3 -cmd '.timeout 30000' "$source" ".backup '$target'" && \
      sqlite3 "$target" 'PRAGMA integrity_check;' | grep -qx ok; then
      return 0
    fi
    delay=$((attempt * 2))
    printf 'SQLite backup retry %s/5 for %s in %s seconds\n' "$attempt" "$source" "$delay" >&2
    sleep "$delay"
  done
  printf 'SQLite backup failed after retries: %s\n' "$source" >&2
  return 1
}

backup_sqlite "$APP_ROOT/shared/data/prod/new-api/one-api.db" "$stage/sqlite/new-api.db"
backup_sqlite "$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite" "$stage/sqlite/woodpecker.sqlite"
while IFS= read -r database; do
  backup_sqlite "$database" "$stage/sqlite/beszel-$(basename "$database")"
done < <(find "$PLATFORM_ROOT/beszel/hub" -maxdepth 1 -type f -name '*.db' -print 2>/dev/null | sort)

manifest="$stage/manifest.txt"
{
  printf 'created_utc=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason"
  readlink "$APP_ROOT/current" 2>/dev/null || true
} >"$manifest"

paths=(
  "$APP_ROOT/shared/data/prod"
  "$APP_ROOT/shared/.env.production"
  "$APP_ROOT/shared/runtime"
  "$APP_ROOT/current"
  "$APP_ROOT/previous"
  "$PLATFORM_ROOT/woodpecker/data"
  "$PLATFORM_ROOT/woodpecker/agent"
  "$PLATFORM_ROOT/woodpecker/.env"
  "$PLATFORM_ROOT/beszel/hub"
  "$PLATFORM_ROOT/beszel/agent"
  "$PLATFORM_ROOT/beszel/.env"
  "$PLATFORM_ROOT/beszel/secrets"
  "$stage/sqlite"
  "$manifest"
)
existing=()
for path in "${paths[@]}"; do [[ -e "$path" || -L "$path" ]] && existing+=("$path"); done
restic backup --tag platform --tag "$reason" \
  --exclude "$APP_ROOT/shared/data/prod/new-api/one-api.db" \
  --exclude "$APP_ROOT/shared/data/prod/new-api/one-api.db-journal" \
  --exclude "$APP_ROOT/shared/data/prod/new-api/one-api.db-shm" \
  --exclude "$APP_ROOT/shared/data/prod/new-api/one-api.db-wal" \
  --exclude "$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite" \
  --exclude "$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite-journal" \
  --exclude "$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite-shm" \
  --exclude "$PLATFORM_ROOT/woodpecker/data/woodpecker.sqlite-wal" \
  --exclude "$PLATFORM_ROOT/beszel/hub/*.db" \
  --exclude "$PLATFORM_ROOT/beszel/hub/*.db-journal" \
  --exclude "$PLATFORM_ROOT/beszel/hub/*.db-shm" \
  --exclude "$PLATFORM_ROOT/beszel/hub/*.db-wal" \
  "${existing[@]}"
restic forget --tag platform --keep-last 48 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
check_stamp="$(dirname "$REPO")/.last-restic-check"
if [[ ! -f "$check_stamp" ]] || find "$check_stamp" -mtime "+$CHECK_MAX_AGE_DAYS" -print -quit | grep -q .; then
  restic check
  touch "$check_stamp"
fi
printf 'backup complete: repository=%s reason=%s\n' "$REPO" "$reason"
