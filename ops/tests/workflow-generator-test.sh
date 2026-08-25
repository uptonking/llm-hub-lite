#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$repo_root/config/cluster/policy.env" "$tmp/policy.env"

# Disabled consumers must not require their migration, primary, or backup
# policy fields. The remaining deployment workflows are still generated.
sed -E '/^(NEW_API_MIGRATION_NODE_ID|NEW_API_BACKUP_NODE_ID)=/d' \
	"$tmp/policy.env" >"$tmp/policy-disabled.env"
CLUSTER_POLICY_FILE="$tmp/policy-disabled.env" WOODPECKER_WORKFLOW_ROOT="$tmp/disabled" \
	"$repo_root/ops/generate-woodpecker-workflows.sh" generate

if rg -n $'\t' "$tmp"/*.yml >/dev/null 2>&1; then
	printf 'generated workflows must not contain tab indentation\n' >&2
	exit 1
fi
if grep -R -Eq '^[[:space:]]+role:' "$tmp/disabled"; then
	printf 'generated workflows must select stable node labels, not stale role labels\n' >&2
	exit 1
fi
[[ -f "$tmp/disabled/deploy-worker-1.yml" && -f "$tmp/disabled/deploy-worker-2.yml" ]]
[[ -f "$tmp/disabled/foundation-upgrade-worker-2.yml" && -f "$tmp/disabled/runner-upgrade-worker-2.yml" && -f "$tmp/disabled/rollback-leader.yml" ]]
[[ -f "$tmp/disabled/singleton-stage-observer.yml" && -f "$tmp/disabled/singleton-switch-observer.yml" ]]
[[ -f "$tmp/disabled/singleton-stop-observer-worker-1.yml" && -f "$tmp/disabled/singleton-stop-observer-worker-2.yml" ]]
grep -Fq $'depends_on:\n  - foundation-upgrade-leader' "$tmp/disabled/foundation-upgrade-worker-1.yml"
grep -Fq $'depends_on:\n  - cluster-reconcile-leader' "$tmp/disabled/cluster-reconcile-worker-1.yml"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$tmp/disabled/deploy-smoke.yml"
grep -Fq '/run/lock/llm-hub-lite:/run/lock/llm-hub-lite' "$tmp/disabled/deploy-smoke.yml"
grep -Fq '        - apps/librechat/**' "$tmp/disabled/deploy-leader.yml"
if grep -Fq '        - apps/aichorouter/**' "$tmp/disabled/deploy-leader.yml"; then
	printf 'singleton app source must not trigger normal deployment workflow\n' >&2
	exit 1
fi
grep -Fq '        - config/routes.d/**' "$tmp/disabled/deploy-leader.yml"
grep -Fq '        - config/cluster/apps/librechat.policy' "$tmp/disabled/cluster-reconcile-leader.yml"
if grep -Fq '        - apps/observer/**' "$tmp/disabled/cluster-reconcile-leader.yml" || grep -Fq '        - config/cluster/apps/observer.policy' "$tmp/disabled/cluster-reconcile-leader.yml"; then
	printf 'singleton application paths must not trigger cluster reconciliation\n' >&2
	exit 1
fi
if grep -Fq '        - config/cluster/apps/librechat.policy' "$tmp/disabled/deploy-leader.yml"; then
	printf 'non-singleton policy must not trigger normal deployment\n' >&2
	exit 1
fi
grep -Fq '        - ops/images.apps.prod.env' "$tmp/disabled/singleton-stage-aichorouter.yml"
grep -Fq '        - apps/observer/**' "$tmp/disabled/singleton-stage-observer.yml"
if grep -Fq 'depends_on:' "$tmp/disabled/singleton-stage-observer.yml"; then
	printf 'generated singleton stage has an unrelated dependency\n' >&2
	exit 1
fi
if grep -Fq '        - config/Caddyfile' "$tmp/disabled/singleton-stage-aichorouter.yml" || grep -Fq '        - config/routes.d/**' "$tmp/disabled/singleton-stage-aichorouter.yml"; then
	printf 'singleton workflows must not own shared Caddy configuration paths\n' >&2
	exit 1
fi
if grep -Fq 'config/cluster/apps/aichorouter.policy' "$tmp/disabled/deploy-smoke.yml"; then
	printf 'singleton-only app policy must not trigger aggregate normal smoke workflow\n' >&2
	exit 1
fi
if grep -Fq 'singleton-stop-' "$tmp/disabled/deploy-smoke.yml"; then
	printf 'aggregate normal smoke workflow must not depend on singleton stop jobs\n' >&2
	exit 1
fi
if grep -Fq '        - ops/**' "$tmp/disabled/deploy-leader.yml" || grep -Fq '        - compose/foundation/**' "$tmp/disabled/deploy-leader.yml"; then
	printf 'automatic deploy workflow must not include control-plane paths\n' >&2
	exit 1
fi

cp "$repo_root/config/cluster/apps/newapi.policy" "$tmp/newapi.policy.original"
sed 's/^ENABLED=.*/ENABLED=true/' "$tmp/newapi.policy.original" >"$repo_root/config/cluster/apps/newapi.policy"
trap 'cp "$tmp/newapi.policy.original" "$repo_root/config/cluster/apps/newapi.policy"; rm -rf "$tmp"' EXIT
sed -e 's/^NEW_API_BACKUP_NODE_ID=.*/NEW_API_BACKUP_NODE_ID=missing/' "$tmp/policy.env" >"$tmp/policy-invalid.env"
if CLUSTER_POLICY_FILE="$tmp/policy-invalid.env" WOODPECKER_WORKFLOW_ROOT="$tmp/invalid" \
	"$repo_root/ops/generate-woodpecker-workflows.sh" generate >/dev/null 2>&1; then
	printf 'invalid backup node was accepted\n' >&2
	exit 1
fi

sed 's/^NEW_API_NODE_TYPE=slave$/NEW_API_NODE_TYPE=master/' \
	"$repo_root/config/cluster/nodes/worker-2.env" >"$tmp/worker-2-master.env"
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/worker-2.original.env"
cp "$tmp/worker-2-master.env" "$repo_root/config/cluster/nodes/worker-2.env"
cp "$tmp/policy.env" "$tmp/policy-multi.env"
trap 'cp "$tmp/worker-2.original.env" "$repo_root/config/cluster/nodes/worker-2.env"; cp "$tmp/newapi.policy.original" "$repo_root/config/cluster/apps/newapi.policy"; rm -rf "$tmp"' EXIT
if CLUSTER_POLICY_FILE="$tmp/policy-multi.env" "$repo_root/ops/generate-woodpecker-workflows.sh" generate >/dev/null 2>&1; then
	printf 'multiple New API masters were accepted\n' >&2
	exit 1
fi
cp "$tmp/worker-2.original.env" "$repo_root/config/cluster/nodes/worker-2.env"

printf 'workflow generator tests passed\n'
