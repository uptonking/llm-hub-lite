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
RECOVERY_GRACE_SECONDS="${RECOVERY_GRACE_SECONDS:-60}"

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

project_expected() {
  local name="$1" key token
  case "$name" in
    app) printf '3\n' ;;
    woodpecker) printf '2\n' ;;
    beszel)
      key="$(sed -n 's/^BESZEL_KEY_FILE=//p' "$BESZEL_ENV" | tail -n1)"
      token="$(sed -n 's/^BESZEL_TOKEN_FILE=//p' "$BESZEL_ENV" | tail -n1)"
      key="${key:-$BESZEL_ROOT/secrets/key}"
      token="${token:-$BESZEL_ROOT/secrets/token}"
      [[ -s "$key" && -s "$token" ]] && printf '2\n' || printf '1\n'
      ;;
  esac
}

project_ids() {
  case "$1" in
    app) "${app_compose[@]}" ps -q ;;
    woodpecker) "${woodpecker_compose[@]}" ps -q ;;
    beszel) "${beszel_compose[@]}" ps -q ;;
  esac
}

project_is_healthy() {
  local name="$1" expected ids count id state
  expected="$(project_expected "$name")"
  ids="$(project_ids "$name")"
  count="$(grep -c . <<<"$ids" || true)"
  (( count == expected )) || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
    [[ "$state" == 'running healthy' || "$state" == 'running none' ]] || return 1
  done <<<"$ids"
}

reconcile_project() {
  local name="$1" waited=0 ids
  ensure_network
  if project_is_healthy "$name"; then return 0; fi
  ids="$(project_ids "$name")"
  if [[ -n "$ids" ]]; then
    while (( waited < RECOVERY_GRACE_SECONDS )); do
      sleep 5
      waited=$((waited + 5))
      if project_is_healthy "$name"; then return 0; fi
    done
  fi
  "start_${name}"
}

validate() {
  need_file "$APP_ENV"; need_file "$APP_RUNTIME/docker-compose.yml"; need_file "$APP_RUNTIME/docker-compose.prod.yml"
  "${app_compose[@]}" config --quiet
  if [[ -f "$WOODPECKER_ENV" && -f "$woodpecker_file" ]]; then "${woodpecker_compose[@]}" config --quiet; fi
  if [[ -f "$BESZEL_ENV" && -f "$BESZEL_ROOT/docker-compose.yml" ]]; then "${beszel_compose[@]}" config --quiet; fi
}

health() {
  local failed=0 name
  for name in beszel woodpecker app; do
    if ! status_project "$name"; then
      failed=1
      continue
    fi
    project_is_healthy "$name" || { printf '%s: one or more services are missing or unhealthy\n' "$name" >&2; failed=1; }
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
  reconcile_project beszel
  reconcile_project woodpecker
  reconcile_project app
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
  reconcile)
    case "${2:-all}" in all) recover ;; app|woodpecker|beszel) reconcile_project "$2" ;; *) die "unknown project: $2" ;; esac
    ;;
  upgrade) upgrade ;;
  backup) backup "$@" ;;
  restore)
    [[ -n "${2:-}" ]] || die 'restore requires a snapshot id or latest'
    "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "$2"
    ;;
  logs)
    case "${2:-app}" in app) "${app_compose[@]}" logs --tail 200 ;; woodpecker) "${woodpecker_compose[@]}" logs --tail 200 ;; beszel) "${beszel_compose[@]}" logs --tail 200 ;; *) die "unknown project: $2" ;; esac
    ;;
  *) die 'usage: platformctl {ensure-network|validate|status|start|restart|stop|reconcile|recover|upgrade|backup|restore|logs} [project]' ;;
esac
