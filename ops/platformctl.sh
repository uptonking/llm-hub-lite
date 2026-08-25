#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2155
set -Eeuo pipefail
umask 077

APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONTROL_ROOT="${CONTROL_ROOT:-$PLATFORM_ROOT/control}"
APPS_ROOT="${APPS_ROOT:-$CONTROL_ROOT/current/apps}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-$PLATFORM_ROOT/foundation}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
APP_IMAGE_ENV="${APP_IMAGE_ENV:-/etc/llm-hub-lite/images.apps.env}"
FOUNDATION_IMAGE_ENV="${FOUNDATION_IMAGE_ENV:-/etc/llm-hub-lite/images.foundation.env}"
FOUNDATION_ENV_ROOT="${FOUNDATION_ENV_ROOT:-$FOUNDATION_ROOT/env}"
RUNTIME_ROOT="${RUNTIME_ROOT:-$APP_ROOT/shared/runtime}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
SINGLETON_STATE_ROOT="${SINGLETON_STATE_ROOT:-$CONFIG_ROOT/singleton-state}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$CONTROL_ROOT/current/config/cluster/policy.env}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-180}"
die() {
	printf 'platformctl: %s\n' "$*" >&2
	exit 1
}
cleanup_candidate() {
	if [[ -n "${RUNTIME_CONFIG_CANDIDATE:-}" && -d "$RUNTIME_CONFIG_CANDIDATE" ]]; then
		rm -rf -- "$RUNTIME_CONFIG_CANDIDATE"
	fi
}
trap cleanup_candidate EXIT
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }
env_value() {
	local k="$1" f="${2:-$APP_ENV}"
	[[ -f "$f" ]] || return 0
	sed -n "s/^${k}=//p" "$f" | tail -n1
}
policy_value() { env_value "$1" "$CLUSTER_POLICY_FILE"; }
node_value() { env_value "$1" "$NODE_CONFIG_FILE"; }
csv_has() {
	local c=",${1//[[:space:]]/},"
	[[ "$c" == *",$2,"* ]]
}
placeholder_value() {
	case "$1" in
	'' | replace-with-* | *'<'* | *'>'* | *example.invalid* | *example.* | *your-upstash* | *account-id*) return 0 ;;
	*) return 1 ;;
	esac
}
safe_relative() {
	local value="$1"
	[[ "$value" != /* && "$value" != *..* && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}
compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then compose_bin=("$PLATFORM_COMPOSE_BIN"); elif [[ -x /usr/local/bin/platform-compose ]]; then compose_bin=(/usr/local/bin/platform-compose); fi
acquire_lock() {
	[[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return
	install -d -m700 "$(dirname "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for platform lock'
	export PLATFORM_LOCK_HELD=1
}
edge_network() { printf '%s\n' "$(env_value PLATFORM_EDGE_NETWORK)" | sed '/^$/s//platform_edge/'; }
ensure_network() {
	local n
	for n in "$(edge_network)" foundation-woodpecker_private; do docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null; done
}
node_id() { printf '%s\n' "${NODE_ID:-$(node_value NODE_ID)}" | sed '/^$/s//leader/'; }
leader_node_id() { printf '%s\n' "$(policy_value LEADER_NODE_ID)"; }
node_role() { [[ "$(node_id)" == "$(leader_node_id)" ]] && printf 'leader\n' || printf 'follower\n'; }
role_foundations() { [[ "$(node_role)" == leader ]] && policy_value FOUNDATION_LEADER || policy_value FOUNDATION_FOLLOWER; }
app_placement() { descriptor_value "$1" PLACEMENT; }
app_runtime_env_file() {
	local d="$1" rel
	rel="$(descriptor_value "$d" RUNTIME_ENV_FILE)"
	[[ -n "$rel" ]] || return 0
	printf '%s/%s\n' "$CONFIG_ROOT" "$rel"
}
app_policy_file() {
	local d="$1" rel
	rel="$(descriptor_value "$d" POLICY_FILE)"
	[[ -n "$rel" ]] || return 0
	printf '%s/%s\n' "$CONTROL_ROOT/current/config" "$rel"
}
app_policy_value() {
	local d="$1" key="$2"
	env_value "$key" "$(app_policy_file "$d")"
}
app_target_node() {
	local d="$1" key
	key="$(descriptor_value "$d" TARGET_NODE_KEY)"
	[[ -n "$key" ]] || return 1
	app_policy_value "$d" "$key"
}
app_value() {
	local d="$1" key="$2" value file
	file="$(app_runtime_env_file "$d")"
	value="$(env_value "$key" "$file")"
	[[ -n "$value" ]] || value="$(env_value "$key")"
	printf '%s\n' "$value"
}
foundation_active() { [[ "$1" == caddy ]] || { csv_has "$(role_foundations)" "$1" && ! csv_has "$(policy_value DISABLED_FOUNDATION)" "$1"; }; }
app_active() {
	local d="$1" id placement target
	id="$(basename "$d")"
	placement="$(app_placement "$d")"
	app_policy_enabled "$id" || return 1
	case "$placement" in
	follower) [[ "$(node_role)" == follower ]] ;;
	single-follower)
		target="$(app_target_node "$d")"
		[[ "$(node_role)" == follower && "$(node_id)" == "$target" ]]
		;;
	*) return 1 ;;
	esac
}
app_in_reconcile_scope() {
	local d="$1"
	app_active "$d" || return 1
	[[ "${PLATFORM_SKIP_SINGLETONS:-0}" != 1 || "$(app_placement "$d")" != single-follower ]]
}
app_route_active() {
	local id="$(basename "$1")"
	case "$(app_placement "$1")" in follower | single-follower) ;; *) return 1 ;; esac
	[[ "$(node_role)" == leader ]] || app_active "$1"
	app_policy_enabled "$id"
}
foundation_file() { case "$1" in caddy) echo caddy.yml ;; woodpecker-controller) echo woodpecker-controller.yml ;; woodpecker-worker) echo woodpecker-worker.yml ;; woodpecker-deployer) echo woodpecker-deployer.yml ;; beszel-controller) echo beszel-controller.yml ;; beszel-worker) echo beszel-worker.yml ;; *) die "unknown foundation: $1" ;; esac }
foundation_env() {
	case "$1" in
	caddy) echo "$FOUNDATION_ENV_ROOT/caddy.env" ;;
	woodpecker-*) echo "$FOUNDATION_ENV_ROOT/woodpecker.env" ;;
	beszel-*) echo "$FOUNDATION_ENV_ROOT/beszel.env" ;;
	*) die "unknown foundation environment: $1" ;;
	esac
}
foundation_compose() { compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$(foundation_env "$1")" --env-file "$FOUNDATION_IMAGE_ENV" --env-file "$NODE_CONFIG_FILE" -f "$FOUNDATION_ROOT/$(foundation_file "$1")"); }
descriptor_ids() { find -L "$APPS_ROOT" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; 2>/dev/null | sort; }
descriptor_value() {
	local value
	value="$(sed -n "s/^$2=//p" "$1/manifest.env" | tail -n1)"
	# Manifest values are env-style text; allow a single-quoted value to carry
	# JSON fragments such as HEALTH_EXPECT without leaking the delimiters into
	# HTTP smoke comparisons.
	value="$(printf '%s\n' "$value" | sed -e "s/^'//" -e "s/'$//")"
	printf '%s\n' "$value"
}
app_declared() {
	local d
	while IFS= read -r d; do [[ "$(basename "$d")" == "$1" ]] && return 0; done < <(descriptor_ids)
	return 1
}
app_policy_enabled() {
	local d
	while IFS= read -r d; do
		[[ "$(basename "$d")" == "$1" ]] || continue
		if [[ "$(app_policy_value "$d" ENABLED)" != false ]]; then
			return 0
		fi
		return 1
	done < <(descriptor_ids)
	return 1
}
app_compose() {
	local d="$1" runtime_env
	compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$NODE_CONFIG_FILE" --env-file "$APP_IMAGE_ENV")
	runtime_env="$(app_runtime_env_file "$d")"
	[[ -z "$runtime_env" || ! -f "$runtime_env" ]] || compose_command+=(--env-file "$runtime_env")
	compose_command+=(-p "$(descriptor_value "$d" COMPOSE_PROJECT)" -f "$d/$(descriptor_value "$d" COMPOSE_FILE)")
}
cluster_upstreams() {
	local field="$1" node host output="" primary="${2:-}"
	if [[ -n "$primary" ]]; then
		host="$(env_value "$field" "$CONTROL_ROOT/current/config/cluster/nodes/$primary.env")"
		[[ -n "$host" ]] || die "$field is missing from cluster inventory: $primary"
		output="https://$host"
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$(node_id)" ]] || continue
		[[ "$node" != "$primary" ]] || continue
		host="$(env_value "$field" "$CONTROL_ROOT/current/config/cluster/nodes/$node.env")"
		[[ -n "$host" ]] || die "$field is missing from cluster inventory: $node"
		output="${output:+$output }https://$host"
	done < <(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')
	[[ -n "$output" ]] || die "no follower upstreams are defined for $field"
	echo "$output"
}
effective_value() {
	local k="$1" v d target target_file mode groups public_key origin_key upstream_key primary_key primary public_host domain state_file previous_target
	d="${CURRENT_ROUTE_DESCRIPTOR:-}"
	v="$(env_value "$k")"
	[[ -n "$v" ]] || v="$(node_value "$k")"
	if [[ -n "$d" ]]; then
		groups="$(descriptor_value "$d" ROUTE_GROUPS)"
		while IFS='|' read -r public_key origin_key upstream_key; do
			[[ -n "$public_key" ]] || continue
			if [[ "$k" == "$public_key" ]]; then
				v="$(app_value "$d" "$k")"
				if [[ -z "$v" ]]; then
					public_host="$(descriptor_value "$d" PUBLIC_HOST)"
					domain="$(env_value DOMAIN_NAME)"
					if [[ -n "$public_host" && -n "$domain" ]]; then
						if [[ "$domain" == localhost ]]; then v="http://${public_host}.localhost"; else v="https://${public_host}.${domain}"; fi
					fi
				fi
			elif [[ "$k" == "$origin_key" ]]; then
				v="$(node_value "$k")"
			elif [[ "$k" == "$upstream_key" && "$(node_role)" == leader ]]; then
				mode="$(descriptor_value "$d" UPSTREAM_MODE)"
				case "$mode" in
				singleton)
					target="$(app_target_node "$d")"
					if [[ "${PLATFORM_SKIP_SINGLETONS:-0}" == 1 && "$(node_role)" == leader ]]; then
						state_file="$(singleton_state_file "$d")"
						previous_target="$(sed -n '1p' "$state_file" 2>/dev/null || true)"
						[[ -z "$previous_target" ]] || target="$previous_target"
					fi
					target_file="$CONTROL_ROOT/current/config/cluster/nodes/$target.env"
					v="https://$(env_value "$origin_key" "$target_file")"
					;;
				active-active) v="$(cluster_upstreams "$origin_key")" ;;
				active-passive)
					primary_key="$(descriptor_value "$d" PRIMARY_NODE_KEY)"
					primary="$(policy_value "$primary_key")"
					v="$(cluster_upstreams "$origin_key" "$primary")"
					;;
				*) die "unsupported upstream mode for $(basename "$d")" ;;
				esac
				[[ -n "$v" ]] || die "missing upstream for $(basename "$d")"
			fi
		done < <(printf '%s\n' "$groups" | tr ';' '\n')
	fi
	case "$k" in NODE_ID) v="$(node_id)" ;; NODE_ROLE) v="$(node_role)" ;; esac
	echo "$v"
}
render_template() {
	local f="$1" k v e descriptor="${2:-}" previous_descriptor="${CURRENT_ROUTE_DESCRIPTOR:-}"
	CURRENT_ROUTE_DESCRIPTOR="$descriptor"
	while IFS= read -r k; do
		v="$(effective_value "$k")"
		e="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
		sed "s|{\$${k}}|${e}|g" "$f" >"$f.tmp"
		mv "$f.tmp" "$f"
	done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$f" | sed 's/[^A-Z0-9_]//g' | sort -u)
	CURRENT_ROUTE_DESCRIPTOR="$previous_descriptor"
}
render_routes() {
	local s="$RUNTIME_ROOT/.config.staging.$$" d a t o f
	install -d -m700 "$RUNTIME_ROOT"
	rm -rf "$s"
	install -d -m700 "$s/routes.d"
	cp -a "$CONTROL_ROOT/current/config/." "$s/"
	while IFS= read -r f; do render_template "$f"; done < <(find "$s" -type f -name '*.caddy' -print)
	while IFS= read -r d; do
		app_route_active "$d" || continue
		a="$(basename "$d")"
		[[ "$(node_role)" == leader ]] && t="$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" || t="$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
		o="$s/routes.d/$a.caddy"
		cp "$d/$t" "$o"
		render_template "$o" "$d"
	done < <(descriptor_ids)
	foundation_active woodpecker-controller || rm -f "$s/foundation-routes.d/woodpecker.caddy" "$s/foundation-routes.d/woodpecker-grpc.caddy"
	foundation_active beszel-controller || rm -f "$s/foundation-routes.d/beszel.caddy"
	RUNTIME_CONFIG_CANDIDATE="$s"
}
commit_routes() {
	local c="${RUNTIME_CONFIG_CANDIDATE:-}" d="$RUNTIME_ROOT/config" f r
	[[ -d "$c" ]] || die 'missing staged Caddy configuration'
	install -d -m700 "$d"
	while IFS= read -r f; do
		r="${f#"$c/"}"
		install -d -m700 "$d/$(dirname "$r")"
		cp "$f" "$d/$r.tmp"
		mv "$d/$r.tmp" "$d/$r"
	done < <(find "$c" -type f -print)
	while IFS= read -r f; do
		r="${f#"$d/"}"
		[[ -e "$c/$r" ]] || rm -rf "$f"
	done < <(find "$d" -mindepth 1 -print)
	rm -rf "$c"
	unset RUNTIME_CONFIG_CANDIDATE
}
validate_cluster() {
	local node file migration backup origin d groups public_key origin_key host node_count=0 master_count=0 origins='' newapi_enabled=0
	need_file "$CLUSTER_POLICY_FILE"
	need_file "$NODE_CONFIG_FILE"
	[[ "$(policy_value CLUSTER_CONFIG_VERSION)" == 1 ]] || die 'unsupported cluster policy version'
	csv_has "$(policy_value NODE_IDS)" "$(node_id)" || die 'node is absent from cluster policy'
	[[ "$(node_id)" == "$(env_value NODE_ID "$NODE_CONFIG_FILE")" ]] || die 'runtime node identity disagrees with node inventory'
	[[ "$(node_role)" == leader || "$(node_role)" == follower ]] || die 'invalid derived node role'
	while IFS= read -r node; do
		[[ -n "$node" ]] || continue
		node_count=$((node_count + 1))
		file="$CONTROL_ROOT/current/config/cluster/nodes/$node.env"
		need_file "$file"
		[[ "$(env_value NODE_ID "$file")" == "$node" ]] || die "inventory NODE_ID mismatch: $node"
		[[ "$node" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid stable node ID: $node"
		if [[ "$node" != "$(leader_node_id)" ]]; then
			while IFS= read -r d; do
				app_policy_enabled "$(basename "$d")" || continue
				case "$(app_placement "$d")" in follower | single-follower) ;; *) continue ;; esac
				groups="$(descriptor_value "$d" ROUTE_GROUPS)"
				while IFS='|' read -r public_key origin_key _; do
					[[ -n "$public_key" ]] || continue
					host="$(env_value "$origin_key" "$file")"
					[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid origin host $origin_key for $node"
					csv_has "$origins" "$host" && die "duplicate consumer origin host: $host"
					origins="${origins:+$origins,}$host"
				done < <(printf '%s\n' "$groups" | tr ';' '\n')
			done < <(descriptor_ids)
		fi
		if [[ "$node" != "$(leader_node_id)" && "$(env_value NEW_API_NODE_TYPE "$file")" == master ]]; then
			master_count=$((master_count + 1))
		fi
	done < <(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')
	[[ "$node_count" -eq "$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" ]] || die 'NODE_IDS contains duplicate entries'
	csv_has "$(policy_value NODE_IDS)" "$(leader_node_id)" || die 'LEADER_NODE_ID is absent from NODE_IDS'
	app_policy_enabled newapi && newapi_enabled=1
	if ((newapi_enabled == 1)); then
		backup="$(policy_value NEW_API_BACKUP_NODE_ID)"
		csv_has "$(policy_value NODE_IDS)" "$backup" || die 'NEW_API_BACKUP_NODE_ID is absent from NODE_IDS'
	fi
	if ((newapi_enabled == 1)); then
		migration="$(policy_value NEW_API_MIGRATION_NODE_ID)"
		csv_has "$(policy_value NODE_IDS)" "$migration" || die 'NEW_API_MIGRATION_NODE_ID is absent from NODE_IDS'
		[[ "$migration" != "$(leader_node_id)" ]] || die 'NEW_API_MIGRATION_NODE_ID must be a follower'
		[[ "$(env_value NEW_API_NODE_TYPE "$CONTROL_ROOT/current/config/cluster/nodes/$migration.env")" == master ]] || die 'migration node must use NEW_API_NODE_TYPE=master'
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$(leader_node_id)" && "$newapi_enabled" -eq 1 ]] || continue
		case "$(env_value NEW_API_NODE_TYPE "$CONTROL_ROOT/current/config/cluster/nodes/$node.env")" in master | slave) ;; *) die "invalid NEW_API_NODE_TYPE for $node" ;; esac
	done < <(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')
	((newapi_enabled == 0 || master_count == 1)) || die 'exactly one follower must use NEW_API_NODE_TYPE=master'
}
validate_descriptor() {
	local d="$1" k v rel alias services health_service compose_file yaml_file nginx_file local_buffer_bytes
	for k in MANIFEST_VERSION APP_ID PLACEMENT UPSTREAM_MODE POLICY_FILE ROUTE_GROUPS COMPOSE_FILE COMPOSE_PROJECT SERVICE_NAME NETWORK_ALIAS IMAGE_KEYS DATA_ROOT_REL HEALTH_URL SMOKE_URL_KEY SMOKE_LOCAL HEALTH_MODE ROUTE_TEMPLATE_LEADER ROUTE_TEMPLATE_FOLLOWER; do
		v="$(descriptor_value "$d" "$k")"
		[[ -n "$v" ]] || die "$k is required in $d/manifest.env"
	done
	case "$(descriptor_value "$d" SMOKE_LOCAL)" in public | healthcheck) ;; *) die "SMOKE_LOCAL must be public or healthcheck in $d/manifest.env" ;; esac
	case "$(descriptor_value "$d" HEALTH_MODE)" in healthcheck | process) ;; *) die "HEALTH_MODE must be healthcheck or process in $d/manifest.env" ;; esac
	[[ "$(descriptor_value "$d" MANIFEST_VERSION)" == 3 ]] || die 'unsupported app manifest version'
	case "$(descriptor_value "$d" PLACEMENT)" in
	follower)
		[[ "$(descriptor_value "$d" UPSTREAM_MODE)" == active-active || "$(descriptor_value "$d" UPSTREAM_MODE)" == active-passive ]] || die "follower app must use active upstream mode: $d"
		;;
	single-follower)
		for k in TARGET_NODE_KEY RUNTIME_ENV_FILE SECRET_KEYS MOVE_MODE PUBLIC_URL_KEY PUBLIC_HOST HEALTH_SERVICE; do
			[[ -n "$(descriptor_value "$d" "$k")" ]] || die "$k is required for singleton app $d/manifest.env"
		done
		[[ "$(descriptor_value "$d" UPSTREAM_MODE)" == singleton ]] || die 'singleton app must use UPSTREAM_MODE=singleton'
		[[ "$(app_target_node "$d")" != "$(leader_node_id)" ]] || die "singleton app target must be a follower: $d"
		csv_has "$(policy_value NODE_IDS)" "$(app_target_node "$d")" || die "singleton app target is absent from inventory: $d"
		[[ "$(descriptor_value "$d" PUBLIC_HOST)" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid PUBLIC_HOST in singleton app $d/manifest.env"
		if app_policy_enabled "$(basename "$d")" && [[ "$(node_role)" == follower && "$(node_id)" == "$(app_target_node "$d")" ]]; then
			[[ -f "$(app_runtime_env_file "$d")" ]] || die "missing runtime env file for active singleton app: $d"
		fi
		;;
	*) die "unsupported app placement in $d/manifest.env" ;;
	esac
	[[ "$(descriptor_value "$d" APP_ID)" == "$(basename "$d")" && "$(descriptor_value "$d" APP_ID)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid APP_ID in $d/manifest.env"
	while IFS= read -r k; do
		[[ -z "$k" || "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid ENV_KEYS entry in $d/manifest.env: $k"
	done < <(printf '%s\n' "$(descriptor_value "$d" ENV_KEYS)" | tr ',' '\n')
	[[ "$(descriptor_value "$d" COMPOSE_PROJECT)" =~ ^app-[a-z0-9-]+$ ]] || die "invalid COMPOSE_PROJECT in $d/manifest.env"
	alias="$(descriptor_value "$d" NETWORK_ALIAS)"
	[[ "$alias" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid NETWORK_ALIAS in $d/manifest.env"
	for rel in "$(descriptor_value "$d" DATA_ROOT_REL)" "$(descriptor_value "$d" EPHEMERAL_DATA_REL)" "$(descriptor_value "$d" COMPOSE_FILE)" "$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" "$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)" "$(descriptor_value "$d" RUNTIME_ENV_FILE)" "$(descriptor_value "$d" POLICY_FILE)"; do
		[[ -z "$rel" ]] || safe_relative "$rel" || die "unsafe descriptor path in $d/manifest.env"
	done
	need_file "$CONTROL_ROOT/current/config/$(descriptor_value "$d" POLICY_FILE)"
	while IFS='|' read -r public_key origin_key upstream_key; do
		[[ "$public_key" =~ ^[A-Z][A-Z0-9_]*$ && "$origin_key" =~ ^[A-Z][A-Z0-9_]*$ && "$upstream_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid ROUTE_GROUPS in $d/manifest.env"
	done < <(printf '%s\n' "$(descriptor_value "$d" ROUTE_GROUPS)" | tr ';' '\n')
	need_file "$d/$(descriptor_value "$d" COMPOSE_FILE)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
	grep -Fq "$alias" "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)" || die "follower route does not target NETWORK_ALIAS in $d/manifest.env"
	for k in $(descriptor_value "$d" IMAGE_KEYS); do [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ && -n "$(env_value "$k" "$APP_IMAGE_ENV")" ]] || die "$k missing from image manifest"; done
	if app_in_reconcile_scope "$d"; then
		app_compose "$d"
		services="$("${compose_command[@]}" config --services 2>/dev/null || true)"
		[[ -n "$services" ]] || die "unable to evaluate active Compose project: $d"
		printf '%s\n' "$services" | grep -Fxq "$(descriptor_value "$d" SERVICE_NAME)" || die "SERVICE_NAME is absent from Compose project: $d"
		health_service="$(descriptor_value "$d" HEALTH_SERVICE)"
		[[ -z "$health_service" || "$(printf '%s\n' "$services" | grep -Fx "$health_service" || true)" == "$health_service" ]] || die "HEALTH_SERVICE is absent from Compose project: $d"
	fi
	if [[ "$(basename "$d")" == newapi ]] && app_in_reconcile_scope "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		[[ "$(env_value NEW_API_SQL_DSN)" =~ ^postgres(ql)?:// ]] || die 'production New API requires a postgres:// or postgresql:// DSN'
		[[ "$(env_value NEW_API_SQL_DSN)" != *replace-with* && "$(env_value NEW_API_SESSION_SECRET)" != *replace-with* && "$(env_value NEW_API_CRYPTO_SECRET)" != *replace-with* ]] || die 'production New API secrets and DSN must be configured'
	fi
	if [[ "$(basename "$d")" == librechat ]] && app_in_reconcile_scope "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			[[ -n "$(env_value "$k")" && "$(env_value "$k")" != replace-with-* ]] || die "production LibreChat requires $k"
		done
		[[ "$(env_value LIBRECHAT_MONGO_URI)" =~ ^mongodb(\+srv)?:// ]] || die 'LibreChat Mongo URI must use mongodb:// or mongodb+srv://'
		[[ "$(env_value LIBRECHAT_REDIS_URI)" =~ ^rediss:// ]] || die 'LibreChat Upstash Redis URI must use TLS (rediss://)'
		[[ "$(env_value LIBRECHAT_AWS_ENDPOINT_URL)" =~ ^https:// ]] || die 'LibreChat R2 endpoint must use https://'
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			! placeholder_value "$(env_value "$k")" || die "production LibreChat placeholder is not allowed: $k"
		done
	fi
	if [[ "$(basename "$d")" == observer ]]; then
		local_buffer_bytes="$(app_value "$d" OBSERVER_LOG_BUFFER_MAX_BYTES)"
		[[ -n "$local_buffer_bytes" ]] || local_buffer_bytes=8589934592
		[[ "$local_buffer_bytes" =~ ^[0-9]+$ ]] || die 'observer log buffer size must be an integer number of bytes'
		((local_buffer_bytes >= 1048576 && local_buffer_bytes <= 8589934592)) || die 'observer log buffer size must be between 1 MiB and 8 GiB'
	fi
	if [[ "$(descriptor_value "$d" STATE_MODE)" == sqlite ]]; then
		[[ -n "$(descriptor_value "$d" SQLITE_PATHS)" ]] || die "SQLite app is missing SQLITE_PATHS: $d"
		! grep -Eiq 'REDIS_CONN_STRING|SQL_DSN|postgres|redis' "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "SQLite app must not define Redis or PostgreSQL: $d"
		while IFS= read -r k; do
			[[ -n "$k" ]] || continue
			grep -Fq "$k" "$d/$(descriptor_value "$d" COMPOSE_FILE)" || die "SQLite path is absent from Compose: $k"
		done < <(printf '%s\n' "$(descriptor_value "$d" SQLITE_PATHS)" | tr ',' '\n')
		if app_in_reconcile_scope "$d"; then
			while IFS= read -r k; do
				[[ -n "$k" ]] || continue
				[[ -n "$(app_value "$d" "$k")" ]] || die "production SQLite app requires $k"
				! placeholder_value "$(app_value "$d" "$k")" || die "production SQLite app placeholder is not allowed: $k"
			done < <(printf '%s\n' "$(descriptor_value "$d" SECRET_KEYS)" | tr ',' '\n')
		fi
	fi
	if [[ "$(descriptor_value "$d" PLACEMENT)" == single-follower && "$(app_in_reconcile_scope "$d" && printf true || printf false)" == true ]]; then
		while IFS= read -r k; do
			[[ -n "$k" ]] || continue
			value="$(app_value "$d" "$k")"
			[[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "active singleton requires a non-empty single-line secret: $k"
			! placeholder_value "$value" || die "active singleton secret placeholder is not allowed: $k"
		done < <(printf '%s\n' "$(descriptor_value "$d" SECRET_KEYS)" | tr ',' '\n')
	fi
	if [[ "$(basename "$d")" == librechat ]]; then
		compose_file="$d/$(descriptor_value "$d" COMPOSE_FILE)"
		yaml_file="$d/librechat.yaml"
		nginx_file="$d/client.nginx.conf"
		need_file "$yaml_file"
		need_file "$nginx_file"
		# This profile deliberately keeps the follower footprint to API, admin, and Nginx.
		for forbidden in mongodb redis meilisearch vectordb rag_api pgvector; do
			! grep -Eiq "^[[:space:]]{2}${forbidden}:" "$compose_file" || die "LibreChat must not define local service: $forbidden"
		done
		! grep -Eiq 'MEILI_HOST|RAG_API_URL|RAG_PORT|LIBRECHAT_CODE_BASEURL|LIBRECHAT_CODE_API_KEY' "$compose_file" || die 'LibreChat has a forbidden local search, RAG, or code endpoint'
		! grep -Eiq '^[[:space:]]*(mcpServers:|[^#].*type:[[:space:]]*stdio)' "$yaml_file" || die 'LibreChat production YAML must not configure process-backed MCP'
		! grep -Eiq 'execute_code|file_search|web_search|stateful_code_sessions|programmatic_tools|run_in_background|tool_intents' "$yaml_file" || die 'LibreChat YAML enables a forbidden capability'
		grep -Fq 'location = /health' "$nginx_file" || die 'LibreChat Nginx must define an explicit /health endpoint'
		grep -Fq 'return 200 "OK\n"' "$nginx_file" || die 'LibreChat Nginx health endpoint must return OK'
		grep -Fq 'mem_limit:' "$compose_file" || die 'LibreChat Compose must define memory limits'
		grep -Fq 'pids_limit:' "$compose_file" || die 'LibreChat Compose must define PID limits'
		grep -Fq 'NODE_OPTIONS:' "$compose_file" || die 'LibreChat Compose must define Node heap limits'
	fi
}
validate_images() {
	local f="$1" k v
	while IFS='=' read -r k v; do
		[[ -z "$k" || "$k" == \#* ]] && continue
		[[ "$v" =~ @sha256:[0-9a-f]{64}$ ]] || die "$k must be digest-pinned"
	done <"$f"
}
projects_foundation() {
	printf 'caddy\n'
	printf '%s\n' "$(role_foundations)" | tr ',' '\n' | sed '/^$/d;/^caddy$/d' | sort -u
}
projects_apps() {
	local d
	while IFS= read -r d; do app_in_reconcile_scope "$d" && printf 'app:%s\n' "$d"; done < <(descriptor_ids)
}
all_projects() {
	printf 'caddy\nwoodpecker-controller\nwoodpecker-worker\nwoodpecker-deployer\nbeszel-controller\nbeszel-worker\n'
	while IFS= read -r d; do printf 'app:%s\n' "$d"; done < <(descriptor_ids)
}
validate() {
	local d id project alias n ids='' projects='' aliases=''
	validate_cluster
	need_file "$APP_ENV"
	validate_images "$APP_IMAGE_ENV"
	validate_images "$FOUNDATION_IMAGE_ENV"
	need_file "$CONTROL_ROOT/current/config/Caddyfile"
	need_file "$FOUNDATION_ROOT/caddy.yml"
	while IFS= read -r d; do
		validate_descriptor "$d"
		id="$(descriptor_value "$d" APP_ID)"
		project="$(descriptor_value "$d" COMPOSE_PROJECT)"
		alias="$(descriptor_value "$d" NETWORK_ALIAS)"
		csv_has "$ids" "$id" && die "duplicate app ID: $id"
		csv_has "$projects" "$project" && die "duplicate Compose project: $project"
		csv_has "$aliases" "$alias" && die "duplicate network alias: $alias"
		ids="${ids:+$ids,}$id"
		projects="${projects:+$projects,}$project"
		aliases="${aliases:+$aliases,}$alias"
	done < <(descriptor_ids)
	render_routes
	[[ "${VALIDATE_CHECK:-0}" == 1 ]] || ensure_network
	while IFS= read -r n; do
		foundation_active "$n" || continue
		foundation_compose "$n"
		"${compose_command[@]}" config --quiet
	done < <(projects_foundation)
	while IFS= read -r d; do
		app_compose "${d#app:}"
		"${compose_command[@]}" config --quiet
	done < <(projects_apps)
	docker run --rm --pull=never --env-file "$APP_ENV" --env-file "$NODE_CONFIG_FILE" -v "${RUNTIME_CONFIG_CANDIDATE:-$RUNTIME_ROOT/config}:/etc/caddy:ro" "$(env_value CADDY_IMAGE "$FOUNDATION_IMAGE_ENV")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	[[ "${VALIDATE_CHECK:-0}" == 1 ]] && {
		cleanup_candidate
		unset RUNTIME_CONFIG_CANDIDATE
	} || [[ "${VALIDATE_STAGE_ONLY:-0}" == 1 ]] || commit_routes
}
project_enabled() {
	[[ "$1" == caddy ]] && return 0
	if [[ "$1" == app:* ]]; then
		# Normal application reconciliation deliberately skips singleton start and
		# stop operations. Explicit singleton-stop sets the force flag below.
		if [[ "${PLATFORM_SKIP_SINGLETONS:-0}" == 1 && "${PLATFORM_FORCE_SINGLETON_ACTION:-0}" != 1 && "$(app_placement "${1#app:}")" == single-follower ]]; then
			return 0
		fi
		app_active "${1#app:}"
	else
		foundation_active "$1"
	fi
}
beszel_enrollment_pending() {
	[[ "$1" == beszel-worker && (! -s "$(env_value BESZEL_KEY_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" || ! -s "$(env_value BESZEL_TOKEN_FILE "$FOUNDATION_ENV_ROOT/beszel.env")") ]]
}
project_ids() {
	[[ "$1" == app:* ]] && app_compose "${1#app:}" || foundation_compose "$1"
	if beszel_enrollment_pending "$1"; then
		"${compose_command[@]}" ps --all -q beszel-socket-proxy
		return
	fi
	"${compose_command[@]}" ps --all -q
}
project_is_healthy() {
	local ids id state status health health_mode=process health_service health_ids health_id
	project_enabled "$1" || return 0
	if [[ "$1" == app:* ]]; then
		health_mode="$(descriptor_value "${1#app:}" HEALTH_MODE)"
		health_service="$(descriptor_value "${1#app:}" HEALTH_SERVICE)"
	fi
	ids="$(project_ids "$1")"
	[[ -n "$ids" ]] || return 1
	if [[ "$health_mode" == healthcheck && -n "$health_service" ]]; then
		health_ids="$("${compose_command[@]}" ps --all -q "$health_service")"
		[[ -n "$health_ids" ]] || return 1
		while IFS= read -r health_id; do
			[[ -n "$health_id" ]] || continue
			state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$health_id")"
			[[ "$state" == 'running healthy' ]] || return 1
		done <<<"$health_ids"
		while IFS= read -r id; do
			[[ -n "$id" ]] || continue
			state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
			status="${state%% *}"
			health="${state#* }"
			[[ "$status" == running && "$health" != unhealthy ]] || return 1
		done <<<"$ids"
		return 0
	fi
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
		if [[ "$health_mode" == healthcheck ]]; then
			[[ "$state" == 'running healthy' ]] || return 1
		else
			[[ "$state" == 'running healthy' || "$state" == 'running none' ]] || return 1
		fi
	done <<<"$ids"
}
report_compose_failure() {
	local id
	printf 'platformctl: Compose project state after failed health wait:\n' >&2
	"${compose_command[@]}" ps --all >&2 || true
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		docker inspect --format 'container={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}{{range .State.Health.Log}}{{printf "\n  health exit=%d output=%q" .ExitCode .Output}}{{end}}' "$id" >&2 || true
	done < <("${compose_command[@]}" ps --all -q 2>/dev/null || true)
}
compose_up_wait() {
	if "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
		return 0
	fi
	report_compose_failure
	printf 'platformctl: project did not become healthy; recreating it once\n' >&2
	if ! "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
		report_compose_failure
		return 1
	fi
}
start_project() {
	local p="$1"
	project_enabled "$p" || return
	ensure_network
	if beszel_enrollment_pending "$p"; then
		foundation_compose "$p"
		compose_up_wait beszel-socket-proxy
		return
	fi
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	compose_up_wait
}
stop_project() {
	local p="$1" project
	if ! project_enabled "$p"; then
		# Do not evaluate an inactive app's Compose file: disabled services may
		# intentionally have empty required secrets. Remove only its containers;
		# named volumes and bind-mounted data remain untouched.
		if [[ "$p" == app:* ]]; then
			project="$(descriptor_value "${p#app:}" COMPOSE_PROJECT)"
		else
			case "$p" in
			caddy) project=foundation-caddy ;;
			woodpecker-controller) project=foundation-woodpecker-controller ;;
			woodpecker-worker) project=foundation-woodpecker-worker ;;
			woodpecker-deployer) project=foundation-woodpecker-deployer ;;
			beszel-controller) project=foundation-beszel-controller ;;
			beszel-worker) project=foundation-beszel-worker ;;
			*) return 0 ;;
			esac
		fi
		docker ps -aq --filter "label=com.docker.compose.project=$project" | xargs -r docker rm -f >/dev/null
		return 0
	fi
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	"${compose_command[@]}" down --remove-orphans
}
stop_inactive() {
	local p
	while IFS= read -r p; do project_enabled "$p" || stop_project "$p" || true; done < <(all_projects)
}
health_scope() {
	local scope="$1" failed=0 p
	while IFS= read -r p; do project_is_healthy "$p" || {
		printf '%s: unhealthy\n' "$p" >&2
		failed=1
	}; done < <([[ "$scope" == foundation ]] && projects_foundation || projects_apps)
	return "$failed"
}
health() {
	local failed=0
	health_scope foundation || failed=1
	health_scope consumers || failed=1
	return "$failed"
}
wait_project() {
	local p="$1" elapsed=0
	while ((elapsed < COMPOSE_WAIT_TIMEOUT)); do
		project_is_healthy "$p" && return
		sleep 3
		elapsed=$((elapsed + 3))
	done
	return 1
}
reload_caddy() {
	foundation_compose caddy
	"${compose_command[@]}" exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	"${compose_command[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}
recover() {
	VALIDATE_STAGE_ONLY=1 validate
	local p
	while IFS= read -r p; do start_project "$p"; done < <(projects_foundation)
	health_scope foundation || die 'foundation recovery failed'
	while IFS= read -r p; do start_project "$p" || printf 'platformctl: consumer start failed: %s\n' "$p" >&2; done < <(projects_apps)
	stop_inactive
	health_scope consumers || printf 'platformctl: consumer recovery is incomplete; foundation remains healthy and recovery will retry\n' >&2
	commit_routes
	reload_caddy
}
sync() {
	local scope="${1:-all}" p
	[[ "$scope" == apps || "$scope" == foundation || "$scope" == all ]] || die 'sync scope must be apps, foundation, or all'
	VALIDATE_STAGE_ONLY=1 validate
	if [[ "$scope" == foundation || "$scope" == all ]]; then
		while IFS= read -r p; do start_project "$p"; done < <(projects_foundation)
		health_scope foundation || die 'foundation synchronization failed'
	fi
	if [[ "$scope" == apps || "$scope" == all ]]; then
		while IFS= read -r p; do start_project "$p"; done < <(projects_apps)
		stop_inactive
		health_scope consumers
	fi
	commit_routes
	reload_caddy
}
restart_project() {
	local p="$1"
	project_enabled "$p" || {
		stop_project "$p" || true
		return
	}
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	"${compose_command[@]}" restart
	wait_project "$p" || die "$p failed after restart"
}
recreate_project() {
	local p="$1"
	project_enabled "$p" || {
		stop_project "$p" || true
		return
	}
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	"${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"
}
smoke_project() {
	local d="$1" u path expected smoke_local
	smoke_local="$(descriptor_value "$d" SMOKE_LOCAL)"
	if [[ "$(node_role)" == follower && "$smoke_local" == healthcheck ]]; then
		project_is_healthy "app:$d"
		return
	fi
	u="$(env_value "$(descriptor_value "$d" SMOKE_URL_KEY)")"
	path="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	[[ -n "$u" ]] || return
	curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${u%/}$path" | { [[ -z "$expected" ]] || grep -q "$expected"; }
}
maintenance() { case "${1:-status}" in begin)
	install -d -m700 "$(dirname "$MAINTENANCE_FILE")"
	printf 'started_utc=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${2:-manual}" >"$MAINTENANCE_FILE"
	echo enabled
	;;
end)
	rm -f "$MAINTENANCE_FILE"
	echo disabled
	;;
status) [[ -f "$MAINTENANCE_FILE" ]] && cat "$MAINTENANCE_FILE" || echo inactive ;; *) die 'maintenance expects begin, end, or status' ;; esac }
data_root() {
	local v
	v="$(env_value DATA_ROOT)"
	printf '%s\n' "${v:-$APP_ROOT/shared/data/prod}"
}
singleton_descriptor() {
	local wanted="$1" d
	while IFS= read -r d; do
		[[ "$(basename "$d")" == "$wanted" ]] || continue
		[[ "$(app_placement "$d")" == single-follower ]] || die "app is not single-follower: $wanted"
		printf '%s\n' "$d"
		return 0
	done < <(descriptor_ids)
	die "unknown singleton app: $wanted"
}
singleton_state_file() { printf '%s/%s.previous-target\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
singleton_transition_file() { printf '%s/%s.transition.env\n' "$SINGLETON_STATE_ROOT" "$(basename "$1")"; }
transition_value() {
	local key="$1" file="$2"
	[[ -r "$file" ]] || return 0
	sed -n "s/^${key}=//p" "$file" | tail -n1
}
transition_set() {
	local file="$1" key="$2" value="$3" tmp
	install -d -m 700 "$SINGLETON_STATE_ROOT"
	tmp="$(mktemp "$file.XXXXXX")"
	if [[ -f "$file" ]]; then sed "/^${key}=/d" "$file" >"$tmp"; fi
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
transition_begin() {
	local file="$1" app="$2" old_target="$3" new_target="$4" release="$5" archive="$6" tmp
	install -d -m 700 "$SINGLETON_STATE_ROOT"
	tmp="$(mktemp "$file.XXXXXX")"
	{
		printf 'VERSION=1\nAPP_ID=%s\nOLD_TARGET=%s\nNEW_TARGET=%s\nRELEASE_SHA=%s\nPHASE=archiving\n' "$app" "$old_target" "$new_target" "$release"
		printf 'ARCHIVE_PATH=%s\nSTARTED_UTC=%s\nUPDATED_UTC=%s\n' "$archive" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	} >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
singleton_route_keys() {
	local d="$1" groups
	groups="$(descriptor_value "$d" ROUTE_GROUPS)"
	printf '%s\n' "$groups" | tr ';' '\n' | head -n1
}
singleton_prepare() {
	local d="$1" previous="${SINGLETON_PREVIOUS_TARGET:-}" target base rel root ephemeral_rel ephemeral_root archive state_file journal release phase journal_target journal_release
	[[ "$(node_role)" == follower ]] || die 'singleton prepare must run on a follower'
	d="$(singleton_descriptor "$d")"
	state_file="$(singleton_state_file "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ -n "$previous" ]] || previous="$(cat "$state_file" 2>/dev/null || true)"
	target="$(app_target_node "$d")"
	[[ "$(node_id)" == "$target" ]] || die 'singleton prepare must run on the configured target'
	if [[ "$(descriptor_value "$d" MOVE_MODE)" != fresh || -z "$previous" || "$previous" == "$target" ]]; then
		rm -f -- "$state_file"
		return 0
	fi
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	base="$(data_root)"
	rel="$(descriptor_value "$d" DATA_ROOT_REL)"
	safe_relative "$rel" || die "unsafe singleton data path: $rel"
	root="$base/$rel"
	case "$root" in "$base"/*) ;; *) die 'refusing to operate outside DATA_ROOT' ;; esac
	ephemeral_rel="$(descriptor_value "$d" EPHEMERAL_DATA_REL)"
	if [[ -n "$ephemeral_rel" ]]; then
		safe_relative "$ephemeral_rel" || die "unsafe singleton ephemeral data path: $ephemeral_rel"
		ephemeral_root="$root/$ephemeral_rel"
	fi
	journal_target="$(transition_value NEW_TARGET "$journal")"
	journal_release="$(transition_value RELEASE_SHA "$journal")"
	phase="$(transition_value PHASE "$journal")"
	if [[ "$journal_target" == "$target" && "$journal_release" == "$release" && "$phase" != failed && "$phase" != completed ]]; then
		archive="$(transition_value ARCHIVE_PATH "$journal")"
		if [[ -n "$archive" && -e "$archive" && ! -e "$root" ]]; then install -d -m 700 "$root"; fi
		if [[ "$phase" == prepared || "$phase" == origin-healthy ]]; then
			rm -f -- "$state_file"
			return 0
		fi
	fi
	if [[ ! -d "$root" ]]; then
		archive="$root.retained.$(date -u '+%Y%m%dT%H%M%SZ')"
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" "$archive"
		install -d -m 700 "$root"
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		return 0
	fi
	if ! find "$root" -mindepth 1 -print -quit | grep -q .; then
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		return 0
	fi
	stop_project "app:$d" || die "unable to stop existing singleton before fresh prepare"
	if [[ -n "$ephemeral_root" && (-e "$ephemeral_root" || -L "$ephemeral_root") ]]; then
		rm -rf -- "$ephemeral_root"
		printf 'discarded ephemeral singleton data at %s\n' "$ephemeral_root"
	fi
	if ! find "$root" -mindepth 1 -print -quit | grep -q .; then
		transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""
		transition_set "$journal" PHASE prepared
		rm -f -- "$state_file"
		printf 'discarded ephemeral singleton data and created fresh path %s\n' "$root"
		return 0
	fi
	archive="$root.retained.$(date -u '+%Y%m%dT%H%M%SZ')"
	transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" "$archive"
	mv -- "$root" "$archive"
	install -d -m 700 "$root"
	transition_set "$journal" PHASE prepared
	rm -f -- "$state_file"
	printf 'archived previous singleton data at %s and created fresh path %s\n' "$archive" "$root"
}
singleton_origin_smoke() {
	local d="$1" target origin_key origin health expected response journal release
	[[ "$(node_role)" == follower ]] || die 'singleton origin smoke must run on a follower'
	d="$(singleton_descriptor "$d")"
	target="$(app_target_node "$d")"
	[[ "$(node_id)" == "$target" ]] || die 'singleton origin smoke must run on the configured target'
	IFS='|' read -r _ origin_key _ <<EOF
$(singleton_route_keys "$d")
EOF
	origin="$(node_value "$origin_key")"
	health="$(descriptor_value "$d" HEALTH_URL)"
	expected="$(descriptor_value "$d" HEALTH_EXPECT)"
	[[ -n "$origin" && -n "$health" ]] || die "singleton origin smoke is missing origin or health path: $(basename "$d")"
	response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://$origin${health}" 2>/dev/null)" || die "singleton origin is unhealthy: $origin"
	[[ -z "$expected" || "$response" == *"$expected"* ]] || die "singleton origin response did not match HEALTH_EXPECT: $(basename "$d")"
	journal="$(singleton_transition_file "$d")"
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	if [[ "$(transition_value RELEASE_SHA "$journal")" == "$release" ]]; then transition_set "$journal" PHASE origin-healthy; fi
}
singleton_transition_fail() {
	local d="$1" journal
	[[ "$(node_role)" == follower ]] || die 'singleton transition failure must run on a follower'
	d="$(singleton_descriptor "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ -f "$journal" ]] || return 0
	transition_set "$journal" PHASE failed
	transition_set "$journal" FAILED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf 'singleton transition marked failed; retained journal at %s\n' "$journal" >&2
}
singleton_switch() {
	local d="$1" target origin_key origin public_key public_url enabled public_host domain journal release previous state_file
	[[ "$(node_role)" == leader ]] || die 'singleton switch must run on the Leader'
	d="$(singleton_descriptor "$d")"
	target="$(app_target_node "$d")"
	enabled="$(app_policy_enabled "$(basename "$d")" && printf true || printf false)"
	if [[ "$enabled" != true ]]; then
		PLATFORM_SKIP_SINGLETONS=0 sync apps
		printf 'singleton %s is disabled; Leader route and active containers reconciled\n' "$(basename "$d")"
		return 0
	fi
	IFS='|' read -r public_key origin_key _ <<EOF
$(singleton_route_keys "$d")
EOF
	origin="$(env_value "$origin_key" "$CONTROL_ROOT/current/config/cluster/nodes/$target.env")"
	[[ -n "$origin" ]] || die "missing singleton origin for $target"
	curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "https://$origin$(descriptor_value "$d" HEALTH_URL)" >/dev/null || die "singleton origin is unhealthy: $origin"
	PLATFORM_SKIP_SINGLETONS=0 sync apps
	public_url="$(app_value "$d" "$public_key")"
	if [[ -z "$public_url" ]]; then
		public_host="$(descriptor_value "$d" PUBLIC_HOST)"
		domain="$(env_value DOMAIN_NAME)"
		if [[ -n "$public_host" && -n "$domain" ]]; then
			if [[ "$domain" == localhost ]]; then public_url="http://${public_host}.localhost"; else public_url="https://${public_host}.${domain}"; fi
		fi
	fi
	[[ -z "$public_url" ]] || curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${public_url%/}$(descriptor_value "$d" HEALTH_URL)" >/dev/null || die 'singleton public smoke failed'
	journal="$(singleton_transition_file "$d")"
	release="${SINGLETON_RELEASE_SHA:-$(basename "$(readlink "$CONTROL_ROOT/current" 2>/dev/null || true)")}"
	install -d -m 700 "$SINGLETON_STATE_ROOT"
	state_file="$(singleton_state_file "$d")"
	previous="$(cat "$state_file" 2>/dev/null || true)"
	if [[ ! -f "$journal" ]]; then transition_begin "$journal" "$(basename "$d")" "$previous" "$target" "$release" ""; fi
	transition_set "$journal" RELEASE_SHA "$release"
	transition_set "$journal" PHASE switched
	transition_set "$journal" SWITCHED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	rm -f -- "$state_file"
}
singleton_stop() {
	local d="$1" rel root base runtime_env state_file journal
	[[ "$(node_role)" == follower ]] || die 'singleton stop must run on a follower'
	d="$(singleton_descriptor "$d")"
	state_file="$(singleton_state_file "$d")"
	journal="$(singleton_transition_file "$d")"
	[[ "$(node_id)" == "$(app_target_node "$d")" && "$(app_policy_enabled "$(basename "$d")" && printf true || printf false)" == true ]] && {
		printf 'retained active singleton %s on configured target %s\n' "$(basename "$d")" "$(node_id)"
		if [[ "${SINGLETON_FINAL_STOP:-0}" == 1 && -f "$journal" ]]; then
			transition_set "$journal" PHASE completed
			transition_set "$journal" COMPLETED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		fi
		return 0
	}
	app_active "$d" && return 0
	PLATFORM_FORCE_SINGLETON_ACTION=1 stop_project "app:$d" || die "unable to stop singleton containers for $(basename "$d")"
	rm -f -- "$state_file"
	base="$(data_root)"
	rel="$(descriptor_value "$d" DATA_ROOT_REL)"
	safe_relative "$rel" || die "unsafe singleton data path: $rel"
	root="$base/$rel"
	case "$root" in "$base"/*) ;; *) die 'refusing to report data outside DATA_ROOT' ;; esac
	runtime_env="$(app_runtime_env_file "$d")"
	printf 'stopped singleton %s; retained data at %s%s\n' "$(basename "$d")" "$root" "${runtime_env:+ and runtime secrets at $runtime_env}"
	if [[ "${SINGLETON_FINAL_STOP:-0}" == 1 && -f "$journal" ]]; then
		transition_set "$journal" PHASE completed
		transition_set "$journal" COMPLETED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	fi
}
op="${1:-status}"
case "$op" in status | health | validate) ;; *) acquire_lock ;; esac
case "$op" in validate) [[ "${2:-}" == --check ]] && VALIDATE_CHECK=1 validate || validate ;; status) [[ "${2:-}" == --json ]] && printf '{"node":"%s","role":"%s"}\n' "$(node_id)" "$(node_role)" || {
	printf 'node=%s role=%s\n' "$(node_id)" "$(node_role)"
	health
} ;; health) health ;; recover) recover ;; ensure-network) ensure_network ;; start) [[ "${2:-all}" == all ]] && while IFS= read -r p; do start_project "$p"; done < <(
	projects_foundation
	projects_apps
) || start_project "$2" ;; sync) sync "${2:-all}" ;; stop) [[ "${2:-all}" == all ]] && while IFS= read -r p; do stop_project "$p"; done < <(all_projects) || stop_project "$2" ;; restart | recreate) if [[ "${2:-all}" == all ]]; then while IFS= read -r p; do [[ "$op" == restart ]] && restart_project "$p" || recreate_project "$p"; done < <(
	projects_foundation
	projects_apps
); else [[ "$op" == restart ]] && restart_project "$2" || recreate_project "$2"; fi ;; singleton-switch)
	[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-switch <app-id>'
	singleton_switch "$2"
	;;
singleton-stop)
	[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-stop <app-id>'
	singleton_stop "$2"
	;;
singleton-prepare)
	[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-prepare <app-id>'
	singleton_prepare "$2"
	;;
singleton-origin-smoke)
	[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-origin-smoke <app-id>'
	singleton_origin_smoke "$2"
	;;
singleton-transition-fail)
	[[ -n "${2:-}" ]] || die 'usage: platformctl singleton-transition-fail <app-id>'
	singleton_transition_fail "$2"
	;;
smoke) [[ "${2:-}" == all ]] && while IFS= read -r d; do app_route_active "$d" && smoke_project "$d"; done < <(descriptor_ids) || {
	[[ "${2:-}" == app:* ]] || die 'usage: platformctl smoke {all|app:<descriptor>}'
	smoke_project "${2#app:}"
} ;; maintenance) maintenance "${2:-status}" "${3:-}" ;; reload) reload_caddy ;; backup) exec "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;; restore) exec "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;; *) die 'usage: platformctl {validate|status|health|recover|ensure-network|start|sync|restart|recreate|stop|singleton-prepare|singleton-origin-smoke|singleton-switch|singleton-stop|smoke|maintenance|reload|backup|restore}' ;; esac
