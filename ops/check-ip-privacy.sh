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
		if [[ "$before_last" != [0-9] && "$after_first" != [0-9] ]] && is_public_ipv4 "$ip"; then
			printf '%s:%s: globally routable IPv4 literal is not allowed in Git\n' "$path" "$line" >&2
			violations=$((violations + 1))
		fi
		content="$after"
	done
done <<<"$matches"

((violations == 0)) || exit 1
printf 'IP privacy check passed (%s)\n' "$mode"
