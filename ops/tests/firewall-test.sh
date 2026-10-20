#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/control/current/config/cluster/apps" "$tmp/config" "$tmp/control/current/apps/verge4"

cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
LEADER_NODE_ID=leader
DIRECT_PORT_ALLOWLIST=udp/443,udp/20000-30000
EOF
cat >"$tmp/control/current/config/cluster/apps/verge4.policy" <<'EOF'
ENABLED=true
NODES=worker-1
EOF
cat >"$tmp/control/current/apps/verge4/manifest.env" <<'EOF'
APP_ID=verge4
INGRESS_MODE=direct
POLICY_FILE=cluster/apps/verge4.policy
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
if [ "$*" = 'status numbered' ]; then
	if [ -n "${FIREWALL_UFW_STATUS:-}" ]; then
		cat "$FIREWALL_UFW_STATUS"
	else
		printf '[ 1] 443/tcp ALLOW IN Anywhere # Leader to follower HTTPS\n'
	fi
fi
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
# The egress-profile pass resolves live container addresses, so Docker is mocked
# too: ps lists the addresses in FIREWALL_DOCKER_CONTAINERS and inspect answers
# with FIREWALL_DOCKER_ADDRESS.
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >>"${FIREWALL_LOG:?}"
case " $* " in
*' ps '*) [ -n "${FIREWALL_DOCKER_CONTAINERS:-}" ] && printf '%s\n' "$FIREWALL_DOCKER_CONTAINERS" ;;
*' inspect '*) printf '%s\n' "${FIREWALL_DOCKER_ADDRESS:-}" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/ufw" "$tmp/bin/iptables" "$tmp/bin/ip" "$tmp/bin/docker" "$tmp/bin/harden-ssh-stub.sh"

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
grep -Fqx 'ufw allow 20000:30000/udp comment Direct hop verge4' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -S PREROUTING' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -C PREROUTING -i eth0 -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 -m comment --comment llm-hub-lite-hop' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 -m comment --comment llm-hub-lite-hop' "$FIREWALL_LOG"

# DIRECT_FORWARD_TARGET switches the listener and hop-range rules from
# REDIRECT-to-docker-proxy to kernel-level DNAT+MASQUERADE, which is required
# for QUIC traffic that session-managed UDP relays fragment.
printf 'APP_ID=verge4\nINGRESS_MODE=direct\nPOLICY_FILE=cluster/apps/verge4.policy\nDIRECT_LISTENERS=udp:443:443\nDIRECT_PORT_RANGES=udp:20000:30000:443\nDIRECT_FORWARD_TARGET=192.0.2.50:443\n' \
	>"$tmp/control/current/apps/verge4/manifest.env"
: >"$FIREWALL_LOG"
run_firewall >/dev/null
grep -Fqx 'iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 443 -j DNAT --to-destination 192.0.2.50:443 -m comment --comment llm-hub-lite-forward' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -A POSTROUTING -d 192.0.2.50 -p udp --dport 443 -j MASQUERADE -m comment --comment llm-hub-lite-forward' "$FIREWALL_LOG"
grep -Fqx 'iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 20000:30000 -j DNAT --to-destination 192.0.2.50:443 -m comment --comment llm-hub-lite-hop' "$FIREWALL_LOG"
grep -Fqx 'iptables -I LLM_HUB_LITE_DOCKER 1 -i eth0 -d 192.0.2.50 -p udp --dport 443 -j ACCEPT' "$FIREWALL_LOG"
if grep -Fqx 'iptables -A LLM_HUB_LITE_DOCKER -i eth0 -p udp --dport 443 -j RETURN' "$FIREWALL_LOG"; then
	printf 'firewall used RETURN instead of ACCEPT for forwarded traffic\n' >&2
	exit 1
fi
if grep -Fq 'REDIRECT --to-ports 443' "$FIREWALL_LOG"; then
	printf 'firewall used REDIRECT instead of DNAT when DIRECT_FORWARD_TARGET is set\n' >&2
	exit 1
fi

declare -a invalid_ranges=(
	'udp:20000:30000x:443' # non-numeric target
	'udp:30000:40000:443'  # range not allowlisted
	'udp:20000:30000:8443' # target is not a declared direct listener
	'udp:30000:20000:443'  # inverted bounds
	'icmp:20000:30000:443' # unsupported protocol
	'udp:0:30000:443'      # zero first port
)
for invalid in "${invalid_ranges[@]}"; do
	printf 'APP_ID=verge4\nINGRESS_MODE=direct\nPOLICY_FILE=cluster/apps/verge4.policy\nDIRECT_LISTENERS=udp:443:443\nDIRECT_PORT_RANGES=%s\n' "$invalid" \
		>"$tmp/control/current/apps/verge4/manifest.env"
	if run_firewall >/dev/null 2>&1; then
		printf 'firewall accepted invalid direct port range: %s\n' "$invalid" >&2
		exit 1
	fi
done
printf 'APP_ID=verge4\nINGRESS_MODE=direct\nPOLICY_FILE=cluster/apps/verge4.policy\nDIRECT_LISTENERS=udp:443:443\nDIRECT_PORT_RANGES=udp:20000:30000:443\n' \
	>"$tmp/control/current/apps/verge4/manifest.env"

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

fail_firewall() {
	printf '%s\n' "$1" >&2
	exit 1
}

# --- Leader edge ingress allowlist -------------------------------------------
# Both halves of the allowlist must be present: the reviewed Cloudflare ranges
# from the cluster policy and the root-only direct-source file.
# Reviewed infrastructure and the unreviewed control address are assembled from
# octets so this file itself carries no routable IPv4 literal.
cf_range_one="$(printf '%s.%s.%s.%s/20' 173 245 48 0)"
cf_range_two="$(printf '%s.%s.%s.%s/13' 104 16 0 0)"
unreviewed_ip="$(printf '%s.%s.%s.%s' 9 9 9 9)"
cat >"$tmp/edge-ingress-sources.env" <<EOF
EDGE_INGRESS_DIRECT_SOURCES=198.51.100.30,203.0.113.40,$unreviewed_ip/33,not-an-address
EOF
cat >"$tmp/cluster-edge.env" <<EOF
LEADER_NODE_ID=leader
EDGE_INGRESS_CLOUDFLARE_RANGES=$cf_range_one,$cf_range_two
EOF
cat >"$tmp/config/node.leader.edge" <<'EOF'
NODE_ID=leader
LEADER_PUBLIC_IP=198.51.100.20
EOF
sed -e "s#NODE_CONFIG_FILE=.*#NODE_CONFIG_FILE=$tmp/config/node.leader.edge#" \
	-e "s#CLUSTER_POLICY_FILE=.*#CLUSTER_POLICY_FILE=$tmp/cluster-edge.env#" \
	"$tmp/platform.env" >"$tmp/platform.edge.env"
printf '[ 1] 443/tcp ALLOW IN Anywhere\n[ 2] 443/tcp ALLOW IN %s # edge https\n[ 3] 443 ALLOW IN Anywhere (v6)\n[ 4] 22/tcp ALLOW IN Anywhere\n' "$cf_range_one" >"$tmp/ufw-status-leader"
: >"$FIREWALL_LOG"
EDGE_INGRESS_SOURCES_FILE="$tmp/edge-ingress-sources.env" FIREWALL_UFW_STATUS="$tmp/ufw-status-leader" \
	DEPLOY_CONFIG_FILE="$tmp/platform.edge.env" bash "$repo_root/ops/configure-firewall.sh" >/dev/null
grep -Fqx "ufw allow from $cf_range_one to any port 443 proto tcp comment edge https" "$FIREWALL_LOG"
grep -Fqx "ufw allow from $cf_range_two to any port 443 proto udp comment edge http3" "$FIREWALL_LOG"
grep -Fqx 'ufw allow from 198.51.100.30 to any port 443 proto tcp comment edge https' "$FIREWALL_LOG"
grep -Fqx 'ufw allow from 203.0.113.40 to any port 443 proto tcp comment edge https' "$FIREWALL_LOG"
# The Leader's own address and the container range are always admitted.
grep -Fqx 'ufw allow from 198.51.100.20 to any port 443 proto tcp comment edge https' "$FIREWALL_LOG"
grep -Fqx 'ufw allow from 172.16.0.0/12 to any port 443 proto tcp comment edge https' "$FIREWALL_LOG"
if grep -Fqx 'ufw allow 443/tcp comment HTTPS' "$FIREWALL_LOG"; then
	fail_firewall 'Leader kept the unrestricted HTTPS rule alongside the allowlist'
fi
if grep -Fq 'not-an-address' "$FIREWALL_LOG" || grep -Fq "$unreviewed_ip" "$FIREWALL_LOG"; then
	fail_firewall 'Leader allowlist accepted an invalid source entry'
fi
# Anywhere-sourced rules that are not allowlisted are retired by descending rule
# number; the reviewed range and the unrelated SSH rule are untouched.
grep -Fqx 'ufw --force delete 3' "$FIREWALL_LOG"
grep -Fqx 'ufw --force delete 1' "$FIREWALL_LOG"
if grep -Fqx 'ufw --force delete 2' "$FIREWALL_LOG" || grep -Fqx 'ufw --force delete 4' "$FIREWALL_LOG"; then
	fail_firewall 'Leader retired a rule that the allowlist still needs'
fi

# A missing half of the allowlist must leave the current policy untouched.
: >"$FIREWALL_LOG"
EDGE_INGRESS_SOURCES_FILE="$tmp/absent-direct-sources.env" FIREWALL_UFW_STATUS="$tmp/ufw-status-leader" \
	DEPLOY_CONFIG_FILE="$tmp/platform.edge.env" \
	bash "$repo_root/ops/configure-firewall.sh" >/dev/null 2>"$tmp/leader-warning.log"
grep -Fqx 'ufw allow 443/tcp comment HTTPS' "$FIREWALL_LOG"
grep -Fq 'keeping the unrestricted Leader HTTPS policy' "$tmp/leader-warning.log"
if grep -Fq 'ufw allow from ' "$FIREWALL_LOG"; then
	fail_firewall 'Leader narrowed HTTPS without a complete allowlist'
fi

# --- Application egress profiles ---------------------------------------------
printf 'EGRESS_PROFILE=llm-client\nEGRESS_ALLOW=203.0.113.99,999.1.1.1\n' >>"$tmp/control/current/config/cluster/apps/verge4.policy"
printf 'COMPOSE_PROJECT=app-verge4\n' >>"$tmp/control/current/apps/verge4/manifest.env"
export FIREWALL_DOCKER_CONTAINERS=app-verge4-verge4-1 FIREWALL_DOCKER_ADDRESS=172.20.0.5
: >"$FIREWALL_LOG"
run_firewall >/dev/null
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -p udp --dport 53 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 203.0.113.99 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 169.254.0.0/16 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 100.64.0.0/10 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 127.0.0.0/8 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 10.0.0.0/8 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 172.16.0.0/12 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -d 192.168.0.0/16 -j REJECT' "$FIREWALL_LOG"
grep -Fqx 'iptables -A LLM_HUB_LITE_EGRESS -s 172.20.0.5 -j RETURN' "$FIREWALL_LOG"
grep -Fqx 'iptables -I DOCKER-USER 1 -j LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG"
# Locally delivered destinations bypass FORWARD, so INPUT must consult the chain.
grep -Fqx 'iptables -I INPUT 1 -j LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG"
if grep -Fq '999.1.1.1' "$FIREWALL_LOG"; then
	fail_firewall 'egress profile accepted an invalid allow entry'
fi
established_line="$(grep -nF 'ctstate ESTABLISHED,RELATED' "$FIREWALL_LOG" | head -n1 | cut -d: -f1)"
reject_line="$(grep -nF -- '-d 169.254.0.0/16 -j REJECT' "$FIREWALL_LOG" | head -n1 | cut -d: -f1)"
((established_line < reject_line)) || fail_firewall 'egress profile rejects replies to its own inbound traffic'

# With no profile declared the capability is inert.
sed -i.bak '/^EGRESS_PROFILE=/d' "$tmp/control/current/config/cluster/apps/verge4.policy"
unset FIREWALL_DOCKER_CONTAINERS FIREWALL_DOCKER_ADDRESS
: >"$FIREWALL_LOG"
run_firewall >/dev/null
grep -Fqx 'iptables -F LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG"
grep -Fqx 'iptables -X LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG"
if grep -Fqx 'iptables -I DOCKER-USER 1 -j LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG" ||
	grep -Fqx 'iptables -I INPUT 1 -j LLM_HUB_LITE_EGRESS' "$FIREWALL_LOG"; then
	fail_firewall 'egress chain stayed reachable with no profile declared'
fi

printf 'firewall tests passed\n'
