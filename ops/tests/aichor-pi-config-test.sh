#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/sync-aichor-pi-config.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/source" "$tmp/export" "$tmp/data"
cat >"$tmp/source/settings.json" <<'EOF'
{"defaultProvider":"test","defaultModel":"model-1"}
EOF
cat >"$tmp/source/models.json" <<'EOF'
{"providers":{"test":{"baseUrl":"https://example.invalid/v1","api":"openai-completions","apiKey":"$TEST_API_KEY","models":[{"id":"model-1"}]}}}
EOF
printf 'must not be copied\n' >"$tmp/source/auth.json"

AICHOR_PI_DATA_ROOT="$tmp/data" bash "$script" install "$tmp/source"
cmp "$tmp/source/settings.json" "$tmp/data/aichor/.pi/agent/settings.json"
cmp "$tmp/source/models.json" "$tmp/data/aichor/.pi/agent/models.json"
[[ ! -e "$tmp/data/aichor/.pi/agent/auth.json" ]]

printf '{"defaultProvider":"test","defaultModel":"model-2"}\n' >"$tmp/source/settings.json"
AICHOR_PI_DATA_ROOT="$tmp/data" bash "$script" install "$tmp/source"
find "$tmp/data/aichor/.pi/agent" -name 'settings.json.bak.*' | grep -q .

printf '{"defaultProvider":"changed"}\n' >"$tmp/data/aichor/.pi/agent/settings.json"
AICHOR_PI_DATA_ROOT="$tmp/data" bash "$script" export "$tmp/export"
cmp "$tmp/data/aichor/.pi/agent/settings.json" "$tmp/export/settings.json"
cmp "$tmp/data/aichor/.pi/agent/models.json" "$tmp/export/models.json"

printf 'Aichor Pi config sync tests passed\n'
