#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_policy="${CLUSTER_POLICY_FILE:-$root/config/cluster/policy.env}"
generator="${WORKFLOW_GENERATOR:-$root/ops/generate-woodpecker-workflows.sh}"
app_id="${1:-}"
requested_nodes=''
nodes_explicit=0
requested_enabled=''
policy_backup=''
policy_tmp=''
mutation_started=0

usage() {
	cat >&2 <<EOF
usage: $0 <app-id> [node-id[,node-id...]] [--enable|--disable]

Without a node list, placement is prompted interactively unless --enable or
--disable is supplied, in which case the existing placement is retained.
Disabled apps may be reserved on joining or active followers; enabled apps may
target active followers only.
EOF
}
env_value() {
	local key="$1" file="$2" line value=''
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$key="* ]] || continue
		value="${line#*=}"
	done <"$file"
	printf '%s\n' "$value"
}
csv_has() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
finish() {
	local status="$1"
	trap - ERR HUP INT TERM
	if ((mutation_started)) && [[ -n "$policy_backup" && -f "$policy_backup" ]]; then
		cp "$policy_backup" "$app_policy"
	fi
	[[ -z "$policy_backup" ]] || rm -f -- "$policy_backup"
	[[ -z "$policy_tmp" ]] || rm -f -- "$policy_tmp"
	exit "$status"
}
die() {
	printf 'configure-app-placement: %s\n' "$*" >&2
	finish 1
}
on_error() {
	local status=$?
	finish "$status"
}
interrupted() { finish 130; }
trap on_error ERR
trap interrupted HUP INT TERM

[[ -n "$app_id" ]] || {
	usage
	exit 2
}
shift
while (($#)); do
	case "$1" in
	--enable)
		[[ -z "$requested_enabled" || "$requested_enabled" == true ]] || die '--enable and --disable are mutually exclusive'
		requested_enabled=true
		;;
	--disable)
		[[ -z "$requested_enabled" || "$requested_enabled" == false ]] || die '--enable and --disable are mutually exclusive'
		requested_enabled=false
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "unknown option: $1" ;;
	*)
		((nodes_explicit == 0)) || die 'only one node list may be supplied'
		requested_nodes="$1"
		nodes_explicit=1
		;;
	esac
	shift
done

[[ "$app_id" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid application ID: $app_id"
[[ -r "$cluster_policy" ]] || die "missing cluster policy: $cluster_policy"
[[ -r "$generator" ]] || die "missing workflow generator: $generator"
[[ "$(env_value CLUSTER_CONFIG_VERSION "$cluster_policy")" == 3 ]] || die 'unsupported cluster policy version'

manifest="$root/apps/$app_id/manifest.env"
[[ -r "$manifest" ]] || die "missing app manifest: $manifest"
[[ "$(env_value APP_ID "$manifest")" == "$app_id" ]] || die "manifest APP_ID mismatch: $app_id"
[[ "$(env_value PLACEMENT "$manifest")" == consumer ]] || die "$app_id is not a consumer app"
upstream_mode="$(env_value UPSTREAM_MODE "$manifest")"
case "$upstream_mode" in singleton | active-active | active-passive) ;; *) die "unsupported UPSTREAM_MODE for $app_id: $upstream_mode" ;; esac

policy_rel="$(env_value POLICY_FILE "$manifest")"
[[ "$policy_rel" == "cluster/apps/$app_id.policy" ]] || die "invalid POLICY_FILE: $policy_rel"
app_policy="$root/config/$policy_rel"
[[ -r "$app_policy" ]] || die "missing app policy: $app_policy"
[[ "$(grep -c '^ENABLED=' "$app_policy")" -eq 1 ]] || die 'app policy must contain exactly one ENABLED assignment'
[[ "$(grep -c '^NODES=' "$app_policy")" -eq 1 ]] || die 'app policy must contain exactly one NODES assignment'
current_enabled="$(env_value ENABLED "$app_policy")"
case "$current_enabled" in true | false) ;; *) die "app policy ENABLED must be true or false: $app_id" ;; esac
requested_enabled="${requested_enabled:-$current_enabled}"

leader="$(env_value LEADER_NODE_ID "$cluster_policy")"
node_ids="$(env_value NODE_IDS "$cluster_policy")"
[[ "$leader" =~ ^[a-z][a-z0-9-]*$ ]] || die 'invalid LEADER_NODE_ID'
[[ -n "$node_ids" ]] || die 'NODE_IDS is empty'

if ((nodes_explicit == 0)); then
	if [[ "$requested_enabled" != "$current_enabled" ]]; then
		requested_nodes="$(env_value NODES "$app_policy")"
	else
		available=''
		while IFS= read -r id; do
			[[ -n "$id" && "$id" != "$leader" ]] || continue
			node_file="$root/config/cluster/nodes/$id.env"
			[[ -r "$node_file" ]] || die "missing node descriptor: $id"
			state="$(env_value NODE_STATE "$node_file")"
			if [[ "$requested_enabled" == true ]]; then
				[[ "$state" == active ]] || continue
			else
				case "$state" in joining | active) ;; *) continue ;; esac
			fi
			available="${available:+$available,}$id"
		done < <(printf '%s\n' "$node_ids" | tr ',' '\n')
		[[ -n "$available" ]] || die 'cluster has no eligible follower nodes'
		printf 'Available follower nodes: %s\n' "$available"
		[[ -t 0 ]] || die 'a node list is required in non-interactive mode'
		read -r -p "Nodes for $app_id (comma-separated): " requested_nodes || die 'node selection was not received'
	fi
fi

[[ -n "$requested_nodes" && "$requested_nodes" != *, && "$requested_nodes" != ,* && "$requested_nodes" != *',,'* ]] || die 'node list must be a non-empty comma-separated list'
normalized=''
while IFS= read -r id; do
	[[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid node ID: $id"
	csv_has "$node_ids" "$id" || die "node is absent from NODE_IDS: $id"
	[[ "$id" != "$leader" ]] || die "consumer node must be a follower: $id"
	node_file="$root/config/cluster/nodes/$id.env"
	[[ -r "$node_file" ]] || die "missing node descriptor: $id"
	[[ "$(env_value NODE_ID "$node_file")" == "$id" ]] || die "node descriptor NODE_ID mismatch: $id"
	state="$(env_value NODE_STATE "$node_file")"
	if [[ "$requested_enabled" == true ]]; then
		[[ "$state" == active ]] || die "enabled app target is not an active follower: $id/$state"
	else
		case "$state" in joining | active) ;; *) die "disabled app reservation requires a joining or active follower: $id/$state" ;; esac
	fi
	! csv_has "$normalized" "$id" || die "duplicate node ID: $id"
	normalized="${normalized:+$normalized,}$id"
done < <(printf '%s\n' "$requested_nodes" | tr ',' '\n')

if [[ "$upstream_mode" == singleton && "$normalized" == *,* ]]; then
	die "singleton app $app_id requires exactly one node"
fi

policy_backup="$(mktemp "$app_policy.backup.XXXXXX")"
policy_tmp="$(mktemp "$app_policy.tmp.XXXXXX")"
cp "$app_policy" "$policy_backup"
sed -e "s/^ENABLED=.*/ENABLED=$requested_enabled/" -e "s/^NODES=.*/NODES=$normalized/" "$app_policy" >"$policy_tmp"
mutation_started=1
mv -f -- "$policy_tmp" "$app_policy"
policy_tmp=''

if ! bash "$generator" generate; then
	printf 'configure-app-placement: workflow generation failed; restoring the previous app policy\n' >&2
	finish 1
fi

mutation_started=0
trap - ERR HUP INT TERM
rm -f -- "$policy_backup"
policy_backup=''
printf 'Configured %s: ENABLED=%s NODES=%s\n' "$app_id" "$requested_enabled" "$normalized"
printf 'Regenerated application image locks and Woodpecker workflows.\n'
printf 'Run validation, review the diff, commit, and push the app policy/workflow change.\n'
