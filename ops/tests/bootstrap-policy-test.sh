#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns intentionally match literal '$var' text
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap="$repo_root/ops/bootstrap-vps.sh"
bash -n "$bootstrap"
grep -Fq 'shell xtrace was disabled before loading secrets' "$bootstrap"
grep -Fq 'bootstrap_error()' "$bootstrap"
grep -Fq 'bootstrap failed at line %s (exit status %s)' "$bootstrap"
grep -Fq "printf '%s' \"\$value\" | LC_ALL=C grep '[[:cntrl:]]'" "$bootstrap"
grep -Fq 'bootstrap-pending' "$bootstrap"
grep -Fq 'prompt_available()' "$bootstrap"
grep -Fq 'prompt_read()' "$bootstrap"
grep -Fq 'if [[ -t 0 ]]; then' "$bootstrap"
grep -Fq 'if IFS= read -r -s -p "$prompt: " value; then' "$bootstrap"
grep -Fq 'if IFS= read -r -p "$prompt: " value; then' "$bootstrap"
grep -Fq 'read -r -s -p "$prompt: " value </dev/tty' "$bootstrap"
grep -Fq 'read -r -p "$prompt: " value </dev/tty' "$bootstrap"
grep -Fq "previous_woodpecker_domain=''" "$bootstrap"
grep -Fq 'if [[ -r "$woodpecker_env" ]]; then' "$bootstrap"
grep -Fq "previous_beszel_domain=''" "$bootstrap"
grep -Fq 'if [[ -r "$beszel_env" ]]; then' "$bootstrap"
grep -Fq 'if [[ -r "$file" ]]; then' "$bootstrap"
grep -Fq 'The Leader-generated shared bundle is authoritative on Followers' "$bootstrap"
grep -Fq 'set_key_if_changed()' "$bootstrap"
grep -Fq 'set_key_if_changed "$woodpecker_env" "$shared_key" "$shared_value"' "$bootstrap"
grep -Fq 'set_key_if_changed "$app_env" "$key" "$value"' "$bootstrap"
grep -Fq 'set_key_if_changed "$runtime_file" "$key" "$value"' "$bootstrap"
secret_write_helpers="$(sed -n '/^set_key() {/,/^merge_image_manifest() {/p' "$bootstrap" | sed '$d')"
SECRET_WRITE_HELPERS="$secret_write_helpers" bash -c '
	set -Eeuo pipefail
	eval "$SECRET_WRITE_HELPERS"
	tmp="$(mktemp)"
	trap '\''rm -f "$tmp"'\'' EXIT
	printf "KEY=old-value\\n" >"$tmp"
	set_key_if_changed "$tmp" KEY new-value
	grep -qx "KEY=new-value" "$tmp"
	set_key_if_changed "$tmp" KEY new-value
	grep -qx "KEY=new-value" "$tmp"
'
grep -Fq 'already differs from the configured Leader value' "$bootstrap"
secret_reconcile_block="$(sed -n '/^for shared_key in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do$/,/^chmod 600 "\$woodpecker_env"/p' "$bootstrap")"
grep -Fq 'if [[ "$NODE_ROLE" == follower ]]; then' <<<"$secret_reconcile_block"
grep -Fq 'else' <<<"$secret_reconcile_block"
grep -Fq 'prompt_observer_ingest_token()' "$bootstrap"
grep -Fq 'OBSERVER_INGEST_TOKEN must be an OpenObserve token' "$bootstrap"
if grep -Fq 'AICHOROUTER_MEMORY_LIMIT="${AICHOROUTER_MEMORY_LIMIT:-768m}"' "$bootstrap"; then
	printf 'bootstrap still owns application resource tuning\n' >&2
	exit 1
fi
grep -Fq 'AICHOROUTER_MEMORY_LIMIT=768m' "$repo_root/apps/aichorouter/config.env"
grep -Fq 'AICHOROUTER_GOMEMLIMIT=500MiB' "$repo_root/apps/aichorouter/config.env"
grep -Fq 'RESTIC_SCHEDULE_INTERVAL="${RESTIC_SCHEDULE_INTERVAL:-3600}"' "$bootstrap"
grep -Fq 'RESTIC_REMOTE_ENABLED="${RESTIC_REMOTE_ENABLED:-false}"' "$bootstrap"
grep -Fq 'PRODUCTION_REQUIRE_REMOTE_BACKUP="${PRODUCTION_REQUIRE_REMOTE_BACKUP:-false}"' "$bootstrap"
grep -Fq '"PRODUCTION_REQUIRE_REMOTE_BACKUP=$PRODUCTION_REQUIRE_REMOTE_BACKUP"' "$bootstrap"
grep -Fq '"RESTIC_REMOTE_ENABLED=$RESTIC_REMOTE_ENABLED"' "$bootstrap"
grep -Fq '"RESTIC_REMOTE_REPOSITORY=$RESTIC_REMOTE_REPOSITORY"' "$bootstrap"
grep -Fq '"RESTIC_REMOTE_PASSWORD_FILE=$RESTIC_REMOTE_PASSWORD_FILE"' "$bootstrap"
grep -Fq 'if remote_enabled; then' "$bootstrap"
grep -Fq "elif truthy \"\$PRODUCTION_REQUIRE_REMOTE_BACKUP\"; then" "$bootstrap"
if grep -Fq '"PRODUCTION_REQUIRE_REMOTE_BACKUP=true"' "$bootstrap"; then
	printf 'bootstrap must not force remote backups when local-only mode is selected\n' >&2
	exit 1
fi
grep -Fq 'runtime_setting()' "$bootstrap"
grep -Fq 'OBSERVER_INGEST_USER="${OBSERVER_INGEST_USER:-}"' "$bootstrap"
grep -Fq 'OBSERVER_INGEST_USER="${OBSERVER_INGEST_USER:-llm-hub-lite-collector}"' "$bootstrap"
grep -Fq 'observer_default_value()' "$bootstrap"
grep -Fq 'set_derived_key()' "$bootstrap"
grep -Fq 'previous_app_domain=' "$bootstrap"
grep -Fq 'set_derived_key "$app_env" WOODPECKER_SITE' "$bootstrap"
grep -Fq 'set_derived_key "$app_env" BESZEL_SITE' "$bootstrap"
grep -Fq 'previous_observer_domain=' "$bootstrap"
grep -Fq 'OBSERVER_DURABLE_WARN_BYTES=$(observer_default_value OBSERVER_DURABLE_WARN_BYTES 8589934592)' "$bootstrap"
grep -Fq 'OBSERVER_LOG_BUFFER_WARN_PERCENT=$(observer_default_value OBSERVER_LOG_BUFFER_WARN_PERCENT 80)' "$bootstrap"
grep -Fq 'safe_observer_data_root()' "$bootstrap"
grep -Fq 'OBSERVER_DATA_ROOT must be a non-root path below' "$bootstrap"
grep -Fq 'remove_key "$observer_env" OBSERVER_ROOT_USER_EMAIL' "$bootstrap"
grep -Fq 'remove_key "$observer_env" OBSERVER_ROOT_USER_PASSWORD' "$bootstrap"
grep -Fq 'Credentials are deliberately written with set_key' "$bootstrap"
grep -Fq 'set_key "$observer_env" "$observer_key" "$observer_value"' "$bootstrap"
grep -Fq 'RESTIC_COMPRESSION="${RESTIC_COMPRESSION:-$(runtime_setting RESTIC_COMPRESSION)}"' "$bootstrap"
grep -Fq 'RESTIC_SKIP_IF_UNCHANGED="${RESTIC_SKIP_IF_UNCHANGED:-$(runtime_setting RESTIC_SKIP_IF_UNCHANGED)}"' "$bootstrap"
grep -Fq 'normalize_restic_compression' "$bootstrap"
grep -Fq 'normalize_restic_features' "$bootstrap"
grep -Fq 'Restic does not support --skip-if-unchanged' "$bootstrap"
grep -Fq 'restic backup --help' "$repo_root/ops/backup-platform.sh"
grep -Fq "prompt_required RESTIC_REMOTE_PASSWORD 'Remote Restic password' 1" "$bootstrap"
grep -Fq "prompt_required WOODPECKER_GITHUB_SECRET 'GitHub OAuth client secret' 1" "$bootstrap"
configure_secrets="$repo_root/ops/configure-app-secrets.sh"
bash -n "$configure_secrets"
grep -Fq 'shell xtrace was disabled before loading application secrets' "$configure_secrets"
grep -Fq "printf '%s' \"\$value\" | LC_ALL=C grep '[[:cntrl:]]'" "$configure_secrets"
grep -Fq 'install -d -o 1000 -g 1000 -m 700 "$PLATFORM_ROOT/woodpecker/data"' "$bootstrap"
grep -Fq 'detect_ssh_port' "$bootstrap"
grep -Fq 'ufw allow "$SSH_PORT"/tcp' "$bootstrap"
grep -Fq "ufw allow 443/tcp comment 'HTTPS'" "$bootstrap"
grep -Fq "ufw allow 443/udp comment 'HTTP/3'" "$bootstrap"
if grep -Fq 'ufw --force delete allow 443' "$bootstrap"; then
	printf 'bootstrap still deletes the public UFW HTTPS policy\n' >&2
	exit 1
fi
grep -Fq '/usr/local/bin/configure-firewall' "$bootstrap"
grep -Fq 'docker run --rm --network "$edge_network" llm-hub-lite/deploy-runner:current' "$bootstrap"
grep -Fq 'curl --http2' "$bootstrap"
grep -Fq 'container HTTPS preflight failed' "$bootstrap"
grep -Fq 'Older bootstraps nested Hub and agent state' "$bootstrap"
grep -Fq 'migrate_legacy_woodpecker_layout' "$bootstrap"
grep -Fq '[[ -z "$LEADER_PUBLIC_IP" && -r "$CONFIG_ROOT/node.env" ]]' "$bootstrap"
grep -Fq 'unable to pull image after $attempt attempts' "$bootstrap"
grep -Fq 'pull_image "$image_ref"' "$bootstrap"
grep -Fq 'unable to fetch $MAIN_BRANCH after $attempt attempts' "$bootstrap"
grep -Fq 'git_fetch_bootstrap' "$bootstrap"
grep -Fq 'unable to clone $MAIN_BRANCH after $attempt attempts' "$bootstrap"
grep -Fq 'source root already exists but is not a Git checkout' "$bootstrap"
grep -Fq 'Skipping image for disabled or inactive service' "$bootstrap"
grep -Fq 'merge_image_manifest' "$bootstrap"
grep -Fq 'prune_stale_image_keys' "$bootstrap"
image_function="$(sed -n '/^csv_contains() {/,/^}/p; /^bootstrap_foundation_enabled() {/,/^}/p; /^app_policy_file() {/,/^}/p; /^app_enabled() {/,/^}/p; /^app_nodes() /p; /^app_target() {/,/^}/p; /^app_active_on_node() {/,/^}/p; /^image_key_declared() {/,/^}/p; /^image_required() {/,/^}/p' "$bootstrap")"
image_selection="$(IMAGE_FUNCTION="$image_function" SOURCE_ROOT="$repo_root" bash -c '
	set -Eeuo pipefail
	eval "$IMAGE_FUNCTION"
	NODE_ROLE=follower NODE_ID=worker-1 NODE_STATE=active
	for key in CADDY_IMAGE BESZEL_AGENT_IMAGE WOODPECKER_AGENT_IMAGE LIBRECHAT_API_IMAGE NEW_API_IMAGE CPAPI_IMAGE AICHOROUTER_IMAGE CURSORAPI_IMAGE OBSERVER_IMAGE OBSERVER_LOG_PROXY_IMAGE OBSERVER_LOG_SHIPPER_IMAGE; do
		if image_required "$key"; then printf "%s=required\\n" "$key"; else printf "%s=skipped\\n" "$key"; fi
	done
')"
grep -Fqx 'CADDY_IMAGE=required' <<<"$image_selection"
grep -Fqx 'BESZEL_AGENT_IMAGE=required' <<<"$image_selection"
grep -Fqx 'WOODPECKER_AGENT_IMAGE=required' <<<"$image_selection"
grep -Fqx 'LIBRECHAT_API_IMAGE=required' <<<"$image_selection"
grep -Fqx 'NEW_API_IMAGE=skipped' <<<"$image_selection"
grep -Fqx 'CPAPI_IMAGE=required' <<<"$image_selection"
grep -Fqx 'AICHOROUTER_IMAGE=required' <<<"$image_selection"
grep -Fqx 'CURSORAPI_IMAGE=required' <<<"$image_selection"
grep -Fqx 'OBSERVER_IMAGE=skipped' <<<"$image_selection"
grep -Fqx 'OBSERVER_LOG_PROXY_IMAGE=required' <<<"$image_selection"
grep -Fqx 'OBSERVER_LOG_SHIPPER_IMAGE=required' <<<"$image_selection"
leader_image_selection="$(IMAGE_FUNCTION="$image_function" SOURCE_ROOT="$repo_root" bash -c '
	set -Eeuo pipefail
	eval "$IMAGE_FUNCTION"
	NODE_ROLE=leader NODE_ID=leader NODE_STATE=active
	for key in CADDY_IMAGE LIBRECHAT_API_IMAGE NEW_API_IMAGE CPAPI_IMAGE AICHOROUTER_IMAGE CURSORAPI_IMAGE OBSERVER_IMAGE OBSERVER_LOG_PROXY_IMAGE OBSERVER_LOG_SHIPPER_IMAGE; do
		if image_required "$key"; then printf "%s=required\\n" "$key"; else printf "%s=skipped\\n" "$key"; fi
	done
')"
grep -Fqx 'CADDY_IMAGE=required' <<<"$leader_image_selection"
grep -Fqx 'LIBRECHAT_API_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'NEW_API_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'CPAPI_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'AICHOROUTER_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'CURSORAPI_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'OBSERVER_IMAGE=required' <<<"$leader_image_selection"
grep -Fqx 'OBSERVER_LOG_PROXY_IMAGE=required' <<<"$leader_image_selection"
grep -Fqx 'OBSERVER_LOG_SHIPPER_IMAGE=required' <<<"$leader_image_selection"

image_cleanup_helpers="$(sed -n '/^image_key_declared() {/,/^}/p; /^prune_stale_image_keys() {/,/^}/p' "$bootstrap")"
stale_image_file="$(mktemp)"
printf 'CPAPI_IMAGE=current\nCLIPROXY_IMAGE=legacy\n# retained comment\n' >"$stale_image_file"
IMAGE_CLEANUP_HELPERS="$image_cleanup_helpers" SOURCE_ROOT="$repo_root" bash -c '
	set -Eeuo pipefail
	eval "$IMAGE_CLEANUP_HELPERS"
	prune_stale_image_keys "$1"
' -- "$stale_image_file"
grep -Fqx 'CPAPI_IMAGE=current' "$stale_image_file"
grep -Fq 'CLIPROXY_IMAGE=' "$stale_image_file" && exit 1
grep -Fqx '# retained comment' "$stale_image_file"
rm -f -- "$stale_image_file"
grep -Fq 'missing cluster policy' "$bootstrap"
grep -Fq 'BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-first}"' "$bootstrap"
grep -Fq 'BOOTSTRAP_MODE must be first or repair' "$bootstrap"
grep -Fq "CLUSTER_CONFIG_VERSION=//p' \"\$policy_file\"" "$bootstrap"
grep -Fq 'NODE_STATE="$(sed -n' "$bootstrap"
grep -Fq 'cannot bootstrap a node in $NODE_STATE state' "$bootstrap"
grep -Fq 'BOOTSTRAP_MODE=repair requires an existing node installation' "$bootstrap"
grep -Fq 'find "$SOURCE_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name manifest.env' "$bootstrap"
grep -Fq 'prepare_application_secrets()' "$bootstrap"
grep -Fq 'persist_application_secrets()' "$bootstrap"
grep -Fq "s/^CLUSTER_SECRET_KEYS=//p" "$bootstrap"
grep -Fq "s/^NODE_SECRET_KEYS=//p" "$bootstrap"
grep -Fq "s/^GENERATED_SECRET_KEYS=//p" "$bootstrap"
grep -Fq 'set_key_if_changed "$CONFIG_ROOT/shared-secrets.env" "$key" "$value"' "$bootstrap"
grep -Fq 'Create the shared application environment before resolving application' "$bootstrap"
grep -Fq '"DATA_ROOT=$APP_ROOT/shared/data/prod"' "$bootstrap"
app_env_init_line="$(grep -n '^if \[\[ ! -f "\$app_env" \]\]; then$' "$bootstrap" | head -n1 | cut -d: -f1)"
prepare_call_line="$(grep -n '^prepare_application_secrets$' "$bootstrap" | head -n1 | cut -d: -f1)"
[[ -n "$app_env_init_line" && -n "$prepare_call_line" && "$app_env_init_line" -lt "$prepare_call_line" ]] || {
	printf 'bootstrap initializes .env.prod after secret reconciliation\n' >&2
	exit 1
}
grep -Fq 'manifest_secret_min_length' "$bootstrap"
grep -Fq 'manifest_secret_bytes' "$bootstrap"
grep -Fq 'manifest_secret_regex' "$bootstrap"
grep -Fq 'GENERATED_SECRET_BYTES' "$repo_root/apps/flowy/manifest.env"
grep -Fq 'SECRET_REGEXES=FLOWY_ENCRYPTION_KEY' "$repo_root/apps/flowy/manifest.env"
secret_format_helpers="$(sed -n '/^valid_input_value() {/,/^}/p; /^manifest_secret_bytes() {/,/^}/p' "$bootstrap")"
SECRET_FORMAT_HELPERS="$secret_format_helpers" bash -c '
  set -Eeuo pipefail
  eval "$SECRET_FORMAT_HELPERS"
  [[ "$(manifest_secret_bytes "$1" FLOWY_ENCRYPTION_KEY)" == 16 ]]
  valid_input_value FLOWY_ENCRYPTION_KEY 0123456789abcdef0123456789abcdef 32 "^[A-Fa-f0-9]{32}$"
  if valid_input_value FLOWY_ENCRYPTION_KEY 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 32 "^[A-Fa-f0-9]{32}$"; then
    exit 1
  fi
' -- "$repo_root/apps/flowy/manifest.env"
grep -Fq 'app_active_on_node "$app_id"' "$bootstrap"
grep -Fq 'generate_shared_secret WOODPECKER_AGENT_SECRET' "$bootstrap"
grep -Fq "prompt_required LEADER_PUBLIC_IP 'Leader public IPv4 address'" "$bootstrap"
grep -Fq "set_key \"\$CONFIG_ROOT/node.env\" LEADER_PUBLIC_IP \"\$LEADER_PUBLIC_IP\"" "$bootstrap"
grep -Fq "set_key \"\$CONFIG_ROOT/shared-secrets.env\" LEADER_PUBLIC_IP \"\$LEADER_PUBLIC_IP\"" "$bootstrap"
grep -Fq 'shared_key is required and cannot be empty' "$bootstrap"
grep -Fq '/usr/local/bin/git-auth.sh' "$bootstrap"
grep -Fq 'production bootstrap requires RESTIC_REMOTE_ENABLED=true' "$bootstrap"
grep -Fq 'remote Restic repository is unavailable or uninitialized' "$bootstrap"
grep -Fq 'restic snapshots --no-lock' "$bootstrap"
grep -Fq 'print_bootstrap_summary' "$bootstrap"
grep -Fq 'PLATFORM_RECREATE_FOUNDATION=1 PLATFORM_BOOTSTRAP_VALIDATION_REUSE=1 PLATFORM_COMPOSE_BIN="$COMPOSE_BIN" /usr/local/bin/platformctl sync all' "$bootstrap"
grep -Fq 'before starting platform.target' "$bootstrap"
grep -Fq 'flock -u 9' "$bootstrap"
grep -Fq 'start_platform_target()' "$bootstrap"
grep -Fq 'systemctl start --no-block platform.target' "$bootstrap"
grep -Fq 'ERROR: unable to queue platform.target; inspect systemd status' "$bootstrap"
grep -Fq 'platform.target queued; recovery continues in the background' "$bootstrap"
grep -Fq 'BOOTSTRAP_SYSTEMD_WAIT_SECONDS must be between 0 and 60 seconds' "$bootstrap"
grep -Fq 'BOOTSTRAP_ENDPOINT_RETRIES must be between 0 and 3' "$bootstrap"
grep -Fq 'BOOTSTRAP_ENDPOINT_TIMEOUT_SECONDS must be between 1 and 60 seconds' "$bootstrap"
grep -Fq 'systemctl reset-failed platform.target platform-network.service platform-recovery.service' "$bootstrap"
if grep -Fq 'systemctl restart platform-firewall.service platform.target' "$bootstrap"; then
	printf 'bootstrap uses the lock-cycling platform target restart\n' >&2
	exit 1
fi
lock_release_line="$(grep -n '^flock -u 9$' "$bootstrap" | tail -n1 | cut -d: -f1)"
target_start_line="$(grep -n '^start_platform_target ' "$bootstrap" | tail -n1 | cut -d: -f1)"
[[ -n "$lock_release_line" && -n "$target_start_line" && "$lock_release_line" -lt "$target_start_line" ]] || {
	printf 'bootstrap queues platform.target before releasing its lock\n' >&2
	exit 1
}
grep -Fq 'OBSERVER_LOG_PROXY_STREAM_TIMEOUT=$(observer_default_value OBSERVER_LOG_PROXY_STREAM_TIMEOUT 24h)' "$bootstrap"
grep -Fq 'for foundation_file in "$SOURCE_ROOT"/compose/foundation/*' "$bootstrap"
grep -Fq 'for foundation_file in "$SOURCE_ROOT"/compose/foundation/manifests/*.env' "$bootstrap"
grep -Fq "printf 'Services\\n  Foundation:" "$bootstrap"
grep -Fq "printf 'Endpoints\\n'" "$bootstrap"
grep -Fq "printf '\\nNext tasks\\n'" "$bootstrap"
grep -Fq "printf '\\nOperations\\n'" "$bootstrap"
grep -Fq 'available after a Follower is healthy' "$bootstrap"
grep -Fq 'available after its selected Follower is healthy' "$bootstrap"
recovery_unit="$repo_root/ops/systemd/platform-recovery.service"
grep -Fq 'OnFailure=platform-recovery-retry.service' "$recovery_unit"
if sed -n '/^\[Service\]/,/^\[/p' "$recovery_unit" | grep -Fq 'OnFailure='; then
	printf 'platform recovery OnFailure must be a Unit directive\n' >&2
	exit 1
fi
grep -Fq 'BOOTSTRAP_ASSUME_YES' "$bootstrap"
grep -Fq 'bootstrap confirmation was not received' "$bootstrap"
grep -Fq "read -r -p 'Node role (leader or follower): ' requested_role" "$bootstrap"
grep -Fq "read -r -p 'Stable follower node ID: ' NODE_ID" "$bootstrap"
grep -Fq "NODE_ID is required for non-interactive bootstrap" "$bootstrap"
grep -Fq 'origin: https://' "$bootstrap"
summary_function="$(sed -n '/^print_bootstrap_summary() {/,/^}/p' "$bootstrap")"
summary_inventory="$(mktemp)"
summary_env="$(mktemp)"
trap 'rm -f -- "$summary_inventory" "$summary_env"' EXIT
cat >"$summary_inventory" <<'EOF'
NODE_LIBRECHAT_ORIGIN_HOST=worker-chat-origin.example.test
NODE_LIBRECHAT_ADMIN_ORIGIN_HOST=worker-chat-admin-origin.example.test
EOF
cat >"$summary_env" <<'EOF'
LIBRECHAT_SITE=https://chat.example.test
AICHOROUTER_SITE=https://aichorouter.example.test
CPAPI_SITE=https://cpapi.example.test
CURSORAPI_SITE=https://cursorapi.example.test
OBSERVER_SITE=https://observer.example.test
EOF
summary_helpers='csv_contains() { local csv=",${1//[[:space:]]/},"; [[ "$csv" == *",$2,"* ]]; }
app_policy_file() { local app="$1" rel; rel="$(sed -n '\''s/^POLICY_FILE=//p'\'' "$SOURCE_ROOT/apps/$app/manifest.env" | tail -n1)"; printf "%s/config/%s\\n" "$SOURCE_ROOT" "$rel"; }
app_enabled() { [[ "$(sed -n '\''s/^ENABLED=//p'\'' "$(app_policy_file "$1")" | tail -n1)" != false ]]; }
app_nodes() { sed -n '\''s/^NODES=//p'\'' "$(app_policy_file "$1")" | tail -n1; }
app_active_on_node() { local app="$1"; app_enabled "$app" && [[ "$NODE_ROLE" == follower ]] && csv_contains "$(app_nodes "$app")" "$NODE_ID"; }
bootstrap_foundation_enabled() { local component="$1" manifest roles policy_rel enabled mandatory; manifest="$SOURCE_ROOT/compose/foundation/manifests/$component.env"; roles="$(sed -n '\''s/^ROLES=//p'\'' "$manifest" | tail -n1)"; csv_contains "$roles" "$NODE_ROLE" || return 1; policy_rel="$(sed -n '\''s/^POLICY_FILE=//p'\'' "$manifest" | tail -n1)"; enabled="$(sed -n '\''s/^ENABLED=//p'\'' "$SOURCE_ROOT/config/$policy_rel" | tail -n1)"; mandatory="$(sed -n '\''s/^MANDATORY=//p'\'' "$manifest" | tail -n1)"; [[ "$mandatory" != true || "$enabled" == true ]] && [[ "$enabled" == true ]]; }'
leader_summary="$(SUMMARY_FUNCTION="$summary_function" SUMMARY_HELPERS="$summary_helpers" INVENTORY_FILE="$summary_inventory" bash -c '
	set -Eeuo pipefail
	eval "$SUMMARY_HELPERS"
	eval "$SUMMARY_FUNCTION"
	SOURCE_ROOT="'"$repo_root"'" app_env="'"$summary_env"'" NODE_ID=leader NODE_ROLE=leader DOMAIN_NAME=example.test CONFIG_ROOT=/etc/example inventory_file="$INVENTORY_FILE"
	librechat_enabled=1 newapi_enabled=0 cpapi_enabled=0 aichorouter_enabled=0
	print_bootstrap_summary
')"
grep -Fq 'Foundation: beszel-controller, beszel-worker, caddy, observer-collector, observer-controller, woodpecker-controller, woodpecker-deployer' <<<"$leader_summary"
grep -Fq 'Consumers: none' <<<"$leader_summary"
grep -Fq 'LibreChat: https://chat.example.test (available after a Follower is healthy)' <<<"$leader_summary"
grep -Fq 'Bootstrap worker-1, then worker-2.' <<<"$leader_summary"
follower_summary="$(SUMMARY_FUNCTION="$summary_function" SUMMARY_HELPERS="$summary_helpers" INVENTORY_FILE="$summary_inventory" bash -c '
	set -Eeuo pipefail
	eval "$SUMMARY_HELPERS"
	eval "$SUMMARY_FUNCTION"
	SOURCE_ROOT="'"$repo_root"'" app_env="'"$summary_env"'" NODE_ID=worker-1 NODE_ROLE=follower DOMAIN_NAME=example.test CONFIG_ROOT=/etc/example inventory_file="$INVENTORY_FILE"
	librechat_enabled=1 newapi_enabled=0 cpapi_enabled=0 aichorouter_enabled=0
	print_bootstrap_summary
')"
grep -Fq 'Foundation: beszel-worker, caddy, observer-collector, woodpecker-worker' <<<"$follower_summary"
grep -Fq 'Consumers: Aichorouter, CPAPI, Cursor API Proxy, LibreChat' <<<"$follower_summary"
grep -Fq 'LibreChat origin: https://worker-chat-origin.example.test' <<<"$follower_summary"
grep -Fq 'Daily deployments are workflow-driven' <<<"$follower_summary"
wrapper_declaration="$(sed -n '/^for script in /p' "$bootstrap")"
while IFS= read -r executable; do
	wrapper="$(basename "${executable%% *}")"
	grep -Eq "(^|[[:space:]])${wrapper}([[:space:];]|$)" <<<"$wrapper_declaration" || {
		printf 'bootstrap does not install systemd command wrapper: %s\n' "$wrapper" >&2
		exit 1
	}
done < <(sed -n 's/^ExecStart=//p' "$repo_root"/ops/systemd/* | sort -u)
bundle_functions="$(sed -n '/^bundle_value() {/,/^}/p; /^load_bundle_value() {/,/^}/p' "$bootstrap")"
loader_result="$(BUNDLE_FUNCTIONS="$bundle_functions" bash -c '
	set -Eeuo pipefail
	eval "$BUNDLE_FUNCTIONS"
	SHARED_SECRET_BUNDLE_FILE=/missing/optional-bundle.env
	OPTIONAL_TEST_VALUE=
	load_bundle_value OPTIONAL_TEST_VALUE
	printf "continued\n"
')"
[[ "$loader_result" == continued ]] || {
	printf 'optional shared bundle lookup terminated bootstrap under set -e\n' >&2
	exit 1
}
runtime_function="$(sed -n '/^load_runtime_value() {/,/^}/p' "$bootstrap")"
runtime_result="$(RUNTIME_FUNCTION="$runtime_function" bash -c '
	set -Eeuo pipefail
	eval "$RUNTIME_FUNCTION"
	OPTIONAL_TEST_VALUE=
	load_runtime_value OPTIONAL_TEST_VALUE /missing/optional-runtime.env
	printf "continued\n"
')"
[[ "$runtime_result" == continued ]] || {
	printf 'optional runtime lookup terminated clean bootstrap under set -e\n' >&2
	exit 1
}
migration_functions="$(sed -n '/^directory_has_entries() {/p; /^move_directory_contents() {/,/^}/p' "$bootstrap")"
migration_result="$(MIGRATION_FUNCTIONS="$migration_functions" bash -c '
	set -Eeuo pipefail
	eval "$MIGRATION_FUNCTIONS"
	die() { printf "%s\n" "$*" >&2; return 1; }
	tmp="$(mktemp -d)"
	trap '\''rm -rf "$tmp"'\'' EXIT
	mkdir -p "$tmp/legacy" "$tmp/current"
	printf data >"$tmp/legacy/state.db"
	move_directory_contents "$tmp/legacy" "$tmp/current"
	[[ -f "$tmp/current/state.db" && ! -e "$tmp/legacy" ]]
	printf "migrated\n"
')"
[[ "$migration_result" == migrated ]] || {
	printf 'legacy Beszel layout migration failed\n' >&2
	exit 1
}
woodpecker_migration_functions="$(sed -n '/^directory_has_entries() {/p; /^move_directory_contents() {/,/^}/p; /^migrate_legacy_woodpecker_layout() {/,/^}/p' "$bootstrap")"
woodpecker_migration_result="$(MIGRATION_FUNCTIONS="$woodpecker_migration_functions" bash -c '
	set -Eeuo pipefail
	eval "$MIGRATION_FUNCTIONS"
	die() { printf "%s\n" "$*" >&2; return 1; }
	docker() { return 0; }
	PLATFORM_ROOT="$(mktemp -d)"
	trap '\''rm -rf "$PLATFORM_ROOT"'\'' EXIT
	mkdir -p "$PLATFORM_ROOT/woodpecker/agent/agent" "$PLATFORM_ROOT/woodpecker/agent/deployer"
	printf worker >"$PLATFORM_ROOT/woodpecker/agent/agent/agent.conf"
	printf deployer >"$PLATFORM_ROOT/woodpecker/agent/deployer/agent.conf"
	migrate_legacy_woodpecker_layout
	[[ -f "$PLATFORM_ROOT/woodpecker/agent/agent.conf" ]]
	[[ -f "$PLATFORM_ROOT/woodpecker/deployer/agent.conf" ]]
	[[ ! -e "$PLATFORM_ROOT/woodpecker/agent/agent" && ! -e "$PLATFORM_ROOT/woodpecker/agent/deployer" ]]
	printf "migrated\n"
')"
[[ "$woodpecker_migration_result" == migrated ]] || {
	printf 'legacy Woodpecker layout migration failed\n' >&2
	exit 1
}
ssh_port_function="$(sed -n '/^detect_ssh_port() {/,/^}/p' "$bootstrap")"
ssh_port_result="$(SSH_PORT_FUNCTION="$ssh_port_function" SSH_PORT=0022 bash -c '
	set -Eeuo pipefail
	eval "$SSH_PORT_FUNCTION"
	die() { return 1; }
	detect_ssh_port
	printf "%s\n" "$SSH_PORT"
')"
[[ "$ssh_port_result" == 0022 ]] || {
	printf 'explicit SSH port was not preserved\n' >&2
	exit 1
}
if SSH_PORT_FUNCTION="$ssh_port_function" SSH_PORT=70000 bash -c 'eval "$SSH_PORT_FUNCTION"; die() { return 1; }; detect_ssh_port' 2>/dev/null; then
	printf 'invalid SSH port was accepted\n' >&2
	exit 1
fi
if grep -Fq "NEW_API_SQL_DSN:-\$(openssl rand" "$bootstrap"; then
	printf 'bootstrap still generates a divergent New API DSN\n' >&2
	exit 1
fi
if grep -Fq "WOODPECKER_AGENT_SECRET:-\$(openssl rand" "$bootstrap"; then
	printf 'bootstrap still generates an unshared Woodpecker secret\n' >&2
	exit 1
fi
derived_functions="$(sed -n '/^ensure_key() {/,/^}/p; /^set_key() {/,/^}/p; /^set_derived_key() {/,/^}/p' "$bootstrap")"
derived_result="$(DERIVED_FUNCTIONS="$derived_functions" bash -c '
	set -Eeuo pipefail
	eval "$DERIVED_FUNCTIONS"
	tmp="$(mktemp -d)"
	trap '\''rm -rf "$tmp"'\'' EXIT
	printf '\''DOMAIN_NAME=old.example\nOBSERVER_SITE=https://observer.old.example\n'\'' >"$tmp/generated.env"
	set_derived_key "$tmp/generated.env" OBSERVER_SITE https://observer.new.example old.example https://observer.
	grep -Fqx '\''OBSERVER_SITE=https://observer.new.example'\'' "$tmp/generated.env"
	printf '\''OBSERVER_SITE=https://custom.example\n'\'' >"$tmp/custom.env"
	set_derived_key "$tmp/custom.env" OBSERVER_SITE https://observer.new.example old.example https://observer.
	grep -Fqx '\''OBSERVER_SITE=https://custom.example'\'' "$tmp/custom.env"
	printf '\''preserved-custom\n'\''
')"
[[ "$derived_result" == preserved-custom ]] || {
	printf 'derived URL migration did not update generated values and preserve overrides\n' >&2
	exit 1
}
printf 'bootstrap policy tests passed\n'
