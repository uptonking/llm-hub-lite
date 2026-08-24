#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap="$repo_root/ops/bootstrap-vps.sh"
bash -n "$bootstrap"
grep -Fq 'shell xtrace was disabled before loading secrets' "$bootstrap"
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
grep -Fq 'LibreChat Upstash requires a TLS rediss:// URI' "$bootstrap"
grep -Fq 'unable to pull image after $attempt attempts' "$bootstrap"
grep -Fq 'pull_image "$image_ref"' "$bootstrap"
grep -Fq 'unable to fetch $MAIN_BRANCH after $attempt attempts' "$bootstrap"
grep -Fq 'git_fetch_bootstrap' "$bootstrap"
grep -Fq 'unable to clone $MAIN_BRANCH after $attempt attempts' "$bootstrap"
grep -Fq 'source root already exists but is not a Git checkout' "$bootstrap"
grep -Fq 'Skipping image for disabled or inactive service' "$bootstrap"
image_function="$(sed -n '/^csv_contains() {/,/^}/p; /^bootstrap_foundation_enabled() {/,/^}/p; /^image_required() {/,/^}/p' "$bootstrap")"
image_selection="$(IMAGE_FUNCTION="$image_function" bash -c '
	set -Eeuo pipefail
	eval "$IMAGE_FUNCTION"
	tmp_policy="$(mktemp)"
	trap '\''rm -f "$tmp_policy"'\'' EXIT
	printf "FOUNDATION_FOLLOWER=beszel-worker,woodpecker-worker\\nDISABLED_FOUNDATION=\\n" >"$tmp_policy"
	policy_file="$tmp_policy" NODE_ROLE=follower
	newapi_enabled=0 cliproxy_enabled=0 librechat_enabled=1
	for key in CADDY_IMAGE BESZEL_AGENT_IMAGE WOODPECKER_AGENT_IMAGE LIBRECHAT_API_IMAGE NEW_API_IMAGE CLIPROXY_IMAGE; do
		if image_required "$key"; then printf "%s=required\\n" "$key"; else printf "%s=skipped\\n" "$key"; fi
	done
')"
grep -Fqx 'CADDY_IMAGE=required' <<<"$image_selection"
grep -Fqx 'BESZEL_AGENT_IMAGE=required' <<<"$image_selection"
grep -Fqx 'WOODPECKER_AGENT_IMAGE=required' <<<"$image_selection"
grep -Fqx 'LIBRECHAT_API_IMAGE=required' <<<"$image_selection"
grep -Fqx 'NEW_API_IMAGE=skipped' <<<"$image_selection"
grep -Fqx 'CLIPROXY_IMAGE=skipped' <<<"$image_selection"
leader_image_selection="$(IMAGE_FUNCTION="$image_function" bash -c '
	set -Eeuo pipefail
	eval "$IMAGE_FUNCTION"
	tmp_policy="$(mktemp)"
	trap '\''rm -f "$tmp_policy"'\'' EXIT
	printf "FOUNDATION_LEADER=caddy,woodpecker-controller,woodpecker-deployer,beszel-controller,beszel-worker\\nDISABLED_FOUNDATION=\\n" >"$tmp_policy"
	policy_file="$tmp_policy" NODE_ROLE=leader
	newapi_enabled=1 cliproxy_enabled=1 librechat_enabled=1
	for key in CADDY_IMAGE LIBRECHAT_API_IMAGE NEW_API_IMAGE CLIPROXY_IMAGE; do
		if image_required "$key"; then printf "%s=required\\n" "$key"; else printf "%s=skipped\\n" "$key"; fi
	done
')"
grep -Fqx 'CADDY_IMAGE=required' <<<"$leader_image_selection"
grep -Fqx 'LIBRECHAT_API_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'NEW_API_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fqx 'CLIPROXY_IMAGE=skipped' <<<"$leader_image_selection"
grep -Fq 'if [[ "$NODE_ROLE" == leader ]]; then' "$bootstrap"
grep -Fq 'missing cluster policy' "$bootstrap"
grep -Fq 'newapi_enabled=0' "$bootstrap"
grep -Fq 'cliproxy_enabled=0' "$bootstrap"
grep -Fq 'librechat_enabled=0' "$bootstrap"
grep -Fq 'prompt_required LIBRECHAT_MONGO_URI' "$bootstrap"
grep -Fq 'prompt_required LIBRECHAT_REDIS_URI' "$bootstrap"
grep -Fq 'generate_shared_secret LIBRECHAT_JWT_SECRET' "$bootstrap"
grep -Fq 'prompt_required NEW_API_SQL_DSN' "$bootstrap"
grep -Fq 'prompt_required NEW_API_SESSION_SECRET' "$bootstrap"
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
grep -Fq "printf 'Services\\n  Foundation:" "$bootstrap"
grep -Fq "printf 'Endpoints\\n'" "$bootstrap"
grep -Fq "printf '\\nNext tasks\\n'" "$bootstrap"
grep -Fq "printf '\\nOperations\\n'" "$bootstrap"
grep -Fq 'available after a Follower is healthy' "$bootstrap"
grep -Fq 'LibreChat origin:' "$bootstrap"
summary_function="$(sed -n '/^print_bootstrap_summary() {/,/^}/p' "$bootstrap")"
summary_inventory="$(mktemp)"
trap 'rm -f -- "$summary_inventory"' EXIT
cat >"$summary_inventory" <<'EOF'
NODE_LIBRECHAT_ORIGIN_HOST=worker-chat-origin.example.test
NODE_LIBRECHAT_ADMIN_ORIGIN_HOST=worker-chat-admin-origin.example.test
EOF
leader_summary="$(SUMMARY_FUNCTION="$summary_function" INVENTORY_FILE="$summary_inventory" bash -c '
	set -Eeuo pipefail
	eval "$SUMMARY_FUNCTION"
	NODE_ID=leader NODE_ROLE=leader DOMAIN_NAME=example.test CONFIG_ROOT=/etc/example inventory_file="$INVENTORY_FILE"
	librechat_enabled=1 newapi_enabled=0 cliproxy_enabled=0
	print_bootstrap_summary
')"
grep -Fq 'Foundation: Caddy, Beszel Hub, Beszel Agent, Woodpecker Server, Woodpecker Deployer' <<<"$leader_summary"
grep -Fq 'Consumers: none' <<<"$leader_summary"
grep -Fq 'LibreChat: https://chat.example.test (available after a Follower is healthy)' <<<"$leader_summary"
grep -Fq 'Bootstrap worker-1, then worker-2.' <<<"$leader_summary"
follower_summary="$(SUMMARY_FUNCTION="$summary_function" INVENTORY_FILE="$summary_inventory" bash -c '
	set -Eeuo pipefail
	eval "$SUMMARY_FUNCTION"
	NODE_ID=worker-1 NODE_ROLE=follower DOMAIN_NAME=example.test CONFIG_ROOT=/etc/example inventory_file="$INVENTORY_FILE"
	librechat_enabled=1 newapi_enabled=0 cliproxy_enabled=0
	print_bootstrap_summary
')"
grep -Fq 'Foundation: Caddy, Beszel Agent, Woodpecker Agent' <<<"$follower_summary"
grep -Fq 'Consumers: LibreChat' <<<"$follower_summary"
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
printf 'bootstrap policy tests passed\n'
