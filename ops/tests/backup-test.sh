#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2016 # grep intentionally matches literal '$BACKUP_ROOT' text in the source
grep -Fq 'STAGE_ROOT="${BACKUP_STAGE_ROOT:-$BACKUP_ROOT/stage}"' "$repo_root/ops/backup-platform.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/app" "$tmp/platform/foundation/env" "$tmp/config" "$tmp/stage" "$tmp/control/current/apps/aichorouter" "$tmp/control/current/apps/pigeon" "$tmp/control/current/apps/wabase"
printf 'test-password\n' >"$tmp/config/restic-password"
printf 'remote-password\n' >"$tmp/config/restic-remote-password"
cat >"$tmp/control/current/apps/aichorouter/manifest.env" <<'EOF'
RUNTIME_ENV_FILE=aichorouter.env
DATA_ROOT_REL=aichorouter
EPHEMERAL_DATA_REL=log-buffer
SQLITE_PATHS=aichorouter.db
EOF
cat >"$tmp/control/current/apps/pigeon/manifest.env" <<'EOF'
RUNTIME_ENV_FILE=pigeon.env
DATA_ROOT_REL=pigeon
SQLITE_PATHS=outlook_accounts.db
EOF
cat >"$tmp/control/current/apps/wabase/manifest.env" <<'EOF'
RUNTIME_ENV_FILE=wabase.env
DATA_ROOT_REL=wabase
STATE_MODE=sqlite
SQLITE_PATHS=home.sqlite3
SQLITE_GLOBS=docs/*.grist
EOF
printf 'AICHOROUTER_SESSION_SECRET=test\n' >"$tmp/config/aichorouter.env"
printf 'PIGEON_SECRET_KEY=test\n' >"$tmp/config/pigeon.env"
printf 'WABASE_SESSION_SECRET=test\n' >"$tmp/config/wabase.env"
printf 'OBSERVER_DATA_ROOT=%s\n' "$tmp/platform/observer-custom" >"$tmp/platform/foundation/env/observer.env"
mkdir -p "$tmp/platform/observer-custom/data/db"
: >"$tmp/platform/observer-custom/data/db/metadata.sqlite"
mkdir -p "$tmp/app/shared/data/prod/pigeon"
: >"$tmp/app/shared/data/prod/pigeon/outlook_accounts.db"
mkdir -p "$tmp/app/shared/data/prod/wabase/docs"
: >"$tmp/app/shared/data/prod/wabase/home.sqlite3"
: >"$tmp/app/shared/data/prod/wabase/docs/Quarterly Plan.grist"

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
if [ "$1" = version ] && [ "${RESTIC_COMPRESSION:-}" = fastest ]; then
  exit 1
fi
if [ "$1" = backup ] && [ "$2" = --help ]; then
  printf '      --compression mode  one of (auto|off|max)\n'
  [ "${RESTIC_SUPPORTS_SKIP:-0}" = 1 ] && printf '      --skip-if-unchanged  skip snapshot creation when unchanged\n'
  exit 0
fi
if [ "$1" = init ]; then
  touch "${RESTIC_REPOSITORY:?}/config"
fi
exit 0
EOF
cat >"$tmp/bin/sqlite3" <<'EOF'
#!/bin/sh
last=''
source=''
for arg do
  last="$arg"
  case "$arg" in /*) source="$arg" ;; esac
done
printf '%s\n' "$source" >>"${SQLITE_CALL_LOG:?}"
case "$last" in
  .backup\ *)
    target="$(printf '%s\n' "$last" | sed -e "s/^\\.backup '//" -e "s/'\$//")"
    : >"$target"
    ;;
esac
printf 'ok\n'
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/df" "$tmp/bin/restic" "$tmp/bin/sqlite3"
chmod +x "$tmp/bin/flock"

export PATH="$tmp/bin:$PATH"
export DF_CALL_LOG="$tmp/df.log" RESTIC_CALL_LOG="$tmp/restic.log" SQLITE_CALL_LOG="$tmp/sqlite.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp/platform" CONFIG_ROOT="$tmp/config"
export CONTROL_ROOT="$tmp/control" APPS_ROOT="$tmp/control/current/apps"
export RESTIC_REPOSITORY="$tmp/repository" RESTIC_PASSWORD_FILE="$tmp/config/restic-password"
export BACKUP_STAGE_ROOT="$tmp/stage" BACKUP_MIN_FREE_BYTES=1048576 BACKUP_MIN_FREE_PERCENT=1
export PLATFORM_LOCK_FILE="$tmp/platform.lock"
export RESTIC_CACHE_DIR="$tmp/cache" RESTIC_SCHEDULE_MARKER="$tmp/scheduled.marker" RESTIC_SCHEDULE_INTERVAL=3600
export RESTIC_COMPRESSION=fastest

"$repo_root/ops/backup-platform.sh" snapshot portability-test
grep -qx -- "-Pk $tmp/repository" "$tmp/df.log"
grep -q ' backup ' "$tmp/restic.log"
grep -q -- '--compression auto' "$tmp/restic.log"
if grep -q -- '--skip-if-unchanged' "$tmp/restic.log"; then
	printf 'unsupported skip-if-unchanged flag was passed to the old Restic client\n' >&2
	exit 1
fi
grep -q "$tmp/config/aichorouter.env" "$tmp/restic.log"
grep -q "$tmp/config/pigeon.env" "$tmp/restic.log"
grep -qx "$tmp/app/shared/data/prod/pigeon/outlook_accounts.db" "$tmp/sqlite.log"
grep -Fxq "$tmp/app/shared/data/prod/wabase/home.sqlite3" "$tmp/sqlite.log"
grep -Fxq "$tmp/app/shared/data/prod/wabase/docs/Quarterly Plan.grist" "$tmp/sqlite.log"
grep -Fq -- "--exclude $tmp/app/shared/data/prod/wabase/home.sqlite3-wal" "$tmp/restic.log"
grep -Fq -- "--exclude $tmp/app/shared/data/prod/wabase/docs/Quarterly Plan.grist-shm" "$tmp/restic.log"
grep -Fq -- "--exclude $tmp/app/shared/data/prod/wabase/docs/*.grist-journal" "$tmp/restic.log"
grep -q -- "--exclude $tmp/app/shared/data/prod/aichorouter/log-buffer" "$tmp/restic.log"
grep -q "$tmp/platform/observer-custom" "$tmp/restic.log"
grep -q -- "--exclude $tmp/platform/observer-custom/collector-buffer" "$tmp/restic.log"
grep -q -- "--exclude $tmp/platform/observer-custom/data/db/metadata.sqlite" "$tmp/restic.log"
grep -q "$tmp/platform/observer-custom/data/db/metadata.sqlite" "$tmp/restic.log"

cp "$tmp/control/current/apps/wabase/manifest.env" "$tmp/wabase.manifest"
: >"$tmp/app/shared/data/prod/wabase/docs/report.grist"
sed 's/^SQLITE_PATHS=.*/SQLITE_PATHS=home.sqlite3,docs\/report.grist/' "$tmp/wabase.manifest" >"$tmp/control/current/apps/wabase/manifest.env"
if output="$("$repo_root/ops/backup-platform.sh" snapshot duplicate-sqlite-test 2>&1)"; then
	printf 'duplicate exact/glob SQLite declaration was accepted\n' >&2
	exit 1
fi
grep -Fq 'duplicate SQLite database declaration' <<<"$output"
sed 's#^SQLITE_GLOBS=.*#SQLITE_GLOBS=../docs/*.grist#' "$tmp/wabase.manifest" >"$tmp/control/current/apps/wabase/manifest.env"
if output="$("$repo_root/ops/backup-platform.sh" snapshot unsafe-glob-test 2>&1)"; then
	printf 'unsafe SQLite glob was accepted\n' >&2
	exit 1
fi
grep -Fq 'unsafe SQLITE_GLOBS entry' <<<"$output"
mkdir -p "$tmp/outside-docs"
ln -s "$tmp/outside-docs" "$tmp/app/shared/data/prod/wabase/docs-link"
sed 's#^SQLITE_GLOBS=.*#SQLITE_GLOBS=docs-link/*.grist#' "$tmp/wabase.manifest" >"$tmp/control/current/apps/wabase/manifest.env"
if output="$("$repo_root/ops/backup-platform.sh" snapshot symlink-glob-test 2>&1)"; then
	printf 'symlinked SQLite glob directory was accepted\n' >&2
	exit 1
fi
grep -Fq 'SQLITE_GLOBS directory traverses a symlink' <<<"$output"
cp "$tmp/wabase.manifest" "$tmp/control/current/apps/wabase/manifest.env"

# A node may explicitly opt out when its disk is too small for a local
# repository. The backup command must return successfully without invoking
# Restic so deployments do not fail on the opt-out node.
printf 'NODE_ID=worker-2\nBACKUP_ENABLED=false\n' >"$tmp/config/node.env"
: >"$tmp/restic.log"
output="$(NODE_CONFIG_FILE="$tmp/config/node.env" "$repo_root/ops/backup-platform.sh" snapshot disabled-node 2>&1)"
grep -Fq 'Restic backup is disabled for node worker-2' <<<"$output"
[[ ! -s "$tmp/restic.log" ]] || {
	printf 'disabled backup node invoked Restic\n' >&2
	exit 1
}
# The opt-out is self-contained: no Restic binary, password, or flock is
# required when the node descriptor disables backups.
output="$(PATH="$tmp/no-restic:/usr/bin:/bin" RESTIC_PASSWORD_FILE="$tmp/missing-password" PLATFORM_LOCK_FILE="$tmp/missing-lock" NODE_CONFIG_FILE="$tmp/config/node.env" "$repo_root/ops/backup-platform.sh" snapshot disabled-without-backend 2>&1)"
grep -Fq 'Restic backup is disabled for node worker-2' <<<"$output"
printf 'NODE_ID=leader\n' >"$tmp/config/node.env"

if PRODUCTION_REQUIRE_REMOTE_BACKUP=true RESTIC_REMOTE_ENABLED=false \
	"$repo_root/ops/backup-platform.sh" snapshot production-gate-test >/dev/null 2>&1; then
	printf 'production backup gate accepted a local-only snapshot\n' >&2
	exit 1
fi

export RESTIC_REMOTE_ENABLED=true RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password"
export RESTIC_SUPPORTS_SKIP=1
mkdir -p "$tmp/remote-repository"
"$repo_root/ops/backup-platform.sh" snapshot remote-test
grep -q "$tmp/remote-repository" "$tmp/restic.log"

# A fresh scheduled marker suppresses the expensive Restic calls, while a
# manual snapshot remains immediate even inside the scheduled interval.
printf '%s\n' "$(date +%s)" >"$RESTIC_SCHEDULE_MARKER"
before_backups="$(grep -c ' backup --compression ' "$tmp/restic.log" || true)"
"$repo_root/ops/backup-platform.sh" snapshot scheduled >/dev/null
after_backups="$(grep -c ' backup --compression ' "$tmp/restic.log" || true)"
[[ "$before_backups" == "$after_backups" ]] || {
	printf 'scheduled backup was not throttled\n' >&2
	exit 1
}
"$repo_root/ops/backup-platform.sh" snapshot manual >/dev/null
manual_backups="$(grep -c ' backup --compression ' "$tmp/restic.log" || true)"
((manual_backups > after_backups)) || {
	printf 'manual backup was incorrectly throttled\n' >&2
	exit 1
}

mkdir -p "$tmp/control/current/apps/newapi" "$tmp/control/current/config/cluster/apps" "$tmp/control/current/config/cluster/nodes"
cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
NODE_IDS=leader,worker-1
EOF
cat >"$tmp/control/current/apps/newapi/manifest.env" <<'EOF'
POLICY_FILE=cluster/apps/newapi.policy
DATA_ROOT_REL=new-api
SQLITE_PATHS=
EOF
cat >"$tmp/control/current/config/cluster/apps/newapi.policy" <<'EOF'
ENABLED=true
NODES=leader,worker-1
NEW_API_BACKUP_NODE_ID=leader
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

# A malformed New API policy must fail closed like an explicitly disabled one;
# the standalone backup timer may run before a controller reconciliation has
# rejected the bad release.
sed 's/^ENABLED=.*/ENABLED=typo/' \
	"$tmp/control/current/config/cluster/apps/newapi.policy" >"$tmp/control/current/config/cluster/apps/newapi.policy.tmp"
mv "$tmp/control/current/config/cluster/apps/newapi.policy.tmp" "$tmp/control/current/config/cluster/apps/newapi.policy"
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=leader
EOF
: >"$PG_DUMP_CALL_LOG"
"$repo_root/ops/backup-platform.sh" snapshot postgres-malformed-policy-test
[[ ! -s "$PG_DUMP_CALL_LOG" ]] || {
	printf 'malformed New API policy unexpectedly invoked pg_dump\n' >&2
	exit 1
}

mkdir -p "$tmp/control/current/apps/librechat"
cat >"$tmp/control/current/apps/librechat/manifest.env" <<'EOF'
POLICY_FILE=cluster/apps/librechat.policy
DATA_ROOT_REL=librechat
SQLITE_PATHS=
EOF
cat >"$tmp/control/current/config/cluster/apps/librechat.policy" <<'EOF'
ENABLED=true
NODES=leader,worker-1
MONGO_BACKUP_ENABLED=true
MONGO_BACKUP_NODE_ID=worker-1
EOF
cat >"$tmp/bin/mongodump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MONGODUMP_CALL_LOG:?}"
for argument do
  case "$argument" in
    --archive=*) : >"${argument#--archive=}" ;;
  esac
done
EOF
chmod +x "$tmp/bin/mongodump"
export MONGODUMP_CALL_LOG="$tmp/mongodump.log" LIBRECHAT_MONGO_URI=mongodb+srv://backup.example/LibreChat
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=worker-1
EOF
: >"$MONGODUMP_CALL_LOG"
"$repo_root/ops/backup-platform.sh" snapshot mongo-owner-test
grep -q -- '--uri mongodb+srv://backup.example/LibreChat --gzip --archive=' "$MONGODUMP_CALL_LOG"

cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=leader
EOF
: >"$MONGODUMP_CALL_LOG"
"$repo_root/ops/backup-platform.sh" snapshot mongo-non-owner-test
[[ ! -s "$MONGODUMP_CALL_LOG" ]] || {
	printf 'non-owner node invoked mongodump\n' >&2
	exit 1
}

sed 's/^MONGO_BACKUP_NODE_ID=.*/MONGO_BACKUP_NODE_ID=missing-node/' \
	"$tmp/control/current/config/cluster/apps/librechat.policy" >"$tmp/control/current/config/cluster/apps/librechat.policy.tmp"
mv "$tmp/control/current/config/cluster/apps/librechat.policy.tmp" "$tmp/control/current/config/cluster/apps/librechat.policy"
if "$repo_root/ops/backup-platform.sh" snapshot mongo-invalid-owner-test >/dev/null 2>&1; then
	printf 'LibreChat backup accepted an owner outside app placement\n' >&2
	exit 1
fi

printf 'backup tests passed\n'
