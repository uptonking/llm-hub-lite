#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
APP_RUNTIME="${APP_RUNTIME:-$APP_ROOT/shared/runtime}"
WOODPECKER_ROOT="${WOODPECKER_ROOT:-$PLATFORM_ROOT/woodpecker}"
BESZEL_ROOT="${BESZEL_ROOT:-$PLATFORM_ROOT/beszel}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
WOODPECKER_ENV="${WOODPECKER_ENV:-$WOODPECKER_ROOT/.env}"
BESZEL_ENV="${BESZEL_ENV:-$BESZEL_ROOT/.env}"
SOURCE_ROOT="${SOURCE_ROOT:-$PLATFORM_ROOT/llm-hub-lite-bootstrap}"
IMAGE_ENV="${PLATFORM_IMAGE_ENV:-/etc/llm-hub-lite/images.env}"
PREVIOUS_IMAGE_ENV="${PLATFORM_PREVIOUS_IMAGE_ENV:-/etc/llm-hub-lite/images.previous.env}"
IMAGE_HISTORY_ROOT="${PLATFORM_IMAGE_HISTORY_ROOT:-/etc/llm-hub-lite/image-history}"
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-/etc/llm-hub-lite/maintenance}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
LOCK_WAIT="${PLATFORM_LOCK_WAIT:-300}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-180}"
RECOVERY_GRACE_SECONDS="${RECOVERY_GRACE_SECONDS:-90}"

die() { printf 'platformctl: %s\n' "$*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }

compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then
  compose_bin=("$PLATFORM_COMPOSE_BIN")
elif [[ -x /usr/local/bin/platform-compose ]]; then
  compose_bin=(/usr/local/bin/platform-compose)
fi

app_compose=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$IMAGE_ENV" -f "$APP_RUNTIME/docker-compose.base.yml" -f "$APP_RUNTIME/docker-compose.prod.yml")
woodpecker_file="$WOODPECKER_ROOT/docker-compose.yml"
[[ -f "$woodpecker_file" ]] || woodpecker_file="$SOURCE_ROOT/ops/woodpecker/docker-compose.yml"
woodpecker_compose=("${compose_bin[@]}" --env-file "$WOODPECKER_ENV" --env-file "$IMAGE_ENV" -f "$woodpecker_file")
beszel_compose=("${compose_bin[@]}" --env-file "$BESZEL_ENV" --env-file "$IMAGE_ENV" -f "$BESZEL_ROOT/docker-compose.yml")

acquire_lock() {
  [[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return 0
  install -d -m 700 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -w "$LOCK_WAIT" 9 || die 'timed out waiting for another platform operation'
  export PLATFORM_LOCK_HELD=1
}

ensure_network() {
  docker network inspect shared_network >/dev/null 2>&1 || docker network create shared_network >/dev/null
}

validate_image_manifest() {
  local file="$1" key value
  need_file "$file"
  for key in CADDY_IMAGE NEW_API_IMAGE CLIPROXY_IMAGE WOODPECKER_SERVER_IMAGE WOODPECKER_AGENT_IMAGE BESZEL_HUB_IMAGE BESZEL_AGENT_IMAGE BESZEL_SOCKET_PROXY_IMAGE; do
    value="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
    [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] || die "$key must be digest-pinned in $file"
  done
}

validate() {
  need_file "$APP_ENV"
  need_file "$IMAGE_ENV"
  need_file "$APP_RUNTIME/docker-compose.base.yml"
  need_file "$APP_RUNTIME/docker-compose.prod.yml"
  validate_image_manifest "$IMAGE_ENV"
  "${app_compose[@]}" config --quiet
  if [[ -f "$WOODPECKER_ENV" && -f "$woodpecker_file" ]]; then "${woodpecker_compose[@]}" config --quiet; fi
  if [[ -f "$BESZEL_ENV" && -f "$BESZEL_ROOT/docker-compose.yml" ]]; then "${beszel_compose[@]}" config --quiet; fi
}

beszel_agent_ready() {
  local key token
  key="$(sed -n 's/^BESZEL_KEY_FILE=//p' "$BESZEL_ENV" | tail -n1)"
  token="$(sed -n 's/^BESZEL_TOKEN_FILE=//p' "$BESZEL_ENV" | tail -n1)"
  key="${key:-$BESZEL_ROOT/secrets/key}"
  token="${token:-$BESZEL_ROOT/secrets/token}"
  [[ -s "$key" && -s "$token" ]]
}

project_expected() {
  case "$1" in
    app) printf '3\n' ;;
    woodpecker) printf '2\n' ;;
    beszel) beszel_agent_ready && printf '3\n' || printf '1\n' ;;
    *) die "unknown project: $1" ;;
  esac
}

project_ids() {
  case "$1" in
    app) "${app_compose[@]}" ps --all -q ;;
    woodpecker) "${woodpecker_compose[@]}" ps --all -q ;;
    beszel) "${beszel_compose[@]}" ps --all -q ;;
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

wait_project() {
  local name="$1" timeout="${2:-$COMPOSE_WAIT_TIMEOUT}" elapsed=0
  while (( elapsed < timeout )); do
    project_is_healthy "$name" && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

compose_up() {
  local -n cmd=$1
  shift
  local attempt delay
  for attempt in 1 2 3; do
    if "${cmd[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" "$@"; then return 0; fi
    delay=$((attempt * 5))
    printf 'Compose start failed (attempt %s/3); retrying in %s seconds\n' "$attempt" "$delay" >&2
    sleep "$delay"
  done
  return 1
}

start_project() {
  ensure_network
  case "$1" in
    app) compose_up app_compose ;;
    woodpecker) compose_up woodpecker_compose ;;
    beszel)
      if beszel_agent_ready; then compose_up beszel_compose; else compose_up beszel_compose beszel-hub; fi
      ;;
    *) die "unknown project: $1" ;;
  esac
}

restart_project() {
  local name="$1"
  case "$name" in
    app) "${app_compose[@]}" restart ;;
    woodpecker) "${woodpecker_compose[@]}" restart ;;
    beszel) "${beszel_compose[@]}" restart ;;
    *) die "unknown project: $name" ;;
  esac
  wait_project "$name" || die "$name failed to become healthy after restart"
}

recreate_project() {
  local name="$1"
  ensure_network
  case "$name" in
    app) "${app_compose[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" ;;
    woodpecker) "${woodpecker_compose[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" ;;
    beszel)
      if beszel_agent_ready; then
        "${beszel_compose[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"
      else
        "${beszel_compose[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" beszel-hub
      fi
      ;;
    *) die "unknown project: $name" ;;
  esac
}

stop_project() {
  case "$1" in
    app) "${app_compose[@]}" stop ;;
    woodpecker) "${woodpecker_compose[@]}" stop ;;
    beszel) "${beszel_compose[@]}" stop ;;
    all) stop_project app; stop_project woodpecker; stop_project beszel ;;
    *) die "unknown project: $1" ;;
  esac
}

for_projects() {
  local action="$1" selection="${2:-all}" name
  if [[ "$selection" == all ]]; then
    for name in beszel woodpecker app; do "$action" "$name"; done
  else
    "$action" "$selection"
  fi
}

health() {
  local failed=0 name quiet="${1:-false}"
  for name in beszel woodpecker app; do
    if ! project_is_healthy "$name"; then
      printf '%s: missing, stopped, or unhealthy services\n' "$name" >&2
      failed=1
    elif [[ "$quiet" != true ]]; then
      printf '%s: healthy\n' "$name"
    fi
  done
  return "$failed"
}

recover() {
  local quiet="${1:-false}" elapsed=0 name failed
  if [[ -f "$MAINTENANCE_FILE" && "${PLATFORM_IGNORE_MAINTENANCE:-0}" != 1 ]]; then
    [[ "$quiet" == true ]] || printf 'maintenance mode active: %s\n' "$(tr '\n' ' ' <"$MAINTENANCE_FILE")"
    return 0
  fi
  validate
  ensure_network
  while (( elapsed < RECOVERY_GRACE_SECONDS )); do
    failed=0
    for name in beszel woodpecker app; do project_is_healthy "$name" || failed=1; done
    (( failed == 0 )) && { health "$quiet"; return; }
    sleep 3
    elapsed=$((elapsed + 3))
  done
  for name in beszel woodpecker app; do
    project_is_healthy "$name" || start_project "$name"
  done
  health "$quiet"
}

status_human() {
  local name
  printf 'maintenance=%s\n' "$([[ -f "$MAINTENANCE_FILE" ]] && printf active || printf inactive)"
  printf 'release=%s\n' "$(readlink "$APP_ROOT/current" 2>/dev/null || true)"
  for name in beszel woodpecker app; do
    printf '\n[%s]\n' "$name"
    case "$name" in
      app) "${app_compose[@]}" ps ;;
      woodpecker) "${woodpecker_compose[@]}" ps ;;
      beszel) "${beszel_compose[@]}" ps ;;
    esac
  done
}

status_json() {
  docker ps -a --filter label=com.aichorage.platform=llm-hub-lite --format '{{json .}}' | jq -s \
    --arg maintenance "$([[ -f "$MAINTENANCE_FILE" ]] && printf active || printf inactive)" \
    --arg release "$(readlink "$APP_ROOT/current" 2>/dev/null || true)" \
    '{maintenance:$maintenance,release:$release,containers:.}'
}

smoke_project() {
  local name="$1" new_api_site cliproxy_site woodpecker_site beszel_site
  new_api_site="$(sed -n 's/^NEW_API_SITE=//p' "$APP_ENV" | tail -n1)"
  cliproxy_site="$(sed -n 's/^CLIPROXY_SITE=//p' "$APP_ENV" | tail -n1)"
  woodpecker_site="$(sed -n 's/^WOODPECKER_SITE=//p' "$APP_ENV" | tail -n1)"
  beszel_site="$(sed -n 's/^BESZEL_SITE=//p' "$APP_ENV" | tail -n1)"
  case "$name" in
    app)
      curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${new_api_site%/}/api/status" | grep -q '"success":true'
      curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${cliproxy_site%/}/management.html" >/dev/null
      ;;
    woodpecker) curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${woodpecker_site%/}/" >/dev/null ;;
    beszel) curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "${beszel_site%/}/api/health" >/dev/null ;;
  esac
}

woodpecker_agent_busy() {
  local id ip running
  id="$("${woodpecker_compose[@]}" ps -q woodpecker-agent)"
  [[ -n "$id" ]] || return 1
  ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")"
  [[ -n "$ip" ]] || return 1
  running="$(curl -fsS --max-time 3 "http://$ip:3000/varz" 2>/dev/null | jq -r '.running_count // 0' 2>/dev/null || printf '0')"
  [[ "$running" =~ ^[0-9]+$ ]] && (( running > 0 ))
}

pull_project() {
  case "$1" in
    app) "${app_compose[@]}" pull ;;
    woodpecker) "${woodpecker_compose[@]}" pull ;;
    beszel) "${beszel_compose[@]}" pull ;;
  esac
}

upgrade() {
  local selection="${1:-all}" candidate="${2:-$APP_ROOT/current/ops/images.prod.env}" stamp name failed=0
  [[ "$selection" =~ ^(all|app|woodpecker|beszel)$ ]] || die "unknown project: $selection"
  validate_image_manifest "$candidate"
  if [[ "$selection" == all || "$selection" == woodpecker ]]; then
    if woodpecker_agent_busy && [[ "${FORCE_WOODPECKER_UPGRADE:-0}" != 1 ]]; then
      die 'Woodpecker has an active workflow; retry when idle or set FORCE_WOODPECKER_UPGRADE=1'
    fi
  fi
  "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" snapshot pre-upgrade
  install -d -m 700 "$IMAGE_HISTORY_ROOT"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 600 "$IMAGE_ENV" "$IMAGE_HISTORY_ROOT/$stamp.env"
  install -m 600 "$IMAGE_ENV" "$PREVIOUS_IMAGE_ENV"
  install -m 600 "$candidate" "$IMAGE_ENV.new"
  mv -f "$IMAGE_ENV.new" "$IMAGE_ENV"
  if ! validate || ! for_projects pull_project "$selection" || ! for_projects recreate_project "$selection"; then failed=1; fi
  if (( failed == 0 )); then
    if [[ "$selection" == all ]]; then
      for name in beszel woodpecker app; do smoke_project "$name" || failed=1; done
    else
      smoke_project "$selection" || failed=1
    fi
  fi
  if (( failed != 0 )); then
    printf 'upgrade failed; restoring previous image manifest\n' >&2
    install -m 600 "$PREVIOUS_IMAGE_ENV" "$IMAGE_ENV"
    for_projects recreate_project "$selection" || true
    die 'upgrade rolled back'
  fi
  printf 'upgrade complete: project=%s candidate=%s\n' "$selection" "$candidate"
}

maintenance() {
  case "${1:-status}" in
    begin)
      install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"
      printf 'started_utc=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${2:-manual maintenance}" >"$MAINTENANCE_FILE"
      printf 'maintenance mode enabled\n'
      ;;
    end) rm -f -- "$MAINTENANCE_FILE"; printf 'maintenance mode disabled\n' ;;
    status) [[ -f "$MAINTENANCE_FILE" ]] && cat "$MAINTENANCE_FILE" || printf 'inactive\n' ;;
    *) die 'usage: platformctl maintenance {begin|end|status} [reason]' ;;
  esac
}

reload_caddy() {
  "${app_compose[@]}" exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  "${app_compose[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

credentials() {
  case "${1:-}" in
    purge-beszel-initial)
      local file="/etc/llm-hub-lite/beszel-initial-credentials"
      [[ -f "$file" ]] || { printf 'Beszel initial credentials are already absent\n'; return 0; }
      rm -f -- "$file"
      printf 'Beszel initial credential file removed; recovery requires your external password record\n'
      ;;
    *) die 'usage: platformctl credentials purge-beszel-initial' ;;
  esac
}

command="${1:-status}"
case "$command" in
  status|health|logs|validate) ;;
  *) acquire_lock ;;
esac

case "$command" in
  ensure-network) ensure_network ;;
  validate) validate ;;
  health) health "${2:-false}" ;;
  status)
    if [[ "${2:-}" == --json ]]; then status_json; else status_human; fi
    ;;
  recover) recover "$([[ "${2:-}" == --quiet ]] && printf true || printf false)" ;;
  start) for_projects start_project "${2:-all}" ;;
  restart) for_projects restart_project "${2:-all}" ;;
  recreate) for_projects recreate_project "${2:-all}" ;;
  stop) stop_project "${2:-all}" ;;
  upgrade) upgrade "${2:-all}" "${3:-$APP_ROOT/current/ops/images.prod.env}" ;;
  backup) "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;;
  restore) "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;;
  maintenance) maintenance "${2:-status}" "${3:-}" ;;
  credentials) credentials "${2:-}" ;;
  reload) [[ "${2:-caddy}" == caddy ]] || die 'only caddy supports reload'; reload_caddy ;;
  logs)
    case "${2:-app}" in
      app) "${app_compose[@]}" logs --tail 200 ;;
      woodpecker) "${woodpecker_compose[@]}" logs --tail 200 ;;
      beszel) "${beszel_compose[@]}" logs --tail 200 ;;
      *) die "unknown project: ${2:-}" ;;
    esac
    ;;
  *) die 'usage: platformctl {validate|status|health|recover|start|restart|recreate|stop|upgrade|backup|restore|maintenance|credentials|reload|logs} [args]' ;;
esac
