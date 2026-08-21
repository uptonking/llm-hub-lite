#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$1 $2" in
  "network inspect") exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"

cat >"$tmp/prod.env" <<'EOF'
DOMAIN_NAME=aichorage.de
SSL_EMAIL=admin@aichorage.de
NEW_API_SITE=https://newapi.aichorage.de
CLIPROXY_SITE=https://cpa.aichorage.de
WOODPECKER_SITE=https://ci.aichorage.de
BESZEL_SITE=https://status.aichorage.de
SESSION_COOKIE_TRUSTED_URL=https://ci.aichorage.de
DATA_ROOT=/opt/apps/llm-hub-lite/shared/data/prod
NEW_API_SESSION_SECRET=test-secret
CLIPROXY_API_KEY=test-api-key
CLIPROXY_MANAGEMENT_KEY=test-management-key
SHARED_NETWORK_NAME=shared_network
EOF
cat >"$tmp/images.env" <<'EOF'
CADDY_IMAGE=caddy:2.10.0@sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de
NEW_API_IMAGE=calciumion/new-api:v1.0.0-rc.25@sha256:54a0b10924aa75fa5b5947208b820ced66b6ef4b445b35f122b31d80676aba2b
CLIPROXY_IMAGE=eceasy/cli-proxy-api:v7.2.137@sha256:591a09c19de769be09a2e56277365cd568b83fc7d98c94d2e7e7bef7069f7422
EOF

export PATH="$tmp/bin:$PATH"
export DOCKER_CALL_LOG="$tmp/docker.log"
export PLATFORM_COMPOSE_BIN="$tmp/bin/docker"
export STACK_ENV_FILE="$tmp/prod.env"
export STACK_IMAGE_ENV_FILE="$tmp/images.env"

"$repo_root/stack.sh" prod validate
"$repo_root/stack.sh" prod restart caddy
grep -q -- "--env-file $tmp/prod.env --env-file $tmp/images.env .* restart caddy" "$tmp/docker.log"
if grep -q 'up -d' "$tmp/docker.log"; then
  printf 'restart must not recreate containers with compose up\n' >&2
  exit 1
fi

sed -i.bak '/^CADDY_IMAGE=/d' "$tmp/images.env"
if "$repo_root/stack.sh" prod validate >"$tmp/missing.out" 2>&1; then
  printf 'validation must reject a missing image digest\n' >&2
  exit 1
fi
grep -q "CADDY_IMAGE must use an immutable sha256 digest in $tmp/images.env" "$tmp/missing.out"

printf 'stack tests passed\n'
