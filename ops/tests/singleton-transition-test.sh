#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/control/current/apps/observer" "$tmp/control/current/config/cluster/apps" \
	"$tmp/config" "$tmp/app/shared/data/prod/observer" "$tmp/config/singleton-state" "$tmp/locks"
cp "$repo_root/apps/observer/manifest.env" "$tmp/control/current/apps/observer/manifest.env"
cp "$repo_root/apps/observer/compose.yml" "$tmp/control/current/apps/observer/compose.yml"
cat >"$tmp/control/current/config/cluster/apps/observer.policy" <<'EOF'
ENABLED=true
OBSERVER_TARGET_NODE_ID=worker-1
EOF
cat >"$tmp/control/current/config/cluster/policy.env" <<'EOF'
LEADER_NODE_ID=leader
NODE_IDS=leader,worker-1,worker-2
EOF
cat >"$tmp/config/node.env" <<'EOF'
NODE_ID=worker-1
EOF
cat >"$tmp/app/shared/.env.prod" <<EOF
DATA_ROOT=$tmp/app/shared/data/prod
PLATFORM_EDGE_NETWORK=platform_edge
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${COMPOSE_CALL_LOG:?}"
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/platform-compose" "$tmp/bin/flock"
export PATH="$tmp/bin:$PATH"
export PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose"
export COMPOSE_CALL_LOG="$tmp/compose.log"
export APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp/platform" CONTROL_ROOT="$tmp/control"
export CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/config/node.env"
export APP_ENV="$tmp/app/shared/.env.prod"
export CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env"
export SINGLETON_STATE_ROOT="$tmp/config/singleton-state"
export PLATFORM_LOCK_HELD=1

root="$tmp/app/shared/data/prod/observer"
printf 'worker-2\n' >"$tmp/config/singleton-state/observer.previous-target"
mkdir -p "$root/log-buffer"
bash "$repo_root/ops/platformctl.sh" singleton-prepare observer >/dev/null
[[ -d "$root" && ! -e "$root/log-buffer" ]] || {
	printf 'ephemeral-only singleton data was not discarded\n' >&2
	exit 1
}
if find "$tmp/app/shared/data/prod" -maxdepth 1 -name 'observer.retained.*' -print -quit | grep -q .; then
	printf 'ephemeral-only singleton data was archived\n' >&2
	exit 1
fi

rm -f "$tmp/config/singleton-state/observer.transition.env"
printf 'worker-2\n' >"$tmp/config/singleton-state/observer.previous-target"
mkdir -p "$root/log-buffer"
printf 'durable\n' >"$root/data.txt"
bash "$repo_root/ops/platformctl.sh" singleton-prepare observer >/dev/null
archive="$(find "$tmp/app/shared/data/prod" -maxdepth 1 -type d -name 'observer.retained.*' -print -quit)"
[[ -n "$archive" && -f "$archive/data.txt" && ! -e "$archive/log-buffer" ]] || {
	printf 'durable singleton data was not archived correctly\n' >&2
	exit 1
}
[[ -d "$root" && ! -e "$root/data.txt" && ! -e "$root/log-buffer" ]] || {
	printf 'fresh singleton data root was not created\n' >&2
	exit 1
}
[[ "$(wc -l <"$tmp/compose.log" | tr -d ' ')" == 2 ]] || {
	printf 'singleton preparation did not stop the existing project for each move\n' >&2
	exit 1
}

cp "$tmp/control/current/apps/observer/manifest.env" "$tmp/manifest.env.bak"
sed 's/^DATA_ROOT_REL=.*/DATA_ROOT_REL=./' "$tmp/manifest.env.bak" >"$tmp/control/current/apps/observer/manifest.env"
printf 'worker-2\n' >"$tmp/config/singleton-state/observer.previous-target"
if bash "$repo_root/ops/platformctl.sh" singleton-prepare observer >/dev/null 2>&1; then
	printf 'singleton accepted a data root that escapes its application directory\n' >&2
	exit 1
fi
mv "$tmp/manifest.env.bak" "$tmp/control/current/apps/observer/manifest.env"

printf 'singleton transition tests passed\n'
