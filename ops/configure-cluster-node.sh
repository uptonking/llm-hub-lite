#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${CLUSTER_POLICY_FILE:-$root/config/cluster/policy.env}"
generator="$root/ops/generate-woodpecker-workflows.sh"
generated_output="${WOODPECKER_WORKFLOW_ROOT:-$root/.woodpecker}"
action="${1:-${CLUSTER_NODE_ACTION:-}}"
node_id="${2:-${NODE_ID:-}}"
requested_state="${3:-${NODE_STATE:-}}"
domain_name="${DOMAIN_NAME:-}"
origin_prefix="${NODE_ORIGIN_PREFIX:-}"
assume_yes="${CLUSTER_NODE_ASSUME_YES:-0}"
policy_backup=''
node_backup=''
descriptor_tmp=''
policy_tmp=''
node_file=''
generated_backup=''
mutation_started=0

usage() {
	cat >&2 <<EOF
usage:
  DOMAIN_NAME=example.com $0 add <node-id>
  $0 state <node-id> <active|draining|retired>

Missing values are prompted for on a terminal. New nodes are always added as
Followers in joining state. LEADER_NODE_ID remains the only role selector.
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
prompt_value() {
	local variable="$1" prompt="$2" value
	[[ -z "${!variable:-}" ]] || return 0
	[[ -t 0 ]] || die "$variable is required in non-interactive mode"
	read -r -p "$prompt: " value || die "$variable input was not received"
	printf -v "$variable" '%s' "$value"
}
valid_dns_name() {
	local name="$1" label old_ifs
	local -a labels
	[[ -n "$name" && "${#name}" -le 253 && "$name" == *.* ]] || return 1
	[[ ! "$name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	old_ifs="$IFS"
	IFS=.
	read -r -a labels <<<"$name"
	IFS="$old_ifs"
	((${#labels[@]} >= 2)) || return 1
	for label in "${labels[@]}"; do
		[[ -n "$label" && "${#label}" -le 63 ]] || return 1
		[[ "$label" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ || "$label" =~ ^[a-z0-9]$ ]] || return 1
	done
}
public_label_for() {
	local manifest="$1" wanted="$2" entries entry key label old_ifs
	entries="$(env_value PUBLIC_ENDPOINTS "$manifest")"
	old_ifs="$IFS"
	IFS=';'
	for entry in $entries; do
		key="${entry%%|*}"
		label="${entry#*|}"
		if [[ "$key" == "$wanted" && "$label" != "$entry" && "$label" != *'|'* ]]; then
			printf '%s\n' "$label"
			IFS="$old_ifs"
			return 0
		fi
	done
	IFS="$old_ifs"
	return 1
}
descriptor_has_value() {
	local file="$1" wanted="$2" line value
	[[ -r "$file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		*=*)
			value="${line#*=}"
			[[ "$value" == "$wanted" ]] && return 0
			;;
		esac
	done <"$file"
	return 1
}
render_app_node_fields() {
	local manifest groups group public_key remainder origin_key upstream_key extra label host defaults default_entry key value old_ifs seen_origins='' seen_keys='' seen_hosts='' existing_node_file
	for manifest in "$root"/apps/*/manifest.env; do
		[[ -f "$manifest" ]] || continue
		groups="$(env_value ROUTE_GROUPS "$manifest")"
		old_ifs="$IFS"
		IFS=';'
		for group in $groups; do
			public_key="${group%%|*}"
			remainder="${group#*|}"
			origin_key="${remainder%%|*}"
			remainder="${remainder#*|}"
			upstream_key="${remainder%%|*}"
			extra="${remainder#*|}"
			[[ -n "$public_key" && -n "$origin_key" && -n "$upstream_key" && "$extra" == "$remainder" ]] || die "invalid ROUTE_GROUPS entry: $manifest/$group"
			[[ "$origin_key" =~ ^NODE_[A-Z][A-Z0-9_]*_ORIGIN_HOST$ ]] || die "invalid node origin key: $manifest/$origin_key"
			! csv_has "$seen_origins" "$origin_key" || die "duplicate node origin key: $origin_key"
			label="$(public_label_for "$manifest" "$public_key")" || die "ROUTE_GROUPS key is absent from PUBLIC_ENDPOINTS: $manifest/$public_key"
			[[ "$label" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ || "$label" =~ ^[a-z0-9]$ ]] || die "invalid public endpoint label: $manifest/$label"
			host="$origin_prefix-$label-origin.$domain_name"
			valid_dns_name "$host" || die "generated origin hostname is invalid or too long: $host"
			! csv_has "$seen_hosts" "$host" || die "duplicate generated origin hostname: $host"
			for existing_node_file in "$root"/config/cluster/nodes/*.env; do
				[[ -f "$existing_node_file" && "$existing_node_file" != "$node_file" ]] || continue
				! descriptor_has_value "$existing_node_file" "$host" ||
					die "generated origin hostname is already used by $(basename "$existing_node_file" .env): $host"
			done
			printf '%s=%s\n' "$origin_key" "$host"
			seen_origins="${seen_origins:+$seen_origins,}$origin_key"
			seen_keys="${seen_keys:+$seen_keys,}$origin_key"
			seen_hosts="${seen_hosts:+$seen_hosts,}$host"
		done
		IFS="$old_ifs"

		defaults="$(env_value NODE_DEFAULTS "$manifest")"
		IFS=';'
		for default_entry in $defaults; do
			key="${default_entry%%|*}"
			value="${default_entry#*|}"
			[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$value" != "$default_entry" && -n "$value" && "$value" != *'|'* ]] || die "invalid NODE_DEFAULTS entry: $manifest/$default_entry"
			case "$key" in NODE_ID | NODE_STATE | WOODPECKER_AGENT_LABELS | BESZEL_SYSTEM_NAME) die "NODE_DEFAULTS uses a reserved key: $key" ;; esac
			! csv_has "$seen_keys" "$key" || die "duplicate generated node key: $key"
			[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "NODE_DEFAULTS value must be single-line: $key"
			printf '%s=%s\n' "$key" "$value"
			seen_keys="${seen_keys:+$seen_keys,}$key"
		done
		IFS="$old_ifs"
	done
}
confirm_change() {
	local prompt="$1" answer
	case "$assume_yes" in 0 | 1) ;; *) die 'CLUSTER_NODE_ASSUME_YES must be 0 or 1' ;; esac
	if [[ "$assume_yes" != 1 && -t 0 ]]; then
		read -r -p "$prompt [y/N]: " answer || die 'confirmation was not received'
		[[ "$answer" =~ ^[Yy]$ ]] || die 'change cancelled'
	fi
}
regenerate() {
	if ! bash "$generator" generate; then
		printf 'configure-cluster-node: workflow generation failed; restoring the previous inventory\n' >&2
		return 1
	fi
}
snapshot_generated() {
	local file app lock
	generated_backup="$(mktemp -d "$root/.cluster-node-generated.XXXXXX")"
	install -d -m 700 "$generated_backup/workflows" "$generated_backup/locks"
	for file in "$generated_output"/*.yml; do
		[[ -f "$file" ]] || continue
		# The generator owns only files with its marker. Preserve hand-authored
		# workflows in place and restore generated files byte-for-byte on error.
		head -n1 "$file" | grep -Fq 'generated by ops/generate-woodpecker-workflows.sh' || continue
		cp -p "$file" "$generated_backup/workflows/$(basename "$file")"
	done
	for lock in "$root"/apps/*/images.lock.env; do
		[[ -f "$lock" ]] || continue
		head -n1 "$lock" | grep -Fq 'generated by ops/generate-woodpecker-workflows.sh' || continue
		app="$(basename "$(dirname "$lock")")"
		install -d -m 700 "$generated_backup/locks/$app"
		cp -p "$lock" "$generated_backup/locks/$app/images.lock.env"
	done
}
restore_generated() {
	local file app lock
	[[ -n "$generated_backup" && -d "$generated_backup" ]] || return 0
	for file in "$generated_output"/*.yml; do
		[[ -f "$file" ]] || continue
		head -n1 "$file" | grep -Fq 'generated by ops/generate-woodpecker-workflows.sh' || continue
		rm -f -- "$file"
	done
	for file in "$generated_backup/workflows"/*.yml; do
		[[ -f "$file" ]] || continue
		install -d -m 700 "$generated_output"
		cp -p "$file" "$generated_output/$(basename "$file")"
	done
	for lock in "$root"/apps/*/images.lock.env; do
		[[ -f "$lock" ]] || continue
		head -n1 "$lock" | grep -Fq 'generated by ops/generate-woodpecker-workflows.sh' || continue
		rm -f -- "$lock"
	done
	for app in "$generated_backup/locks"/*; do
		[[ -d "$app" && -f "$app/images.lock.env" ]] || continue
		install -d -m 700 "$root/apps/$(basename "$app")"
		cp -p "$app/images.lock.env" "$root/apps/$(basename "$app")/images.lock.env"
	done
}
finish() {
	local status="$1"
	trap - ERR HUP INT TERM
	if ((mutation_started)); then
		[[ -z "$policy_backup" ]] || cp "$policy_backup" "$policy"
		if [[ -n "$node_backup" ]]; then
			cp "$node_backup" "$node_file"
		else
			rm -f -- "$node_file"
		fi
		restore_generated
	fi
	[[ -z "$policy_backup" ]] || rm -f -- "$policy_backup"
	[[ -z "$node_backup" ]] || rm -f -- "$node_backup"
	[[ -z "$descriptor_tmp" ]] || rm -f -- "$descriptor_tmp"
	[[ -z "$policy_tmp" ]] || rm -f -- "$policy_tmp"
	[[ -z "$generated_backup" ]] || rm -rf -- "$generated_backup"
	exit "$status"
}
die() {
	printf 'configure-cluster-node: %s\n' "$*" >&2
	finish 1
}
on_error() {
	local status=$?
	finish "$status"
}
interrupted() { finish 130; }
trap on_error ERR
trap interrupted HUP INT TERM

[[ -r "$policy" ]] || die "missing cluster policy: $policy"
[[ -x "$generator" || -r "$generator" ]] || die "missing workflow generator: $generator"
[[ "$(env_value CLUSTER_CONFIG_VERSION "$policy")" == 3 ]] || die 'unsupported cluster policy version'
leader_id="$(env_value LEADER_NODE_ID "$policy")"
node_ids="$(env_value NODE_IDS "$policy")"
repo_slug="$(env_value REPO_SLUG "$policy")"
[[ "$leader_id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'invalid LEADER_NODE_ID'
[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'REPO_SLUG must be owner/repository'

if [[ -z "$action" ]]; then
	prompt_value action 'Cluster node action (add or state)'
fi
case "$action" in add | state) ;; -h | --help)
	usage
	exit 0
	;;
*)
	usage
	die "unsupported action: $action"
	;;
esac
prompt_value node_id 'Stable follower node ID'
[[ "$node_id" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid node ID: $node_id"
[[ "$node_id" != "$leader_id" ]] || die 'the Leader is managed only by LEADER_NODE_ID and must remain active'

node_file="$root/config/cluster/nodes/$node_id.env"

case "$action" in
add)
	! csv_has "$node_ids" "$node_id" || die "node already exists in NODE_IDS: $node_id"
	[[ ! -e "$node_file" ]] || die "node descriptor already exists: $node_file"
	[[ -z "$requested_state" || "$requested_state" == joining ]] || die 'new followers must enter the cluster in joining state'
	prompt_value domain_name 'Base DNS domain'
	valid_dns_name "$domain_name" || die "DOMAIN_NAME must be a lowercase DNS name: $domain_name"
	if [[ -z "$origin_prefix" ]]; then origin_prefix="${node_id//-/}"; fi
	[[ "$origin_prefix" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ || "$origin_prefix" =~ ^[a-z0-9]$ ]] || die "invalid NODE_ORIGIN_PREFIX: $origin_prefix"
	confirm_change "Add follower $node_id in joining state using origin prefix $origin_prefix"

	snapshot_generated
	policy_backup="$(mktemp "$policy.backup.XXXXXX")"
	cp "$policy" "$policy_backup"
	descriptor_tmp="$(mktemp "$root/config/cluster/nodes/$node_id.env.XXXXXX")"
	policy_tmp="$(mktemp "$policy.tmp.XXXXXX")"
	{
		printf 'NODE_ID=%s\nNODE_STATE=joining\n' "$node_id"
		render_app_node_fields
		printf 'WOODPECKER_AGENT_LABELS=node=%s,deployment=true,target=production,repo=%s\n' "$node_id" "$repo_slug"
		printf 'BESZEL_SYSTEM_NAME=%s\n' "$node_id"
	} >"$descriptor_tmp"
	sed "s/^NODE_IDS=.*/NODE_IDS=$node_ids,$node_id/" "$policy" >"$policy_tmp"
	[[ "$(grep -c '^NODE_IDS=' "$policy_tmp")" -eq 1 ]] || die 'cluster policy must contain exactly one NODE_IDS assignment'
	mutation_started=1
	mv "$descriptor_tmp" "$node_file"
	mv "$policy_tmp" "$policy"
	regenerate
	printf 'Added follower %s in joining state.\n' "$node_id"
	printf 'Review and commit the inventory/workflow diff, then bootstrap that VPS once.\n'
	printf 'After foundation health is verified, run: %s state %s active\n' "$0" "$node_id"
	;;
state)
	csv_has "$node_ids" "$node_id" || die "node is absent from NODE_IDS: $node_id"
	[[ -r "$node_file" ]] || die "missing node descriptor: $node_file"
	[[ "$(env_value NODE_ID "$node_file")" == "$node_id" ]] || die "node descriptor identity mismatch: $node_id"
	prompt_value requested_state 'New node state (active, draining, or retired)'
	case "$requested_state" in active | draining | retired) ;; *) die "invalid node state: $requested_state" ;; esac
	current_state="$(env_value NODE_STATE "$node_file")"
	if [[ "$current_state" == "$requested_state" ]]; then
		printf '%s is already %s; no files changed.\n' "$node_id" "$requested_state"
		exit 0
	fi
	case "$current_state:$requested_state" in
	joining:active | active:draining | draining:active | draining:retired) ;;
	*) die "invalid node state transition: $node_id/$current_state -> $requested_state" ;;
	esac
	if [[ "$requested_state" == draining || "$requested_state" == retired ]]; then
		for app_policy in "$root"/config/cluster/apps/*.policy; do
			[[ -f "$app_policy" ]] || continue
			if csv_has "$(env_value NODES "$app_policy")" "$node_id"; then
				die "move $node_id out of app policy before $requested_state: $(basename "$app_policy")"
			fi
		done
	fi
	confirm_change "Change $node_id from $current_state to $requested_state"

	snapshot_generated
	node_backup="$(mktemp "$node_file.backup.XXXXXX")"
	cp "$node_file" "$node_backup"
	descriptor_tmp="$(mktemp "$node_file.tmp.XXXXXX")"
	sed "s/^NODE_STATE=.*/NODE_STATE=$requested_state/" "$node_file" >"$descriptor_tmp"
	[[ "$(grep -c '^NODE_STATE=' "$descriptor_tmp")" -eq 1 ]] || die 'node descriptor must contain exactly one NODE_STATE assignment'
	mutation_started=1
	mv "$descriptor_tmp" "$node_file"
	regenerate
	printf 'Changed %s from %s to %s.\n' "$node_id" "$current_state" "$requested_state"
	[[ "$requested_state" != retired ]] || printf 'Run the generated node-retire-%s workflow before decommissioning the VPS.\n' "$node_id"
	;;
esac

mutation_started=0
trap - ERR HUP INT TERM
[[ -z "$policy_backup" ]] || rm -f -- "$policy_backup"
[[ -z "$node_backup" ]] || rm -f -- "$node_backup"
[[ -z "$descriptor_tmp" ]] || rm -f -- "$descriptor_tmp"
[[ -z "$policy_tmp" ]] || rm -f -- "$policy_tmp"
[[ -z "$generated_backup" ]] || rm -rf -- "$generated_backup"
printf 'Run validation, review the diff, commit, and push the cluster change.\n'
