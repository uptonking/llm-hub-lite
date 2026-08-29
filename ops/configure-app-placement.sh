#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="${1:-}"
requested_nodes="${2:-}"
cluster_policy="${CLUSTER_POLICY_FILE:-$root/config/cluster/policy.env}"
usage() { printf 'usage: %s <app-id> [node-id[,node-id...]]\n' "$0" >&2; }
[[ -n "$app_id" && $# -le 2 ]] || {
	usage
	exit 2
}
[[ -r "$cluster_policy" ]] || {
	printf 'missing cluster policy: %s\n' "$cluster_policy" >&2
	exit 1
}
manifest="$root/apps/$app_id/manifest.env"
[[ -r "$manifest" ]] || {
	printf 'missing app manifest: %s\n' "$manifest" >&2
	exit 1
}
value() { sed -n "s/^$1=//p" "$manifest" | tail -n1; }
[[ "$(value PLACEMENT)" == consumer ]] || {
	printf '%s is not a consumer app\n' "$app_id" >&2
	exit 1
}
upstream_mode="$(value UPSTREAM_MODE)"
case "$upstream_mode" in singleton | active-active | active-passive) ;; *)
	printf 'unsupported UPSTREAM_MODE for %s: %s\n' "$app_id" "$upstream_mode" >&2
	exit 1
	;;
esac
policy_rel="$(value POLICY_FILE)"
[[ "$policy_rel" != /* && "$policy_rel" != *..* && "$policy_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || {
	printf 'invalid POLICY_FILE\n' >&2
	exit 1
}
app_policy="$root/config/$policy_rel"
[[ -r "$app_policy" ]] || {
	printf 'missing app policy: %s\n' "$app_policy" >&2
	exit 1
}
leader="$(sed -n 's/^LEADER_NODE_ID=//p' "$cluster_policy" | tail -n1)"
node_ids="$(sed -n 's/^NODE_IDS=//p' "$cluster_policy" | tail -n1)"
followers=''
old_ifs="$IFS"
IFS=,
for id in $node_ids; do
	[[ -n "$id" && "$id" != "$leader" ]] || continue
	node_file="$root/config/cluster/nodes/$id.env"
	[[ -r "$node_file" ]] || {
		printf 'missing node descriptor: %s\n' "$id" >&2
		exit 1
	}
	[[ "$(sed -n 's/^NODE_ID=//p' "$node_file" | tail -n1)" == "$id" ]] || {
		printf 'node descriptor NODE_ID mismatch: %s\n' "$id" >&2
		exit 1
	}
	[[ "$(sed -n 's/^NODE_STATE=//p' "$node_file" | tail -n1)" == active ]] || continue
	followers="${followers:+$followers,}$id"
done
IFS="$old_ifs"
[[ -n "$followers" ]] || {
	printf 'cluster has no active follower nodes\n' >&2
	exit 1
}
if [[ -z "$requested_nodes" ]]; then
	printf 'Available active follower nodes: %s\n' "$followers"
	if ! read -r -p "Nodes for $app_id (comma-separated): " requested_nodes; then
		printf 'node selection was not received\n' >&2
		exit 1
	fi
fi
[[ -n "$requested_nodes" && "$requested_nodes" != *, && "$requested_nodes" != ,* && "$requested_nodes" != *',,'* ]] || {
	printf 'node list must be a non-empty comma-separated list\n' >&2
	exit 1
}
normalized=''
IFS=,
for id in $requested_nodes; do
	[[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] || {
		printf 'invalid node ID: %s\n' "$id" >&2
		exit 1
	}
	case ",$followers," in *,$id,*) ;; *)
		printf 'node is not an active follower: %s\n' "$id" >&2
		exit 1
		;;
	esac
	case ",$normalized," in *,$id,*)
		printf 'duplicate node ID: %s\n' "$id" >&2
		exit 1
		;;
	esac
	normalized="${normalized:+$normalized,}$id"
done
IFS="$old_ifs"
if [[ "$upstream_mode" == singleton && "$normalized" == *,* ]]; then
	printf 'singleton app %s requires exactly one node\n' "$app_id" >&2
	exit 1
fi

tmp="$(mktemp "$app_policy.tmp.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
sed '/^NODES=/d' "$app_policy" >"$tmp"
printf 'NODES=%s\n' "$normalized" >>"$tmp"
if cmp -s "$app_policy" "$tmp"; then
	printf '%s placement is already %s\n' "$app_id" "$normalized"
	exit 0
fi
mv -f -- "$tmp" "$app_policy"
trap - EXIT
printf 'Updated NODES=%s in %s\n' "$normalized" "$policy_rel"
printf 'Run validation, review the diff, commit, and push the policy change.\n'
