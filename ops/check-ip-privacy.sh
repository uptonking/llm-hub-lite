#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-working-tree}"
pattern='([0-9]{1,3}\.){3}[0-9]{1,3}'

case "$mode" in
working-tree) grep_args=(-n -I -E "$pattern" --) ;;
--cached) grep_args=(--cached -n -I -E "$pattern" --) ;;
*)
	printf 'usage: check-ip-privacy.sh [--cached]\n' >&2
	exit 2
	;;
esac

is_public_ipv4() {
	local ip="$1" octet a b
	local -a octets
	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS=. read -r -a octets <<<"$ip"
	[[ "${#octets[@]}" -eq 4 ]] || return 1
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
	done
	a=$((10#${octets[0]}))
	b=$((10#${octets[1]}))
	((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
	((a == 100 && b >= 64 && b <= 127)) && return 1
	((a == 169 && b == 254)) && return 1
	((a == 172 && b >= 16 && b <= 31)) && return 1
	((a == 192 && b == 168)) && return 1
	((a == 192 && b == 0 && 10#${octets[2]} == 2)) && return 1
	((a == 198 && (b == 18 || b == 19))) && return 1
	((a == 198 && b == 51 && 10#${octets[2]} == 100)) && return 1
	((a == 203 && b == 0 && 10#${octets[2]} == 113)) && return 1
	return 0
}

is_reviewed_public_infrastructure_cidr() {
	local path="$1" ip="$2" after="$3" network prefix suffix
	# Cloudflare publishes these CIDRs as shared proxy infrastructure; they
	# identify no private node or customer endpoint. Keep the exception exact so
	# unrelated addresses, bare network bases, and malformed prefixes still fail.
	# The same reviewed table backs Caddy's trusted_proxies and the Leader's
	# packet-filter allowlist, so both files qualify.
	case "$path" in
	config/Caddyfile | config/cluster/policy.env) ;;
	*) return 1 ;;
	esac
	while IFS=' ' read -r network prefix; do
		[[ "$ip" == "$network" && "$after" == "/$prefix"* ]] || continue
		suffix="${after#"/$prefix"}"
		[[ "${suffix:0:1}" != [0-9] ]] && return 0
	done <<EOF
$(printf '%s.%s.%s.%s %s\n' 173 245 48 0 20 103 21 244 0 22 103 22 200 0 22 103 31 4 0 22 141 101 64 0 18 108 162 192 0 18 190 93 240 0 20 188 114 96 0 20 197 234 240 0 22 198 41 128 0 17 162 158 0 0 15 104 16 0 0 13 104 24 0 0 14 172 64 0 0 13 131 0 72 0 22)
EOF
	return 1
}

set +e
matches="$(git -C "$repo_root" grep "${grep_args[@]}")"
grep_status=$?
set -e
((grep_status == 0 || grep_status == 1)) || exit "$grep_status"

violations=0
while IFS= read -r record; do
	[[ -n "$record" ]] || continue
	path="${record%%:*}"
	record="${record#*:}"
	line="${record%%:*}"
	content="${record#*:}"
	while [[ "$content" =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; do
		ip="${BASH_REMATCH[0]}"
		before="${content%%"$ip"*}"
		after="${content#*"$ip"}"
		before_last="${before: -1}"
		after_first="${after:0:1}"
		if [[ "$before_last" != [0-9] && "$after_first" != [0-9] && ! ("$after_first" == "." && "${after:1:1}" == [0-9]) && ! ("$before_last" == "." && "${before: -2:1}" == [0-9]) && "$ip" != 8.8.8.8 && "$ip" != 1.1.1.1 ]] && is_public_ipv4 "$ip" && ! is_reviewed_public_infrastructure_cidr "$path" "$ip" "$after"; then
			printf '%s:%s: globally routable IPv4 literal is not allowed in Git\n' "$path" "$line" >&2
			violations=$((violations + 1))
		fi
		content="$after"
	done
done <<<"$matches"

reviewed_cloudflare_networks() {
	sed -n 's/^EDGE_INGRESS_CLOUDFLARE_RANGES=//p' "$repo_root/config/cluster/policy.env" 2>/dev/null |
		tr ',' '\n' | sed -n '/^\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\(\/[0-9]\{1,2\}\)\{0,1\}$/p' | sort -u || true
}
caddy_trusted_networks() {
	grep -E '^[[:space:]]*trusted_proxies static ' "$repo_root/config/Caddyfile" 2>/dev/null |
		tr ' ' '\n' | sed -n '/^\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\(\/[0-9]\{1,2\}\)\{0,1\}$/p' | sort -u || true
}
# The packet-filter allowlist and Caddy's trusted_proxies describe the same
# reviewed infrastructure. If they drift, one would trust a source the other
# rejects, so the IPv4 halves are compared as a unit whenever both are present.
if [[ -f "$repo_root/config/Caddyfile" && -f "$repo_root/config/cluster/policy.env" ]]; then
	policy_networks="$(reviewed_cloudflare_networks || true)"
	caddy_networks="$(caddy_trusted_networks || true)"
	if [[ -n "$policy_networks" && "$policy_networks" != "$caddy_networks" ]]; then
		printf 'config/cluster/policy.env and config/Caddyfile disagree on the reviewed Cloudflare networks\n' >&2
		violations=$((violations + 1))
	fi
fi

((violations == 0)) || exit 1
printf 'IP privacy check passed (%s)\n' "$mode"
