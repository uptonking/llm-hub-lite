#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
APP_RUNTIME="${APP_RUNTIME:-$APP_ROOT/shared/runtime}"
WOODPECKER_ROOT="${WOODPECKER_ROOT:-$PLATFORM_ROOT/woodpecker}"
BESZEL_ROOT="${BESZEL_ROOT:-$PLATFORM_ROOT/beszel}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.production}"
WOODPECKER_ENV="${WOODPECKER_ENV:-$WOODPECKER_ROOT/.env}"
BESZEL_ENV="${BESZEL_ENV:-$BESZEL_ROOT/.env}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/llm-hub-lite-bootstrap}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
LOCK_WAIT="${PLATFORM_LOCK_WAIT:-300}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-180}"

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w "$LOCK_WAIT" 9 || { printf 'timed out waiting for another platform operation\n' >&2; exit 75; }

die() { printf 'platformctl: %s\n' "$*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }

app_compose=(docker compose --env-file "$APP_ENV" -f "$APP_RUNTIME/docker-compose.yml" -f "$APP_RUNTIME/docker-compose.prod.yml")
woodpecker_file="$WOODPECKER_ROOT/docker-compose.yml"
[[ -f "$woodpecker_file" ]] || woodpecker_file="$SOURCE_ROOT/ops/woodpecker/docker-compose.yml"
woodpecker_compose=(docker compose --env-file "$WOODPECKER_ENV" -f "$woodpecker_file")
beszel_compose=(docker compose --env-file "$BESZEL_ENV" -f "$BESZEL_ROOT/docker-compose.yml")

ensure_network() {
  docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null
}

compose_up() {
  local -n cmd=$1
  shift
  local attempt delay
  for attempt in 1 2 3; do
    if "${cmd[@]}" up -d --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then
      return 0
    fi
    delay=$((attempt * 5))
    printf 'Compose start failed (attempt %s/3); retrying in %s seconds\n' "$attempt" "$delay" >&2
    sleep "$delay"
  done
  return 1
}

start_beszel() {
  need_file "$BESZEL_ENV"
  need_file "$BESZEL_ROOT/docker-compose.yml"
  ensure_network
  local key token
  key="$(sed -n 's/^BESZEL_KEY_FILE=//p' "$BESZEL_ENV" | tail -n1)"
  token="$(sed -n 's/^BESZEL_TOKEN_FILE=//p' "$BESZEL_ENV" | tail -n1)"
  key="${key:-$BESZEL_ROOT/secrets/key}"
  token="${token:-$BESZEL_ROOT/secrets/token}"
  if [[ -s "$key" && -s "$token" ]]; then
    compose_up beszel_compose
  else
    printf 'Beszel hub only: populate %s and %s to enable the agent\n' "$key" "$token" >&2
    compose_up beszel_compose beszel-hub
  fi
}

start_woodpecker() {
  need_file "$WOODPECKER_ENV"
  ensure_network
  compose_up woodpecker_compose
}

start_app() {
  need_file "$APP_ENV"
  need_file "$APP_RUNTIME/docker-compose.yml"
  ensure_network
  compose_up app_compose
}

stop_project() {
  local name="$1"
  case "$name" in
    app) "${app_compose[@]}" stop ;;
    woodpecker) "${woodpecker_compose[@]}" stop ;;
    beszel) "${beszel_compose[@]}" stop ;;
    all)
      stop_project app
      stop_project woodpecker
      stop_project beszel
      ;;
    *) die "unknown project: $name" ;;
  esac
}

status_project() {
  local name="$1"
  case "$name" in
    app)
      [[ -f "$APP_ENV" && -f "$APP_RUNTIME/docker-compose.yml" ]] || { printf 'app: not configured\n'; return 1; }
      "${app_compose[@]}" ps
      ;;
    woodpecker)
      [[ -f "$WOODPECKER_ENV" && -f "$woodpecker_file" ]] || { printf 'woodpecker: not configured\n'; return 1; }
      "${woodpecker_compose[@]}" ps
      ;;
    beszel)
      [[ -f "$BESZEL_ENV" && -f "$BESZEL_ROOT/docker-compose.yml" ]] || { printf 'beszel: not configured\n'; return 1; }
      "${beszel_compose[@]}" ps
      ;;
    *) die "unknown project: $name" ;;
  esac
}

validate() {
  need_file "$APP_ENV"; need_file "$APP_RUNTIME/docker-compose.yml"; need_file "$APP_RUNTIME/docker-compose.prod.yml"
  "${app_compose[@]}" config --quiet
  if [[ -f "$WOODPECKER_ENV" && -f "$woodpecker_file" ]]; then "${woodpecker_compose[@]}" config --quiet; fi
  if [[ -f "$BESZEL_ENV" && -f "$BESZEL_ROOT/docker-compose.yml" ]]; then "${beszel_compose[@]}" config --quiet; fi
}

health() {
  local failed=0 name expected running key token id state
  for name in beszel woodpecker app; do
    if ! status_project "$name"; then
      failed=1
      continue
    fi
    case "$name" in
      app) expected=3; running="$("${app_compose[@]}" ps --status running -q | wc -l)" ;;
      woodpecker) expected=2; running="$("${woodpecker_compose[@]}" ps --status running -q | wc -l)" ;;
      beszel)
        key="$(sed -n 's/^BESZEL_KEY_FILE=//p' "$BESZEL_ENV" | tail -n1)"
        token="$(sed -n 's/^BESZEL_TOKEN_FILE=//p' "$BESZEL_ENV" | tail -n1)"
        key="${key:-$BESZEL_ROOT/secrets/key}"
        token="${token:-$BESZEL_ROOT/secrets/token}"
        [[ -s "$key" && -s "$token" ]] && expected=2 || expected=1
        running="$("${beszel_compose[@]}" ps --status running -q | wc -l)"
        ;;
    esac
    if (( running != expected )); then
      printf '%s: expected %s running services, found %s\n' "$name" "$expected" "$running" >&2
      failed=1
    fi
    case "$name" in
      app) ids="$("${app_compose[@]}" ps -q)" ;;
      woodpecker) ids="$("${woodpecker_compose[@]}" ps -q)" ;;
      beszel) ids="$("${beszel_compose[@]}" ps -q)" ;;
    esac
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
      if [[ "$state" != 'running healthy' && "$state" != 'running none' ]]; then
        printf '%s: container %s state is %s\n' "$name" "$id" "$state" >&2
        failed=1
      fi
    done <<<"$ids"
  done
  return "$failed"
}

start_all() {
  start_beszel
  start_woodpecker
  start_app
}

recover() {
  validate
  ensure_network
  start_all
  health
}

backup() {
  "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-manual}"
}

upgrade() {
  backup upgrade
  "${beszel_compose[@]}" pull
  "${woodpecker_compose[@]}" pull
  "${app_compose[@]}" pull
  recover
}

case "${1:-status}" in
  ensure-network) ensure_network ;;
  validate) validate ;;
  status) [[ "${2:-}" == "--json" ]] && docker ps --format '{{json .}}' || health ;;
  start)
    case "${2:-all}" in all) start_all ;; app|woodpecker|beszel) "start_${2}" ;; *) die "unknown project: $2" ;; esac ;;
  restart)
    case "${2:-all}" in all) start_all ;; app|woodpecker|beszel) "start_${2}" ;; *) die "unknown project: $2" ;; esac ;;
  stop) stop_project "${2:-all}" ;;
  recover) recover ;;
  upgrade) upgrade ;;
  backup) backup "$@" ;;
  restore)
    [[ -n "${2:-}" ]] || die 'restore requires a snapshot id or latest'
    "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "$2"
    ;;
  logs)
    case "${2:-app}" in app) "${app_compose[@]}" logs --tail 200 ;; woodpecker) "${woodpecker_compose[@]}" logs --tail 200 ;; beszel) "${beszel_compose[@]}" logs --tail 200 ;; *) die "unknown project: $2" ;; esac
    ;;
  *) die 'usage: platformctl {ensure-network|validate|status|start|restart|stop|recover|upgrade|backup|restore|logs} [project]' ;;
esac
