#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/app/shared/runtime" "$tmp/woodpecker" "$tmp/beszel/secrets" "$tmp/config" "$tmp/locks"

cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in
  *" ps --all -q"*)
    case "$*" in
      *woodpecker*) printf 'wood-server\nwood-agent\n' ;;
      *beszel*) printf 'beszel-hub\n' ;;
      *) printf 'app-caddy\napp-api\napp-proxy\n' ;;
    esac
    ;;
esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "network inspect") exit 0 ;;
  "inspect --format") printf 'running healthy\n' ;;
  "ps -a") printf '{"Names":"test"}\n' ;;
esac
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/platform-compose" "$tmp/bin/docker" "$tmp/bin/flock"

printf 'services: {}\n' >"$tmp/app/shared/runtime/docker-compose.base.yml"
printf 'services: {}\n' >"$tmp/app/shared/runtime/docker-compose.prod.yml"
printf 'services: {}\n' >"$tmp/woodpecker/docker-compose.yml"
printf 'services: {}\n' >"$tmp/beszel/docker-compose.yml"
printf 'DATA_ROOT=%s\n' "$tmp/app/shared/data/prod" >"$tmp/app/shared/.env.prod"
printf 'WOODPECKER_ADMIN=test\n' >"$tmp/woodpecker/.env"
printf 'BESZEL_APP_URL=https://status.example.invalid\n' >"$tmp/beszel/.env"
cp "$repo_root/ops/images.prod.env" "$tmp/config/images.env"

export PATH="$tmp/bin:$PATH"
export PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose"
export COMPOSE_CALL_LOG="$tmp/compose.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp"
export WOODPECKER_ROOT="$tmp/woodpecker" BESZEL_ROOT="$tmp/beszel"
export PLATFORM_IMAGE_ENV="$tmp/config/images.env"
export PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
export PLATFORM_MAINTENANCE_FILE="$tmp/config/maintenance"
export RECOVERY_GRACE_SECONDS=0 COMPOSE_WAIT_TIMEOUT=3

controller="$repo_root/ops/platformctl.sh"
"$controller" validate
"$controller" recover --quiet
if grep -q ' up -d ' "$tmp/compose.log"; then
  printf 'healthy recovery must not reconcile containers\n' >&2
  exit 1
fi
"$controller" restart app
grep -q ' restart$' "$tmp/compose.log"
"$controller" recreate app
grep -q -- '--force-recreate' "$tmp/compose.log"
"$controller" status --json | jq -e '.containers | length == 1' >/dev/null
"$controller" maintenance begin test
[[ -f "$tmp/config/maintenance" ]]
"$controller" maintenance end
[[ ! -e "$tmp/config/maintenance" ]]
printf 'platformctl tests passed\n'
