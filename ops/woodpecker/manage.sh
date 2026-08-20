#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="${WOODPECKER_ENV_FILE:-/opt/platform/woodpecker/.env}"
action="${1:-status}"

[[ -f "$env_file" ]] || {
  printf 'Missing Woodpecker environment file: %s\n' "$env_file" >&2
  exit 1
}

compose=(docker compose --env-file "$env_file" -f "$script_dir/docker-compose.yml")

case "$action" in
  validate)
    "${compose[@]}" config --quiet
    ;;
  up)
    docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null
    "${compose[@]}" up -d
    ;;
  upgrade)
    data_root="$(sed -n 's/^WOODPECKER_DATA_ROOT=//p' "$env_file" | tail -n 1)"
    [[ "$data_root" == /opt/platform/woodpecker/* ]] || {
      printf 'Unsafe WOODPECKER_DATA_ROOT: %s\n' "$data_root" >&2
      exit 1
    }
    backup_dir="$(dirname "$data_root")/backups"
    install -d -m 700 "$backup_dir"
    backup="$backup_dir/woodpecker-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
    tar -czf "$backup" -C "$(dirname "$data_root")" "$(basename "$data_root")"
    "${compose[@]}" pull
    "${compose[@]}" up -d
    printf 'Woodpecker upgraded; backup: %s\n' "$backup"
    ;;
  restart)
    "${compose[@]}" up -d --force-recreate
    ;;
  logs)
    "${compose[@]}" logs -f --tail 200
    ;;
  status)
    "${compose[@]}" ps
    ;;
  *)
    printf 'Usage: %s {validate|up|upgrade|restart|logs|status}\n' "$0" >&2
    exit 2
    ;;
esac
