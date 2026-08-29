#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$-" == *x* ]]; then
	set +x
	printf 'WARNING: shell xtrace was disabled before loading application secrets.\n' >&2
fi
umask 077

[[ "$EUID" -eq 0 ]] || {
	printf 'Run this command as root.\n' >&2
	exit 1
}

script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
control_root="${CONTROL_ROOT:-/opt/platform/control}"
if [[ -d "$script_root/apps" && -d "$script_root/config/cluster" ]]; then
	root="$script_root"
else
	root="${REPO_ROOT:-$control_root/current}"
fi
config_root="${CONFIG_ROOT:-/etc/llm-hub-lite}"
app_env="${APP_ENV:-/opt/apps/llm-hub-lite/shared/.env.prod}"
bundle_file="${SHARED_SECRET_BUNDLE_FILE:-$config_root/shared-secrets.env}"
node_file="${NODE_CONFIG_FILE:-$config_root/node.env}"
cluster_policy="${CLUSTER_POLICY_FILE:-$root/config/cluster/policy.env}"
app_id="${1:-}"
target_node=''
target_node_explicit=0
reset_config=0
non_interactive=0

usage() {
	printf 'usage: %s <app-id> [--target-node <node-id>] [--reset-config] [--non-interactive]\n' "$0" >&2
}
die() {
	printf 'configure-app-secrets: %s\n' "$*" >&2
	exit 1
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
placeholder_value() {
	case "$1" in
	'' | replace-with-* | bootstrap-pending | *'<'* | *'>'* | *example.invalid* | *example.* | *your-upstash* | *account-id*) return 0 ;;
	*) return 1 ;;
	esac
}
valid_mongo_uri() {
	local uri="$1" scheme rest authority host entry host_name host_port
	case "$uri" in
	mongodb://*)
		scheme=mongodb
		rest="${uri#mongodb://}"
		;;
	mongodb+srv://*)
		scheme=mongodb+srv
		rest="${uri#mongodb+srv://}"
		;;
	*) return 1 ;;
	esac
	# Reject duplicate schemes and control characters without exposing credentials.
	[[ -n "$rest" && "$rest" != *'://' && "$rest" != *$'\n'* && "$rest" != *$'\r'* ]] || return 1
	authority="${rest%%[/?#]*}"
	[[ -n "$authority" ]] || return 1
	host="${authority##*@}"
	[[ -n "$host" ]] || return 1
	if [[ "$scheme" == mongodb+srv ]]; then
		[[ "$host" != *:* && "$host" != *,* ]] || return 1
		[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$host" =~ ^[A-Za-z0-9]$ ]] || return 1
		return 0
	fi
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || return 1
		host_name="${entry%%:*}"
		host_port="${entry#*:}"
		[[ "$host_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$host_name" =~ ^[A-Za-z0-9]$ ]] || return 1
		if [[ "$entry" == *:* ]]; then
			[[ "$host_port" =~ ^[0-9]{1,5}$ ]] || return 1
		fi
	done <<<"$(printf '%s' "$host" | tr ',' '\n')"
}
set_key() {
	local file="$1" key="$2" value="$3" tmp
	install -d -m 700 "$(dirname "$file")"
	tmp="$(mktemp "$(dirname "$file")/.env.XXXXXX")"
	[[ -f "$file" ]] && sed "/^${key}=/d" "$file" >"$tmp"
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}

[[ -n "$app_id" ]] || {
	usage
	exit 2
}
shift
while (($#)); do
	case "$1" in
	--target-node)
		[[ $# -ge 2 && -n "$2" ]] || {
			usage
			exit 2
		}
		target_node="$2"
		target_node_explicit=1
		shift 2
		;;
	--reset-config)
		reset_config=1
		shift
		;;
	--non-interactive)
		non_interactive=1
		shift
		;;
	*)
		usage
		exit 2
		;;
	esac
done

[[ "$app_id" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid application ID: $app_id"
manifest="$root/apps/$app_id/manifest.env"
[[ -r "$manifest" ]] || die "missing app manifest: $manifest"
[[ "$(env_value MANIFEST_VERSION "$manifest")" == 5 ]] || die "unsupported application manifest version: $app_id"
[[ "$(env_value APP_ID "$manifest")" == "$app_id" ]] || die "manifest APP_ID mismatch: $app_id"
[[ "$(env_value PLACEMENT "$manifest")" == consumer ]] || die "$app_id is not a consumer application"

policy_rel="$(env_value POLICY_FILE "$manifest")"
[[ "$policy_rel" == "cluster/apps/$app_id.policy" ]] || die "invalid application policy path: $policy_rel"
policy="$root/config/$policy_rel"
[[ -r "$policy" && -r "$node_file" && -r "$cluster_policy" ]] || die 'missing application policy, node configuration, or cluster policy'
[[ "$(env_value ENABLED "$policy")" == true ]] || die "$app_id is disabled by cluster policy"

local_node="$(env_value NODE_ID "$node_file")"
leader_node="$(env_value LEADER_NODE_ID "$cluster_policy")"
node_ids="$(env_value NODE_IDS "$cluster_policy")"
[[ "$local_node" =~ ^[a-z][a-z0-9-]*$ ]] || die 'local node configuration has an invalid NODE_ID'
[[ "$leader_node" =~ ^[a-z][a-z0-9-]*$ ]] || die 'cluster policy has an invalid LEADER_NODE_ID'
csv_has "$node_ids" "$local_node" || die "local node is absent from NODE_IDS: $local_node"

target_node="${target_node:-$local_node}"
[[ "$target_node" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid target node: $target_node"
csv_has "$node_ids" "$target_node" || die "target node is absent from NODE_IDS: $target_node"
if ((target_node_explicit)); then
	[[ "$target_node" != "$leader_node" ]] || die "explicit target must be a follower: $target_node"
	[[ "$target_node" == "$local_node" ]] || die "this node ($local_node) is not the requested explicit target ($target_node)"
fi
target_descriptor="$root/config/cluster/nodes/$target_node.env"
[[ -r "$target_descriptor" ]] || die "target node descriptor is missing: $target_node"
[[ "$(env_value NODE_ID "$target_descriptor")" == "$target_node" ]] || die "target descriptor NODE_ID mismatch: $target_node"
[[ "$(env_value NODE_STATE "$target_descriptor")" == active ]] || die "target node is not active: $target_node"

nodes="$(env_value NODES "$policy")"
if [[ "$local_node" != "$leader_node" ]]; then
	((target_node_explicit)) || csv_has "$nodes" "$local_node" || die "$app_id is not placed on this follower: $local_node"
elif [[ -z "$(env_value CLUSTER_SECRET_KEYS "$manifest")" ]]; then
	die "$app_id has no Leader-owned cluster secrets"
fi

cluster_keys="$(env_value CLUSTER_SECRET_KEYS "$manifest")"
node_keys="$(env_value NODE_SECRET_KEYS "$manifest")"
generated_keys="$(env_value GENERATED_SECRET_KEYS "$manifest")"
min_rules="$(env_value SECRET_MIN_LENGTHS "$manifest")"
runtime_rel="$(env_value RUNTIME_ENV_FILE "$manifest")"
if [[ -n "$node_keys" ]]; then
	[[ -n "$runtime_rel" && "$runtime_rel" != /* && "$runtime_rel" != *..* && "$runtime_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die 'node secrets require a safe RUNTIME_ENV_FILE'
fi
runtime_file=''
[[ -z "$runtime_rel" ]] || runtime_file="$config_root/$runtime_rel"

secret_min_length() {
	local wanted="$1" rule key length
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		length="${rule#*:}"
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$length" =~ ^[1-9][0-9]*$ ]] || die "invalid SECRET_MIN_LENGTHS entry: $rule"
		if [[ "$key" == "$wanted" ]]; then
			printf '%s\n' "$length"
			return 0
		fi
	done < <(printf '%s\n' "$min_rules" | tr ',' '\n')
	printf '1\n'
}
validate_secret() {
	local key="$1" value="$2" min_length="$3"
	placeholder_value "$value" && {
		printf '%s is required and cannot be a placeholder\n' "$key" >&2
		return 1
	}
	if ((${#value} < min_length)); then
		printf '%s must contain at least %s characters\n' "$key" "$min_length" >&2
		return 1
	fi
	if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then
		printf '%s contains control characters\n' "$key" >&2
		return 1
	fi
	if [[ "$key" == LIBRECHAT_MONGO_URI ]] && ! valid_mongo_uri "$value"; then
		printf '%s must be one valid mongodb:// or mongodb+srv:// URI\n' "$key" >&2
		return 1
	fi
}
existing_secret() {
	local key="$1" destination="$2" value
	value="$(env_value "$key" "$destination")"
	if [[ -z "$value" && "$destination" == "$app_env" ]]; then
		value="$(env_value "$key" "$bundle_file")"
	fi
	printf '%s\n' "$value"
}
resolve_secret() {
	local key="$1" destination="$2" value min_length
	min_length="$(secret_min_length "$key")"
	value="${!key:-}"
	if [[ -z "$value" ]]; then
		value="$(existing_secret "$key" "$destination")"
	fi
	if ((non_interactive == 0)) && placeholder_value "$value" && csv_has "$generated_keys" "$key"; then
		value="$(openssl rand -hex 32)"
	fi
	while ! validate_secret "$key" "$value" "$min_length"; do
		((non_interactive == 0)) || die "$key must be supplied by a protected Woodpecker secret"
		[[ -t 0 ]] || die "$key is missing or invalid; rerun interactively or provide it through the environment"
		if ! read -r -s -p "$app_id $key: " value; then
			die "$key input was not received"
		fi
		printf '\n'
	done
	printf '%s\n' "$value"
}
validate_key_list() {
	local keys="$1" key
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid secret key in manifest: $key"
	done < <(printf '%s\n' "$keys" | tr ',' '\n')
}
write_secrets() {
	local keys="$1" destination="$2" persist_bundle="${3:-0}" key value
	[[ -n "$keys" ]] || return 0
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		value="$(resolve_secret "$key" "$destination")"
		set_key "$destination" "$key" "$value"
		((persist_bundle == 0)) || set_key "$bundle_file" "$key" "$value"
	done < <(printf '%s\n' "$keys" | tr ',' '\n')
}

validate_key_list "$cluster_keys"
validate_key_list "$node_keys"
validate_key_list "$generated_keys"
while IFS= read -r generated_key; do
	[[ -n "$generated_key" ]] || continue
	csv_has "$cluster_keys,$node_keys" "$generated_key" || die "generated secret is not declared as a cluster or node secret: $generated_key"
done < <(printf '%s\n' "$generated_keys" | tr ',' '\n')

if [[ "$local_node" == "$leader_node" ]]; then
	write_secrets "$cluster_keys" "$app_env" 1
	printf 'Reconciled Leader-owned cluster secrets for %s.\n' "$app_id"
else
	write_secrets "$cluster_keys" "$app_env"
	write_secrets "$node_keys" "$runtime_file"
	printf 'Reconciled application secrets for %s on %s.\n' "$app_id" "$local_node"
	if ((target_node_explicit)) && ! csv_has "$nodes" "$local_node"; then
		printf 'Application secrets were prepared; cluster policy was not changed.\n'
	fi
fi

if ((reset_config)); then
	[[ "$local_node" != "$leader_node" ]] || die '--reset-config is valid only on a selected follower'
	data_root="$(env_value DATA_ROOT "$app_env")"
	data_root="${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}"
	data_rel="$(env_value DATA_ROOT_REL "$manifest")"
	marker_rel="$(env_value CONFIG_RESET_MARKER_REL "$manifest")"
	marker_rel="${marker_rel:-.reset-config}"
	[[ "$data_rel" != /* && "$data_rel" != *..* && "$data_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die 'invalid DATA_ROOT_REL'
	[[ "$marker_rel" != /* && "$marker_rel" != *..* && "$marker_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die 'invalid CONFIG_RESET_MARKER_REL'
	marker="$data_root/$data_rel/$marker_rel"
	install -d -m 700 "$(dirname "$marker")"
	: >"$marker"
	chmod 600 "$marker"
	printf 'Queued a one-shot configuration reset marker at %s.\n' "$marker"
fi
