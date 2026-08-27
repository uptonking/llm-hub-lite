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
EOF
cat >"$tmp/bin/sqlite3" <<'EOF'
#!/bin/sh
printf 'ok\n'
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/restic" "$tmp/bin/sqlite3" "$tmp/bin/flock"

PATH="$tmp/bin:$PATH" RESTIC_CALL_LOG="$tmp/restic.log" \
	CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/config/node.env" \
	RESTORE_ROOT="$tmp/restores" PLATFORM_LOCK_FILE="$tmp/platform.lock" \
	RESTORE_SOURCE=remote RESTORE_NODE_ID=leader \
	RESTIC_REMOTE_REPOSITORY="$tmp/remote-repository" \
	RESTIC_REMOTE_PASSWORD_FILE="$tmp/config/restic-remote-password" \
	"$repo_root/ops/restore-platform.sh" extract latest >/dev/null

grep -Fq "repository=$tmp/remote-repository" "$tmp/restic.log"
grep -Fq "password=$tmp/config/restic-remote-password" "$tmp/restic.log"
grep -Fq 'args=restore latest' "$tmp/restic.log"
grep -Fq -- '--tag platform,node:leader' "$tmp/restic.log"
printf 'restore tests passed\n'
