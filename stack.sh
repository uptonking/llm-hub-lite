#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2043,SC2155
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-dev}"
action="${2:-validate}"
case "$mode" in dev)
	env_file="${STACK_ENV_FILE:-$root/.env.dev}"
	runtime="${STACK_RUNTIME_ROOT:-$root/.runtime/dev}"
	bind=127.0.0.1
	;;
prod)
	env_file="${STACK_ENV_FILE:-$root/.env.prod}"
	runtime="${STACK_RUNTIME_ROOT:-$root/.runtime/prod}"
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
cluster_upstreams() {
	local field="$1" primary="${2:-}" node host output=""
	if [[ -n "$primary" ]]; then
		host="$(sed -n "s/^${field}=//p" "$root/config/cluster/nodes/$primary.env" | tail -n1)"
		[[ -n "$host" ]] || {
			printf 'missing %s in inventory for %s\n' "$field" "$primary" >&2
			return 1
		}
		output="https://$host"
	fi
	while IFS= read -r node; do
		[[ -n "$node" && "$node" != "$leader_id" && "$node" != "$primary" ]] || continue
		host="$(sed -n "s/^${field}=//p" "$root/config/cluster/nodes/$node.env" | tail -n1)"
		[[ -n "$host" ]] || {
			printf 'missing %s in inventory for %s\n' "$field" "$node" >&2
			return 1
		}
		output="${output:+$output }https://$host"
	done < <(sed -n 's/^NODE_IDS=//p' "$policy" | tr ',' '\n' | sed '/^$/d')
	printf '%s\n' "$output"
}
get() {
	local k="$1" v domain
	v="$(sed -n "s/^$k=//p" "$env_file" | tail -n1)"
	[[ -n "$v" ]] || v="$(sed -n "s/^$k=//p" "$node_config" 2>/dev/null | tail -n1)"
	domain="$(sed -n 's/^DOMAIN_NAME=//p' "$env_file" | tail -n1)"
	case "$k" in NEW_API_UPSTREAMS) [[ "$role" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_NEW_API_ORIGIN_HOST)" ;; CLIPROXY_UPSTREAMS) [[ "$role" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_CLIPROXY_ORIGIN_HOST "$(sed -n 's/^CLIPROXY_PRIMARY_NODE_ID=//p' "$policy" | tail -n1)")" ;; LIBRECHAT_UPSTREAMS) [[ "$role" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_LIBRECHAT_ORIGIN_HOST)" ;; LIBRECHAT_ADMIN_UPSTREAMS) [[ "$role" != leader || "$domain" == localhost || -n "${PLATFORM_ALLOW_STATIC_UPSTREAMS:-}" ]] || v="$(cluster_upstreams NODE_LIBRECHAT_ADMIN_ORIGIN_HOST)" ;; esac
	printf '%s\n' "$v"
}
csv_has() {
	local c=",${1//[[:space:]]/},"
	[[ "$c" == *",$2,"* ]]
}
foundations() { [[ "$role" == leader ]] && sed -n 's/^FOUNDATION_LEADER=//p' "$policy" || sed -n 's/^FOUNDATION_FOLLOWER=//p' "$policy"; }
disabled_apps() { sed -n 's/^DISABLED_APPS=//p' "$policy"; }
app_dirs() { find "$root/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; | sort; }
app_placement() { sed -n 's/^PLACEMENT=//p' "$1/manifest.env" | tail -n1; }
app_active() { [[ "$(app_placement "$1")" == follower && "$role" == follower ]] && ! csv_has "$(disabled_apps)" "$(basename "$1")"; }
app_route_active() { [[ "$(app_placement "$1")" == follower ]] && { [[ "$role" == leader ]] || app_active "$1"; } && ! csv_has "$(disabled_apps)" "$(basename "$1")"; }
foundation_file() { case "$1" in caddy) echo caddy.yml ;; woodpecker-controller) echo woodpecker-controller.yml ;; woodpecker-worker) echo woodpecker-worker.yml ;; woodpecker-deployer) echo woodpecker-deployer.yml ;; beszel-controller) echo beszel-controller.yml ;; beszel-worker) echo beszel-worker.yml ;; esac }
foundation_env() { case "$1" in caddy) echo "$root/ops/foundation/caddy.env.example" ;; woodpecker-*) echo "$root/ops/foundation/woodpecker.env.example" ;; *) echo "$root/ops/foundation/beszel.env.example" ;; esac }
fc() {
	local n="$1"
	command=("${compose_bin[@]}" --env-file "$env_file" --env-file "$(foundation_env "$n")" --env-file "$image_foundation" --env-file "$node_config" -f "$root/compose/foundation/$(foundation_file "$n")")
}
ac() {
	local d="$1"
	command=("${compose_bin[@]}" --env-file "$env_file" --env-file "$node_config" --env-file "$image_apps" -p "$(sed -n 's/^COMPOSE_PROJECT=//p' "$d/manifest.env")" -f "$d/compose.yml")
}
render() {
	local s="$runtime/config" d a t
	rm -rf "$runtime"
	install -d -m700 "$s/routes.d"
	cp -a "$root/config/." "$s/"
	while IFS= read -r f; do while IFS= read -r k; do
		v="$(get "$k")"
		sed "s|{\$${k}}|${v//&/\\&}|g" "$f" >"$f.tmp"
		mv "$f.tmp" "$f"
	done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$f" | sed 's/[^A-Z0-9_]//g' | sort -u); done < <(find "$s" -type f -name '*.caddy' -print)
	while IFS= read -r d; do
		app_route_active "$d" || continue
		a="$(basename "$d")"
		[[ "$role" == leader ]] && t="$(sed -n 's/^ROUTE_TEMPLATE_LEADER=//p' "$d/manifest.env")" || t="$(sed -n 's/^ROUTE_TEMPLATE_FOLLOWER=//p' "$d/manifest.env")"
		cp "$d/$t" "$s/routes.d/$a.caddy"
		while IFS= read -r k; do
			v="$(get "$k")"
			sed "s|{\$${k}}|${v//&/\\&}|g" "$s/routes.d/$a.caddy" >"$s/routes.d/$a.caddy.tmp"
			mv "$s/routes.d/$a.caddy.tmp" "$s/routes.d/$a.caddy"
		done < <(grep -oE '\{\$[A-Z0-9_]+\}' "$s/routes.d/$a.caddy" | sed 's/[^A-Z0-9_]//g' | sort -u)
	done < <(app_dirs)
	[[ "$role" == leader ]] || rm -f "$s/foundation-routes.d/woodpecker.caddy" "$s/foundation-routes.d/woodpecker-grpc.caddy" "$s/foundation-routes.d/beszel.caddy"
}
base_env() { export CADDY_CONFIG_ROOT="$runtime/config" CADDY_DATA_ROOT="$runtime/data" CADDY_HTTP_BIND="$bind" CADDY_HTTPS_BIND="$bind" PLATFORM_EDGE_NETWORK="$(get PLATFORM_EDGE_NETWORK)"; }
validate() {
	base_env
	render
	fc caddy
	"${command[@]}" config --quiet
	while IFS= read -r n; do
		[[ "$n" == caddy ]] && continue
		fc "$n"
		"${command[@]}" config --quiet
	done < <(printf '%s\n' "$(foundations)" | tr ',' '\n' | sed '/^$/d')
	while IFS= read -r d; do
		app_active "$d" || continue
		ac "$d"
		"${command[@]}" config --quiet
	done < <(app_dirs)
	docker run --rm --pull=never --env-file "$env_file" -v "$runtime/config:/etc/caddy:ro" "$(sed -n 's/^CADDY_IMAGE=//p' "$image_foundation")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}
up() {
	validate
	base_env
	fc caddy
	"${command[@]}" up -d --pull never --wait --wait-timeout 180
	while IFS= read -r n; do
		[[ "$n" == caddy ]] && continue
		fc "$n"
		"${command[@]}" up -d --pull never --wait --wait-timeout 180
	done < <(printf '%s\n' "$(foundations)" | tr ',' '\n' | sed '/^$/d')
	while IFS= read -r d; do
		app_active "$d" || continue
		ac "$d"
		"${command[@]}" up -d --pull never --wait --wait-timeout 180
	done < <(app_dirs)
}
base_env
case "$action" in validate) validate ;; up | restart) up ;; down)
	for n in caddy woodpecker-controller woodpecker-worker woodpecker-deployer beszel-controller beszel-worker; do
		fc "$n"
		"${command[@]}" down --remove-orphans || true
	done
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
