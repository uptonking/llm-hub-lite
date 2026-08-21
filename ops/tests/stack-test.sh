#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$1 $2" in "network inspect") exit 0 ;; esac
exit 0
EOF
chmod +x "$tmp/bin/platform-compose" "$tmp/bin/docker"
cp "$repo_root/.env.prod.example" "$tmp/prod.env"
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose"
export STACK_ENV_FILE="$tmp/prod.env" STACK_IMAGE_ENV_FILE="$repo_root/ops/images.apps.prod.env"
export STACK_FOUNDATION_IMAGE_ENV_FILE="$repo_root/ops/images.foundation.prod.env" STACK_RUNTIME_ROOT="$tmp/runtime"
export COMPOSE_CALL_LOG="$tmp/compose.log" DOCKER_CALL_LOG="$tmp/docker.log"
"$repo_root/stack.sh" prod validate
grep -q 'compose/foundation/caddy.yml config --quiet' "$tmp/compose.log"
grep -q 'apps/newapi/compose.yml config --quiet' "$tmp/compose.log"
grep -q 'apps/cliproxyapi/compose.yml config --quiet' "$tmp/compose.log"
grep -q 'https://newapi.example.com' "$tmp/runtime/config/routes.d/newapi.caddy"
: >"$tmp/compose.log"
sed -i.bak 's/^APP_NEWAPI_DISABLE=false/APP_NEWAPI_DISABLE=true/' "$tmp/prod.env"
"$repo_root/stack.sh" prod up
grep -q 'apps/newapi/compose.yml down --remove-orphans' "$tmp/compose.log"
grep -q 'apps/cliproxyapi/compose.yml up -d' "$tmp/compose.log"
grep -q 'compose/foundation/caddy.yml up -d' "$tmp/compose.log"
: >"$tmp/compose.log"
sed -i.bak 's/^APP_CLIPROXYAPI_DISABLE=false/APP_CLIPROXYAPI_DISABLE=true/' "$tmp/prod.env"
"$repo_root/stack.sh" prod up
grep -q 'apps/newapi/compose.yml down --remove-orphans' "$tmp/compose.log"
grep -q 'apps/cliproxyapi/compose.yml down --remove-orphans' "$tmp/compose.log"
printf 'stack tests passed\n'
