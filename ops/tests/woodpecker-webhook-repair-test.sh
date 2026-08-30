#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
repair="$repo_root/ops/woodpecker-repair.sh"
bash -n "$repair"
bash -n "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'select id,hash from users where admin = 1' "$repair"
grep -Fq '/api/repos/repair' "$repair"
grep -Fq 'platform-woodpecker-repair.timer' "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'woodpecker-repair' "$repo_root/ops/bootstrap-vps.sh"
grep -Fq 'OnUnitActiveSec=24h' "$repo_root/ops/systemd/platform-woodpecker-repair.timer"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llm-hub-lite-webhook.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/control/current/config/cluster" "$tmp/foundation/env" "$tmp/data" "$tmp/bin"
printf 'NODE_ID=leader\n' >"$tmp/node.env"
printf 'LEADER_NODE_ID=leader\n' >"$tmp/control/current/config/cluster/policy.env"
printf 'PLATFORM_ROOT=%s\n' "$tmp" >"$tmp/platform.env"
printf 'WOODPECKER_HOST=https://ci.example.test\nWOODPECKER_DATA_ROOT=%s\n' "$tmp/data" >"$tmp/foundation/env/woodpecker.env"
sqlite3 "$tmp/data/woodpecker.sqlite" 'create table users (id integer, hash text, admin integer); insert into users values (1, "test-admin-hash", 1);'
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"${CURL_ARGS_FILE:?}"
printf '204\n'
EOF
chmod 700 "$tmp/bin/curl"
CURL_ARGS_FILE="$tmp/curl.args" PATH="$tmp/bin:$PATH" CONFIG_ROOT="$tmp" PLATFORM_ENV="$tmp/platform.env" NODE_CONFIG_FILE="$tmp/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" WOODPECKER_ENV="$tmp/foundation/env/woodpecker.env" "$repair" >/dev/null
grep -Fq 'api/repos/repair' "$tmp/curl.args"
grep -Eq 'Authorization: Bearer [^ ]+\.[^ ]+\.[^ ]+' "$tmp/curl.args"
printf 'Woodpecker webhook repair tests passed\n'
