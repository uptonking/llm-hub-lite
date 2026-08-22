#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/app" "$tmp/platform" "$tmp/config" "$tmp/stage"
printf 'test-password\n' >"$tmp/config/restic-password"
printf 'remote-password\n' >"$tmp/config/restic-remote-password"

cat >"$tmp/bin/df" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DF_CALL_LOG:?}"
case "$1" in
  --output*|-B1)
    printf 'GNU-only df option used\n' >&2
    exit 2
    ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'testfs 20000000 1000000 19000000 5%% /backup\n'
EOF
cat >"$tmp/bin/restic" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${RESTIC_REPOSITORY:-}" "$*" >>"${RESTIC_CALL_LOG:?}"
if [ "$1" = init ]; then
  touch "${RESTIC_REPOSITORY:?}/config"
fi
exit 0
EOF
cat >"$tmp/bin/sqlite3" <<'EOF'
#!/bin/sh
printf 'ok\n'
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/df" "$tmp/bin/restic" "$tmp/bin/sqlite3"
chmod +x "$tmp/bin/flock"

export PATH="$tmp/bin:$PATH"
export DF_CALL_LOG="$tmp/df.log" RESTIC_CALL_LOG="$tmp/restic.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp/platform" CONFIG_ROOT="$tmp/config"
export RESTIC_REPOSITORY="$tmp/repository" RESTIC_PASSWORD_FILE="$tmp/config/restic-password"
export BACKUP_STAGE_ROOT="$tmp/stage" BACKUP_MIN_FREE_BYTES=1048576 BACKUP_MIN_FREE_PERCENT=1
export PLATFORM_LOCK_FILE="$tmp/platform.lock"

"$repo_root/ops/backup-platform.sh" snapshot portability-test
grep -qx -- "-Pk $tmp/repository" "$tmp/df.log"
grep -q ' backup ' "$tmp/restic.log"

export RESTIC_REMOTE_ENABLED=true RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password"
mkdir -p "$tmp/remote-repository"
"$repo_root/ops/backup-platform.sh" snapshot remote-test
grep -q "$tmp/remote-repository" "$tmp/restic.log"

printf 'backup tests passed\n'
