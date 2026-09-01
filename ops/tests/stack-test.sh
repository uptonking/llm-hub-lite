#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
for node_file in "$repo_root"/config/cluster/nodes/*.env; do
	node="$(basename "$node_file" .env)"
	STACK_ENV_FILE="$repo_root/.env.dev.example" STACK_NODE_CONFIG_FILE="$node_file" STACK_RUNTIME_ROOT="$tmp/$node" \
		"$repo_root/stack.sh" dev validate >/dev/null
	grep -Fxq 'AICHOROUTER_SITE=http://aichorouter.localhost' "$tmp/$node/app-env/aichorouter.env"
	grep -Fxq 'LIBRECHAT_SITE=http://chat.localhost' "$tmp/$node/app-env/librechat.env"
	grep -Fxq 'LIBRECHAT_ADMIN_SITE=http://chat-admin.localhost' "$tmp/$node/app-env/librechat.env"
	grep -Fxq 'WABASE_SITE=http://wabase.localhost' "$tmp/$node/app-env/wabase.env"
done
# A malformed policy must not silently enable a consumer in local mode. Keep
# this check independent of Docker by validating the generated routes only.
malformed_root="$tmp/malformed"
mkdir -p "$malformed_root"
ln -s "$repo_root/stack.sh" "$malformed_root/stack.sh"
ln -s "$repo_root/apps" "$malformed_root/apps"
ln -s "$repo_root/compose" "$malformed_root/compose"
ln -s "$repo_root/ops" "$malformed_root/ops"
cp -a "$repo_root/config" "$malformed_root/config"
cp "$repo_root/.env.dev.example" "$malformed_root/.env.dev.example"
sed -i.bak 's/^ENABLED=true$/ENABLED=typo/' "$malformed_root/config/cluster/apps/aichorouter.policy"
rm -f "$malformed_root/config/cluster/apps/aichorouter.policy.bak"
STACK_ENV_FILE="$malformed_root/.env.dev.example" STACK_NODE_CONFIG_FILE="$malformed_root/config/cluster/nodes/worker-1.env" STACK_RUNTIME_ROOT="$tmp/malformed-runtime" \
	"$malformed_root/stack.sh" dev validate >/dev/null
if [[ -e "$tmp/malformed-runtime/config/routes.d/aichorouter.caddy" ]]; then
	printf 'malformed app policy unexpectedly produced a route\n' >&2
	exit 1
fi
printf 'stack role validation tests passed\n'
