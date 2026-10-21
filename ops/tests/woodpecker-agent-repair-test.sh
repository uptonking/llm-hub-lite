#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/foundation/env" "$tmp/foundation/manifests" "$tmp/config" "$tmp/bin" "$tmp/locks"

cat >"$tmp/foundation/manifests/woodpecker-worker.env" <<'EOF'
COMPONENT_ID=woodpecker-worker
ENV_FILE=woodpecker.env
EOF
cat >"$tmp/foundation/manifests/woodpecker-deployer.env" <<'EOF'
COMPONENT_ID=woodpecker-deployer
ENV_FILE=woodpecker.env
EOF
cat >"$tmp/foundation/env/woodpecker.env" <<EOF
WOODPECKER_AGENT_CONFIG_ROOT=$tmp/agent
WOODPECKER_DEPLOYER_CONFIG_ROOT=$tmp/deployer
EOF
mkdir -p "$tmp/agent" "$tmp/deployer"
printf 'agent-id=2\n' >"$tmp/agent/agent.conf"
printf 'agent-id=3\n' >"$tmp/deployer/agent.conf"

cat >"$tmp/bin/compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
case "$*" in
  *"up -d "*)
    if [ ! -e "${COMPOSE_UP_MARKER:?}" ]; then
      : >"$COMPOSE_UP_MARKER"
      exit 1
    fi
    exit 0
    ;;
  *"ps --all -q"*) printf 'woodpecker-agent\n';;
esac
exit 0
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "logs --tail")
    if [ "${WOODPECKER_STALE_LOG:-0}" = 1 ]; then
      printf '%s\n' 'agent could not auth: AgentID not found in database'
    else
      printf '%s\n' 'agent could not auth: connection refused'
    fi
    ;;
  "inspect --format") printf 'running healthy\n';;
esac
exit 0
EOF
chmod +x "$tmp/bin/compose" "$tmp/bin/docker"

export PATH="$tmp/bin:$PATH"
export APP_ENV="$tmp/config/app.env" PLATFORM_ROOT="$tmp/platform"
export CONTROL_ROOT="$tmp/control" APPS_ROOT="$tmp/control/current/apps"
export FOUNDATION_ROOT="$tmp/foundation" FOUNDATION_MANIFEST_ROOT="$tmp/foundation/manifests"
export FOUNDATION_ENV_ROOT="$tmp/foundation/env" CONFIG_ROOT="$tmp/config"
export NODE_CONFIG_FILE="$tmp/config/node.env" CLUSTER_POLICY_FILE="$tmp/config/policy.env"
export PLATFORM_LOCK_FILE="$tmp/locks/platform.lock"
export COMPOSE_CALL_LOG="$tmp/compose.log" COMPOSE_UP_MARKER="$tmp/compose-up.marker"
export PLATFORM_TEST_MODE=1 PLATFORM_TEST_SKIP_EXTERNAL_VALIDATION=1 PLATFORMCTL_LIBRARY=1
: >"$APP_ENV"
: >"$NODE_CONFIG_FILE"
: >"$CLUSTER_POLICY_FILE"

source "$repo_root/ops/platformctl.sh"
# platformctl installs its own EXIT trap when sourced as a library. Restore
# this fixture's cleanup so the temporary config and identity files are always
# removed, including on an assertion failure.
cleanup_test() {
	cleanup_candidate >/dev/null 2>&1 || true
	rm -rf -- "$tmp"
}
trap cleanup_test EXIT
compose_command=("$tmp/bin/compose")

[[ "$(woodpecker_agent_config_file woodpecker-worker)" == "$tmp/agent/agent.conf" ]]
[[ "$(woodpecker_agent_config_file foundation-woodpecker-worker)" == "$tmp/agent/agent.conf" ]]
[[ "$(woodpecker_agent_config_file woodpecker-deployer)" == "$tmp/deployer/agent.conf" ]]

valid_mongo_uri 'mongodb+srv://user:password@cluster.example.mongodb.net/LibreChat'
valid_mongo_uri 'mongodb://user:password@mongo.example:27017/LibreChat'
if valid_mongo_uri 'mongodb+srv://clmongodb+srv://user:password@cluster.example.mongodb.net/'; then
	printf 'malformed duplicated Mongo scheme was accepted\n' >&2
	exit 1
fi
if valid_mongo_uri 'mongodb+srv://user:password@cluster.example.mongodb.net:27017/'; then
	printf 'mongodb+srv URI with a port was accepted\n' >&2
	exit 1
fi

export WOODPECKER_STALE_LOG=1
repair_woodpecker_agent_identity woodpecker-worker
[[ ! -e "$tmp/agent/agent.conf" ]]
[[ "$(find "$tmp/agent/orphaned" -type f -name 'agent.conf.*' | wc -l | tr -d ' ')" == 1 ]]

repair_woodpecker_agent_identity foundation-woodpecker-deployer
[[ ! -e "$tmp/deployer/agent.conf" ]]
[[ "$(find "$tmp/deployer/orphaned" -type f -name 'agent.conf.*' | wc -l | tr -d ' ')" == 1 ]]

printf 'valid-agent\n' >"$tmp/agent/agent.conf"
export WOODPECKER_STALE_LOG=0
if repair_woodpecker_agent_identity woodpecker-worker; then
	printf 'unrelated Woodpecker auth failure triggered identity quarantine\n' >&2
	exit 1
fi
[[ -s "$tmp/agent/agent.conf" ]]

# A generic health failure must fail closed. Recreating an unchanged Caddy,
# controller, or agent can interrupt the control plane that owns this command.
: >"$tmp/compose.log"
rm -f -- "$COMPOSE_UP_MARKER"
compose_command=("$tmp/bin/compose")
if PLATFORM_COMPOSE_PROJECT=caddy compose_up_wait >/dev/null 2>&1; then
	printf 'generic Compose failure triggered an implicit retry\n' >&2
	exit 1
fi
[[ "$(grep -c 'up -d --pull never --wait' "$tmp/compose.log")" == 1 ]]
if grep -Fq -- '--force-recreate' "$tmp/compose.log"; then
	printf 'generic Compose failure force-recreated an unchanged project\n' >&2
	exit 1
fi

# A failed Compose health wait must quarantine the stale identity and retry
# without pulling mutable images.
printf 'agent-id=4\n' >"$tmp/agent/agent.conf"
export WOODPECKER_STALE_LOG=1
: >"$tmp/compose.log"
rm -f -- "$COMPOSE_UP_MARKER"
compose_command=("$tmp/bin/compose")
PLATFORM_COMPOSE_PROJECT=woodpecker-worker compose_up_wait
[[ ! -e "$tmp/agent/agent.conf" ]]
grep -Fq 'up -d --pull never --wait' "$tmp/compose.log"
grep -Fq 'up -d --pull never --force-recreate --wait' "$tmp/compose.log"

# The explicit recreate command has its own Compose wait path; keep the same
# repair contract covered there as well.
printf 'agent-id=5\n' >"$tmp/agent/agent.conf"
rm -f -- "$COMPOSE_UP_MARKER"
project_enabled() { return 0; }
foundation_compose() { compose_command=("$tmp/bin/compose"); }
recreate_project woodpecker-worker
[[ ! -e "$tmp/agent/agent.conf" ]]

# Verify verify_cluster_agents in deploy-controller.sh
mkdir -p "$tmp/cluster_test/config/cluster/nodes" "$tmp/cluster_test/data"
cat >"$tmp/cluster_test/config/cluster/policy.env" <<EOF
LEADER_NODE_ID=leader
NODE_IDS=leader,worker-1
EOF
cat >"$tmp/cluster_test/config/cluster/nodes/worker-1.env" <<EOF
NODE_ID=worker-1
NODE_STATE=active
EOF
sqlite3 "$tmp/cluster_test/data/woodpecker.sqlite" <<'EOF'
create table agents (id integer primary key, name text, last_contact integer, custom_labels text);
insert into agents values (1, 'worker-1', unixepoch('now') - 10, '{"node":"worker-1"}');
insert into agents values (2, 'worker-ghost', unixepoch('now') - 3600, '{"node":"worker-ghost"}');
EOF

cat >"$tmp/cluster_test/node.env" <<EOF
NODE_ID=leader
EOF
cat >"$tmp/cluster_test/platform.env" <<EOF
REPO_URL=https://github.com/uptonking/llm-hub-lite
PLATFORM_ROOT=$tmp/cluster_test
CONTROL_ROOT=$tmp/cluster_test
APP_ROOT=$tmp/cluster_test
PLATFORM_LOCK_FILE=$tmp/cluster_test/platform.lock
CONTROL_SYNC_STATE_FILE=$tmp/cluster_test/control-sync.state
EOF

(
	REPO_ROOT="$repo_root" \
		TARGET_DIR="$tmp/cluster_test" \
		DEPLOY_CONFIG_FILE="$tmp/cluster_test/platform.env" \
		CONFIG_ROOT="$tmp/cluster_test" \
		NODE_CONFIG_FILE="$tmp/cluster_test/node.env" \
		CONTROL_SYNC_STATE_FILE="$tmp/cluster_test/control-sync.state" \
		PLATFORM_LOCK_FILE="$tmp/cluster_test/platform.lock" \
		PLATFORM_ROOT="$tmp/cluster_test" \
		WOODPECKER_DATA_ROOT="$tmp/cluster_test/data" \
		PLATFORM_TEST_MODE=1 \
		DEPLOY_VERIFY_AGENTS_TEST=1 \
		DEPLOY_AGENT_WAIT_TIMEOUT=1 \
		bash -c '
		source "$REPO_ROOT/ops/deploy-controller.sh"
		verify_cluster_agents "$TARGET_DIR" "sha" "old_sha"
	'
)
[[ "$(sqlite3 "$tmp/cluster_test/data/woodpecker.sqlite" 'SELECT count(*) FROM agents WHERE id = 2;')" -eq 0 ]]
[[ "$(sqlite3 "$tmp/cluster_test/data/woodpecker.sqlite" 'SELECT count(*) FROM agents WHERE id = 1;')" -eq 1 ]]

sqlite3 "$tmp/cluster_test/data/woodpecker.sqlite" "UPDATE agents SET last_contact = unixepoch('now') - 3600 WHERE id = 1;"
if (
	REPO_ROOT="$repo_root" \
		TARGET_DIR="$tmp/cluster_test" \
		DEPLOY_CONFIG_FILE="$tmp/cluster_test/platform.env" \
		CONFIG_ROOT="$tmp/cluster_test" \
		NODE_CONFIG_FILE="$tmp/cluster_test/node.env" \
		CONTROL_SYNC_STATE_FILE="$tmp/cluster_test/control-sync.state" \
		PLATFORM_LOCK_FILE="$tmp/cluster_test/platform.lock" \
		PLATFORM_ROOT="$tmp/cluster_test" \
		WOODPECKER_DATA_ROOT="$tmp/cluster_test/data" \
		PLATFORM_TEST_MODE=1 \
		DEPLOY_VERIFY_AGENTS_TEST=1 \
		DEPLOY_AGENT_WAIT_TIMEOUT=1 \
		bash -c '
		source "$REPO_ROOT/ops/deploy-controller.sh"
		verify_cluster_agents "$TARGET_DIR" "sha" "old_sha"
	' 2>/dev/null
); then
	printf 'verify_cluster_agents should have failed for offline follower node\n' >&2
	exit 1
fi

printf 'Woodpecker agent repair tests passed\n'
