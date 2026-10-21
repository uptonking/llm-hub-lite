#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
dev_searx_hash="\$2a\$14\$v67tDOrc14wVF5bwuJ4SYe48FsnIx1kB4LUZA7TAmCepLmj7tYzQ."
for node_file in "$repo_root"/config/cluster/nodes/*.env; do
	node="$(basename "$node_file" .env)"
	STACK_ENV_FILE="$repo_root/.env.dev.example" STACK_NODE_CONFIG_FILE="$node_file" STACK_RUNTIME_ROOT="$tmp/$node" \
		"$repo_root/stack.sh" dev validate >/dev/null
	grep -Fxq 'AICHOROUTER_SITE=http://aichorouter.localhost' "$tmp/$node/app-env/aichorouter.env"
	grep -Fxq 'AICHOR_SITE=http://aichor.localhost' "$tmp/$node/app-env/aichor.env"
	grep -Fxq 'AICHOR_SITE_HOST=aichor.localhost' "$tmp/$node/app-env/aichor.env"
	grep -Fxq 'AICHOR1_SITE=http://aichor1.localhost' "$tmp/$node/app-env/aichor1.env"
	grep -Fxq 'AICHOR1_SITE_HOST=aichor1.localhost' "$tmp/$node/app-env/aichor1.env"
	grep -Fxq 'SEARX_SITE=http://searx.localhost' "$tmp/$node/app-env/searx.env"
	grep -Fxq 'SEARX_SITE_HOST=searx.localhost' "$tmp/$node/app-env/searx.env"
	grep -Fxq 'LIBRECHAT_SITE=http://chat.localhost' "$tmp/$node/app-env/librechat.env"
	grep -Fxq 'LIBRECHAT_ADMIN_SITE=http://chat-admin.localhost' "$tmp/$node/app-env/librechat.env"
	grep -Fxq 'WABASE_SITE=http://wabase.localhost' "$tmp/$node/app-env/wabase.env"
	grep -Fxq 'WABASE_SITE_HOST=wabase.localhost' "$tmp/$node/app-env/wabase.env"
	grep -Fxq 'MAILER_SITE=http://mail.localhost' "$tmp/$node/app-env/mailer.env"
	grep -Fxq 'MAILER_SITE_HOST=mail.localhost' "$tmp/$node/app-env/mailer.env"
	if [[ "$node" == worker-3 ]]; then
		grep -Fq 'reverse_proxy mailer:8080' "$tmp/$node/config/routes.d/mailer.caddy"
	fi
	if [[ "$node" == worker-4 ]]; then
		grep -Fq 'header_up Host wabase.localhost' "$tmp/$node/config/routes.d/wabase.caddy"
		grep -Fq 'header_up X-Forwarded-Host wabase.localhost' "$tmp/$node/config/routes.d/wabase.caddy"
	fi
done
grep -Fq 'reverse_proxy aichor:6767' "$tmp/worker-2/config/routes.d/aichor.caddy"
grep -Fq 'header_up Host aichor.localhost:443' "$tmp/worker-2/config/routes.d/aichor.caddy"
grep -Fq 'header_up X-Forwarded-Host aichor.localhost' "$tmp/worker-2/config/routes.d/aichor.caddy"
grep -Fq 'reverse_proxy https://worker2-aichor-origin.aichorage.de' "$tmp/leader/config/routes.d/aichor.caddy"
grep -Fq 'header_up X-Forwarded-Host aichor.localhost' "$tmp/leader/config/routes.d/aichor.caddy"
grep -Fq 'reverse_proxy https://worker3-mail-origin.aichorage.de' "$tmp/leader/config/routes.d/mailer.caddy"
grep -Fq 'reverse_proxy searx:8080' "$tmp/worker-2/config/routes.d/searx.caddy"
grep -Fq 'reverse_proxy https://worker2-searx-origin.aichorage.de' "$tmp/leader/config/routes.d/searx.caddy"
grep -Fq 'basic_auth @searx_auth_required' "$tmp/leader/config/routes.d/searx.caddy"
grep -Fq "searx-dev $dev_searx_hash" "$tmp/leader/config/routes.d/searx.caddy"
grep -Fq 'basic_auth @searx_auth_required' "$tmp/worker-2/config/routes.d/searx.caddy"
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
	"$malformed_root/stack.sh" dev render >/dev/null
if [[ -e "$tmp/malformed-runtime/config/routes.d/aichorouter.caddy" ]]; then
	printf 'malformed app policy unexpectedly produced a route\n' >&2
	exit 1
fi
printf 'stack role validation tests passed\n'
