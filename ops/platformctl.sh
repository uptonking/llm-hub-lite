#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2015,SC2318
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
MAINTENANCE_FILE="${PLATFORM_MAINTENANCE_FILE:-$CONFIG_ROOT/maintenance}"
LOCK_FILE="${PLATFORM_LOCK_FILE:-/run/lock/llm-hub-lite/platform.lock}"
COMPOSE_WAIT_TIMEOUT="${COMPOSE_WAIT_TIMEOUT:-180}"
RECOVERY_GRACE_SECONDS="${RECOVERY_GRACE_SECONDS:-90}"

die() { printf 'platformctl: %s\n' "$*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }
env_value() { local key="$1" file="${2:-$APP_ENV}"; sed -n "s/^${key}=//p" "$file" | tail -n1; }
bool_true() { [[ "${1:-}" == true || "${1:-}" == TRUE || "${1:-}" == 1 ]]; }
service_disabled() { bool_true "$(env_value "$1")"; }

compose_bin=(docker compose)
if [[ -n "${PLATFORM_COMPOSE_BIN:-}" ]]; then compose_bin=("$PLATFORM_COMPOSE_BIN"); elif [[ -x /usr/local/bin/platform-compose ]]; then compose_bin=(/usr/local/bin/platform-compose); fi

acquire_lock() {
  [[ "${PLATFORM_LOCK_HELD:-0}" == 1 ]] && return 0
  install -d -m 700 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -w "${PLATFORM_LOCK_WAIT:-300}" 9 || die 'timed out waiting for platform lock'
  export PLATFORM_LOCK_HELD=1
}

edge_network() { local value="$(env_value PLATFORM_EDGE_NETWORK)"; printf '%s\n' "${value:-platform_edge}"; }
ensure_network() { local network_name="$(edge_network)"; docker network inspect "$network_name" >/dev/null 2>&1 || docker network create "$network_name" >/dev/null; }

foundation_disabled() {
  case "$1" in
    caddy) return 1 ;;
    woodpecker) service_disabled SERVICE_WOODPECKER_DISABLE ;;
    beszel) service_disabled SERVICE_BESZEL_DISABLE ;;
    *) die "unknown foundation: $1" ;;
  esac
}

foundation_env() {
  case "$1" in
    caddy) printf '%s\n' "$FOUNDATION_ENV_ROOT/caddy.env" ;;
    woodpecker) printf '%s\n' "$FOUNDATION_ENV_ROOT/woodpecker.env" ;;
    beszel) printf '%s\n' "$FOUNDATION_ENV_ROOT/beszel.env" ;;
  esac
}

foundation_compose() {
  local name="$1"
  compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$(foundation_env "$name")" --env-file "$FOUNDATION_IMAGE_ENV" -f "$FOUNDATION_ROOT/$name.yml")
}

descriptor_ids() {
  # Keep this portable across the macOS Bash 3.2/bootstrap environment and
  # GNU/Linux.  `find -printf` is not available in BSD find.
  find -L "$APPS_ROOT" -mindepth 2 -maxdepth 2 -type f -name manifest.env \
    -exec dirname {} \; 2>/dev/null | sort
}
descriptor_value() { local file="$1" key="$2"; sed -n "s/^${key}=//p" "$file" | tail -n1; }
app_disabled() { local descriptor="$1"; service_disabled "$(descriptor_value "$descriptor/manifest.env" DISABLE_ENV)"; }
app_compose() { local descriptor="$1"; compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$APP_IMAGE_ENV" -f "$descriptor/$(descriptor_value "$descriptor/manifest.env" COMPOSE_FILE)"); }

render_routes() {
  local config_dir="$RUNTIME_ROOT/config" descriptor app output key value escaped_value
  install -d -m 700 "$config_dir/routes.d"
  find "$config_dir" -mindepth 1 -delete
  local source_config="$CONTROL_ROOT/config"
  [[ -d "$CONTROL_ROOT/current/config" ]] && source_config="$CONTROL_ROOT/current/config"
  cp -a "$source_config/." "$config_dir/"
  install -d -m 700 "$config_dir/routes.d"
  while IFS= read -r descriptor; do
    app="$(basename "$descriptor")"
    output="$config_dir/routes.d/$app.caddy"
    cp "$descriptor/$(descriptor_value "$descriptor/manifest.env" ROUTE_TEMPLATE)" "$output"
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$APP_ENV")
  done < <(descriptor_ids)
}

validate_manifest() {
  local file="$1" key value
  need_file "$file"
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "invalid manifest key $key in $file"
  done <"$file"
}

validate_descriptor() {
  local descriptor="$1" file="$descriptor/manifest.env" key value
  validate_manifest "$file"
  for key in APP_ID DISABLE_ENV COMPOSE_FILE COMPOSE_PROJECT SERVICE_NAME NETWORK_ALIAS IMAGE_KEYS DATA_ROOT_REL HEALTH_URL SMOKE_URL_KEY ROUTE_TEMPLATE; do
    value="$(descriptor_value "$file" "$key")"
    [[ -n "$value" ]] || die "$key is required in $file"
  done
  [[ "$(descriptor_value "$file" APP_ID)" == "$(basename "$descriptor")" ]] || die "APP_ID must match directory name: $descriptor"
  [[ "$(descriptor_value "$file" APP_ID)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid APP_ID in $file"
  [[ "$(descriptor_value "$file" DISABLE_ENV)" =~ ^APP_[A-Z0-9_]+_DISABLE$ ]] || die "invalid DISABLE_ENV in $file"
  [[ "$(descriptor_value "$file" COMPOSE_PROJECT)" =~ ^app-[a-z0-9-]+$ ]] || die "invalid COMPOSE_PROJECT in $file"
  [[ "$(descriptor_value "$file" NETWORK_ALIAS)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid NETWORK_ALIAS in $file"
  [[ "$(descriptor_value "$file" DATA_ROOT_REL)" != /* && "$(descriptor_value "$file" DATA_ROOT_REL)" != *..* ]] || die "unsafe DATA_ROOT_REL in $file"
  need_file "$descriptor/$(descriptor_value "$file" COMPOSE_FILE)"
  need_file "$descriptor/$(descriptor_value "$file" ROUTE_TEMPLATE)"
  for key in $(descriptor_value "$file" IMAGE_KEYS); do [[ -n "$(env_value "$key" "$APP_IMAGE_ENV")" ]] || die "$key is missing from $APP_IMAGE_ENV"; done
}

validate_images() {
  local file="$1" key value; validate_manifest "$file"
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] || die "$key must be digest-pinned in $file"
  done <"$file"
}

validate() {
  need_file "$APP_ENV"; validate_images "$APP_IMAGE_ENV"; validate_images "$FOUNDATION_IMAGE_ENV"
  need_file "$CONTROL_ROOT/current/config/Caddyfile"
  need_file "$FOUNDATION_ROOT/caddy.yml"
  render_routes; ensure_network
  local name descriptor id seen_ids=""
  for name in caddy woodpecker beszel; do foundation_compose "$name"; "${compose_command[@]}" config --quiet; done
  while IFS= read -r descriptor; do
    validate_descriptor "$descriptor"; id="$(descriptor_value "$descriptor/manifest.env" APP_ID)"
    [[ " $seen_ids " != *" $id "* ]] || die "duplicate app ID: $id"
    seen_ids="$seen_ids $id"
    app_compose "$descriptor"; "${compose_command[@]}" config --quiet
  done < <(descriptor_ids)
  docker run --rm --env-file "$APP_ENV" -v "$RUNTIME_ROOT/config:/etc/caddy:ro" "$(env_value CADDY_IMAGE "$FOUNDATION_IMAGE_ENV")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}

project_ids() { case "$1" in
  caddy) foundation_compose caddy; "${compose_command[@]}" ps --all -q ;;
  woodpecker) foundation_compose woodpecker; "${compose_command[@]}" ps --all -q ;;
  beszel) foundation_compose beszel; "${compose_command[@]}" ps --all -q ;;
  app:*) app_compose "${1#app:}"; "${compose_command[@]}" ps --all -q ;;
esac; }

project_enabled() {
  case "$1" in caddy) return 0 ;; woodpecker|beszel) ! foundation_disabled "$1" ;; app:*) ! app_disabled "${1#app:}" ;; esac
}

project_is_healthy() {
  local project="$1" ids id state; project_enabled "$project" || return 0
  ids="$(project_ids "$project")"; [[ -n "$ids" ]] || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
    [[ "$state" == 'running healthy' || "$state" == 'running none' ]] || return 1
  done <<<"$ids"
}

wait_project() { local project="$1" elapsed=0; while (( elapsed < ${2:-$COMPOSE_WAIT_TIMEOUT} )); do project_is_healthy "$project" && return 0; sleep 3; elapsed=$((elapsed+3)); done; return 1; }

start_project() {
  local project="$1"; ensure_network; project_enabled "$project" || return 0
  case "$project" in
    caddy|woodpecker) foundation_compose "$project"; "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" ;;
    beszel)
      foundation_compose beszel
      if [[ -s "$(env_value BESZEL_KEY_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" && -s "$(env_value BESZEL_TOKEN_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" ]]; then
        "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"
      else
        "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" beszel-hub beszel-socket-proxy
      fi
      ;;
    app:*) app_compose "${project#app:}"; "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" ;;
  esac
}

stop_project() { local project="$1"; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" down --remove-orphans; }
restart_project() { local project="$1"; project_enabled "$project" || return 0; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" restart; wait_project "$project" || die "$project failed after restart"; }
recreate_project() { local project="$1"; project_enabled "$project" || return 0; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"; }

projects() {
  printf 'caddy\n'
  if ! foundation_disabled woodpecker; then printf 'woodpecker\n'; fi
  if ! foundation_disabled beszel; then printf 'beszel\n'; fi
  while IFS= read -r descriptor; do app_disabled "$descriptor" || printf 'app:%s\n' "$descriptor"; done < <(descriptor_ids)
}

reconcile() {
  local project
  validate
  while IFS= read -r descriptor; do
    if app_disabled "$descriptor"; then stop_project "app:$descriptor"; fi
  done < <(descriptor_ids)
  while IFS= read -r project; do project_is_healthy "$project" || start_project "$project"; done < <(projects)
  health true
}

health() { local quiet="${1:-false}" failed=0 project; while IFS= read -r project; do if ! project_is_healthy "$project"; then printf '%s: unhealthy\n' "$project" >&2; failed=1; elif [[ "$quiet" != true ]]; then printf '%s: healthy\n' "$project"; fi; done < <(projects); return "$failed"; }

recover() {
  [[ -f "$MAINTENANCE_FILE" && "${PLATFORM_IGNORE_MAINTENANCE:-0}" != 1 ]] && { [[ "${1:-false}" == true ]] || cat "$MAINTENANCE_FILE"; return 0; }
  validate
  local elapsed=0 project failed
  while (( elapsed < RECOVERY_GRACE_SECONDS )); do failed=0; while IFS= read -r project; do project_is_healthy "$project" || failed=1; done < <(projects); (( failed == 0 )) && health "${1:-false}" && return; sleep 3; elapsed=$((elapsed+3)); done
  while IFS= read -r project; do project_is_healthy "$project" || start_project "$project"; done < <(projects)
  health "${1:-false}"
}

status_json() { local projects_json; projects_json="$(projects | jq -R . | jq -s .)"; docker ps -a --filter label=com.aichorage.platform=llm-hub-lite --format '{{json .}}' | jq -s --arg release "$(readlink "$APP_ROOT/current" 2>/dev/null || true)" --argjson projects "$projects_json" --arg maintenance "$([[ -f "$MAINTENANCE_FILE" ]] && printf active || printf inactive)" '{maintenance:$maintenance,release:$release,projects:$projects,containers:.}'; }
status_human() { printf 'maintenance=%s\nrelease=%s\n' "$([[ -f "$MAINTENANCE_FILE" ]] && printf active || printf inactive)" "$(readlink "$APP_ROOT/current" 2>/dev/null || true)"; health false || true; }

smoke_project() {
  local descriptor="$1" url_key url base path expect
  url_key="$(descriptor_value "$descriptor/manifest.env" SMOKE_URL_KEY)"; url="$(env_value "$url_key")"; path="$(descriptor_value "$descriptor/manifest.env" HEALTH_URL)"; expect="$(descriptor_value "$descriptor/manifest.env" HEALTH_EXPECT)"; base="${url%/}"
  [[ -n "$url" ]] || return 0
  if [[ -n "$expect" ]]; then curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "$base$path" | grep -q "$expect"; else curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 "$base$path" >/dev/null; fi
}

maintenance() { case "${1:-status}" in begin) install -d -m 700 "$(dirname "$MAINTENANCE_FILE")"; printf 'started_utc=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${2:-manual}" >"$MAINTENANCE_FILE"; echo enabled ;; end) rm -f -- "$MAINTENANCE_FILE"; echo disabled ;; status) [[ -f "$MAINTENANCE_FILE" ]] && cat "$MAINTENANCE_FILE" || echo inactive ;; *) die 'usage: platformctl maintenance {begin|end|status} [reason]' ;; esac; }
reload_caddy() { foundation_compose caddy; "${compose_command[@]}" exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; "${compose_command[@]}" exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; }

operation="${1:-status}"; case "$operation" in status|health|validate) ;; *) acquire_lock ;; esac
case "$operation" in
  validate) validate ;;
  status) [[ "${2:-}" == --json ]] && status_json || status_human ;;
  health) health false ;;
  recover) recover "$([[ "${2:-}" == --quiet ]] && printf true || printf false)" ;;
  ensure-network) ensure_network ;;
  start) [[ "${2:-all}" == all ]] && while IFS= read -r p; do start_project "$p"; done < <(projects) || start_project "${2}" ;;
  restart) [[ "${2:-all}" == all ]] && while IFS= read -r p; do restart_project "$p"; done < <(projects) || restart_project "${2}" ;;
  recreate) [[ "${2:-all}" == all ]] && while IFS= read -r p; do recreate_project "$p"; done < <(projects) || recreate_project "${2}" ;;
  stop) [[ "${2:-all}" == all ]] && while IFS= read -r p; do stop_project "$p"; done < <(projects) || stop_project "${2}" ;;
  smoke) [[ "${2:-}" == app:* ]] && smoke_project "${2#app:}" || die 'usage: platformctl smoke app:<descriptor>' ;;
  maintenance) maintenance "${2:-status}" "${3:-}" ;;
  reload) reload_caddy ;;
  logs|ps) [[ "${2:-all}" == all ]] && while IFS= read -r p; do case "$p" in caddy|woodpecker|beszel) foundation_compose "$p" ;; app:*) app_compose "${p#app:}" ;; esac; "${compose_command[@]}" "$1" --tail 200; done < <(projects) || { case "${2}" in caddy|woodpecker|beszel) foundation_compose "${2}" ;; app:*) app_compose "${2#app:}" ;; esac; "${compose_command[@]}" "$1" --tail 200; } ;;
  backup) exec "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;;
  restore) exec "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;;
  *) die 'usage: platformctl {validate|status|health|recover|start|restart|recreate|stop|smoke|backup|restore|maintenance|reload|logs|ps}' ;;
esac
