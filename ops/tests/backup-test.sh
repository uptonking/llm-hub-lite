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

if PRODUCTION_REQUIRE_REMOTE_BACKUP=true RESTIC_REMOTE_ENABLED=false \
	"$repo_root/ops/backup-platform.sh" snapshot production-gate-test >/dev/null 2>&1; then
	printf 'production backup gate accepted a local-only snapshot\n' >&2
	exit 1
fi

export RESTIC_REMOTE_ENABLED=true RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password"
mkdir -p "$tmp/remote-repository"
"$repo_root/ops/backup-platform.sh" snapshot remote-test
grep -q "$tmp/remote-repository" "$tmp/restic.log"

mkdir -p "$tmp/control/current/config/cluster/nodes"
cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
NODE_IDS=leader,worker-1
NEW_API_BACKUP_NODE_ID=leader
DISABLED_APPS=
EOF
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=leader
EOF
cat >"$tmp/bin/pg_dump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PG_DUMP_CALL_LOG:?}"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --file ]; then
    shift
    : >"$1"
  fi
  shift
done
EOF
cat >"$tmp/bin/pg_restore" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/pg_dump" "$tmp/bin/pg_restore"
export PG_DUMP_CALL_LOG="$tmp/pg_dump.log" NEW_API_SQL_DSN=postgresql://backup.example/newapi
export NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env"
: >"$PG_DUMP_CALL_LOG"
"$repo_root/ops/backup-platform.sh" snapshot postgres-owner-test
grep -q 'postgresql://backup.example/newapi' "$PG_DUMP_CALL_LOG"
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=worker-1
EOF
: >"$PG_DUMP_CALL_LOG"
"$repo_root/ops/backup-platform.sh" snapshot postgres-non-owner-test
[[ ! -s "$PG_DUMP_CALL_LOG" ]] || {
	printf 'non-owner node invoked pg_dump\n' >&2
	exit 1
}

printf 'backup tests passed\n'
