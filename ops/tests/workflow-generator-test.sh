#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make_fixture() {
	local name="$1" root
	root="$tmp/$name"
	mkdir -p "$root/ops"
	cp "$repo_root/ops/generate-woodpecker-workflows.sh" "$root/ops/"
	cp -R "$repo_root/apps" "$root/apps"
	cp -R "$repo_root/config" "$root/config"
	cp "$repo_root/ops/images.apps.prod.env" "$root/ops/"
	printf '%s\n' "$root"
}
generate_fixture() {
	local root="$1"
	WOODPECKER_WORKFLOW_ROOT="$root/workflows" "$root/ops/generate-woodpecker-workflows.sh" generate
}
expect_invalid() {
	local root="$1" expected="$2"
	if generate_fixture "$root" >"$root/error.log" 2>&1; then
		printf 'workflow generator accepted invalid fixture: %s\n' "$expected" >&2
		exit 1
	fi
	grep -Fq "$expected" "$root/error.log"
}

base="$(make_fixture base)"
generate_fixture "$base"

# Disabled direct applications are reconciled from the Leader only so stale
# follower listeners can be stopped; they must never emit a direct-publish job.
disabled_direct="$(make_fixture disabled-direct)"
sed 's/^ENABLED=.*/ENABLED=false/' "$disabled_direct/config/cluster/apps/verge.policy" >"$disabled_direct/config/cluster/apps/verge.policy.tmp"
mv "$disabled_direct/config/cluster/apps/verge.policy.tmp" "$disabled_direct/config/cluster/apps/verge.policy"
generate_fixture "$disabled_direct"
[[ ! -e "$disabled_direct/workflows/direct-publish-verge.yml" ]]
[[ -f "$disabled_direct/workflows/consumer-publish-verge.yml" ]]
grep -Fq 'CONSUMER_APP_ID=verge /usr/local/bin/platform-submit consumer-publish' "$disabled_direct/workflows/consumer-publish-verge.yml"

if rg -n $'\t' "$base/workflows"/*.yml >/dev/null 2>&1; then
	printf 'generated workflows must not contain tab indentation\n' >&2
	exit 1
fi
if grep -R -Eq '^[[:space:]]+role:' "$base/workflows"; then
	printf 'generated workflows must select stable node labels\n' >&2
	exit 1
fi

for file in \
	push-audit.yml \
	consumer-stage-aichorouter-worker-1.yml consumer-publish-aichorouter.yml consumer-stop-aichorouter-worker-2.yml \
	consumer-finalize-aichorouter-worker-1.yml \
	consumer-stage-librechat-worker-1.yml consumer-stage-librechat-worker-2.yml consumer-publish-librechat.yml \
	consumer-stage-wapdf-worker-2.yml consumer-publish-wapdf.yml consumer-stop-wapdf-worker-1.yml \
	consumer-stop-wapdf-worker-3.yml consumer-stop-wapdf-worker-4.yml consumer-finalize-wapdf-worker-2.yml \
	consumer-publish-newapi.yml consumer-stop-newapi-worker-1.yml consumer-stop-newapi-worker-2.yml \
	foundation-upgrade-leader.yml foundation-upgrade-worker-1.yml foundation-upgrade-worker-2.yml \
	runner-upgrade-leader.yml rollback-leader.yml; do
	[[ -f "$base/workflows/$file" ]] || {
		printf 'missing generated workflow: %s\n' "$file" >&2
		exit 1
	}
done
grep -Fq 'event: push' "$base/workflows/push-audit.yml"
grep -Fq 'node: leader' "$base/workflows/push-audit.yml"
grep -Fq '/usr/local/bin/woodpecker-plan' "$base/workflows/push-audit.yml"
grep -Fq 'elif [ -f /usr/local/bin/woodpecker-plan ]' "$base/workflows/push-audit.yml"
grep -Fq "cat-file -e \"\$CI_COMMIT_SHA^{commit}\"" "$base/workflows/push-audit.yml"
grep -Fq "grep -q 'cat-file -e' /opt/platform/control/current/ops/woodpecker-plan.sh" "$base/workflows/push-audit.yml"
if grep -Fq '/usr/local/bin/woodpecker-plan:/usr/local/bin/woodpecker-plan' "$base/workflows/push-audit.yml"; then
	printf 'push audit must not bind-mount an optional planner path (Docker creates missing targets as directories)\n' >&2
	exit 1
fi
grep -Fq 'MIRROR_PATH=/opt/platform/control/mirror.git' "$base/workflows/push-audit.yml"
if grep -Fq 'depends_on:' "$base/workflows/push-audit.yml"; then
	printf 'push audit must remain visible even when control sync fails\n' >&2
	exit 1
fi
if grep -Eq '^  audit: ' "$base/workflows/push-audit.yml"; then
	printf 'push audit workflow must use labels present on the Leader agent\n' >&2
	exit 1
fi
if grep -Fq 'path:' "$base/workflows/push-audit.yml"; then
	printf 'push audit workflow must run for every main push and have no path filter\n' >&2
	exit 1
fi
for file in "$base"/workflows/consumer-{stage,publish,stop,finalize}-*.yml "$base"/workflows/cluster-reconcile-*.yml; do
	[[ -f "$file" ]] || continue
	grep -Fq 'on_empty: false' "$file" || {
		printf 'path-filtered workflow must opt out of empty commits: %s\n' "$file" >&2
		exit 1
	}
done
[[ ! -e "$base/workflows/consumer-stage-newapi-worker-1.yml" ]]
[[ ! -e "$base/workflows/consumer-stage-pigeon-worker-2.yml" ]]
[[ ! -e "$base/workflows/consumer-stop-librechat-worker-1.yml" ]]
[[ ! -e "$base/workflows/consumer-secrets-wapdf-worker-2.yml" ]]
if grep -Fq 'consumer-stage-librechat-worker-1' "$base/workflows/consumer-stage-librechat-worker-2.yml"; then
	printf 'active-active stages must fan out without stage dependencies\n' >&2
	exit 1
fi
grep -Fq 'consumer-stage-librechat-worker-1' "$base/workflows/consumer-publish-librechat.yml"
grep -Fq 'consumer-stage-librechat-worker-2' "$base/workflows/consumer-publish-librechat.yml"
grep -Fq $'depends_on:\n  - consumer-stage-aichorouter-worker-1' "$base/workflows/consumer-publish-aichorouter.yml"
grep -Fq $'depends_on:\n  - consumer-publish-aichorouter' "$base/workflows/consumer-stop-aichorouter-worker-2.yml"
grep -Fq 'consumer-stop-aichorouter-worker-2' "$base/workflows/consumer-finalize-aichorouter-worker-1.yml"
grep -Fq 'consumer-stop-aichorouter-worker-3' "$base/workflows/consumer-finalize-aichorouter-worker-1.yml"
grep -Fq 'consumer-stop-aichorouter-worker-4' "$base/workflows/consumer-finalize-aichorouter-worker-1.yml"
grep -Fq 'SINGLETON_FINAL_STOP=1 CONSUMER_APP_ID=aichorouter' "$base/workflows/consumer-finalize-aichorouter-worker-1.yml"
if grep -Fq 'SINGLETON_FINAL_STOP=1' "$base/workflows/consumer-stop-aichorouter-worker-2.yml"; then
	printf 'stale-node stop must not finalize the selected target journal\n' >&2
	exit 1
fi
grep -Fq $'depends_on:\n  - consumer-publish-newapi' "$base/workflows/consumer-stop-newapi-worker-2.yml"
grep -Fq 'CONSUMER_APP_ID=librechat /usr/local/bin/platform-submit consumer-stage' "$base/workflows/consumer-stage-librechat-worker-1.yml"
grep -Fq $'depends_on:\n  - push-audit' "$base/workflows/control-sync-leader.yml"
for node in worker-1 worker-2 worker-3 worker-4; do
	grep -Fq $'depends_on:\n  - control-sync-leader' "$base/workflows/control-sync-$node.yml"
	grep -Fq 'platform-submit control-verify' "$base/workflows/control-sync-$node.yml"
	grep -Fq 'grep -q control-verify /opt/platform/control/current/ops/platform-submit.sh' "$base/workflows/control-sync-$node.yml"
	grep -Fq 'else DEPLOY_DEBUG_LEVEL=off /usr/local/bin/platform-submit control-sync' "$base/workflows/control-sync-$node.yml"
	grep -Fq 'skip_clone: true' "$base/workflows/control-sync-$node.yml"
done
grep -Fq 'platform-submit control-sync' "$base/workflows/control-sync-leader.yml"
grep -Fq '/usr/local/bin/configure-app-secrets aichorouter --target-node worker-1 --ensure-generated' "$base/workflows/consumer-stage-aichorouter-worker-1.yml"
grep -Fq $'depends_on:\n  - control-sync-worker-1\n  - name: foundation-reconcile-leader\n    optional: true' "$base/workflows/foundation-reconcile-worker-1.yml"
if grep -R -Fq 'legacy deployment wrapper detected' "$base/workflows"; then
	printf 'generated control sync workflows must not auto-upgrade legacy wrappers\n' >&2
	exit 1
fi
for app in aichorouter cpapi cursorapi; do
	[[ -f "$base/workflows/consumer-secrets-$app-worker-1.yml" ]] || {
		printf 'missing selected-node secret workflow: %s\n' "$app/worker-1" >&2
		exit 1
	}
	[[ ! -e "$base/workflows/consumer-secrets-$app-worker-2.yml" ]] || {
		printf 'singleton app received an unselected node secret workflow: %s/worker-2\n' "$app" >&2
		exit 1
	}
done
[[ -f "$base/workflows/consumer-secrets-flowy-worker-3.yml" ]]
[[ ! -e "$base/workflows/consumer-secrets-flowy-leader.yml" ]]
for secret in FLOWY_S3_ENDPOINT FLOWY_S3_BUCKET FLOWY_S3_ACCESS_KEY_ID FLOWY_S3_SECRET_ACCESS_KEY; do
	grep -Fq "from_secret: $secret" "$base/workflows/consumer-secrets-flowy-worker-3.yml"
done
grep -Fq 'FLOWY_FILE_STORAGE_LOCATION=S3' "$base/apps/flowy/config.env"
[[ -f "$base/workflows/consumer-secrets-librechat-leader.yml" ]]
[[ -f "$base/workflows/consumer-secrets-librechat-worker-1.yml" ]]
[[ -f "$base/workflows/consumer-secrets-librechat-worker-2.yml" ]]
[[ ! -e "$base/workflows/consumer-secrets-librechat-worker-3.yml" ]]
for node in leader worker-1 worker-2; do
	grep -Fq 'from_secret: LIBRECHAT_OPENROUTER_KEY' "$base/workflows/consumer-secrets-librechat-$node.yml"
done
if grep -Fq 'from_secret: librechat_mongo_uri' "$base/workflows/consumer-secrets-librechat-worker-1.yml"; then
	printf 'mapped LibreChat secret workflow must preserve unmapped host-local secrets\n' >&2
	exit 1
fi
for file in \
	consumer-secrets-librechat-leader.yml \
	consumer-secrets-librechat-worker-1.yml \
	foundation-upgrade-leader.yml \
	runner-upgrade-leader.yml \
	rollback-leader.yml; do
	workflow="${file%.yml}"
	grep -Fq "evaluate: 'MANUAL_WORKFLOW == \"$workflow\"'" "$base/workflows/$file" || {
		printf 'manual workflow must require its explicit selector: %s\n' "$file" >&2
		exit 1
	}
done
if grep -q '^depends_on:' "$base/workflows/consumer-secrets-cpapi-worker-1.yml"; then
	printf 'manual consumer secret workflow must be independently runnable\n' >&2
	exit 1
fi
grep -Fq 'group: llm-hub-lite-node-leader' "$base/workflows/consumer-publish-cpapi.yml"
for node in leader worker-1 worker-2 worker-3; do
	[[ -f "$base/workflows/cluster-reconcile-$node.yml" ]] || {
		printf 'missing cluster reconciliation workflow: %s\n' "$node" >&2
		exit 1
	}
done
grep -Fq 'config/cluster/foundation/**' "$base/workflows/cluster-reconcile-leader.yml"
grep -Fq 'config/Caddyfile' "$base/workflows/cluster-reconcile-leader.yml"
grep -Fq 'compose/foundation/**' "$base/workflows/cluster-reconcile-leader.yml"
grep -Fq 'ops/**' "$base/workflows/cluster-reconcile-leader.yml"
grep -Fq $'depends_on:\n  - name: cluster-reconcile-leader\n    optional: true' "$base/workflows/cluster-reconcile-worker-1.yml"
WOODPECKER_WORKFLOW_ROOT="$base/workflows" "$base/ops/generate-woodpecker-workflows.sh" --check

# Rendering is staged before the live generated set is touched. An invalid
# policy therefore leaves both an existing workflow and image lock unchanged.
transactional="$(make_fixture transactional)"
generate_fixture "$transactional"
cp "$transactional/workflows/consumer-publish-cpapi.yml" "$transactional/workflow.before"
cp "$transactional/apps/cpapi/images.lock.env" "$transactional/lock.before"
sed 's/^NODES=.*/NODES=worker-1,worker-2/' "$transactional/config/cluster/apps/cpapi.policy" >"$transactional/cpapi.policy"
mv "$transactional/cpapi.policy" "$transactional/config/cluster/apps/cpapi.policy"
if generate_fixture "$transactional" >"$transactional/transaction.error" 2>&1; then
	printf 'workflow generator accepted an invalid transactional fixture\n' >&2
	exit 1
fi
cmp -s "$transactional/workflow.before" "$transactional/workflows/consumer-publish-cpapi.yml"
cmp -s "$transactional/lock.before" "$transactional/apps/cpapi/images.lock.env"

opt_in="$(make_fixture opt-in)"
sed 's/^ENABLED=.*/ENABLED=true/' "$opt_in/config/cluster/apps/pigeon.policy" >"$opt_in/pigeon.policy"
mv "$opt_in/pigeon.policy" "$opt_in/config/cluster/apps/pigeon.policy"
generate_fixture "$opt_in"
[[ -f "$opt_in/workflows/consumer-stage-pigeon-worker-2.yml" ]]
[[ -f "$opt_in/workflows/consumer-publish-pigeon.yml" ]]

wabase_opt_in="$(make_fixture wabase-opt-in)"
sed 's/^NODE_STATE=.*/NODE_STATE=active/' "$wabase_opt_in/config/cluster/nodes/worker-4.env" >"$wabase_opt_in/worker-4.env"
mv "$wabase_opt_in/worker-4.env" "$wabase_opt_in/config/cluster/nodes/worker-4.env"
sed 's/^ENABLED=.*/ENABLED=true/' "$wabase_opt_in/config/cluster/apps/wabase.policy" >"$wabase_opt_in/wabase.policy"
mv "$wabase_opt_in/wabase.policy" "$wabase_opt_in/config/cluster/apps/wabase.policy"
generate_fixture "$wabase_opt_in"
[[ -f "$wabase_opt_in/workflows/consumer-stage-wabase-worker-4.yml" ]]
[[ -f "$wabase_opt_in/workflows/consumer-publish-wabase.yml" ]]
[[ -f "$wabase_opt_in/workflows/consumer-finalize-wabase-worker-4.yml" ]]
[[ -f "$wabase_opt_in/workflows/consumer-secrets-wabase-worker-4.yml" ]]
[[ ! -e "$wabase_opt_in/workflows/consumer-secrets-wabase-leader.yml" ]]
if grep -Fq 'migrate-app-identity.sh' "$wabase_opt_in/workflows/consumer-stage-wabase-worker-4.yml" \
	"$wabase_opt_in/workflows/consumer-finalize-wabase-worker-4.yml"; then
	printf 'completed Wabase rename still generated identity migration commands\n' >&2
	exit 1
fi
secret_line="$(grep -n -- '--ensure-generated' "$wabase_opt_in/workflows/consumer-stage-wabase-worker-4.yml" | cut -d: -f1)"
stage_line="$(grep -n 'platform-submit consumer-stage' "$wabase_opt_in/workflows/consumer-stage-wabase-worker-4.yml" | cut -d: -f1)"
[[ -n "$secret_line" && -n "$stage_line" && "$secret_line" -lt "$stage_line" ]]
[[ -f "$opt_in/workflows/consumer-stop-pigeon-worker-1.yml" ]]
[[ ! -e "$opt_in/workflows/consumer-stop-pigeon-worker-2.yml" ]]
[[ -f "$opt_in/workflows/consumer-finalize-pigeon-worker-2.yml" ]]

multi_singleton="$(make_fixture multi-singleton)"
sed 's/^NODES=.*/NODES=worker-1,worker-2/' "$multi_singleton/config/cluster/apps/cpapi.policy" >"$multi_singleton/cpapi.policy"
mv "$multi_singleton/cpapi.policy" "$multi_singleton/config/cluster/apps/cpapi.policy"
expect_invalid "$multi_singleton" 'singleton application must target exactly one follower: cpapi'

duplicate="$(make_fixture duplicate)"
sed 's/^NODES=.*/NODES=worker-1,worker-1/' "$duplicate/config/cluster/apps/librechat.policy" >"$duplicate/librechat.policy"
mv "$duplicate/librechat.policy" "$duplicate/config/cluster/apps/librechat.policy"
expect_invalid "$duplicate" 'duplicate consumer node: librechat/worker-1'

leader_target="$(make_fixture leader-target)"
sed 's/^NODES=.*/NODES=leader/' "$leader_target/config/cluster/apps/cpapi.policy" >"$leader_target/cpapi.policy"
mv "$leader_target/cpapi.policy" "$leader_target/config/cluster/apps/cpapi.policy"
expect_invalid "$leader_target" 'consumer node must be an active follower: cpapi/leader'

draining="$(make_fixture draining)"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$draining/config/cluster/nodes/worker-1.env" >"$draining/worker-1.env"
mv "$draining/worker-1.env" "$draining/config/cluster/nodes/worker-1.env"
expect_invalid "$draining" 'consumer node must be an active follower: aichorouter/worker-1'

draining_leader="$(make_fixture draining-leader)"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$draining_leader/config/cluster/nodes/leader.env" >"$draining_leader/leader.env"
mv "$draining_leader/leader.env" "$draining_leader/config/cluster/nodes/leader.env"
expect_invalid "$draining_leader" 'designated Leader node must be active: leader'

# Draining followers remain cleanup and rollback targets, but must not receive
# new secret-provisioning workflows. Evacuate all committed placement first so
# the fixture models a valid draining transition.
draining_secrets="$(make_fixture draining-secrets)"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$draining_secrets/config/cluster/nodes/worker-2.env" >"$draining_secrets/worker-2.env"
mv "$draining_secrets/worker-2.env" "$draining_secrets/config/cluster/nodes/worker-2.env"
sed 's/^NODES=.*/NODES=worker-1/' "$draining_secrets/config/cluster/apps/librechat.policy" >"$draining_secrets/librechat.policy"
mv "$draining_secrets/librechat.policy" "$draining_secrets/config/cluster/apps/librechat.policy"
sed -e 's/^NODES=.*/NODES=worker-1/' -e 's/^NEW_API_BACKUP_NODE_ID=.*/NEW_API_BACKUP_NODE_ID=worker-1/' \
	"$draining_secrets/config/cluster/apps/newapi.policy" >"$draining_secrets/newapi.policy"
mv "$draining_secrets/newapi.policy" "$draining_secrets/config/cluster/apps/newapi.policy"
sed 's/^NODES=.*/NODES=worker-1/' "$draining_secrets/config/cluster/apps/pigeon.policy" >"$draining_secrets/pigeon.policy"
mv "$draining_secrets/pigeon.policy" "$draining_secrets/config/cluster/apps/pigeon.policy"
sed 's/^NODES=.*/NODES=worker-1/' "$draining_secrets/config/cluster/apps/wapdf.policy" >"$draining_secrets/wapdf.policy"
mv "$draining_secrets/wapdf.policy" "$draining_secrets/config/cluster/apps/wapdf.policy"
generate_fixture "$draining_secrets"
[[ -f "$draining_secrets/workflows/consumer-stop-aichorouter-worker-2.yml" ]]
if find "$draining_secrets/workflows" -name 'consumer-secrets-*-worker-2.yml' | grep -q .; then
	printf 'draining follower received a secret-provisioning workflow\n' >&2
	exit 1
fi

# Joining and draining nodes are lifecycle targets only. They must not receive
# new foundation or runner upgrades; draining nodes do receive the explicit
# consumer stop jobs needed to evacuate already-running placements.
for lifecycle_state in joining draining; do
	evacuating="$(make_fixture "evacuating-$lifecycle_state")"
	sed "s/^NODE_STATE=.*/NODE_STATE=$lifecycle_state/" "$evacuating/config/cluster/nodes/worker-2.env" >"$evacuating/worker-2.env"
	mv "$evacuating/worker-2.env" "$evacuating/config/cluster/nodes/worker-2.env"
	sed 's/^NODES=.*/NODES=worker-1/' "$evacuating/config/cluster/apps/librechat.policy" >"$evacuating/librechat.policy"
	mv "$evacuating/librechat.policy" "$evacuating/config/cluster/apps/librechat.policy"
	sed -e 's/^NODES=.*/NODES=worker-1/' -e 's/^NEW_API_MIGRATION_NODE_ID=.*/NEW_API_MIGRATION_NODE_ID=worker-1/' -e 's/^NEW_API_BACKUP_NODE_ID=.*/NEW_API_BACKUP_NODE_ID=worker-1/' \
		"$evacuating/config/cluster/apps/newapi.policy" >"$evacuating/newapi.policy"
	mv "$evacuating/newapi.policy" "$evacuating/config/cluster/apps/newapi.policy"
	sed 's/^NODES=.*/NODES=worker-1/' "$evacuating/config/cluster/apps/pigeon.policy" >"$evacuating/pigeon.policy"
	mv "$evacuating/pigeon.policy" "$evacuating/config/cluster/apps/pigeon.policy"
	sed 's/^NODES=.*/NODES=worker-1/' "$evacuating/config/cluster/apps/wapdf.policy" >"$evacuating/wapdf.policy"
	mv "$evacuating/wapdf.policy" "$evacuating/config/cluster/apps/wapdf.policy"
	generate_fixture "$evacuating"
	[[ ! -e "$evacuating/workflows/foundation-upgrade-worker-2.yml" ]]
	[[ ! -e "$evacuating/workflows/runner-upgrade-worker-2.yml" ]]
	if [[ "$lifecycle_state" == draining ]]; then
		[[ -f "$evacuating/workflows/consumer-stop-librechat-worker-2.yml" ]]
	else
		[[ ! -e "$evacuating/workflows/consumer-stop-librechat-worker-2.yml" ]]
	fi
done

bad_owner="$(make_fixture bad-owner)"
sed -e 's/^ENABLED=.*/ENABLED=true/' -e 's/^NEW_API_BACKUP_NODE_ID=.*/NEW_API_BACKUP_NODE_ID=leader/' \
	"$bad_owner/config/cluster/apps/newapi.policy" >"$bad_owner/newapi.policy"
mv "$bad_owner/newapi.policy" "$bad_owner/config/cluster/apps/newapi.policy"
expect_invalid "$bad_owner" 'NEW_API_BACKUP_NODE_ID is absent from New API NODES: leader'

bad_manifest="$(make_fixture bad-manifest)"
sed 's/^MANIFEST_VERSION=.*/MANIFEST_VERSION=3/' "$bad_manifest/apps/cpapi/manifest.env" >"$bad_manifest/manifest.env"
mv "$bad_manifest/manifest.env" "$bad_manifest/apps/cpapi/manifest.env"
expect_invalid "$bad_manifest" 'unsupported application manifest version'

printf 'workflow generator tests passed\n'
