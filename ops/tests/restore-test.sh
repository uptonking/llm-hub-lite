#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/restores"
printf 'remote-password\n' >"$tmp/config/restic-remote-password"
printf 'NODE_ID=worker-1\n' >"$tmp/config/node.env"

cat >"$tmp/bin/restic" <<'EOF'
#!/bin/sh
printf 'repository=%s password=%s args=%s\n' "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD_FILE" "$*" >"${RESTIC_CALL_LOG:?}"
target=''
next_target=0
for argument do
  if [ "$next_target" = 1 ]; then target="$argument"; next_target=0; continue; fi
  [ "$argument" = --target ] && next_target=1
done
if [ -n "$target" ]; then
  staged="$target${TEST_BACKUP_STAGE_ROOT:?}/sqlite"
  mkdir -p "$staged"
  artifact=wobase-document.grist
  [ "${RESTIC_FIXTURE_CORRUPT:-0}" = 1 ] && artifact=corrupt.grist
  : >"$staged/$artifact"
  printf 'wobase\twobase\tdocs/Quarterly Plan.grist\t%s\n' "$artifact" >"$staged/map.tsv"
fi
EOF
cat >"$tmp/bin/sqlite3" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"${SQLITE_CALL_LOG:?}"
case "$1" in *corrupt.grist) printf 'not ok\n'; exit 0 ;; esac
printf 'ok\n'
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/restic" "$tmp/bin/sqlite3" "$tmp/bin/flock"

PATH="$tmp/bin:$PATH" RESTIC_CALL_LOG="$tmp/restic.log" SQLITE_CALL_LOG="$tmp/sqlite.log" \
	CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/config/node.env" \
	RESTORE_ROOT="$tmp/restores" PLATFORM_LOCK_FILE="$tmp/platform.lock" \
	BACKUP_STAGE_ROOT=/backup/stage TEST_BACKUP_STAGE_ROOT=/backup/stage \
	RESTORE_SOURCE=remote RESTORE_NODE_ID=leader \
	RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" \
	RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password" \
	"$repo_root/ops/restore-platform.sh" extract latest "$tmp/restores/good" >/dev/null

grep -Fq "repository=$tmp/remote-repository" "$tmp/restic.log"
grep -Fq "password=$tmp/config/restic-remote-password" "$tmp/restic.log"
grep -Fq 'args=restore latest' "$tmp/restic.log"
grep -Fq -- '--tag platform,node:leader' "$tmp/restic.log"
grep -Fq 'wobase-document.grist' "$tmp/sqlite.log"

if PATH="$tmp/bin:$PATH" RESTIC_CALL_LOG="$tmp/restic.log" SQLITE_CALL_LOG="$tmp/sqlite.log" \
	CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/config/node.env" \
	RESTORE_ROOT="$tmp/restores" PLATFORM_LOCK_FILE="$tmp/platform.lock" \
	BACKUP_STAGE_ROOT=/backup/stage TEST_BACKUP_STAGE_ROOT=/backup/stage RESTIC_FIXTURE_CORRUPT=1 \
	RESTORE_SOURCE=remote RESTORE_NODE_ID=leader \
	RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" \
	RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password" \
	"$repo_root/ops/restore-platform.sh" extract latest "$tmp/restores/corrupt" >/dev/null 2>&1; then
	printf 'corrupt mapped .grist database passed restore validation\n' >&2
	exit 1
fi
printf 'restore tests passed\n'
