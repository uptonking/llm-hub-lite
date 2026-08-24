#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="${1:-}"
policy="${CLUSTER_POLICY_FILE:-$root/config/cluster/policy.env}"
[[ -n "$app_id" ]] || {
	printf 'usage: %s <app-id>\n' "$0" >&2
	exit 2
}
[[ -r "$policy" ]] || {
	printf 'missing policy: %s\n' "$policy" >&2
	exit 1
}
manifest="$root/apps/$app_id/manifest.env"
[[ -r "$manifest" ]] || {
	printf 'missing app manifest: %s\n' "$manifest" >&2
	exit 1
}
placement="$(sed -n 's/^PLACEMENT=//p' "$manifest" | tail -n1)"
[[ "$placement" == single-follower ]] || {
	printf '%s is not a single-follower app\n' "$app_id" >&2
	exit 1
}
target_key="$(sed -n 's/^TARGET_NODE_KEY=//p' "$manifest" | tail -n1)"
policy_rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"
[[ "$target_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
	printf 'invalid TARGET_NODE_KEY\n' >&2
	exit 1
}
[[ "$policy_rel" != /* && "$policy_rel" != *..* && "$policy_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || {
	printf 'invalid POLICY_FILE\n' >&2
	exit 1
}
policy_file="$root/config/$policy_rel"
[[ -r "$policy_file" ]] || {
	printf 'missing app policy: %s\n' "$policy_file" >&2
	exit 1
}
leader="$(sed -n 's/^LEADER_NODE_ID=//p' "$policy" | tail -n1)"
ids="$(sed -n 's/^NODE_IDS=//p' "$policy" | tr ',' ' ')"
printf 'Available follower nodes:\n'
for id in $ids; do [[ "$id" != "$leader" ]] && printf '  %s\n' "$id"; done
read -r -p "Target node for $app_id: " target
[[ -n "$target" && "$target" != "$leader" ]] || {
	printf 'target must be a follower\n' >&2
	exit 1
}
case " $ids " in *" $target "*) ;; *)
	printf 'target is not in NODE_IDS\n' >&2
	exit 1
	;;
esac
tmp="$(mktemp "$policy.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if grep -q "^${target_key}=" "$policy_file"; then
	sed "s/^${target_key}=.*/${target_key}=${target}/" "$policy_file" >"$tmp"
else
	cp "$policy_file" "$tmp"
	printf '%s=%s\n' "$target_key" "$target" >>"$tmp"
fi
cmp -s "$policy_file" "$tmp" && {
	printf 'target is already %s\n' "$target"
	exit 0
}
mv -f "$tmp" "$policy_file"
trap - EXIT
printf 'Updated %s=%s in %s\n' "$target_key" "$target" "$policy_rel"
printf 'Run validation, review the diff, commit, and push the policy change.\n'
