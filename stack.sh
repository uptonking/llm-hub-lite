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

foundation_env_root="${STACK_FOUNDATION_ENV_ROOT:-$script_dir/ops/foundation}"
foundation_env_file() {
  local name="$1" candidate
  candidate="$foundation_env_root/$name.env"
  [[ -f "$candidate" ]] || candidate="$foundation_env_root/$name.env.example"
  [[ -f "$candidate" ]] || { printf 'Missing foundation environment file: %s/{%s.env,%s.env.example}\n' "$foundation_env_root" "$name" "$name" >&2; exit 1; }
  printf '%s\n' "$candidate"
}

[[ -f "$env_file" ]] || { printf 'Missing environment file: %s\n' "$env_file" >&2; exit 1; }
if [[ -n "$image_env_file" ]]; then [[ -f "$image_env_file" ]] || { printf 'Missing image manifest: %s\n' "$image_env_file" >&2; exit 1; }; fi
if [[ -n "${foundation_image_env_file:-}" ]]; then [[ -f "$foundation_image_env_file" ]] || { printf 'Missing foundation image manifest: %s\n' "$foundation_image_env_file" >&2; exit 1; }; fi

compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then compose_bin=("$PLATFORM_COMPOSE_BIN"); elif [[ -x /usr/local/bin/platform-compose ]]; then compose_bin=(/usr/local/bin/platform-compose); fi

read_env() { local key="$1"; sed -n "s/^${key}=//p" "$env_file" | tail -n1; }
read_image() {
  local key="$1" file="${foundation_image_env_file:-$image_env_file}" value
  if [[ -n "$file" && -f "$file" ]]; then
    value="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
  else
    value="$(read_env "$key")"
  fi
  printf '%s\n' "$value"
}
disabled() { local key="$1" value; value="$(read_env "$key")"; [[ "$value" == true || "$value" == TRUE || "$value" == 1 ]]; }
app_disabled() {
  local descriptor="$1" key value
  key="$(sed -n 's/^DISABLE_ENV=//p' "$descriptor/manifest.env" | tail -n1)"
  value="$(read_env "$key")"
  [[ -n "$value" ]] || value="$(sed -n 's/^DEFAULT_DISABLED=//p' "$descriptor/manifest.env" | tail -n1)"
  [[ "$value" == true || "$value" == TRUE || "$value" == 1 ]]
}
validate_descriptor_paths() {
  local descriptor="$1" key value version
  version="$(sed -n 's/^MANIFEST_VERSION=//p' "$descriptor/manifest.env" | tail -n1)"
  [[ "$version" == 1 ]] || { printf 'Unsupported MANIFEST_VERSION in %s\n' "$descriptor" >&2; exit 1; }
  for key in COMPOSE_FILE ROUTE_TEMPLATE; do
    value="$(sed -n "s/^${key}=//p" "$descriptor/manifest.env" | tail -n1)"
    [[ "$value" != /* && "$value" != *..* && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { printf 'Invalid %s in %s\n' "$key" "$descriptor" >&2; exit 1; }
  done
}
ensure_network() { local network_name="$(read_env PLATFORM_EDGE_NETWORK)"; network_name="${network_name:-platform_edge}"; docker network inspect "$network_name" >/dev/null 2>&1 || docker network create "$network_name" >/dev/null; }

render_config() {
  local config_root="$runtime_root/config" staged="$runtime_root/.config.staging.$$" descriptor app output key value escaped_value existing active_ids relative
  install -d -m 700 "$runtime_root/data" "$runtime_root"
  rm -rf -- "$staged"
  install -d -m 700 "$staged/routes.d"
  cp -a "$script_dir/config/." "$staged/"
  install -d -m 700 "$staged/routes.d.disabled"
  active_ids=""
  while IFS= read -r descriptor; do
    app_disabled "$descriptor" || active_ids="$active_ids $(basename "$descriptor")"
  done < <(app_descriptors)
  if [[ -d "$config_root/routes.d" ]]; then
    while IFS= read -r existing; do
      [[ -f "$existing" ]] || continue
      app="$(basename "$existing" .caddy)"
      case " $active_ids " in *" $app "*) ;; *) cp "$existing" "$staged/routes.d.disabled/$app.caddy" ;; esac
    done < <(find "$config_root/routes.d" -mindepth 1 -maxdepth 1 -type f -name '*.caddy' -print 2>/dev/null)
  fi
  while IFS= read -r output; do
    [[ -f "$output" ]] || continue
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$env_file")
  done < <(find "$staged" -type f -name '*.caddy' -print | sort)
  while IFS= read -r descriptor; do
    app_disabled "$descriptor" && continue
    app="$(basename "$descriptor")"; output="$staged/routes.d/$app.caddy"
    cp "$descriptor/$(sed -n 's/^ROUTE_TEMPLATE=//p' "$descriptor/manifest.env" | tail -n1)" "$output"
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$env_file")
  done < <(app_descriptors)
  disabled SERVICE_WOODPECKER_DISABLE && rm -f -- "$staged/foundation-routes.d/woodpecker.caddy"
  disabled SERVICE_BESZEL_DISABLE && rm -f -- "$staged/foundation-routes.d/beszel.caddy"
  # Keep the bind-mounted directory stable; validate the staged tree before
  # replacing its contents so a bad change cannot erase the live config.
  validate_config_dir "$staged"
  install -d -m 700 "$config_root"
  while IFS= read -r output; do
    relative="${output#"$staged/"}"
    install -d -m 700 "$config_root/$(dirname "$relative")"
    cp "$output" "$config_root/$relative.tmp"
    mv -f -- "$config_root/$relative.tmp" "$config_root/$relative"
  done < <(find "$staged" -type f -print)
  while IFS= read -r output; do
    relative="${output#"$config_root/"}"
    [[ -e "$staged/$relative" ]] || rm -rf -- "$output"
  done < <(find "$config_root" -mindepth 1 -print)
  rm -rf -- "$staged"
}

validate_config_dir() {
  local config_dir="$1"
  docker run --rm --pull=never --env-file "$env_file" -v "$config_dir:/etc/caddy:ro" "$(read_image CADDY_IMAGE)" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

base_env=(--env-file "$env_file")
if [[ -n "$image_env_file" ]]; then base_env+=(--env-file "$image_env_file"); fi
if [[ -n "${foundation_image_env_file:-}" ]]; then base_env+=(--env-file "$foundation_image_env_file"); fi
base_env+=(--env-file "$(foundation_env_file caddy)" --env-file "$(foundation_env_file woodpecker)" --env-file "$(foundation_env_file beszel)")
export CADDY_CONFIG_ROOT="$runtime_root/config" CADDY_DATA_ROOT="$runtime_root/data" CADDY_HTTP_BIND="$caddy_bind" CADDY_HTTPS_BIND="$caddy_bind"
caddy_compose=("${compose_bin[@]}" "${base_env[@]}" -f "$script_dir/compose/foundation/caddy.yml")
foundation_compose() { local name="$1"; foundation_command=("${compose_bin[@]}" "${base_env[@]}" -f "$script_dir/compose/foundation/$name.yml"); }
run_app() {
  local app="$1"; shift
  local project
  project="$(sed -n 's/^COMPOSE_PROJECT=//p' "$script_dir/apps/$app/manifest.env" | tail -n1)"
  local -a command=("${compose_bin[@]}" "${base_env[@]}" -p "$project" -f "$script_dir/apps/$app/compose.yml")
  "${command[@]}" "$@"
}

validate() {
  while IFS= read -r descriptor; do validate_descriptor_paths "$descriptor"; done < <(app_descriptors)
  render_config; ensure_network
  "${caddy_compose[@]}" config --quiet
  foundation_compose woodpecker; "${foundation_command[@]}" config --quiet
  foundation_compose beszel; "${foundation_command[@]}" config --quiet
  while IFS= read -r descriptor; do run_app "$(basename "$descriptor")" config --quiet; done < <(app_descriptors)
  validate_config_dir "$CADDY_CONFIG_ROOT"
}

up() {
  render_config; ensure_network
  foundation_compose caddy; "${foundation_command[@]}" up -d --pull never --wait --wait-timeout 180
  if disabled SERVICE_WOODPECKER_DISABLE; then foundation_compose woodpecker; "${foundation_command[@]}" down --remove-orphans; else foundation_compose woodpecker; "${foundation_command[@]}" up -d --pull never --wait --wait-timeout 180; fi
  foundation_compose beszel
  if disabled SERVICE_BESZEL_DISABLE; then
    "${foundation_command[@]}" down --remove-orphans
  else
    beszel_key_file="$(sed -n 's/^BESZEL_KEY_FILE=//p' "$(foundation_env_file beszel)" | tail -n1)"
    beszel_token_file="$(sed -n 's/^BESZEL_TOKEN_FILE=//p' "$(foundation_env_file beszel)" | tail -n1)"
    if [[ -s "$beszel_key_file" && -s "$beszel_token_file" ]]; then
      "${foundation_command[@]}" up -d --pull never --wait --wait-timeout 180
    else
      "${foundation_command[@]}" up -d --pull never --wait --wait-timeout 180 beszel-hub beszel-socket-proxy
    fi
  fi
  while IFS= read -r descriptor; do
    app="$(basename "$descriptor")"
    if app_disabled "$descriptor"; then run_app "$app" down --remove-orphans; else run_app "$app" up -d --pull never --wait --wait-timeout 180 "$@"; fi
  done < <(find "$script_dir/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; | sort)
}

app_descriptors() { find "$script_dir/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env -exec dirname {} \; | sort; }

case "$action" in
  validate) validate ;;
  config) validate; "${caddy_compose[@]}" config "$@" ;;
  up|start) up "$@" ;;
  restart) up; ;;
  down) for foundation in caddy woodpecker beszel; do foundation_compose "$foundation"; "${foundation_command[@]}" down --remove-orphans; done; while IFS= read -r descriptor; do run_app "$(basename "$descriptor")" down --remove-orphans; done < <(app_descriptors) ;;
  logs|ps) for foundation in caddy woodpecker beszel; do foundation_compose "$foundation"; "${foundation_command[@]}" "$action" "$@"; done; while IFS= read -r descriptor; do run_app "$(basename "$descriptor")" "$action" "$@"; done < <(app_descriptors) ;;
  *) printf 'Unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
