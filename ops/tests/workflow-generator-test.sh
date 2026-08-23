#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$repo_root/config/cluster/policy.env" "$tmp/policy.env"

# Disabled consumers must not require their migration, primary, or backup
# policy fields. The remaining deployment workflows are still generated.
sed -E '/^(CLIPROXY_PRIMARY_NODE_ID|NEW_API_MIGRATION_NODE_ID|NEW_API_BACKUP_NODE_ID)=/d; s/^DISABLED_APPS=.*/DISABLED_APPS=newapi,cliproxyapi/' \
	"$tmp/policy.env" >"$tmp/policy-disabled.env"
CLUSTER_POLICY_FILE="$tmp/policy-disabled.env" WOODPECKER_WORKFLOW_ROOT="$tmp/disabled" \
	"$repo_root/ops/generate-woodpecker-workflows.sh" generate
if grep -R -Eq '^[[:space:]]+role:' "$tmp/disabled"; then
	printf 'generated workflows must select stable node labels, not stale role labels\n' >&2
	exit 1
fi
[[ -f "$tmp/disabled/deploy-worker-1.yml" && -f "$tmp/disabled/deploy-worker-2.yml" ]]
[[ -f "$tmp/disabled/foundation-upgrade-worker-2.yml" && -f "$tmp/disabled/runner-upgrade-worker-2.yml" && -f "$tmp/disabled/rollback-leader.yml" ]]
grep -Fq $'depends_on:\n  - foundation-upgrade-leader' "$tmp/disabled/foundation-upgrade-worker-1.yml"
grep -Fq $'depends_on:\n  - cluster-reconcile-leader' "$tmp/disabled/cluster-reconcile-worker-1.yml"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock' "$tmp/disabled/deploy-smoke.yml"
grep -Fq '/run/lock/llm-hub-lite:/run/lock/llm-hub-lite' "$tmp/disabled/deploy-smoke.yml"

sed -e 's/^NEW_API_BACKUP_NODE_ID=.*/NEW_API_BACKUP_NODE_ID=missing/' -e 's/^DISABLED_APPS=.*/DISABLED_APPS=cliproxyapi/' "$tmp/policy.env" >"$tmp/policy-invalid.env"
if CLUSTER_POLICY_FILE="$tmp/policy-invalid.env" WOODPECKER_WORKFLOW_ROOT="$tmp/invalid" \
	"$repo_root/ops/generate-woodpecker-workflows.sh" generate >/dev/null 2>&1; then
	printf 'invalid backup node was accepted\n' >&2
	exit 1
fi

sed 's/^NEW_API_NODE_TYPE=slave$/NEW_API_NODE_TYPE=master/' \
	"$repo_root/config/cluster/nodes/worker-2.env" >"$tmp/worker-2-master.env"
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/worker-2.original.env"
cp "$tmp/worker-2-master.env" "$repo_root/config/cluster/nodes/worker-2.env"
sed 's/^DISABLED_APPS=.*/DISABLED_APPS=cliproxyapi/' "$tmp/policy.env" >"$tmp/policy-multi.env"
trap 'cp "$tmp/worker-2.original.env" "$repo_root/config/cluster/nodes/worker-2.env"; rm -rf "$tmp"' EXIT
if CLUSTER_POLICY_FILE="$tmp/policy-multi.env" "$repo_root/ops/generate-woodpecker-workflows.sh" generate >/dev/null 2>&1; then
	printf 'multiple New API masters were accepted\n' >&2
	exit 1
fi
cp "$tmp/worker-2.original.env" "$repo_root/config/cluster/nodes/worker-2.env"

printf 'workflow generator tests passed\n'
