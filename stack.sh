#!/usr/bin/env bash
# shellcheck disable=SC2155
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-dev}"
action="${2:-up}"
shift || true
shift || true

case "$mode" in
  dev)
    env_file="${STACK_ENV_FILE:-$script_dir/.env.dev}"
    image_env_file="${STACK_IMAGE_ENV_FILE:-}"
    runtime_root="${STACK_RUNTIME_ROOT:-$script_dir/.runtime/dev}"
    caddy_bind="127.0.0.1"
    ;;
  prod)
    env_file="${STACK_ENV_FILE:-$script_dir/.env.prod}"
    image_env_file="${STACK_IMAGE_ENV_FILE:-$script_dir/ops/images.apps.prod.env}"
    foundation_image_env_file="${STACK_FOUNDATION_IMAGE_ENV_FILE:-$script_dir/ops/images.foundation.prod.env}"
    runtime_root="${STACK_RUNTIME_ROOT:-$script_dir/.runtime/prod}"
    caddy_bind="0.0.0.0"
    ;;
  *) printf 'Usage: %s {dev|prod} {up|down|restart|validate|config|logs|ps}\n' "$0" >&2; exit 2 ;;
esac

[[ -f "$env_file" ]] || { printf 'Missing environment file: %s\n' "$env_file" >&2; exit 1; }
if [[ -n "$image_env_file" ]]; then [[ -f "$image_env_file" ]] || { printf 'Missing image manifest: %s\n' "$image_env_file" >&2; exit 1; }; fi
if [[ -n "${foundation_image_env_file:-}" ]]; then [[ -f "$foundation_image_env_file" ]] || { printf 'Missing foundation image manifest: %s\n' "$foundation_image_env_file" >&2; exit 1; }; fi

compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then compose_bin=("$PLATFORM_COMPOSE_BIN"); elif [[ -x /usr/local/bin/platform-compose ]]; then compose_bin=(/usr/local/bin/platform-compose); fi

read_env() { local key="$1"; sed -n "s/^${key}=//p" "$env_file" | tail -n1; }
read_image() { local key="$1" file="${foundation_image_env_file:-$image_env_file}"; sed -n "s/^${key}=//p" "$file" | tail -n1; }
disabled() { local key="$1" value; value="$(read_env "$key")"; [[ "$value" == true || "$value" == TRUE || "$value" == 1 ]]; }
ensure_network() { local network_name="$(read_env PLATFORM_EDGE_NETWORK)"; network_name="${network_name:-platform_edge}"; docker network inspect "$network_name" >/dev/null 2>&1 || docker network create "$network_name" >/dev/null; }

render_config() {
  local config_root="$runtime_root/config"
  install -d -m 700 "$runtime_root/data" "$config_root/routes.d"
  find "$config_root" -mindepth 1 -delete
  cp -a "$script_dir/config/." "$config_root/"
  install -d -m 700 "$config_root/routes.d"
  local escaped_value
  for app in newapi cliproxyapi; do
    local output="$config_root/routes.d/$app.caddy"
    cp "$script_dir/apps/$app/route.caddy" "$output"
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$env_file")
  done
}

base_env=(--env-file "$env_file")
if [[ -n "$image_env_file" ]]; then base_env+=(--env-file "$image_env_file"); fi
if [[ -n "${foundation_image_env_file:-}" ]]; then base_env+=(--env-file "$foundation_image_env_file"); fi
export CADDY_CONFIG_ROOT="$runtime_root/config" CADDY_DATA_ROOT="$runtime_root/data" CADDY_HTTP_BIND="$caddy_bind" CADDY_HTTPS_BIND="$caddy_bind"
caddy_compose=("${compose_bin[@]}" "${base_env[@]}" -f "$script_dir/compose/foundation/caddy.yml")
run_app() { local app="$1"; shift; local -a command=("${compose_bin[@]}" "${base_env[@]}" -f "$script_dir/apps/$app/compose.yml"); "${command[@]}" "$@"; }

validate() {
  render_config; ensure_network
  "${caddy_compose[@]}" config --quiet
  for app in newapi cliproxyapi; do run_app "$app" config --quiet; done
  docker run --rm --env-file "$env_file" -v "$CADDY_CONFIG_ROOT:/etc/caddy:ro" "$(read_image CADDY_IMAGE)" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

up() {
  render_config; ensure_network
  for app in newapi cliproxyapi; do
    local toggle
    case "$app" in newapi) toggle=APP_NEWAPI_DISABLE ;; cliproxyapi) toggle=APP_CLIPROXYAPI_DISABLE ;; esac
    if disabled "$toggle"; then run_app "$app" down --remove-orphans; else run_app "$app" up -d --pull never --wait --wait-timeout 180 "$@"; fi
  done
  "${caddy_compose[@]}" up -d --wait --wait-timeout 180 "$@"
}

case "$action" in
  validate) validate ;;
  config) validate; "${caddy_compose[@]}" config "$@" ;;
  up|start) up "$@" ;;
  restart) for app in newapi cliproxyapi; do run_app "$app" restart || true; done; "${caddy_compose[@]}" restart ;;
  down) "${caddy_compose[@]}" down --remove-orphans; for app in newapi cliproxyapi; do run_app "$app" down --remove-orphans; done ;;
  logs|ps) "${caddy_compose[@]}" "$action" "$@"; for app in newapi cliproxyapi; do run_app "$app" "$action" "$@"; done ;;
  *) printf 'Unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
