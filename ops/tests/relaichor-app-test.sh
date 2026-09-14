#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/relaichor"

grep -q '^APP_ID=relaichor$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=ephemeral$' "$app/manifest.env"
grep -q '^RUNTIME_ENV_FILE=$' "$app/manifest.env"
grep -q '^HEALTH_URL=/ready$' "$app/manifest.env"
grep -q '^HEALTH_MODE=process$' "$app/manifest.env"
grep -q '^HEALTH_SERVICE=health-probe$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/relaichor.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/relaichor.policy"

grep -q '^RELAICHOR_MEMORY_LIMIT=512m$' "$app/config.env"
grep -q '^RELAICHOR_CPUS=0.35$' "$app/config.env"
grep -q '^RELAICHOR_ACCEPTORS=2$' "$app/config.env"
grep -q '^RELAICHOR_CONNECTIONS_PER_ACCEPTOR=128$' "$app/config.env"
grep -q '^RELAICHOR_INGRESS_BUDGET_BYTES=134217728$' "$app/config.env"
grep -q '^RELAICHOR_MEMORY_WATERMARK_BYTES=400000000$' "$app/config.env"
grep -q '^RELAICHOR_CLUSTER_QUERY=ignore$' "$app/config.env"

grep -Fq 'read_only: true' "$app/compose.yml"
grep -Fq 'cap_drop: [ALL]' "$app/compose.yml"
grep -Fq "security_opt: ['no-new-privileges:true']" "$app/compose.yml"
grep -Fq 'LANG: C.UTF-8' "$app/compose.yml"
grep -Fq 'LC_ALL: C.UTF-8' "$app/compose.yml"
grep -Fq 'ELIXIR_ERL_OPTIONS: +fnu' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'PASEO_RELAY_CLUSTER_QUERY: ${RELAICHOR_CLUSTER_QUERY:-ignore}' "$app/compose.yml"
grep -Fq 'curl -fsS http://relaichor:4000/ready' "$app/compose.yml"
if grep -Eq '^[[:space:]]+ports:' "$app/compose.yml"; then
	printf 'Relaichor must not publish a host port\n' >&2
	exit 1
fi
if grep -Eq '^[[:space:]]+volumes:' "$app/compose.yml"; then
	printf 'Relaichor must remain stateless without persistent mounts\n' >&2
	exit 1
fi

grep -Fq '@relaichor_public path /ws /health /ready' "$app/route.leader.caddy"
grep -Fq 'health_uri /ready' "$app/route.leader.caddy"
grep -Fq 'tls_insecure_skip_verify' "$app/route.leader.caddy"
grep -Fq 'flush_interval -1' "$app/route.leader.caddy"
grep -Fq 'import forward_verified_client_ip' "$app/route.leader.caddy"
if grep -Fq '/metrics' "$app/route.leader.caddy"; then
	printf 'Relaichor metrics must not be exposed publicly\n' >&2
	exit 1
fi
grep -Fq '@relaichor_origin path /ws /health /ready /metrics' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'reverse_proxy relaichor:4000' "$app/route.follower.caddy"
grep -Fq 'import forward_verified_client_ip' "$app/route.follower.caddy"

for node in leader worker-1 worker-2 worker-3 worker-4; do
	prefix="${node/-/}"
	grep -q "^NODE_RELAICHOR_ORIGIN_HOST=${prefix}-relaichor-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

for workflow in \
	consumer-stage-relaichor-worker-2.yml \
	consumer-publish-relaichor.yml \
	consumer-finalize-relaichor-worker-2.yml \
	consumer-stop-relaichor-worker-1.yml \
	consumer-stop-relaichor-worker-3.yml \
	consumer-stop-relaichor-worker-4.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done
if find "$repo_root/.woodpecker" -maxdepth 1 -name 'consumer-stage-relaichor-worker-*.yml' ! -name '*worker-2.yml' | grep -q .; then
	printf 'Relaichor generated a stage workflow outside its singleton target\n' >&2
	exit 1
fi

# Prove empty app hooks do not pass empty PASEO relay overrides, while explicit
# per-app values are translated independently for Aichor and Aichor3.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/workspace"
cat >"$tmp/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/base-entrypoint" <<'EOF'
#!/bin/sh
for key in ENABLED ENDPOINT PUBLIC_ENDPOINT USE_TLS PUBLIC_USE_TLS; do
  eval "value=\${PASEO_RELAY_${key}-unset}"
  printf '%s=%s\n' "$key" "$value"
done >"$RELAICHOR_HOOK_LOG"
EOF
chmod 700 "$tmp/bin/chown" "$tmp/bin/base-entrypoint"

run_paseo_host() {
	local app="$1"
	PATH="$tmp/bin:$PATH" PASEO_HOME="$tmp/home/.paseo" PASEO_WORKSPACE="$tmp/workspace" \
		PASEO_COMMON_ENTRYPOINT="$repo_root/apps/paseo/entrypoint-common.sh" \
		PASEO_BASE_ENTRYPOINT="$tmp/bin/base-entrypoint" RELAICHOR_HOOK_LOG="$tmp/hook.log" \
		"$repo_root/apps/$app/entrypoint.sh" smoke
}

PASEO_RELAY_ENDPOINT=stale PASEO_RELAY_ENABLED=true run_paseo_host aichor
grep -Fxq 'ENABLED=unset' "$tmp/hook.log"
grep -Fxq 'ENDPOINT=unset' "$tmp/hook.log"

AICHOR_RELAY_ENABLED=true AICHOR_RELAY_ENDPOINT=relaichor.aichorage.de:443 \
	AICHOR_RELAY_PUBLIC_ENDPOINT=relaichor.aichorage.de:443 \
	AICHOR_RELAY_USE_TLS=true AICHOR_RELAY_PUBLIC_USE_TLS=true run_paseo_host aichor
grep -Fxq 'ENABLED=true' "$tmp/hook.log"
grep -Fxq 'ENDPOINT=relaichor.aichorage.de:443' "$tmp/hook.log"
grep -Fxq 'PUBLIC_ENDPOINT=relaichor.aichorage.de:443' "$tmp/hook.log"
grep -Fxq 'USE_TLS=true' "$tmp/hook.log"
grep -Fxq 'PUBLIC_USE_TLS=true' "$tmp/hook.log"

AICHOR3_RELAY_ENABLED=false AICHOR3_RELAY_ENDPOINT=relay.internal:443 \
	AICHOR3_RELAY_USE_TLS=true run_paseo_host aichor3
grep -Fxq 'ENABLED=false' "$tmp/hook.log"
grep -Fxq 'ENDPOINT=relay.internal:443' "$tmp/hook.log"
grep -Fxq 'PUBLIC_ENDPOINT=unset' "$tmp/hook.log"

printf 'Relaichor application and Paseo hook tests passed\n'
