#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2043,SC2155
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-dev}"
action="${2:-validate}"
case "$mode" in dev)
	env_file="${STACK_ENV_FILE:-$root/.env.dev}"
	runtime="${STACK_RUNTIME_ROOT:-$root/.runtime/dev}"
	# Do not let a local validation accidentally consume production secrets from
	# /etc/llm-hub-lite. Development credentials come from the selected env file;
	# an explicit STACK_CONFIG_ROOT is still available for fixture testing.
	CONFIG_ROOT="${STACK_CONFIG_ROOT:-$runtime/secrets}"
	bind=127.0.0.1
	;;
prod)
	env_file="${STACK_ENV_FILE:-$root/.env.prod}"
	runtime="${STACK_RUNTIME_ROOT:-$root/.runtime/prod}"
	CONFIG_ROOT="${STACK_CONFIG_ROOT:-${CONFIG_ROOT:-/etc/llm-hub-lite}}"
	bind=0.0.0.0
	;;
*)
	printf 'usage: %s {dev|prod} {validate|up|down|restart|logs|ps}\n' "$0" >&2
	exit 2
	;;
esac
[[ -f "$env_file" ]] || {
	printf 'missing environment file: %s\n' "$env_file" >&2
	exit 1
}
image_apps="${STACK_IMAGE_ENV_FILE:-$root/ops/images.apps.prod.env}"
image_foundation="${STACK_FOUNDATION_IMAGE_ENV_FILE:-$root/ops/images.foundation.prod.env}"
[[ -f "$image_apps" && -f "$image_foundation" ]] || {
	printf 'missing image manifest\n' >&2
	exit 1
}
compose_bin=(docker compose)
[[ -n "${PLATFORM_COMPOSE_BIN:-}" ]] && compose_bin=("$PLATFORM_COMPOSE_BIN")
policy="$root/config/cluster/policy.env"
node_config="${STACK_NODE_CONFIG_FILE:-$root/config/cluster/nodes/$(sed -n 's/^NODE_ID=//p' "$env_file" | tail -n1).env}"
node_id="$(sed -n 's/^NODE_ID=//p' "$node_config" 2>/dev/null | tail -n1)"
leader_id="$(sed -n 's/^LEADER_NODE_ID=//p' "$policy" | tail -n1)"
[[ -n "$node_id" ]] || node_id=leader
[[ -n "$leader_id" ]] || leader_id=leader
[[ "$node_id" == "$leader_id" ]] && role=leader || role=follower
node_state="$(sed -n 's/^NODE_STATE=//p' "$node_config" 2>/dev/null | tail -n1)"
env_value() {
	local key="$1" file="${2:-$env_file}" value=''
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$key="* ]] && value="${line#*=}"
	done <"$file"
	printf '%s\n' "$value"
}
csv_has() {
	local c=",${1//[[:space:]]/},"
	[[ "$c" == *",$2,"* ]]
}
app_dirs() { find "$root/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; | sort; }
descriptor_value() { env_value "$2" "$1/manifest.env"; }
app_public_host() {
	local d="$1" wanted="$2" key host
	while IFS='|' read -r key host; do
		[[ "$key" == "$wanted" ]] || continue
		printf '%s\n' "$host"
		return 0
	done < <(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')
}
app_public_endpoint_env() {
	local d="$1" key host domain scheme public_host file tmp
	domain="$(env_value DOMAIN_NAME "$env_file")"
	[[ -n "$domain" ]] || {
		printf 'DOMAIN_NAME is required to derive application public endpoints\n' >&2
		return 1
	}
	if [[ "$domain" == localhost ]]; then scheme=http; else scheme=https; fi
	file="$runtime/app-env/$(basename "$d").env"
	install -d -m 700 "$(dirname "$file")"
	tmp="$(mktemp "$file.tmp.XXXXXX")"
	while IFS='|' read -r key host; do
		[[ -n "$key" && -n "$host" ]] || continue
		public_host="$host.$domain"
		printf '%s=%s://%s\n%s_HOST=%s\n' "$key" "$scheme" "$public_host" "$key" "$public_host" >>"$tmp"
	done < <(printf '%s\n' "$(descriptor_value "$d" PUBLIC_ENDPOINTS)" | tr ';' '\n')
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
	printf '%s\n' "$file"
}
app_policy_file() { printf '%s/config/%s\n' "$root" "$(descriptor_value "$1" POLICY_FILE)"; }
app_policy_value() { env_value "$2" "$(app_policy_file "$1")"; }
app_nodes() { app_policy_value "$1" NODES; }
app_config_file() { printf '%s/%s\n' "$1" "$(descriptor_value "$1" CONFIG_FILE)"; }
app_override_file() { printf '%s/config/cluster/overrides/%s/%s.env\n' "$root" "$node_id" "$(basename "$1")"; }
app_runtime_env_file() {
	local rel
	rel="$(descriptor_value "$1" RUNTIME_ENV_FILE)"
	[[ -n "$rel" ]] || return 0
	printf '%s/%s\n' "${CONFIG_ROOT:-/etc/llm-hub-lite}" "$rel"
}
app_value() {
	local d="$1" key="$2" value runtime override config
	runtime="$(app_runtime_env_file "$d")"
	override="$(app_override_file "$d")"
	config="$(app_config_file "$d")"
	value=''
	[[ -z "$runtime" ]] || value="$(env_value "$key" "$runtime")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$override")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$config")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$image_apps")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$node_config")"
	[[ -n "$value" ]] || value="$(env_value "$key" "$env_file")"
	printf '%s\n' "$value"
}
cluster_upstreams() {
	local d="$1" field="$2" primary="${3:-}" node host output="" state
	if [[ -n "$primary" ]]; then
		state="$(sed -n 's/^NODE_STATE=//p' "$root/config/cluster/nodes/$primary.env" 2>/dev/null | tail -n1)"
		[[ "$state" == active ]] || {
			printf 'primary upstream node is not active for %s: %s\n' "$(basename "$d")" "$primary" >&2
			return 1
		}
		host="$(env_value "$field" "$root/config/cluster/nodes/$primary.env")"
		[[ -n "$host" ]] || {
			printf 'missing %s in inventory for %s\n' "$field" "$primary" >&2
			return 1
		}
		output="https://$host"
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$primary" ]] || continue
		state="$(sed -n 's/^NODE_STATE=//p' "$root/config/cluster/nodes/$node.env" 2>/dev/null | tail -n1)"
		[[ "$state" == active ]] || continue
		host="$(env_value "$field" "$root/config/cluster/nodes/$node.env")"
		[[ -n "$host" ]] || {
			printf 'missing %s in inventory for %s\n' "$field" "$node" >&2
			return 1
		}
		output="${output:+$output }https://$host"
	done < <(printf '%s\n' "$(app_nodes "$d")" | tr ',' '\n' | sed '/^$/d')
	[[ -n "$output" ]] || {
		printf 'no upstream nodes are configured for %s\n' "$(basename "$d")" >&2
		return 1
	}
	printf '%s\n' "$output"
}
get() {
	local k="$1" v domain groups public_key origin_key upstream_key upstream_mode target primary_key primary host public_host
	v="$(env_value "$k" "$env_file")"
	[[ -n "$v" ]] || v="$(env_value "$k" "$node_config")"
	domain="$(env_value DOMAIN_NAME "$env_file")"
	if [[ -n "${CURRENT_ROUTE_DESCRIPTOR:-}" ]]; then
		groups="$(descriptor_value "$CURRENT_ROUTE_DESCRIPTOR" ROUTE_GROUPS)"
		while IFS='|' read -r public_key origin_key upstream_key; do
			[[ -n "$public_key" ]] || continue
			if [[ "$k" == "$public_key" ]]; then
				v="$(app_value "$CURRENT_ROUTE_DESCRIPTOR" "$k")"
				if [[ -z "$v" ]]; then
					public_host="$(app_public_host "$CURRENT_ROUTE_DESCRIPTOR" "$public_key")"
					if [[ -n "$public_host" && -n "$domain" ]]; then
						if [[ "$domain" == localhost ]]; then v="http://${public_host}.localhost"; else v="https://${public_host}.${domain}"; fi
					fi
				fi
			elif [[ "$k" == "${public_key}_HOST" ]]; then
				public_host="$(app_public_host "$CURRENT_ROUTE_DESCRIPTOR" "$public_key")"
				[[ -n "$public_host" && -n "$domain" ]] && v="$public_host.$domain"
			elif [[ "$k" == "$origin_key" ]]; then
				v="$(env_value "$k" "$node_config")"
			elif [[ "$k" == "$upstream_key" && "$role" == leader ]]; then
				upstream_mode="$(descriptor_value "$CURRENT_ROUTE_DESCRIPTOR" UPSTREAM_MODE)"
				case "$upstream_mode" in
				singleton)
					target="$(app_nodes "$CURRENT_ROUTE_DESCRIPTOR")"
					[[ "$target" != *,* && -n "$target" ]] || {
						printf 'singleton app must target exactly one node: %s\n' "$(basename "$CURRENT_ROUTE_DESCRIPTOR")" >&2
						return 1
					}
					host="$(env_value "$origin_key" "$root/config/cluster/nodes/$target.env")"
					[[ -n "$host" && "$(env_value NODE_STATE "$root/config/cluster/nodes/$target.env")" == active && "$target" != "$leader_id" ]] || {
						printf 'singleton target is not an active follower: %s\n' "$target" >&2
						return 1
					}
					v="https://$host"
					;;
				active-active) v="$(cluster_upstreams "$CURRENT_ROUTE_DESCRIPTOR" "$origin_key")" ;;
				active-passive)
					primary_key="$(descriptor_value "$CURRENT_ROUTE_DESCRIPTOR" PRIMARY_NODE_KEY)"
					primary="$(app_policy_value "$CURRENT_ROUTE_DESCRIPTOR" "$primary_key")"
					v="$(cluster_upstreams "$CURRENT_ROUTE_DESCRIPTOR" "$origin_key" "$primary")"
					;;
				esac
			fi
		done < <(printf '%s\n' "$groups" | tr ';' '\n')
	fi
	printf '%s\n' "$v"
}
foundation_manifest_root="$root/compose/foundation/manifests"
foundation_manifest_file() { printf '%s/%s.env\n' "$foundation_manifest_root" "$1"; }
foundation_value() { env_value "$2" "$(foundation_manifest_file "$1")"; }
foundation_ids() {
	local manifest id order
	for manifest in "$foundation_manifest_root"/*.env; do
		[[ -f "$manifest" ]] || continue
		id="$(env_value COMPONENT_ID "$manifest")"
		order="$(env_value START_ORDER "$manifest")"
		[[ -n "$id" && "$order" =~ ^[0-9]+$ ]] && printf '%s\t%s\n' "$order" "$id"
	done | sort -n -k1,1 -k2,2 | cut -f2-
}
foundation_active() {
	local component="$1" roles policy_file enabled mandatory
	[[ -f "$(foundation_manifest_file "$component")" ]] || return 1
	[[ "$node_state" != retired ]] || return 1
	roles="$(foundation_value "$component" ROLES)"
	csv_has "$roles" "$role" || return 1
	policy_file="$root/config/$(foundation_value "$component" POLICY_FILE)"
	enabled="$(env_value ENABLED "$policy_file")"
	mandatory="$(foundation_value "$component" MANDATORY)"
	[[ "$mandatory" != true || "$enabled" == true ]] || {
		printf 'mandatory foundation service is disabled: %s\n' "$component" >&2
		return 1
	}
	[[ "$enabled" == true ]]
}
foundations() {
	local component
	while IFS= read -r component; do foundation_active "$component" && printf '%s\n' "$component"; done < <(foundation_ids)
}
app_placement() { descriptor_value "$1" PLACEMENT; }
app_active() {
	local d="$1"
	# Policy files are authoritative. Treat missing or malformed values as
	# disabled so local validation follows the same contract as platformctl.
	[[ "$(app_policy_value "$d" ENABLED)" == true ]] || return 1
	[[ "$(app_placement "$d")" == consumer && "$role" == follower ]] || return 1
	[[ "$node_state" == active ]] || return 1
	csv_has "$(app_nodes "$d")" "$node_id"
}
app_route_active() {
	local d="$1" node state mode primary_key primary active_count=0
	[[ "$(app_placement "$d")" == consumer ]] || return 1
	[[ "$(descriptor_value "$d" INGRESS_MODE)" != direct ]] || return 1
	[[ "$(app_policy_value "$d" ENABLED)" == true ]] || return 1
	if [[ "$role" == leader ]]; then
		mode="$(descriptor_value "$d" UPSTREAM_MODE)"
		while IFS= read -r node; do
			[[ -n "$node" ]] || continue
			[[ "$node" != "$leader_id" ]] || return 1
			state="$(sed -n 's/^NODE_STATE=//p' "$root/config/cluster/nodes/$node.env" 2>/dev/null | tail -n1)"
			[[ "$state" == active ]] || continue
			active_count=$((active_count + 1))
		done < <(printf '%s\n' "$(app_nodes "$d")" | tr ',' '\n' | sed '/^$/d')
		case "$mode" in
		singleton) ((active_count == 1)) || return 1 ;;
		active-active) ((active_count > 0)) || return 1 ;;
		active-passive)
			primary_key="$(descriptor_value "$d" PRIMARY_NODE_KEY)"
			primary="$(app_policy_value "$d" "$primary_key")"
			state="$(sed -n 's/^NODE_STATE=//p' "$root/config/cluster/nodes/$primary.env" 2>/dev/null | tail -n1)"
			[[ "$state" == active ]] || return 1
			;;
		*) return 1 ;;
		esac
	else
		app_active "$d" || return 1
	fi
}
foundation_file() { foundation_value "$1" COMPOSE_FILE; }
foundation_env() { printf '%s/ops/foundation/%s.example\n' "$root" "$(foundation_value "$1" ENV_FILE)"; }
fc() {
	local n="$1"
	# Compose resolves duplicate variables using the last env file. Keep the
	# checked-in foundation profile as the baseline, allow the selected stack
	# environment to override non-secret local settings, then make image and
	# node identity manifests authoritative.
	command=("${compose_bin[@]}" --env-file "$(foundation_env "$n")" --env-file "$env_file" --env-file "$image_foundation" --env-file "$node_config" -f "$root/compose/foundation/$(foundation_file "$n")")
}
ac() {
	local d="$1" runtime_env override_file endpoint_env
	# App config is a committed default profile. The selected stack env may
	# override it for local development; immutable images and node identity stay
	# authoritative, followed by explicit per-node/runtime values.
	command=("${compose_bin[@]}" --env-file "$(app_config_file "$d")" --env-file "$env_file" --env-file "$node_config" --env-file "$image_apps")
	override_file="$(app_override_file "$d")"
	[[ ! -f "$override_file" ]] || command+=(--env-file "$override_file")
	runtime_env="$(app_runtime_env_file "$d")"
	[[ -z "$runtime_env" || ! -f "$runtime_env" ]] || command+=(--env-file "$runtime_env")
	endpoint_env="$(app_public_endpoint_env "$d")"
	command+=(--env-file "$endpoint_env")
	command+=(-p "$(descriptor_value "$d" COMPOSE_PROJECT)" -f "$d/$(descriptor_value "$d" COMPOSE_FILE)")
}
render() {
	local s="$runtime/config" d a t f k v tmp
	rm -rf "$runtime"
	install -d -m700 "$s/routes.d"
	cp -a "$root/config/." "$s/"
	while IFS= read -r f; do while IFS= read -r k; do
		v="$(get "$k")"
		tmp="$(mktemp "$f.tmp.XXXXXX")"
		sed "s|{\$${k}}|${v//&/\\&}|g" "$f" >"$tmp"
		mv -f -- "$tmp" "$f"
	done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$f" | sed 's/[^A-Z0-9_]//g' | sort -u); done < <(find "$s" -type f -name '*.caddy' -print)
	while IFS= read -r d; do
		app_route_active "$d" || continue
		CURRENT_ROUTE_DESCRIPTOR="$d"
		a="$(basename "$d")"
		[[ "$role" == leader ]] && t="$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" || t="$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
		cp "$d/$t" "$s/routes.d/$a.caddy"
		while IFS= read -r k; do
			v="$(get "$k")"
			tmp="$(mktemp "$s/routes.d/$a.caddy.tmp.XXXXXX")"
			sed "s|{\$${k}}|${v//&/\\&}|g" "$s/routes.d/$a.caddy" >"$tmp"
			mv -f -- "$tmp" "$s/routes.d/$a.caddy"
		done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$s/routes.d/$a.caddy" | sed 's/[^A-Z0-9_]//g' | sort -u)
		unset CURRENT_ROUTE_DESCRIPTOR
	done < <(app_dirs)
	foundation_active woodpecker-controller || rm -f "$s/foundation-routes.d/woodpecker.caddy" "$s/foundation-routes.d/woodpecker-grpc.caddy"
	foundation_active beszel-controller || rm -f "$s/foundation-routes.d/beszel.caddy"
	foundation_active observer-controller || rm -f "$s/foundation-routes.d/observer.caddy"
}
base_env() {
	export CADDY_CONFIG_ROOT="$runtime/config" CADDY_DATA_ROOT="$runtime/data" \
		OBSERVER_DATA_ROOT="$runtime/data/observer" \
		CADDY_HTTP_BIND="$bind" CADDY_HTTPS_BIND="$bind" PLATFORM_EDGE_NETWORK="$(get PLATFORM_EDGE_NETWORK)"
}
ensure_networks() {
	local network
	for network in "$(get PLATFORM_EDGE_NETWORK)" foundation-woodpecker_private foundation-observer_private; do
		[[ -n "$network" ]] || continue
		docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
	done
}
validate() {
	base_env
	render
	fc caddy
	"${command[@]}" config --quiet
	while IFS= read -r n; do
		[[ "$n" == caddy ]] && continue
		fc "$n"
		"${command[@]}" config --quiet
	done < <(foundation_ids)
	while IFS= read -r d; do
		ac "$d"
		"${command[@]}" config --quiet
	done < <(app_dirs)
	docker run --rm --env-file "$env_file" -v "$runtime/config:/etc/caddy:ro" "$(sed -n 's/^CADDY_IMAGE=//p' "$image_foundation")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}
up() {
	validate
	ensure_networks
	base_env
	fc caddy
	"${command[@]}" up -d --pull never --wait --wait-timeout 180
	while IFS= read -r n; do
		[[ "$n" == caddy ]] && continue
		fc "$n"
		"${command[@]}" up -d --pull never --wait --wait-timeout 180
	done < <(foundations)
	while IFS= read -r d; do
		app_active "$d" || continue
		ac "$d"
		"${command[@]}" up -d --pull never --wait --wait-timeout 180
	done < <(app_dirs)
}
base_env
case "$action" in validate) validate ;; up | restart) up ;; down)
	while IFS= read -r n; do
		fc "$n"
		"${command[@]}" down --remove-orphans || true
	done < <(foundation_ids)
	while IFS= read -r d; do
		ac "$d"
		"${command[@]}" down --remove-orphans || true
	done < <(app_dirs)
	;;
logs | ps) for n in caddy; do
	fc "$n"
	"${command[@]}" "$action"
done ;; *)
	printf 'unknown action: %s\n' "$action" >&2
	exit 2
	;;
esac
