#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

config_file="${DEPLOY_CONFIG_FILE:-/etc/llm-hub-lite/platform.env}"
[[ -r "$config_file" ]] || {
	printf 'configure-firewall: missing %s\n' "$config_file" >&2
	exit 1
}
# shellcheck disable=SC1090
source "$config_file"
: "${CONTROL_ROOT:=/opt/platform/control}"
: "${NODE_CONFIG_FILE:=/etc/llm-hub-lite/node.env}"
: "${CLUSTER_POLICY_FILE:=$CONTROL_ROOT/current/config/cluster/policy.env}"
REQUEST_FILE="${FIREWALL_RECONCILE_REQUEST_FILE:-/etc/llm-hub-lite/firewall-reconcile.request}"
value() { sed -n "s/^$1=//p" "$2" | tail -n1; }
valid_ipv4() {
	local ip="$1" octet
	local -a octets
	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS=. read -r -a octets <<<"$ip"
	[[ "${#octets[@]}" -eq 4 ]] || return 1
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
	done
}
public_interface() {
	local interface="${PLATFORM_PUBLIC_INTERFACE:-}"
	if [[ -z "$interface" ]]; then
		interface="$(ip -4 route show default | awk '{for (field = 1; field <= NF; field++) if ($field == "dev") {print $(field + 1); exit}}')"
	fi
	[[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
		printf 'configure-firewall: unable to determine a valid public network interface\n' >&2
		return 1
	}
	ip link show dev "$interface" >/dev/null 2>&1 || {
		printf 'configure-firewall: public network interface does not exist: %s\n' "$interface" >&2
		return 1
	}
	printf '%s\n' "$interface"
}
node_id="${NODE_ID:-$(value NODE_ID "$NODE_CONFIG_FILE")}"
leader_id="$(value LEADER_NODE_ID "$CLUSTER_POLICY_FILE")"
[[ -n "$node_id" && -n "$leader_id" ]] || {
	printf 'configure-firewall: node identity or cluster policy is incomplete\n' >&2
	exit 1
}
[[ "$node_id" == "$leader_id" ]] && NODE_ROLE=leader || NODE_ROLE=follower
LEADER_PUBLIC_IP="$(value LEADER_PUBLIC_IP "$NODE_CONFIG_FILE")"

command -v iptables >/dev/null 2>&1 || {
	printf 'configure-firewall: iptables is required\n' >&2
	exit 1
}
command -v ufw >/dev/null 2>&1 || {
	printf 'configure-firewall: ufw is required\n' >&2
	exit 1
}
clear_follower_ufw_rules() {
	local number
	while IFS= read -r number; do
		[[ "$number" =~ ^[0-9]+$ ]] || continue
		ufw --force delete "$number" >/dev/null || true
	done < <(ufw status numbered 2>/dev/null | sed -n '/Leader to follower/{s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p;}' | sort -rn)
}
chain=LLM_HUB_LITE_DOCKER
clear_follower_ufw_rules
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
if [[ "$NODE_ROLE" == leader ]]; then
	while iptables -C DOCKER-USER -j "$chain" 2>/dev/null; do iptables -D DOCKER-USER -j "$chain"; done
	iptables -F "$chain" 2>/dev/null || true
	iptables -X "$chain" 2>/dev/null || true
	rm -f -- "$REQUEST_FILE"
	exit 0
fi
valid_ipv4 "$LEADER_PUBLIC_IP" || {
	printf 'configure-firewall: valid runtime LEADER_PUBLIC_IP is required for followers\n' >&2
	exit 1
}
command -v ip >/dev/null 2>&1 || {
	printf 'configure-firewall: ip is required on followers\n' >&2
	exit 1
}
PUBLIC_INTERFACE="$(public_interface)"

# Docker evaluates DOCKER-USER for both ingress and container egress. Scope the
# policy to the public ingress interface so outbound HTTPS remains available.
iptables -N "$chain" 2>/dev/null || true
iptables -F "$chain"
iptables -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A "$chain" -i "$PUBLIC_INTERFACE" -s "$LEADER_PUBLIC_IP" -p tcp --dport 443 -j RETURN
iptables -A "$chain" -i "$PUBLIC_INTERFACE" -s "$LEADER_PUBLIC_IP" -p udp --dport 443 -j RETURN
# Direct/orphan applications declare their public listeners in manifests. The
# cluster policy allowlist is reviewed in Git and prevents an application from
# opening an arbitrary Docker-published port on a follower.
direct_allowlist="$(value DIRECT_PORT_ALLOWLIST "$CLUSTER_POLICY_FILE")"
while IFS= read -r manifest; do
	[[ -f "$manifest" ]] || continue
	[[ "$(value INGRESS_MODE "$manifest")" == direct ]] || continue
	app="$(value APP_ID "$manifest")"
	policy_rel="$(value POLICY_FILE "$manifest")"
	[[ "$(value ENABLED "$CONTROL_ROOT/current/config/$policy_rel")" == true ]] || continue
	nodes="$(value NODES "$CONTROL_ROOT/current/config/$policy_rel")"
	[[ ",$nodes," == *",$node_id,"* ]] || continue
	while IFS= read -r listener; do
		[[ -n "$listener" ]] || continue
		proto="${listener%%:*}"
		ports="${listener#*:}"
		port="${ports%%:*}"
		container_port="${ports#*:}"
		[[ "$proto" == tcp || "$proto" == udp ]] || {
			printf 'configure-firewall: malformed direct listener protocol: %s (%s)\n' "$listener" "$app" >&2
			exit 1
		}
		[[ "$port" =~ ^[1-9][0-9]*$ && "$port" -le 65535 && "$container_port" =~ ^[1-9][0-9]*$ && "$container_port" -le 65535 ]] || {
			printf 'configure-firewall: malformed direct listener: %s (%s)\n' "$listener" "$app" >&2
			exit 1
		}
		[[ ",$direct_allowlist," == *",$proto/$port,"* ]] || {
			printf 'configure-firewall: direct listener is not allowlisted: %s/%s (%s)\n' "$proto" "$port" "$app" >&2
			exit 1
		}
		iptables -A "$chain" -i "$PUBLIC_INTERFACE" -p "$proto" --dport "$port" -j RETURN
		ufw allow "$port/$proto" comment "Direct $app" >/dev/null
	done <<<"$(value DIRECT_LISTENERS "$manifest" | tr ',' '\n')"
done < <(find "$CONTROL_ROOT/current/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)
# Default-deny Docker-published ingress on the public interface. Exceptions
# above cover the Leader proxy and explicitly allowlisted direct listeners;
# container egress is unaffected because these rules are interface-scoped.
iptables -A "$chain" -i "$PUBLIC_INTERFACE" -p tcp -j DROP
iptables -A "$chain" -i "$PUBLIC_INTERFACE" -p udp -j DROP
while iptables -C DOCKER-USER -j "$chain" 2>/dev/null; do iptables -D DOCKER-USER -j "$chain"; done
iptables -I DOCKER-USER 1 -j "$chain"

printf 'Docker published-port policy applied on public interface %s for the configured Leader address\n' "$PUBLIC_INTERFACE"
rm -f -- "$REQUEST_FILE"
