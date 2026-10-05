#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/control/current/config/cluster/apps" "$tmp/config" "$tmp/control/current/apps/verge"

cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
LEADER_NODE_ID=leader
DIRECT_PORT_ALLOWLIST=udp/443,udp/20000-30000
EOF
cat >"$tmp/control/current/config/cluster/apps/verge.policy" <<'EOF'
ENABLED=true
NODES=worker-1
EOF
cat >"$tmp/control/current/apps/verge/manifest.env" <<'EOF'
APP_ID=verge
INGRESS_MODE=direct
POLICY_FILE=cluster/apps/verge.policy
DIRECT_LISTENERS=udp:443:443
DIRECT_PORT_RANGES=udp:20000:30000:443
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
# -C reports every rule as absent so the script always takes the install path.
cat >"$tmp/bin/iptables" <<'EOF'
#!/bin/sh
printf 'iptables %s\n' "$*" >>"${FIREWALL_LOG:?}"
case " $* " in *' -C '*) exit 1 ;; esac
exit 0
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >>"${FIREWALL_LOG:?}"
if [ "$*" = '-4 route show default' ]; then
	printf 'default via 192.0.2.1 dev eth0\n'
	exit 0
fi
[ "${1:-}" = link ] && exit 0
exit 1
EOF
cat >"$tmp/bin/harden-ssh-stub.sh" <<'EOF'
#!/bin/sh
# Stand-in for ops/harden-ssh.sh: this test must not touch the real sshd.
printf 'harden-ssh quiet=%s\n' "${PLATFORM_SSH_HARDENING_QUIET:-unset}" >>"${HARDEN_LOG:?}"
exit 0
EOF
chmod +x "$tmp/bin/ufw" "$tmp/bin/iptables" "$tmp/bin/ip" "$tmp/bin/harden-ssh-stub.sh"

run_firewall() {
	LEADER_PUBLIC_IP=198.51.100.20 DEPLOY_CONFIG_FILE="$tmp/platform.env" \
		FIREWALL_LOG="$tmp/firewall.log" PATH="$tmp/bin:$PATH" \
		bash "$repo_root/ops/configure-firewall.sh"
}

export PATH="$tmp/bin:$PATH" FIREWALL_LOG="$tmp/firewall.log"
# Every reconciliation must also refresh the SSH authentication policy. The
# Leader returns early from the firewall body, so this stub also guards against
# that early return skipping the role-independent hardening step.
export HARDEN_SSH_SCRIPT="$tmp/bin/harden-ssh-stub.sh" HARDEN_LOG="$tmp/harden.log"
: >"$FIREWALL_LOG"
: >"$HARDEN_LOG"
firewall_output="$(run_firewall)"
grep -Fqx 'harden-ssh quiet=1' "$HARDEN_LOG"
grep -Fqx 'ufw --force delete 1' "$FIREWALL_LOG"
grep -Fqx 'ufw allow 443/tcp comment HTTPS' "$FIREWALL_LOG"
grep -Fqx 'ufw allow 443/udp comment HTTP/3' "$FIREWALL_LOG"
if grep -Fq 'ufw allow from ' "$FIREWALL_LOG"; then
	printf 'firewall narrowed the persistent UFW HTTPS policy to one source\n' >&2
	exit 1
fi
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -i eth0 -s 192.0.2.10 -p tcp --dport 443 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -i eth0 -s 192.0.2.10 -p udp --dport 443 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -i eth0 -p tcp -j DROP' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -i eth0 -p udp -j DROP' "$FIREWALL_LOG"
if grep -Eq '^iptables -A LLM_HUB_LITE_DOCKER -p (tcp|udp) --dport 443' "$FIREWALL_LOG"; then
	printf 'firewall contains an unscoped port 443 rule that can block container egress\n' >&2
	exit 1
fi
if grep -Fq '198.51.100.20' "$FIREWALL_LOG"; then
	printf 'firewall accepted a Leader IP override outside runtime node.env\n' >&2
	exit 1
fi
if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$firewall_output"; then
	printf 'firewall logged the private Leader IP\n' >&2
	exit 1
fi
grep -Fqx 'ufw allow 20000:30000/udp comment Direct hop verge' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -S PREROUTING' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -C PREROUTING -i eth0 -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 -m comment --comment llm-hub-lite-hop' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 -m comment --comment llm-hub-lite-hop' "$FIREWALL_LOG"

declare -a invalid_ranges=(
	'udp:20000:30000x:443' # non-numeric target
	'udp:30000:40000:443'  # range not allowlisted
	'udp:20000:30000:8443' # target is not a declared direct listener
	'udp:30000:20000:443'  # inverted bounds
	'icmp:20000:30000:443' # unsupported protocol
	'udp:0:30000:443'      # zero first port
)
for invalid in "${invalid_ranges[@]}"; do
	printf 'APP_ID=verge\nINGRESS_MODE=direct\nPOLICY_FILE=cluster/apps/verge.policy\nDIRECT_LISTENERS=udp:443:443\nDIRECT_PORT_RANGES=%s\n' "$invalid" \
		>"$tmp/control/current/apps/verge/manifest.env"
	if run_firewall >/dev/null 2>&1; then
		printf 'firewall accepted invalid direct port range: %s\n' "$invalid" >&2
		exit 1
	fi
done
printf 'APP_ID=verge\nINGRESS_MODE=direct\nPOLICY_FILE=cluster/apps/verge.policy\nDIRECT_LISTENERS=udp:443:443\nDIRECT_PORT_RANGES=udp:20000:30000:443\n' \
	>"$tmp/control/current/apps/verge/manifest.env"

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
: >"$FIREWALL_LOG"
: >"$HARDEN_LOG"
DEPLOY_CONFIG_FILE="$tmp/platform.leader.env" bash "$repo_root/ops/configure-firewall.sh" >/dev/null
if grep -Fq 'llm-hub-lite-hop' "$FIREWALL_LOG"; then
	printf 'leader firewall must not install port-hop REDIRECT rules\n' >&2
	exit 1
fi
# The Leader returns early from the firewall body, so it is the case most
# likely to silently lose the SSH hardening step.
grep -Fqx 'harden-ssh quiet=1' "$HARDEN_LOG"

printf 'firewall tests passed\n'
