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
RECOVERY_GRACE_SECONDS="${RECOVERY_GRACE_SECONDS:-240}"

die() { printf 'platformctl: %s\n' "$*" >&2; exit 1; }
cleanup_candidate() { [[ -n "${RUNTIME_CONFIG_CANDIDATE:-}" && -d "${RUNTIME_CONFIG_CANDIDATE}" ]] && rm -rf -- "$RUNTIME_CONFIG_CANDIDATE" || true; }
trap cleanup_candidate EXIT
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
app_disabled() {
  local descriptor="$1" disable_env value
  disable_env="$(descriptor_value "$descriptor/manifest.env" DISABLE_ENV)"
  value="$(env_value "$disable_env")"
  [[ -n "$value" ]] || value="$(descriptor_value "$descriptor/manifest.env" DEFAULT_DISABLED)"
  bool_true "$value"
}
app_compose() {
  local descriptor="$1" project
  project="$(descriptor_value "$descriptor/manifest.env" COMPOSE_PROJECT)"
  compose_command=("${compose_bin[@]}" --env-file "$APP_ENV" --env-file "$APP_IMAGE_ENV" -p "$project" -f "$descriptor/$(descriptor_value "$descriptor/manifest.env" COMPOSE_FILE)")
}

render_routes() {
  local config_dir="$RUNTIME_ROOT/config" staged="$RUNTIME_ROOT/.config.staging.$$" source_config descriptor app output key value escaped_value existing active_ids
  install -d -m 700 "$RUNTIME_ROOT"
  rm -rf -- "$staged"
  install -d -m 700 "$staged/routes.d"
  source_config="$CONTROL_ROOT/config"
  [[ -d "$CONTROL_ROOT/current/config" ]] && source_config="$CONTROL_ROOT/current/config"
  cp -a "$source_config/." "$staged/"
  # Keep previously rendered app routes as dormant records when a descriptor
  # is removed; data, image pins, and backup scope remain recoverable.
  install -d -m 700 "$staged/routes.d.disabled"
  active_ids=""
  while IFS= read -r descriptor; do
    app_disabled "$descriptor" || active_ids="$active_ids $(basename "$descriptor")"
  done < <(descriptor_ids)
  if [[ -d "$config_dir/routes.d" ]]; then
    while IFS= read -r existing; do
      [[ -f "$existing" ]] || continue
      app="$(basename "$existing" .caddy)"
      case " $active_ids " in *" $app "*) ;; *) cp "$existing" "$staged/routes.d.disabled/$app.caddy" ;; esac
    done < <(find "$config_dir/routes.d" -mindepth 1 -maxdepth 1 -type f -name '*.caddy' -print 2>/dev/null)
  fi
  while IFS= read -r output; do
    [[ -f "$output" ]] || continue
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$APP_ENV")
  done < <(find "$staged" -type f -name '*.caddy' -print | sort)
  while IFS= read -r descriptor; do
    app_disabled "$descriptor" && continue
    app="$(basename "$descriptor")"
    output="$staged/routes.d/$app.caddy"
    cp "$descriptor/$(descriptor_value "$descriptor/manifest.env" ROUTE_TEMPLATE)" "$output"
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      escaped_value="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
      sed "s|{\$${key}}|${escaped_value}|g" "$output" >"$output.tmp"
      mv "$output.tmp" "$output"
    done < <(grep -E '^[A-Z0-9_]+=' "$APP_ENV")
  done < <(descriptor_ids)
  foundation_disabled woodpecker && rm -f -- "$staged/foundation-routes.d/woodpecker.caddy"
  foundation_disabled beszel && rm -f -- "$staged/foundation-routes.d/beszel.caddy"
  RUNTIME_CONFIG_CANDIDATE="$staged"
}

commit_routes() {
  local candidate="${RUNTIME_CONFIG_CANDIDATE:-}" config_dir="$RUNTIME_ROOT/config" previous="$RUNTIME_ROOT/.config.previous.$$" file relative
  [[ -n "$candidate" && -d "$candidate" ]] || die 'missing staged Caddy configuration'
  install -d -m 700 "$config_dir"
  rm -rf -- "$previous"
  [[ -d "$config_dir" ]] && cp -a "$config_dir" "$previous"
  # Keep the bind-mounted directory inode stable. Copy new files first, then
  # remove obsolete entries, so a failed update never creates an empty Caddy
  # configuration window.
  if ! while IFS= read -r file; do
    relative="${file#"$candidate/"}"
    install -d -m 700 "$config_dir/$(dirname "$relative")"
    cp "$file" "$config_dir/$relative.tmp"
    mv -f -- "$config_dir/$relative.tmp" "$config_dir/$relative"
  done < <(find "$candidate" -type f -print); then
    # Roll back file-by-file.  Do not clear the bind-mounted directory: an
    # empty Caddy config can cause an avoidable outage if the process is
    # observed between the failed write and restoration.
    while IFS= read -r file; do
      relative="${file#"$previous/"}"
      install -d -m 700 "$config_dir/$(dirname "$relative")"
      cp "$file" "$config_dir/$relative.tmp"
      mv -f -- "$config_dir/$relative.tmp" "$config_dir/$relative"
    done < <(find "$previous" -type f -print)
    while IFS= read -r file; do
      relative="${file#"$config_dir/"}"
      [[ -e "$previous/$relative" ]] || rm -rf -- "$file"
    done < <(find "$config_dir" -mindepth 1 -print)
    rm -rf -- "$candidate" "$previous"
    unset RUNTIME_CONFIG_CANDIDATE
    die 'unable to commit Caddy configuration; previous bundle restored'
  fi
  while IFS= read -r file; do
    relative="${file#"$config_dir/"}"
    [[ -e "$candidate/$relative" ]] || rm -rf -- "$file"
  done < <(find "$config_dir" -mindepth 1 -print)
  rm -rf -- "$candidate" "$previous"
  unset RUNTIME_CONFIG_CANDIDATE
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
  local descriptor="$1" file="$descriptor/manifest.env" key value relative
  validate_manifest "$file"
  for key in MANIFEST_VERSION APP_ID DISABLE_ENV COMPOSE_FILE COMPOSE_PROJECT SERVICE_NAME NETWORK_ALIAS IMAGE_KEYS DATA_ROOT_REL HEALTH_URL SMOKE_URL_KEY ROUTE_TEMPLATE; do
    value="$(descriptor_value "$file" "$key")"
    [[ -n "$value" ]] || die "$key is required in $file"
  done
  [[ "$(descriptor_value "$file" MANIFEST_VERSION)" == 1 ]] || die "unsupported MANIFEST_VERSION in $file"
  [[ "$(descriptor_value "$file" APP_ID)" == "$(basename "$descriptor")" ]] || die "APP_ID must match directory name: $descriptor"
  [[ "$(descriptor_value "$file" APP_ID)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid APP_ID in $file"
  [[ "$(descriptor_value "$file" DISABLE_ENV)" =~ ^APP_[A-Z0-9_]+_DISABLE$ ]] || die "invalid DISABLE_ENV in $file"
  [[ "$(descriptor_value "$file" COMPOSE_PROJECT)" =~ ^app-[a-z0-9-]+$ ]] || die "invalid COMPOSE_PROJECT in $file"
  [[ "$(descriptor_value "$file" NETWORK_ALIAS)" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid NETWORK_ALIAS in $file"
  for key in DATA_ROOT_REL COMPOSE_FILE ROUTE_TEMPLATE; do
    value="$(descriptor_value "$file" "$key")"
    [[ "$value" != /* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "unsafe $key in $file"
    [[ "$value" != *..* ]] || die "unsafe $key in $file"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "invalid $key in $file"
  done
  [[ "$(descriptor_value "$file" DEFAULT_DISABLED)" =~ ^(true|false|TRUE|FALSE|1|0)$ ]] || die "DEFAULT_DISABLED must be boolean in $file"
  for relative in $(descriptor_value "$file" SQLITE_PATHS); do
    [[ "$relative" != /* && "$relative" != *$'\n'* && "$relative" != *$'\r'* ]] || die "unsafe SQLITE_PATHS entry in $file"
    [[ "$relative" != *..* && "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "unsafe SQLITE_PATHS entry in $file"
  done
  need_file "$descriptor/$(descriptor_value "$file" COMPOSE_FILE)"
  need_file "$descriptor/$(descriptor_value "$file" ROUTE_TEMPLATE)"
  grep -Fq "$(descriptor_value "$file" NETWORK_ALIAS)" "$descriptor/$(descriptor_value "$file" ROUTE_TEMPLATE)" || die "route template does not target NETWORK_ALIAS in $file"
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
  local name descriptor id project_name network_alias service_name service_list
  local seen_ids="" seen_projects="" seen_aliases=""
  while IFS= read -r descriptor; do
    validate_descriptor "$descriptor"
    id="$(descriptor_value "$descriptor/manifest.env" APP_ID)"
    case " $seen_ids " in *" $id "*) die "duplicate app ID: $id" ;; esac
    seen_ids="$seen_ids $id"
    project_name="$(descriptor_value "$descriptor/manifest.env" COMPOSE_PROJECT)"
    case " $seen_projects " in *" $project_name "*) die "duplicate Compose project: $project_name" ;; esac
    seen_projects="$seen_projects $project_name"
    network_alias="$(descriptor_value "$descriptor/manifest.env" NETWORK_ALIAS)"
    case " $seen_aliases " in *" $network_alias "*) die "duplicate network alias: $network_alias" ;; esac
    seen_aliases="$seen_aliases $network_alias"
  done < <(descriptor_ids)
  render_routes
  [[ "${VALIDATE_CHECK:-0}" == 1 ]] || ensure_network
  for name in caddy woodpecker beszel; do
    foundation_disabled "$name" && continue
    foundation_compose "$name"; "${compose_command[@]}" config --quiet
  done
  while IFS= read -r descriptor; do
    app_compose "$descriptor"; "${compose_command[@]}" config --quiet
    service_name="$(descriptor_value "$descriptor/manifest.env" SERVICE_NAME)"
    service_list="$("${compose_command[@]}" config --services 2>/dev/null || true)"
    [[ -z "$service_list" ]] || printf '%s\n' "$service_list" | grep -Fxq "$service_name" || die "SERVICE_NAME is absent from Compose project: $descriptor"
  done < <(descriptor_ids)
  docker run --rm --pull=never --env-file "$APP_ENV" -v "${RUNTIME_CONFIG_CANDIDATE:-$RUNTIME_ROOT/config}:/etc/caddy:ro" "$(env_value CADDY_IMAGE "$FOUNDATION_IMAGE_ENV")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  if [[ "${VALIDATE_CHECK:-0}" == 1 ]]; then
    cleanup_candidate
    unset RUNTIME_CONFIG_CANDIDATE
  elif [[ "${VALIDATE_STAGE_ONLY:-0}" == 1 ]]; then
    # Keep the candidate available to the caller.  Sync/recovery commit it
    # only after every selected Compose project is healthy.
    return 0
  else
    commit_routes
  fi
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
  local project="$1" wait_mode="${2:-wait}"; local -a wait_args=(); ensure_network; project_enabled "$project" || return 0
  [[ "$wait_mode" == wait ]] && wait_args=(--wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT")
  case "$project" in
    caddy|woodpecker) foundation_compose "$project"; "${compose_command[@]}" up -d --pull never "${wait_args[@]}" ;;
    beszel)
      foundation_compose beszel
      if [[ -s "$(env_value BESZEL_KEY_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" && -s "$(env_value BESZEL_TOKEN_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" ]]; then
        "${compose_command[@]}" up -d --pull never "${wait_args[@]}"
      else
        "${compose_command[@]}" up -d --pull never "${wait_args[@]}" beszel-hub beszel-socket-proxy
      fi
      ;;
    app:*) app_compose "${project#app:}"; "${compose_command[@]}" up -d --pull never "${wait_args[@]}" ;;
  esac
}

sync_project() {
  local project="$1"
  if ! project_enabled "$project"; then
    stop_project "$project"
    return 0
  fi
  ensure_network
  case "$project" in
    caddy|woodpecker) foundation_compose "$project" ;;
    beszel) foundation_compose beszel ;;
    app:*) app_compose "${project#app:}" ;;
  esac
  # Compose reconciles its config hash, image digest, mounts, and environment;
  # this applies changed releases without blindly recreating every project.
  if [[ "$project" == beszel && ( ! -s "$(env_value BESZEL_KEY_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" || ! -s "$(env_value BESZEL_TOKEN_FILE "$FOUNDATION_ENV_ROOT/beszel.env")" ) ]]; then
    "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT" beszel-hub beszel-socket-proxy
  else
    "${compose_command[@]}" up -d --pull never --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"
  fi
}

stop_project() { local project="$1"; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" down --remove-orphans; }
restart_project() { local project="$1"; if ! project_enabled "$project"; then stop_project "$project"; return 0; fi; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" restart; wait_project "$project" || die "$project failed after restart"; }
recreate_project() { local project="$1"; if ! project_enabled "$project"; then stop_project "$project"; return 0; fi; case "$project" in caddy|woodpecker|beszel) foundation_compose "$project" ;; app:*) app_compose "${project#app:}" ;; esac; "${compose_command[@]}" up -d --pull never --force-recreate --wait --wait-timeout "$COMPOSE_WAIT_TIMEOUT"; }

projects() {
  printf 'caddy\n'
  if ! foundation_disabled woodpecker; then printf 'woodpecker\n'; fi
  if ! foundation_disabled beszel; then printf 'beszel\n'; fi
  while IFS= read -r descriptor; do app_disabled "$descriptor" || printf 'app:%s\n' "$descriptor"; done < <(descriptor_ids)
}

all_projects() {
  printf 'caddy\nwoodpecker\nbeszel\n'
  while IFS= read -r descriptor; do printf 'app:%s\n' "$descriptor"; done < <(descriptor_ids)
}

reconcile() {
  local project descriptor active_components component
  validate
  remove_orphans all
  stop_disabled_projects
  while IFS= read -r project; do project_is_healthy "$project" || start_project "$project"; done < <(projects)
  reload_caddy_if_ready
  health true
}

remove_orphans() {
  local scope="${1:-all}" id component expected active_components='foundation-caddy'
  foundation_disabled woodpecker || active_components="$active_components foundation-woodpecker"
  foundation_disabled beszel || active_components="$active_components foundation-beszel"
  while IFS= read -r descriptor; do
    app_disabled "$descriptor" || active_components="$active_components app-$(basename "$descriptor")"
  done < <(descriptor_ids)
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    component="$(docker inspect --format '{{ index .Config.Labels "com.aichorage.component" }}' "$id" 2>/dev/null || true)"
    case "$scope" in
      all) ;;
      apps) [[ "$component" == app-* ]] || continue ;;
      foundation) [[ "$component" == foundation-* ]] || continue ;;
      app:*) expected="app-$(basename "${scope#app:}")"; [[ "$component" == "$expected" ]] || continue ;;
      caddy|woodpecker|beszel) [[ "$component" == "foundation-$scope" ]] || continue ;;
      *) die "unknown orphan cleanup scope: $scope" ;;
    esac
    [[ " $active_components " == *" $component "* ]] || docker rm -f "$id" >/dev/null 2>&1 || true
  done < <(docker ps -aq --filter label=com.aichorage.platform=llm-hub-lite)
}

stop_disabled_projects() {
  local project descriptor
  for project in woodpecker beszel; do foundation_disabled "$project" && stop_project "$project" || true; done
  while IFS= read -r descriptor; do
    if app_disabled "$descriptor"; then stop_project "app:$descriptor"; fi
  done < <(descriptor_ids)
}

health() { local quiet="${1:-false}" failed=0 project; while IFS= read -r project; do if ! project_is_healthy "$project"; then printf '%s: unhealthy\n' "$project" >&2; failed=1; elif [[ "$quiet" != true ]]; then printf '%s: healthy\n' "$project"; fi; done < <(projects); return "$failed"; }
caddy_config_hash() {
  local config_dir="$RUNTIME_ROOT/config" file
  [[ -d "$config_dir" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$config_dir" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done) | sha256sum | awk '{print $1}'
  else
    (cd "$config_dir" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done) | shasum -a 256 | awk '{print $1}'
  fi
}
reload_caddy_if_ready() {
  local marker="$RUNTIME_ROOT/.caddy-loaded.sha256" current loaded
  project_is_healthy caddy || return 0
  current="$(caddy_config_hash)" || return 1
  loaded="$(cat "$marker" 2>/dev/null || true)"
  [[ "$current" == "$loaded" ]] && return 0
  reload_caddy
  printf '%s\n' "$current" >"$marker"
  chmod 600 "$marker"
}

recover() {
  [[ -f "$MAINTENANCE_FILE" && "${PLATFORM_IGNORE_MAINTENANCE:-0}" != 1 ]] && { [[ "${1:-false}" == true ]] || cat "$MAINTENANCE_FILE"; return 0; }
  VALIDATE_STAGE_ONLY=1 validate
  local project failed deadline=$(( $(date +%s) + RECOVERY_GRACE_SECONDS ))
  while (( $(date +%s) < deadline )); do
    failed=0; while IFS= read -r project; do project_is_healthy "$project" || failed=1; done < <(projects)
    if (( failed == 0 )) && health "${1:-false}"; then
      commit_routes
      reload_caddy_if_ready
      stop_disabled_projects
      remove_orphans all
      return
    fi
    while IFS= read -r project; do project_is_healthy "$project" || start_project "$project" no-wait; done < <(projects)
    sleep 3
  done
  reload_caddy_if_ready || true
  health "${1:-false}"
}

sync() {
  [[ -f "$MAINTENANCE_FILE" && "${PLATFORM_IGNORE_MAINTENANCE:-0}" != 1 ]] && die "platform is in maintenance mode"
  VALIDATE_STAGE_ONLY=1 validate
  local project scope="${1:-all}"
  case "$scope" in
    all) while IFS= read -r project; do sync_project "$project"; done < <(projects) ;;
    foundation) for project in caddy woodpecker beszel; do sync_project "$project"; done ;;
    apps) while IFS= read -r project; do [[ "$project" == app:* ]] && sync_project "$project"; done < <(projects) ;;
    caddy|woodpecker|beszel|app:*) sync_project "$scope" ;;
    *) die 'usage: platformctl sync [all|foundation|apps|project]' ;;
  esac
  # A scoped sync can still affect the public route bundle. Require the full
  # active platform to be healthy before committing that bundle.
  health true
  # Keep the old ingress bundle serving until all selected projects have
  # reconciled successfully.  commit_routes is atomic at the file level and
  # the Caddy reload below is performed only after the new bundle is live.
  commit_routes
  reload_caddy_if_ready
  stop_disabled_projects
  remove_orphans "$scope"
  health false
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
  validate)
    if [[ "${2:-}" == --check ]]; then
      VALIDATE_CHECK=1 validate
    else
      validate
    fi
    ;;
  status) [[ "${2:-}" == --json ]] && status_json || status_human ;;
  health) health false ;;
  recover) recover "$([[ "${2:-}" == --quiet ]] && printf true || printf false)" ;;
  ensure-network) ensure_network ;;
  start) [[ "${2:-all}" == all ]] && while IFS= read -r p; do start_project "$p"; done < <(projects) || start_project "${2}" ;;
  restart|recreate) [[ "${2:-all}" == all ]] && while IFS= read -r p; do [[ "$operation" == restart ]] && restart_project "$p" || recreate_project "$p"; done < <(all_projects) || { [[ "$operation" == restart ]] && restart_project "${2}" || recreate_project "${2}"; } ;;
  stop) [[ "${2:-all}" == all ]] && while IFS= read -r p; do stop_project "$p"; done < <(all_projects) || stop_project "${2}" ;;
  smoke) [[ "${2:-}" == app:* ]] && smoke_project "${2#app:}" || die 'usage: platformctl smoke app:<descriptor>' ;;
  maintenance) maintenance "${2:-status}" "${3:-}" ;;
  reload) reload_caddy ;;
  logs|ps) [[ "${2:-all}" == all ]] && while IFS= read -r p; do case "$p" in caddy|woodpecker|beszel) foundation_compose "$p" ;; app:*) app_compose "${p#app:}" ;; esac; "${compose_command[@]}" "$1" --tail 200; done < <(projects) || { case "${2}" in caddy|woodpecker|beszel) foundation_compose "${2}" ;; app:*) app_compose "${2#app:}" ;; esac; "${compose_command[@]}" "$1" --tail 200; } ;;
  backup) exec "${BACKUP_SCRIPT:-/usr/local/bin/backup-platform}" "${2:-snapshot}" "${3:-manual}" ;;
  restore) exec "${RESTORE_SCRIPT:-/usr/local/bin/restore-platform}" "${2:-extract}" "${3:-latest}" "${4:-}" ;;
  sync) sync "${2:-all}" ;;
  *) die 'usage: platformctl {validate|status|health|recover|sync|start|restart|recreate|stop|smoke|backup|restore|maintenance|reload|logs|ps}' ;;
esac
