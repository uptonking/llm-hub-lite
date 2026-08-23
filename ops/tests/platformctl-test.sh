#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/control/releases/test" "$tmp/foundation/env" "$tmp/app/shared" "$tmp/config" "$tmp/bin" "$tmp/locks"
cp -a "$repo_root/apps" "$repo_root/config" "$tmp/control/releases/test/"
ln -s "$tmp/control/releases/test" "$tmp/control/current"
for f in "$repo_root"/compose/foundation/*.yml; do cp "$f" "$tmp/foundation/"; done
cp "$repo_root"/ops/foundation/*.env.example "$tmp/foundation/env/"
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
cp "$repo_root"/ops/images.*.prod.env "$tmp/config/"
cat >"$tmp/config/node.env" <<EOF
NODE_ID=leader
NODE_NEW_API_ORIGIN_HOST=worker2-newapi.example.invalid
NODE_CLIPROXY_ORIGIN_HOST=worker2-cpa.example.invalid
NODE_LIBRECHAT_ORIGIN_HOST=worker2-chat.example.invalid
NODE_LIBRECHAT_ADMIN_ORIGIN_HOST=worker2-chat-admin.example.invalid
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
case "$*" in *" ps --all -q"*) printf 'container-id\n';; esac
case "$*" in
  *app-librechat*) printf 'librechat-api\nlibrechat-admin-panel\nlibrechat-client\n';;
  *app-newapi*) printf 'newapi\n';;
  *app-cliproxyapi*) printf 'cliproxyapi\n';;
esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in "network inspect") exit 0;; "inspect --format") printf 'running healthy\n';; "run --rm") exit 0;; esac
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" CONTROL_ROOT="$tmp/control" FOUNDATION_ROOT="$tmp/foundation" CONFIG_ROOT="$tmp/config" APP_ENV="$tmp/app/shared/.env.prod" APP_IMAGE_ENV="$tmp/config/images.apps.prod.env" FOUNDATION_IMAGE_ENV="$tmp/config/images.foundation.prod.env" NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" RUNTIME_ROOT="$tmp/app/shared/runtime" PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'Do not evaluate an inactive app' "$repo_root/ops/platformctl.sh"
[[ -f "$tmp/app/shared/runtime/config/Caddyfile" ]]
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/cliproxyapi.caddy" ]]
grep -Fq 'lb_policy random_choose 2' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'header_up Host {http.reverse_proxy.upstream.hostport}' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
grep -Fq 'location = /health' "$repo_root/apps/librechat/client.nginx.conf"
grep -Fq 'mem_limit:' "$repo_root/apps/librechat/compose.yml"
grep -Fq 'MONGO_MAX_POOL_SIZE:' "$repo_root/apps/librechat/compose.yml"
for foundation_file in "$repo_root"/compose/foundation/*.yml; do
	grep -Fq 'mem_limit:' "$foundation_file"
	grep -Fq 'cpus:' "$foundation_file"
	grep -Fq 'pids_limit:' "$foundation_file"
done
awk '/^  librechat-api:/{in_api=1; next} /^  [a-z0-9-]+:/{in_api=0} in_api && /networks: \[librechat_private\]/{found=1} END{exit found ? 0 : 1}' "$repo_root/apps/librechat/compose.yml"
if awk '/^  librechat-api:/{in_api=1; next} /^  [a-z0-9-]+:/{in_api=0} in_api && /platform_edge/{found=1} END{exit found ? 0 : 1}' "$repo_root/apps/librechat/compose.yml"; then
	printf 'LibreChat API must not join the public edge network\n' >&2
	exit 1
fi
if grep -Fq 'header_up Host {http.request.host}' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"; then
	printf 'leader route overrides the origin Host header\n' >&2
	exit 1
fi
bash "$repo_root/ops/platformctl.sh" status --json | jq -e '.node == "leader" and .role == "leader"' >/dev/null
awk -F= '{if ($1 == "DISABLED_APPS") print "DISABLED_APPS=newapi"; else print}' "$tmp/control/current/config/cluster/policy.env" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/policy.env"
bash "$repo_root/ops/platformctl.sh" validate
[[ ! -e "$tmp/app/shared/runtime/config/routes.d/newapi.caddy" ]]
awk -F= '{if ($1 == "DISABLED_APPS") print "DISABLED_APPS="; else print}' "$tmp/control/current/config/cluster/policy.env" >"$tmp/policy.tmp"
mv "$tmp/policy.tmp" "$tmp/control/current/config/cluster/policy.env"
sed -e 's/^DOMAIN_NAME=.*/DOMAIN_NAME=aichorage.de/' -e 's#^LIBRECHAT_AWS_ENDPOINT_URL=.*#LIBRECHAT_AWS_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com#' "$repo_root/.env.dev.example" >"$tmp/app/shared/.env.prod"
cp "$repo_root/config/cluster/nodes/worker-1.env" "$tmp/config/node.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'production LibreChat placeholder was accepted\n' >&2
	exit 1
fi
cp "$repo_root/.env.dev.example" "$tmp/app/shared/.env.prod"
bash "$repo_root/ops/platformctl.sh" validate
grep -Fq 'librechat-client:80' "$tmp/app/shared/runtime/config/routes.d/librechat.caddy"
bash "$repo_root/ops/platformctl.sh" smoke "app:$tmp/control/current/apps/librechat"
policy_backup="$tmp/policy.original"
cp "$tmp/control/current/config/cluster/policy.env" "$policy_backup"
{
	sed -E '/^(CLIPROXY_PRIMARY_NODE_ID|NEW_API_MIGRATION_NODE_ID|NEW_API_BACKUP_NODE_ID)=/d' "$policy_backup"
	printf '%s\n' 'DISABLED_APPS=newapi,cliproxyapi'
} >"$tmp/control/current/config/cluster/policy.env"
bash "$repo_root/ops/platformctl.sh" validate
mv "$policy_backup" "$tmp/control/current/config/cluster/policy.env"
awk -F= '{if ($1 == "NODE_ID") print "NODE_ID=rogue"; else print}' "$tmp/config/node.env" >"$tmp/node.tmp"
mv "$tmp/node.tmp" "$tmp/config/node.env"
if bash "$repo_root/ops/platformctl.sh" validate >/dev/null 2>&1; then
	printf 'runtime node identity mismatch was accepted\n' >&2
	exit 1
fi
printf 'platformctl tests passed\n'
