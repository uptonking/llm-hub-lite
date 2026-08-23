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
foundation_active() { [[ "$1" == caddy ]] || { csv_has "$(role_foundations)" "$1" && ! csv_has "$(policy_value DISABLED_FOUNDATION)" "$1"; }; }
app_active() { [[ "$(app_placement "$1")" == follower && "$(node_role)" == follower ]] && ! csv_has "$(policy_value DISABLED_APPS)" "$(basename "$1")"; }
app_route_active() {
	local id="$(basename "$1")"
	[[ "$(app_placement "$1")" == follower ]]
	[[ "$(node_role)" == leader ]] || app_active "$1"
	! csv_has "$(policy_value DISABLED_APPS)" "$id"
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
descriptor_value() { sed -n "s/^$2=//p" "$1/manifest.env" | tail -n1; }
app_declared() {
	local d
	while IFS= read -r d; do [[ "$(basename "$d")" == "$1" ]] && return 0; done < <(descriptor_ids)
	return 1
}
app_policy_enabled() { app_declared "$1" && ! csv_has "$(policy_value DISABLED_APPS)" "$1"; }
app_compose() { compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$NODE_CONFIG_FILE" --env-file "$APP_IMAGE_ENV" -p "$(descriptor_value "$1" COMPOSE_PROJECT)" -f "$1/$(descriptor_value "$1" COMPOSE_FILE)"); }
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
	local k="$1" v domain
	v="$(env_value "$k")"
	[[ -n "$v" ]] || v="$(node_value "$k")"
	domain="$(env_value DOMAIN_NAME)"
	case "$k" in NODE_ID) v="$(node_id)" ;; NODE_ROLE) v="$(node_role)" ;; NEW_API_UPSTREAMS) [[ "$(node_role)" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_NEW_API_ORIGIN_HOST)" ;; CLIPROXY_UPSTREAMS) [[ "$(node_role)" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_CLIPROXY_ORIGIN_HOST "$(policy_value CLIPROXY_PRIMARY_NODE_ID)")" ;; LIBRECHAT_UPSTREAMS) [[ "$(node_role)" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_LIBRECHAT_ORIGIN_HOST)" ;; LIBRECHAT_ADMIN_UPSTREAMS) [[ "$(node_role)" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_LIBRECHAT_ADMIN_ORIGIN_HOST)" ;; esac
	echo "$v"
}
render_template() {
	local f="$1" k v e
	while IFS= read -r k; do
		v="$(effective_value "$k")"
		e="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
		sed "s|{\$${k}}|${e}|g" "$f" >"$f.tmp"
		mv "$f.tmp" "$f"
	done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$f" | sed 's/[^A-Z0-9_]//g' | sort -u)
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
		render_template "$o"
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
	local node file primary migration backup origin node_count=0 master_count=0 origins='' newapi_enabled=0 cliproxy_enabled=0
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
		[[ "$(env_value NODE_NEW_API_ORIGIN_HOST "$file")" =~ ^[A-Za-z0-9.-]+$ && "$(env_value NODE_CLIPROXY_ORIGIN_HOST "$file")" =~ ^[A-Za-z0-9.-]+$ && "$(env_value NODE_LIBRECHAT_ORIGIN_HOST "$file")" =~ ^[A-Za-z0-9.-]+$ && "$(env_value NODE_LIBRECHAT_ADMIN_ORIGIN_HOST "$file")" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid consumer origin hosts for $node"
		for origin in "$(env_value NODE_NEW_API_ORIGIN_HOST "$file")" "$(env_value NODE_CLIPROXY_ORIGIN_HOST "$file")" "$(env_value NODE_LIBRECHAT_ORIGIN_HOST "$file")" "$(env_value NODE_LIBRECHAT_ADMIN_ORIGIN_HOST "$file")"; do
			csv_has "$origins" "$origin" && die "duplicate consumer origin host: $origin"
			origins="${origins:+$origins,}$origin"
		done
		if [[ "$node" != "$(leader_node_id)" && "$(env_value NEW_API_NODE_TYPE "$file")" == master ]]; then
			master_count=$((master_count + 1))
		fi
	done < <(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d')
	[[ "$node_count" -eq "$(printf '%s\n' "$(policy_value NODE_IDS)" | tr ',' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" ]] || die 'NODE_IDS contains duplicate entries'
	csv_has "$(policy_value NODE_IDS)" "$(leader_node_id)" || die 'LEADER_NODE_ID is absent from NODE_IDS'
	app_policy_enabled newapi && newapi_enabled=1
	app_policy_enabled cliproxyapi && cliproxy_enabled=1
	if ((newapi_enabled == 1)); then
		backup="$(policy_value NEW_API_BACKUP_NODE_ID)"
		csv_has "$(policy_value NODE_IDS)" "$backup" || die 'NEW_API_BACKUP_NODE_ID is absent from NODE_IDS'
	fi
	if ((cliproxy_enabled == 1)); then
		primary="$(policy_value CLIPROXY_PRIMARY_NODE_ID)"
		csv_has "$(policy_value NODE_IDS)" "$primary" || die 'CLIPROXY_PRIMARY_NODE_ID is absent from NODE_IDS'
		[[ "$primary" != "$(leader_node_id)" ]] || die 'CLIPROXY_PRIMARY_NODE_ID must be a follower'
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
	local d="$1" k v rel alias services compose_file yaml_file nginx_file
	for k in MANIFEST_VERSION APP_ID PLACEMENT COMPOSE_FILE COMPOSE_PROJECT SERVICE_NAME NETWORK_ALIAS IMAGE_KEYS DATA_ROOT_REL HEALTH_URL SMOKE_URL_KEY SMOKE_LOCAL ROUTE_TEMPLATE_LEADER ROUTE_TEMPLATE_FOLLOWER; do
		v="$(descriptor_value "$d" "$k")"
		[[ -n "$v" ]] || die "$k is required in $d/manifest.env"
	done
	case "$(descriptor_value "$d" SMOKE_LOCAL)" in public | healthcheck) ;; *) die "SMOKE_LOCAL must be public or healthcheck in $d/manifest.env" ;; esac
	[[ "$(descriptor_value "$d" MANIFEST_VERSION)" == 2 ]] || die 'unsupported app manifest version'
	[[ "$(descriptor_value "$d" PLACEMENT)" == follower ]] || die "unsupported app placement in $d/manifest.env"
	[[ "$(descriptor_value "$d" APP_ID)" == "$(basename "$d")" && "$(descriptor_value "$d" APP_ID)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid APP_ID in $d/manifest.env"
	[[ "$(descriptor_value "$d" COMPOSE_PROJECT)" =~ ^app-[a-z0-9-]+$ ]] || die "invalid COMPOSE_PROJECT in $d/manifest.env"
	alias="$(descriptor_value "$d" NETWORK_ALIAS)"
	[[ "$alias" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid NETWORK_ALIAS in $d/manifest.env"
	for rel in "$(descriptor_value "$d" DATA_ROOT_REL)" "$(descriptor_value "$d" COMPOSE_FILE)" "$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)" "$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"; do [[ "$rel" != /* && "$rel" != *..* && "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "unsafe descriptor path in $d/manifest.env"; done
	need_file "$d/$(descriptor_value "$d" COMPOSE_FILE)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_LEADER)"
	need_file "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)"
	grep -Fq "$alias" "$d/$(descriptor_value "$d" ROUTE_TEMPLATE_FOLLOWER)" || die "follower route does not target NETWORK_ALIAS in $d/manifest.env"
	for k in $(descriptor_value "$d" IMAGE_KEYS); do [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ && -n "$(env_value "$k" "$APP_IMAGE_ENV")" ]] || die "$k missing from image manifest"; done
	if app_active "$d"; then
		app_compose "$d"
		services="$("${compose_command[@]}" config --services 2>/dev/null || true)"
		[[ -n "$services" ]] || die "unable to evaluate active Compose project: $d"
		printf '%s\n' "$services" | grep -Fxq "$(descriptor_value "$d" SERVICE_NAME)" || die "SERVICE_NAME is absent from Compose project: $d"
	fi
	if [[ "$(basename "$d")" == newapi ]] && app_active "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		[[ "$(env_value NEW_API_SQL_DSN)" =~ ^postgres(ql)?:// ]] || die 'production New API requires a postgres:// or postgresql:// DSN'
		[[ "$(env_value NEW_API_SQL_DSN)" != *replace-with* && "$(env_value NEW_API_SESSION_SECRET)" != *replace-with* && "$(env_value NEW_API_CRYPTO_SECRET)" != *replace-with* ]] || die 'production New API secrets and DSN must be configured'
	fi
	if [[ "$(basename "$d")" == librechat ]] && app_active "$d" && [[ "$(env_value DOMAIN_NAME)" != localhost ]]; then
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_JWT_SECRET LIBRECHAT_JWT_REFRESH_SECRET LIBRECHAT_ADMIN_PANEL_SESSION_SECRET LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			[[ -n "$(env_value "$k")" && "$(env_value "$k")" != replace-with-* ]] || die "production LibreChat requires $k"
		done
		[[ "$(env_value LIBRECHAT_MONGO_URI)" =~ ^mongodb(\+srv)?:// ]] || die 'LibreChat Mongo URI must use mongodb:// or mongodb+srv://'
		[[ "$(env_value LIBRECHAT_REDIS_URI)" =~ ^rediss?:// ]] || die 'LibreChat Redis URI must use redis:// or rediss://'
		[[ "$(env_value LIBRECHAT_AWS_ENDPOINT_URL)" =~ ^https:// ]] || die 'LibreChat R2 endpoint must use https://'
		for k in LIBRECHAT_MONGO_URI LIBRECHAT_REDIS_URI LIBRECHAT_AWS_ENDPOINT_URL LIBRECHAT_AWS_ACCESS_KEY_ID LIBRECHAT_AWS_SECRET_ACCESS_KEY LIBRECHAT_AWS_BUCKET_NAME; do
			! placeholder_value "$(env_value "$k")" || die "production LibreChat placeholder is not allowed: $k"
		done
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
	while IFS= read -r d; do app_active "$d" && printf 'app:%s\n' "$d"; done < <(descriptor_ids)
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
	[[ "$1" == app:* ]] && app_active "${1#app:}" || foundation_active "$1"
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
	local ids id state
	project_enabled "$1" || return 0
	ids="$(project_ids "$1")"
	[[ -n "$ids" ]] || return 1
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
		[[ "$state" == 'running healthy' || "$state" == 'running none' ]] || return 1
	done <<<"$ids"
}
start_project() {
	local p="$1"
	project_enabled "$p" || return
	ensure_network
	if beszel_enrollment_pending "$p"; then
		foundation_compose "$p"
		"${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" beszel-socket-proxy
		return
	fi
	[[ "$p" == app:* ]] && app_compose "${p#app:}" || foundation_compose "$p"
	"${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"
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
	commit_routes
	reload_caddy
	while IFS= read -r p; do start_project "$p" || printf 'platformctl: consumer start failed: %s\n' "$p" >&2; done < <(projects_apps)
	stop_inactive
	health_scope consumers || printf 'platformctl: consumer recovery is incomplete; foundation remains healthy and recovery will retry\n' >&2
}
sync() {
	local scope="${1:-all}" p
	[[ "$scope" == apps || "$scope" == foundation || "$scope" == all ]] || die 'sync scope must be apps, foundation, or all'
	VALIDATE_STAGE_ONLY=1 validate
	if [[ "$scope" == foundation || "$scope" == all ]]; then
		while IFS= read -r p; do start_project "$p"; done < <(projects_foundation)
		health_scope foundation || die 'foundation synchronization failed'
	fi
	commit_routes
	reload_caddy
	if [[ "$scope" == apps || "$scope" == all ]]; then
		while IFS= read -r p; do start_project "$p"; done < <(projects_apps)
		stop_inactive
		health_scope consumers
	fi
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
); else [[ "$op" == restart ]] && restart_project "$2" || recreate_project "$2"; fi ;; smoke) [[ "${2:-}" == all ]] && while IFS= read -r d; do app_route_active "$d" && smoke_project "$d"; done < <(descriptor_ids) || {
	[[ "${2:-}" == app:* ]] || die 'usage: platformctl smoke {all|app:<descriptor>}'
	smoke_project "${2#app:}"
} ;; maintenance) maintenance "${2:-status}" "${3:-}" ;; reload) reload_caddy ;; backup) exec "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;; restore) exec "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;; *) die 'usage: platformctl {validate|status|health|recover|ensure-network|start|sync|restart|recreate|stop|smoke|maintenance|reload|backup|restore}' ;; esac
