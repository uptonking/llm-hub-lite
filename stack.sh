#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-dev}"
action="${2:-up}"
if [[ $# -ge 1 ]]; then shift; fi
if [[ $# -ge 1 ]]; then shift; fi

case "$mode" in
  dev)
    env_file="${STACK_ENV_FILE:-.env.dev}"
    overlay="docker-compose.dev.yml"
    ;;
  prod)
    env_file="${STACK_ENV_FILE:-.env.prod}"
    image_env_file="${STACK_IMAGE_ENV_FILE:-ops/images.prod.env}"
    overlay="docker-compose.prod.yml"
    ;;
  *)
    printf 'Usage: %s {dev|prod} {up|down|restart|pull|validate|config|reload|logs|ps} [compose args]\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "$env_file" != /* ]]; then
  env_file="$script_dir/$env_file"
fi
if [[ ! -f "$env_file" ]]; then
  printf 'Missing %s. Copy the matching environment example first.\n' "$env_file" >&2
  exit 1
fi

compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then
  compose_bin=("$PLATFORM_COMPOSE_BIN")
elif [[ -x /usr/local/bin/platform-compose ]]; then
  compose_bin=(/usr/local/bin/platform-compose)
fi

compose_env_args=(--env-file "$env_file")
if [[ "$mode" == prod ]]; then
  if [[ "$image_env_file" != /* ]]; then
    image_env_file="$script_dir/$image_env_file"
  fi
  [[ -f "$image_env_file" ]] || { printf 'Missing production image manifest: %s\n' "$image_env_file" >&2; exit 1; }
  compose_env_args+=(--env-file "$image_env_file")
fi

read_env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$env_file" | tail -n 1
}

if [[ "$mode" == prod ]]; then
  for key in DOMAIN_NAME SSL_EMAIL NEW_API_SITE CLIPROXY_SITE WOODPECKER_SITE BESZEL_SITE SESSION_COOKIE_TRUSTED_URL DATA_ROOT NEW_API_SESSION_SECRET CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY; do
    value="$(read_env_value "$key")"
    if [[ -z "$value" || "$value" == replace-with-* || "$value" == example.com || "$value" == admin@example.com || "$value" == ./data/dev || "$value" == https://newapi.example.com || "$value" == https://cpa.example.com || "$value" == https://newapi.localhost || "$value" == https://cpa.localhost || "$value" == https://*example.invalid ]]; then
      printf '%s must be set to a real value in %s\n' "$key" "$env_file" >&2
      exit 1
    fi
  done
  for key in NEW_API_SITE CLIPROXY_SITE WOODPECKER_SITE BESZEL_SITE SESSION_COOKIE_TRUSTED_URL; do
    value="$(read_env_value "$key")"
    if [[ "$value" != https://* ]]; then
      printf '%s must start with https:// in %s\n' "$key" "$env_file" >&2
      exit 1
    fi
  done
  for key in CADDY_IMAGE NEW_API_IMAGE CLIPROXY_IMAGE; do
    value="$(read_env_value "$key")"
    if [[ ! "$value" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf '%s must use an immutable sha256 digest in %s\n' "$key" "$env_file" >&2
      exit 1
    fi
  done
  data_root="$(read_env_value DATA_ROOT)"
  if [[ "$data_root" != /* ]]; then
    printf 'DATA_ROOT must be an absolute path in %s\n' "$env_file" >&2
    exit 1
  fi
fi

compose=("${compose_bin[@]}" "${compose_env_args[@]}" -f "$script_dir/docker-compose.base.yml" -f "$script_dir/$overlay")

case "$action" in
  validate)
    "${compose[@]}" config --quiet
    ;;
  config)
    if [[ "$mode" == prod ]]; then
      printf 'Use "%s prod validate" for production; refusing to print interpolated secrets.\n' "$0" >&2
      exit 2
    fi
    "${compose[@]}" config "$@"
    ;;
  reload)
    "${compose[@]}" exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    "${compose[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    ;;
  up|start|restart)
    network_name="$(read_env_value SHARED_NETWORK_NAME)"
    network_name="${network_name:-shared_network}"
    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
      docker network create "$network_name" >/dev/null
    fi
    if [[ "$action" == restart ]]; then
      "${compose[@]}" up -d --wait "$@"
    elif [[ "$action" == up ]]; then
      "${compose[@]}" up -d --wait "$@"
    else
      "${compose[@]}" "$action" "$@"
    fi
    ;;
  down|pull|logs|ps|stop)
    "${compose[@]}" "$action" "$@"
    ;;
  *)
    printf 'Unknown action: %s\n' "$action" >&2
    printf 'Usage: %s {dev|prod} {up|down|restart|pull|validate|config|reload|logs|ps} [compose args]\n' "$0" >&2
    exit 2
    ;;
esac
