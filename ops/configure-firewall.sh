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
# Root-only runtime allowlist of clients that may reach the Leader's HTTPS port
# directly. Node addresses are not committed because this repository is public
# and ops/check-ip-privacy.sh rejects routable literals outside the reviewed
# Cloudflare table in config/Caddyfile.
EDGE_SOURCES_FILE="${EDGE_INGRESS_SOURCES_FILE:-/etc/llm-hub-lite/edge-ingress-sources.env}"
# Container-originated traffic reaches the Leader through Docker's masquerade and
# needs no publicly routable entry of its own; RFC1918 is unreachable from the
# public internet.
EDGE_CONTAINER_SOURCES='172.16.0.0/12'
EGRESS_CHAIN=LLM_HUB_LITE_EGRESS
value() { sed -n "s/^$1=//p" "$2" | tail -n1; }
csv_has() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
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
valid_cidr() {
	local cidr="$1" address prefix
	[[ "$cidr" == */* ]] || return 1
	address="${cidr%%/*}"
	prefix="${cidr##*/}"
	[[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
	if valid_ipv4 "$address"; then
		((10#$prefix <= 32))
	elif [[ "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:]+$ ]]; then
		((10#$prefix <= 128))
	else
		return 1
	fi
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

if ! command -v iptables >/dev/null 2>&1 || ! command -v ufw >/dev/null 2>&1; then
	if [[ -f /.dockerenv || ! -d /run/systemd/system ]] && [[ -d "$(dirname "$REQUEST_FILE")" ]]; then
		touch "$REQUEST_FILE" 2>/dev/null || true
		printf 'configure-firewall: host utilities missing in container; queued firewall reconciliation request\n'
		exit 0
	fi
	command -v iptables >/dev/null 2>&1 || {
		printf 'configure-firewall: iptables is required\n' >&2
		exit 1
	}
	command -v ufw >/dev/null 2>&1 || {
		printf 'configure-firewall: ufw is required\n' >&2
		exit 1
	}
fi
clear_follower_ufw_rules() {
	local number
	while IFS= read -r number; do
		[[ "$number" =~ ^[0-9]+$ ]] || continue
		ufw --force delete "$number" >/dev/null || true
	done < <(ufw status numbered 2>/dev/null | sed -n '/Leader to follower/{s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p;}' | sort -rn)
}
# Direct port-hop REDIRECT rules live in nat PREROUTING. They are rebuilt on
# every reconciliation so ranges removed from manifests do not linger, and the
# idempotent re-add below keeps them present after a VPS reboot.
clear_port_hop_rules() {
	local rule
	local -a rule_args
	while IFS= read -r rule; do
		[[ "$rule" == -* ]] || continue
		read -r -a rule_args <<<"${rule/-A/-D}"
		iptables -t nat "${rule_args[@]}" >/dev/null 2>&1 || true
	done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -- '-m comment --comment llm-hub-lite-hop' || true)
}
# Direct forward (DNAT) rules relay traffic to a remote target at the kernel
# level, bypassing the container's docker-proxy entirely. They are rebuilt on
# every reconciliation so targets removed from manifests do not linger.
clear_forward_rules() {
	local rule
	local -a rule_args
	for table_chain in 'PREROUTING' 'POSTROUTING'; do
		while IFS= read -r rule; do
			[[ "$rule" == -* ]] || continue
			read -r -a rule_args <<<"${rule/-A/-D}"
			iptables -t nat "${rule_args[@]}" >/dev/null 2>&1 || true
		done < <(iptables -t nat -S "$table_chain" 2>/dev/null | grep -- '-m comment --comment llm-hub-lite-forward' || true)
	done
}
chain=LLM_HUB_LITE_DOCKER
# Node security baseline beyond the packet filter: refuse SSH password logins.
# This script is the only root, timer-driven reconciliation hook that both new
# and existing nodes already run from the current control release, so the SSH
# policy rolls out with the firewall policy instead of requiring a one-off SSH
# procedure on every VPS. harden-ssh.sh is idempotent and refuses to disable
# passwords while no public key is installed, so it cannot lock an operator out.
reconcile_ssh_hardening() {
	local harden_ssh="${HARDEN_SSH_SCRIPT:-$(dirname -- "${BASH_SOURCE[0]}")/harden-ssh.sh}"
	[[ -x "$harden_ssh" ]] || return 0
	PLATFORM_SSH_HARDENING_QUIET=1 "$harden_ssh"
}
reconcile_app_fail2ban() {
	command -v fail2ban-client >/dev/null 2>&1 || return 0
	[[ -d /etc/fail2ban/filter.d && -d /etc/fail2ban/jail.d ]] || return 0
	local manifest app_dir app_id app_policy app_enabled app_nodes is_active filter_file target_filter jail_file target_jail monitored_log
	local reloaded=0
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app_dir="$(dirname "$manifest")"
		app_id="$(basename "$app_dir")"
		[[ -d "$app_dir/fail2ban" ]] || continue
		app_policy="$CONTROL_ROOT/current/config/cluster/apps/$app_id.policy"
		app_enabled="$(value ENABLED "$app_policy")"
		app_nodes="$(value NODES "$app_policy")"
		is_active=0
		[[ "$app_enabled" == true ]] && csv_has "$app_nodes" "$node_id" && is_active=1

		for filter_file in "$app_dir/fail2ban"/*.filter.conf; do
			[[ -f "$filter_file" ]] || continue
			target_filter="/etc/fail2ban/filter.d/$(basename "${filter_file%.filter.conf}.local")"
			if [[ "$is_active" -eq 1 ]]; then
				if ! cmp -s "$filter_file" "$target_filter" 2>/dev/null; then
					install -m 0644 "$filter_file" "$target_filter"
					reloaded=1
				fi
			fi
		done

		for jail_file in "$app_dir/fail2ban"/*.jail.conf; do
			[[ -f "$jail_file" ]] || continue
			target_jail="/etc/fail2ban/jail.d/$(basename "${jail_file%.jail.conf}.local")"
			if [[ "$is_active" -eq 1 ]]; then
				monitored_log="$(sed -n 's/^[[:space:]]*logpath[[:space:]]*=[[:space:]]*//p' "$jail_file" | head -n1)"
				if [[ -n "$monitored_log" && ! -f "$monitored_log" ]]; then
					mkdir -p "$(dirname "$monitored_log")" 2>/dev/null || true
					touch "$monitored_log" 2>/dev/null || true
				fi
				if ! cmp -s "$jail_file" "$target_jail" 2>/dev/null; then
					install -m 0644 "$jail_file" "$target_jail"
					reloaded=1
				fi
			elif [[ -f "$target_jail" ]]; then
				rm -f -- "$target_jail"
				reloaded=1
			fi
		done
	done < <(find "$CONTROL_ROOT/current/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null)

	if [[ "$reloaded" -eq 1 ]]; then
		fail2ban-client reload >/dev/null 2>&1 || true
	fi
}
reconcile_network_tuning() {
	command -v sysctl >/dev/null 2>&1 || return 0
	[[ -d /etc/sysctl.d && -w /etc/sysctl.d ]] || return 0
	local target_conf="/etc/sysctl.d/99-llm-hub-lite-network.conf"
	local tmp_conf
	modprobe tcp_bbr >/dev/null 2>&1 || true
	tmp_conf="$(mktemp "${target_conf}.tmp.XXXXXX")"
	cat >"$tmp_conf" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535
EOF
	if ! cmp -s "$tmp_conf" "$target_conf" 2>/dev/null; then
		mv -f -- "$tmp_conf" "$target_conf"
		chmod 644 "$target_conf" 2>/dev/null || true
		sysctl -p "$target_conf" >/dev/null 2>&1 || true
	else
		rm -f -- "$tmp_conf"
	fi
}
# Leader HTTPS ingress allowlist. Cloudflare's reviewed ranges are committed in
# config/cluster/policy.env; the direct clients (cluster nodes and the operator)
# are root-only runtime state in $EDGE_SOURCES_FILE. Both halves must be present
# before the broad rules are retired, so an incomplete policy can never take the
# platform's only public entry point offline.
LEADER_EDGE_SOURCES=''
LEADER_EDGE_MISSING=''
collect_leader_edge_sources() {
	local ranges sources source collected=''
	ranges="$(value EDGE_INGRESS_CLOUDFLARE_RANGES "$CLUSTER_POLICY_FILE")"
	if [[ -r "$EDGE_SOURCES_FILE" ]]; then
		sources="$(value EDGE_INGRESS_DIRECT_SOURCES "$EDGE_SOURCES_FILE")"
	else
		sources=''
	fi
	LEADER_EDGE_MISSING=''
	if [[ -z "$ranges" ]]; then
		LEADER_EDGE_MISSING="EDGE_INGRESS_CLOUDFLARE_RANGES is absent from $CLUSTER_POLICY_FILE"
		return 0
	fi
	if [[ -z "$sources" ]]; then
		LEADER_EDGE_MISSING="the direct-source allowlist is absent from $EDGE_SOURCES_FILE"
		return 0
	fi
	for source in $(printf '%s %s' "$ranges" "$sources" | tr ',' ' ') $EDGE_CONTAINER_SOURCES; do
		[[ -n "$source" ]] || continue
		if ! valid_cidr "$source" && ! valid_ipv4 "$source"; then
			printf 'configure-firewall: ignoring an invalid Leader edge source entry\n' >&2
			continue
		fi
		collected="${collected}${source}"$'\n'
	done
	if valid_ipv4 "$LEADER_PUBLIC_IP"; then
		collected="${collected}${LEADER_PUBLIC_IP}"$'\n'
	fi
	LEADER_EDGE_SOURCES="$(printf '%s' "$collected" | sed '/^[[:space:]]*$/d' | sort -u)"
}
# Number and source of every persistent UFW rule that opens HTTPS, including the
# legacy unscoped 443, 443/tcp and 443/udp rules this policy replaces.
leader_edge_rule_lines() {
	ufw status numbered 2>/dev/null | sed -nE 's/^\[[[:space:]]*([0-9]+)\][[:space:]]*443(\/(tcp|udp))?( \(v6\))?[[:space:]]+ALLOW IN[[:space:]]+([^[:space:]]+).*/\1 \5/p' || true
}
restore_unrestricted_leader_https() {
	ufw allow 443/tcp comment 'HTTPS' >/dev/null
	ufw allow 443/udp comment 'HTTP/3' >/dev/null
}
reconcile_leader_edge_ingress() {
	local source number rule_source
	collect_leader_edge_sources
	if [[ -n "$LEADER_EDGE_MISSING" ]]; then
		printf 'configure-firewall: %s; keeping the unrestricted Leader HTTPS policy\n' "$LEADER_EDGE_MISSING" >&2
		restore_unrestricted_leader_https
		return 0
	fi
	if [[ -z "$LEADER_EDGE_SOURCES" ]]; then
		printf 'configure-firewall: no valid Leader edge sources; keeping the unrestricted Leader HTTPS policy\n' >&2
		restore_unrestricted_leader_https
		return 0
	fi
	# Install the allowlist before retiring anything so the public listener is
	# never left without an accepted source.
	while IFS= read -r source; do
		[[ -n "$source" ]] || continue
		ufw allow from "$source" to any port 443 proto tcp comment 'edge https' >/dev/null
		ufw allow from "$source" to any port 443 proto udp comment 'edge http3' >/dev/null
	done <<<"$LEADER_EDGE_SOURCES"
	while IFS=' ' read -r number rule_source; do
		[[ -n "$number" && -n "$rule_source" ]] || continue
		grep -Fxq "$rule_source" <<<"$LEADER_EDGE_SOURCES" && continue
		ufw --force delete "$number" >/dev/null || true
	done < <(leader_edge_rule_lines | sort -k1,1rn)
	printf 'Leader HTTPS ingress restricted to %s reviewed source entries\n' "$(printf '%s\n' "$LEADER_EDGE_SOURCES" | grep -c . || true)"
}
# Application egress profiles. An application that handles untrusted content or
# user-supplied endpoints declares EGRESS_PROFILE in its cluster policy. The
# profile denies that container's traffic to loopback, link-local, carrier-grade
# NAT and private destinations, so a request to a URL chosen through the
# application cannot reach cloud metadata, host services or sibling containers.
# Public destinations stay reachable, so user-selected upstreams keep working.
EGRESS_DENY_V4='169.254.0.0/16 100.64.0.0/10 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
clear_egress_rules() {
	local rule
	local -a rule_args
	while IFS= read -r rule; do
		[[ "$rule" == -* ]] || continue
		read -r -a rule_args <<<"${rule/-A/-D}"
		iptables "${rule_args[@]}" >/dev/null 2>&1 || true
	done < <(iptables -S "$EGRESS_CHAIN" 2>/dev/null || true)
}
reconcile_app_egress_profiles() {
	local manifest app_dir app_id app_policy profile allow project container address entry applied=0
	# DOCKER-USER is evaluated in FORWARD, before Docker's masquerade, so the
	# source address here is still the container's own.
	iptables -n -L DOCKER-USER >/dev/null 2>&1 || {
		printf 'configure-firewall: DOCKER-USER chain is unavailable; skipping application egress profiles\n' >&2
		return 0
	}
	iptables -N "$EGRESS_CHAIN" 2>/dev/null || true
	clear_egress_rules
	if ! command -v docker >/dev/null 2>&1; then
		printf 'configure-firewall: docker is unavailable; skipping application egress profiles\n' >&2
		return 0
	fi
	while IFS= read -r manifest; do
		[[ -f "$manifest" ]] || continue
		app_dir="$(dirname "$manifest")"
		app_id="$(basename "$app_dir")"
		app_policy="$CONTROL_ROOT/current/config/cluster/apps/$app_id.policy"
		[[ -r "$app_policy" ]] || continue
		[[ "$(value ENABLED "$app_policy")" == true ]] || continue
		csv_has "$(value NODES "$app_policy")" "$node_id" || continue
		profile="$(value EGRESS_PROFILE "$app_policy")"
		[[ -n "$profile" ]] || continue
		allow="$(value EGRESS_ALLOW "$app_policy")"
		project="$(value COMPOSE_PROJECT "$manifest")"
		[[ -n "$project" ]] || continue
		while IFS= read -r container; do
			[[ -n "$container" ]] || continue
			address="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container" 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1 || true)"
			[[ -n "$address" ]] || continue
			iptables -A "$EGRESS_CHAIN" -s "$address" -p udp --dport 53 -j RETURN
			iptables -A "$EGRESS_CHAIN" -s "$address" -p tcp --dport 53 -j RETURN
			iptables -A "$EGRESS_CHAIN" -s "$address" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
			for entry in $(printf '%s' "$allow" | tr ',' ' '); do
				[[ -n "$entry" ]] || continue
				if valid_cidr "$entry" || valid_ipv4 "$entry"; then
					iptables -A "$EGRESS_CHAIN" -s "$address" -d "$entry" -j RETURN
				else
					printf 'configure-firewall: ignoring an invalid egress allow entry for %s\n' "$app_id" >&2
				fi
			done
			for entry in $EGRESS_DENY_V4; do
				iptables -A "$EGRESS_CHAIN" -s "$address" -d "$entry" -j REJECT
			done
			iptables -A "$EGRESS_CHAIN" -s "$address" -j RETURN
			applied=$((applied + 1))
		done < <(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Names}}' 2>/dev/null | sed -n '1,4p' || true)
	done < <(find "$CONTROL_ROOT/current/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print 2>/dev/null || true)
	while iptables -C DOCKER-USER -j "$EGRESS_CHAIN" 2>/dev/null; do iptables -D DOCKER-USER -j "$EGRESS_CHAIN"; done
	if [[ "$applied" -eq 0 ]]; then
		iptables -F "$EGRESS_CHAIN" 2>/dev/null || true
		iptables -X "$EGRESS_CHAIN" 2>/dev/null || true
		return 0
	fi
	iptables -I DOCKER-USER 1 -j "$EGRESS_CHAIN"
	printf 'application egress profiles applied to %s container address(es)\n' "$applied"
}
# The role split below returns early for the Leader, so role-independent
# security policies have to be reconciled before it rather than at the end of the file.
reconcile_ssh_hardening
reconcile_app_fail2ban
reconcile_network_tuning
reconcile_app_egress_profiles
clear_follower_ufw_rules
if [[ "$NODE_ROLE" == leader ]]; then
	while iptables -C DOCKER-USER -j "$chain" 2>/dev/null; do iptables -D DOCKER-USER -j "$chain"; done
	iptables -F "$chain" 2>/dev/null || true
	iptables -X "$chain" 2>/dev/null || true
	clear_port_hop_rules
	clear_forward_rules
	reconcile_leader_edge_ingress
	rm -f -- "$REQUEST_FILE"
	exit 0
fi
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
valid_ipv4 "$LEADER_PUBLIC_IP" || {
	printf 'configure-firewall: valid runtime LEADER_PUBLIC_IP is required for followers\n' >&2
	exit 1
}
command -v ip >/dev/null 2>&1 || {
	printf 'configure-firewall: ip is required on followers\n' >&2
	exit 1
}
PUBLIC_INTERFACE="$(public_interface)"
if command -v tc >/dev/null 2>&1; then
	tc qdisc replace dev "$PUBLIC_INTERFACE" root fq >/dev/null 2>&1 || true
fi
if command -v ip >/dev/null 2>&1; then
	ip link set dev "$PUBLIC_INTERFACE" txqueuelen 10000 >/dev/null 2>&1 || true
fi
if command -v ethtool >/dev/null 2>&1; then
	ethtool -K "$PUBLIC_INTERFACE" tx-udp-segmentation off >/dev/null 2>&1 || true
fi
clear_port_hop_rules
clear_forward_rules

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
	forward_target="$(value DIRECT_FORWARD_TARGET "$manifest")"
	forward_ip='' forward_port=''
	if [[ -n "$forward_target" ]]; then
		forward_host="${forward_target%%:*}"
		forward_port="${forward_target##*:}"
		# iptables-nft does not resolve hostnames; resolve to an IP now so
		# rules survive DNS changes on re-deploy. Literal IPs skip resolution.
		if valid_ipv4 "$forward_host"; then
			forward_ip="$forward_host"
		else
			forward_ip="$(getent hosts "$forward_host" | awk '{print $1}' | head -1)"
			[[ -n "$forward_ip" ]] || {
				printf 'configure-firewall: cannot resolve DIRECT_FORWARD_TARGET host: %s (%s)\n' "$forward_host" "$app" >&2
				exit 1
			}
		fi
	fi
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
		if [[ -n "$forward_target" ]]; then
			iptables -C "$chain" -i "$PUBLIC_INTERFACE" -d "$forward_ip" -p "$proto" --dport "$forward_port" -j ACCEPT 2>/dev/null ||
				iptables -I "$chain" 1 -i "$PUBLIC_INTERFACE" -d "$forward_ip" -p "$proto" --dport "$forward_port" -j ACCEPT
		else
			iptables -A "$chain" -i "$PUBLIC_INTERFACE" -p "$proto" --dport "$port" -j RETURN
		fi
		ufw allow "$port/$proto" comment "Direct $app" >/dev/null
		# Kernel-level DNAT to a remote target bypasses docker-proxy and the
		# container entirely, which is required for QUIC traffic that session-
		# managed UDP relays (e.g. gost udp://) fragment. The container stays
		# up as a health-check placeholder; traffic never enters it.
		if [[ -n "$forward_target" ]]; then
			command -v sysctl >/dev/null 2>&1 && sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
			iptables -t nat -C PREROUTING -i "$PUBLIC_INTERFACE" -p "$proto" --dport "$port" -j DNAT --to-destination "$forward_ip:$forward_port" -m comment --comment llm-hub-lite-forward 2>/dev/null ||
				iptables -t nat -I PREROUTING 1 -i "$PUBLIC_INTERFACE" -p "$proto" --dport "$port" -j DNAT --to-destination "$forward_ip:$forward_port" -m comment --comment llm-hub-lite-forward
			iptables -t nat -C POSTROUTING -d "$forward_ip" -p "$proto" --dport "$forward_port" -j MASQUERADE -m comment --comment llm-hub-lite-forward 2>/dev/null ||
				iptables -t nat -A POSTROUTING -d "$forward_ip" -p "$proto" --dport "$forward_port" -j MASQUERADE -m comment --comment llm-hub-lite-forward
		fi
	done <<<"$(value DIRECT_LISTENERS "$manifest" | tr ',' '\n')"
	# Port hopping for QUIC-based direct apps: a UDP port range is DNAT'd with
	# REDIRECT onto the app's published listener port, so clients can hop ports
	# to evade per-flow UDP QoS on congested routes.
	while IFS= read -r range; do
		[[ -n "$range" ]] || continue
		IFS=':' read -r proto from to target <<<"$range"
		[[ "$proto" == udp || "$proto" == tcp ]] || {
			printf 'configure-firewall: malformed direct port range protocol: %s (%s)\n' "$range" "$app" >&2
			exit 1
		}
		[[ "$from" =~ ^[1-9][0-9]*$ && "$to" =~ ^[1-9][0-9]*$ && "$target" =~ ^[1-9][0-9]*$ ]] || {
			printf 'configure-firewall: malformed direct port range: %s (%s)\n' "$range" "$app" >&2
			exit 1
		}
		((10#$from <= 10#$to && 10#$to <= 65535 && 10#$target <= 65535)) || {
			printf 'configure-firewall: invalid direct port range bounds: %s (%s)\n' "$range" "$app" >&2
			exit 1
		}
		[[ ",$direct_allowlist," == *",$proto/$from-$to,"* ]] || {
			printf 'configure-firewall: direct port range is not allowlisted: %s/%s-%s (%s)\n' "$proto" "$from" "$to" "$app" >&2
			exit 1
		}
		range_target_ok=0
		while IFS= read -r listener; do
			[[ -n "$listener" ]] || continue
			[[ "${listener%%:*}" == "$proto" && "${listener#*:}" == "$target":* ]] && range_target_ok=1
		done <<<"$(value DIRECT_LISTENERS "$manifest" | tr ',' '\n')"
		[[ "$range_target_ok" == 1 ]] || {
			printf 'configure-firewall: direct port range target is not a direct listener: %s (%s)\n' "$range" "$app" >&2
			exit 1
		}
		ufw allow "$from:$to/$proto" comment "Direct hop $app" >/dev/null
		if [[ -n "$forward_target" ]]; then
			hop_args=(-i "$PUBLIC_INTERFACE" -p "$proto" --dport "$from:$to" -j DNAT --to-destination "$forward_ip:$forward_port" -m comment --comment llm-hub-lite-hop)
		else
			hop_args=(-i "$PUBLIC_INTERFACE" -p "$proto" --dport "$from:$to" -j REDIRECT --to-ports "$target" -m comment --comment llm-hub-lite-hop)
		fi
		iptables -t nat -C PREROUTING "${hop_args[@]}" 2>/dev/null || iptables -t nat -I PREROUTING 1 "${hop_args[@]}"
	done <<<"$(value DIRECT_PORT_RANGES "$manifest" | tr ',' '\n')"
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
