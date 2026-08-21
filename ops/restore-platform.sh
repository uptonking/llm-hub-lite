#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
REPO="${RESTIC_REPOSITORY:-/opt/backups/llm-hub-lite/repository}"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/llm-hub-lite/restic-password}"
snapshot="${1:-latest}"
target="${2:-/opt/backups/llm-hub-lite/restore-$(date -u +%Y%m%dT%H%M%SZ)}"
command -v restic >/dev/null 2>&1 || { printf 'restic is required\n' >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is required\n' >&2; exit 1; }
[[ -s "$PASSWORD_FILE" ]] || { printf 'missing Restic password file\n' >&2; exit 1; }
[[ "$target" == /* && "$target" != *..* ]] || { printf 'restore target must be a safe absolute path\n' >&2; exit 1; }
[[ ! -e "$target" ]] || { printf 'restore target already exists: %s\n' "$target" >&2; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
install -d -m 700 "$target"
restic restore "$snapshot" --target "$target" --tag platform
while IFS= read -r database; do
  sqlite3 "$database" 'PRAGMA integrity_check;' | grep -qx ok || { printf 'restored SQLite integrity check failed: %s\n' "$database" >&2; exit 1; }
done < <(find "$target/run/llm-hub-lite/backup/sqlite" -type f -name '*.db' 2>/dev/null | sort)
printf 'restore extracted to %s; review and atomically replace affected data after validation\n' "$target"
