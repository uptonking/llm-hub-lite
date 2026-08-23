#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/control/current/config/cluster" "$tmp/config"

cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
LEADER_NODE_ID=leader
EOF
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=worker-1
LEADER_PUBLIC_IP=192.0.2.10
EOF
cat >"$tmp/platform.env" <<EOF
CONTROL_ROOT=$tmp/control
NODE_CONFIG_FILE=$tmp/config/node.env
CLUSTER_POLICY_FILE=$tmp/control/current/config/cluster/policy.env
FIREWALL_RECONCILE_REQUEST_FILE=$tmp/firewall-reconcile.request
EOF
cat >"$tmp/bin/ufw" <<'EOF'
#!/bin/sh
printf 'ufw %s\n' "$*" >>"${FIREWALL_LOG:?}"
[ "$*" = 'status numbered' ] && printf '[ 1] 443/tcp ALLOW IN Anywhere # Leader to follower HTTPS\n'
exit 0
EOF
cat >"$tmp/bin/iptables" <<'EOF'
#!/bin/sh
printf 'iptables %s\n' "$*" >>"${FIREWALL_LOG:?}"
[ "${1:-}" = -C ] && exit 1
exit 0
EOF
chmod +x "$tmp/bin/ufw" "$tmp/bin/iptables"

export PATH="$tmp/bin:$PATH" FIREWALL_LOG="$tmp/firewall.log"
firewall_output="$(LEADER_PUBLIC_IP=198.51.100.20 DEPLOY_CONFIG_FILE="$tmp/platform.env" bash "$repo_root/ops/configure-firewall.sh")"
grep -Fqx 'ufw --force delete 1' "$FIREWALL_LOG"
grep -Fqx 'ufw allow 443/tcp comment HTTPS' "$FIREWALL_LOG"
grep -Fqx 'ufw allow 443/udp comment HTTP/3' "$FIREWALL_LOG"
if grep -Fq 'ufw allow from ' "$FIREWALL_LOG"; then
	printf 'firewall narrowed the persistent UFW HTTPS policy to one source\n' >&2
	exit 1
fi
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -s 192.0.2.10 -p tcp --dport 443 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -s 192.0.2.10 -p udp --dport 443 -j RETURN' "$FIREWALL_LOG"
if grep -Fq '198.51.100.20' "$FIREWALL_LOG"; then
	printf 'firewall accepted a Leader IP override outside runtime node.env\n' >&2
	exit 1
fi
if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$firewall_output"; then
	printf 'firewall logged the private Leader IP\n' >&2
	exit 1
fi

for invalid_ip in missing 999.0.2.10 192.0.2.10. 192.0.2.10.1 192.0.2.x; do
	sed '/^LEADER_PUBLIC_IP=/d' "$tmp/config/node.env" >"$tmp/config/node.invalid"
	if [[ "$invalid_ip" != missing ]]; then printf 'LEADER_PUBLIC_IP=%s\n' "$invalid_ip" >>"$tmp/config/node.invalid"; fi
	sed "s#NODE_CONFIG_FILE=.*#NODE_CONFIG_FILE=$tmp/config/node.invalid#" "$tmp/platform.env" >"$tmp/platform.invalid.env"
	if DEPLOY_CONFIG_FILE="$tmp/platform.invalid.env" bash "$repo_root/ops/configure-firewall.sh" >/dev/null 2>&1; then
		printf 'follower firewall accepted invalid runtime Leader IP: %s\n' "$invalid_ip" >&2
		exit 1
	fi
done

printf 'NODE_ID=leader\n' >"$tmp/config/node.leader"
sed "s#NODE_CONFIG_FILE=.*#NODE_CONFIG_FILE=$tmp/config/node.leader#" "$tmp/platform.env" >"$tmp/platform.leader.env"
DEPLOY_CONFIG_FILE="$tmp/platform.leader.env" bash "$repo_root/ops/configure-firewall.sh" >/dev/null

printf 'firewall tests passed\n'
