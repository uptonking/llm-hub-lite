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
case "$*" in *" up -d "*) [ "${FAIL_UP:-0}" = 1 ] && exit 1 ;; esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "network inspect") [ "${FORCE_NETWORK_MISSING:-0}" = 1 ] && exit 1; exit 0 ;;
  "network create") printf '%s\n' "$*" >>"${NETWORK_CREATE_LOG:?}"; exit 0 ;;
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
export NETWORK_CREATE_LOG="$tmp/network-create.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation"
export APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.env"
export RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock" PLATFORM_MAINTENANCE_FILE="$tmp/config/maintenance"
export RECOVERY_GRACE_SECONDS=0 COMPOSE_WAIT_TIMEOUT=3
controller="$repo_root/ops/platformctl.sh"
bash "$controller" validate
old_route="$(cat "$RUNTIME_ROOT/config/routes.d/newapi.caddy")"
sed -i.bak 's#^NEW_API_SITE=.*#NEW_API_SITE=https://candidate.example.com#' "$APP_ENV"
if FAIL_UP=1 bash "$controller" sync apps; then
  printf 'expected staged sync failure\n' >&2
  exit 1
fi
[[ "$(cat "$RUNTIME_ROOT/config/routes.d/newapi.caddy")" == "$old_route" ]]
sed -i.bak 's#^NEW_API_SITE=.*#NEW_API_SITE=https://newapi.example.com#' "$APP_ENV"
FORCE_NETWORK_MISSING=1 NETWORK_CREATE_LOG="$tmp/check-network-create.log" bash "$controller" validate --check
[[ ! -s "$tmp/check-network-create.log" ]]
: >"$tmp/compose.log"
bash "$controller" recover --quiet
if grep -q ' up -d ' "$tmp/compose.log"; then printf 'healthy recovery must be a no-op\n' >&2; exit 1; fi
 : >"$tmp/compose.log"
 bash "$controller" sync apps
 grep -q ' up -d --pull never --wait' "$tmp/compose.log"
sed -i.bak 's/^APP_NEWAPI_DISABLE=false/APP_NEWAPI_DISABLE=true/' "$APP_ENV"
: >"$tmp/compose.log"
bash "$controller" recover --quiet
bash "$controller" restart all
grep -q 'down --remove-orphans' "$tmp/compose.log"
bash "$controller" status --json | jq -e '.projects | index("app:'"$tmp/control/current/apps/newapi"'") | not' >/dev/null
[[ ! -e "$RUNTIME_ROOT/config/routes.d/newapi.caddy" ]]
sed -i.bak 's/^SERVICE_BESZEL_DISABLE=false/SERVICE_BESZEL_DISABLE=true/' "$APP_ENV"
bash "$controller" status --json | jq -e '.projects | index("beszel") | not' >/dev/null
[[ ! -e "$RUNTIME_ROOT/config/foundation-routes.d/beszel.caddy" ]]
cp -a "$tmp/control/current/apps/newapi" "$tmp/control/current/apps/default-disabled"
sed -i.bak \
  -e 's/^APP_ID=newapi/APP_ID=default-disabled/' \
  -e 's/^COMPOSE_PROJECT=app-newapi/COMPOSE_PROJECT=app-default-disabled/' \
  -e 's/^SERVICE_NAME=newapi/SERVICE_NAME=default-disabled/' \
  -e 's/^NETWORK_ALIAS=newapi/NETWORK_ALIAS=default-disabled/' \
  -e 's/^DEFAULT_DISABLED=false/DEFAULT_DISABLED=true/' \
  "$tmp/control/current/apps/default-disabled/manifest.env"
bash "$controller" status --json | jq -e '.projects | index("app:'"$tmp/control/current/apps/default-disabled"'") | not' >/dev/null
bash "$controller" maintenance begin test >/dev/null
[[ -f "$tmp/config/maintenance" ]]
bash "$controller" maintenance end >/dev/null
[[ ! -e "$tmp/config/maintenance" ]]
printf 'platformctl tests passed\n'
