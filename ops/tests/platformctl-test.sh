#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/control/releases/test" "$tmp/foundation/env" "$tmp/app/shared" "$tmp/config" "$tmp/locks"
cp -a "$repo_root/apps" "$repo_root/config" "$tmp/control/releases/test/"
ln -s "$tmp/control/releases/test" "$tmp/control/current"
cp "$repo_root"/compose/foundation/*.yml "$tmp/foundation/"
cp "$repo_root/ops/foundation/caddy.env.example" "$tmp/foundation/env/caddy.env"
cp "$repo_root/ops/foundation/woodpecker.env.example" "$tmp/foundation/env/woodpecker.env"
cp "$repo_root/ops/foundation/beszel.env.example" "$tmp/foundation/env/beszel.env"
cp "$repo_root/.env.prod.example" "$tmp/app/shared/.env.prod"
cp "$repo_root/ops/images.apps.prod.env" "$tmp/config/images.apps.env"
cp "$repo_root/ops/images.foundation.prod.env" "$tmp/config/images.foundation.env"
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in *" ps --all -q"*) printf 'container-id\n' ;; esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "network inspect") exit 0 ;;
  "inspect --format") printf 'running healthy\n' ;;
  "ps -a") printf '{"Names":"test"}\n' ;;
  "run --rm") exit 0 ;;
esac
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose" COMPOSE_CALL_LOG="$tmp/compose.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation"
export APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.env"
export RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock" PLATFORM_MAINTENANCE_FILE="$tmp/config/maintenance"
export RECOVERY_GRACE_SECONDS=0 COMPOSE_WAIT_TIMEOUT=3
controller="$repo_root/ops/platformctl.sh"
bash "$controller" validate
bash "$controller" recover --quiet
if grep -q ' up -d ' "$tmp/compose.log"; then printf 'healthy recovery must be a no-op\n' >&2; exit 1; fi
sed -i.bak 's/^APP_NEWAPI_DISABLE=false/APP_NEWAPI_DISABLE=true/' "$APP_ENV"
: >"$tmp/compose.log"
bash "$controller" recover --quiet
bash "$controller" status --json | jq -e '.projects | index("app:'"$tmp/control/current/apps/newapi"'") | not' >/dev/null
sed -i.bak 's/^SERVICE_BESZEL_DISABLE=false/SERVICE_BESZEL_DISABLE=true/' "$APP_ENV"
bash "$controller" status --json | jq -e '.projects | index("beszel") | not' >/dev/null
bash "$controller" maintenance begin test >/dev/null
[[ -f "$tmp/config/maintenance" ]]
bash "$controller" maintenance end >/dev/null
[[ ! -e "$tmp/config/maintenance" ]]
printf 'platformctl tests passed\n'
