#!/usr/bin/env bash
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

# A failed Compose health wait must quarantine the stale identity and retry
# without pulling mutable images.
printf 'agent-id=4\n' >"$tmp/agent/agent.conf"
export WOODPECKER_STALE_LOG=1
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
printf 'Woodpecker agent repair tests passed\n'
