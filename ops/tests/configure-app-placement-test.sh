#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make_fixture() {
	local name="$1" fixture
	fixture="$tmp/$name"
	mkdir -p "$fixture/ops"
	cp "$repo_root/ops/configure-app-placement.sh" "$repo_root/ops/generate-woodpecker-workflows.sh" "$repo_root/ops/images.apps.prod.env" "$fixture/ops/"
	cp -R "$repo_root/apps" "$repo_root/config" "$fixture/"
	printf '%s\n' "$fixture"
}
run_placement() {
	local fixture="$1"
	shift
	bash "$fixture/ops/configure-app-placement.sh" "$@"
}
expect_failure() {
	local expected="$1"
	shift
	if "$@" >"$tmp/failure.log" 2>&1; then
		printf 'app placement command unexpectedly succeeded: %s\n' "$expected" >&2
		exit 1
	fi
	grep -Fq "$expected" "$tmp/failure.log"
}

activation="$(make_fixture activation)"
run_placement "$activation" wobase worker-4 --disable >/dev/null
grep -Fxq 'ENABLED=false' "$activation/config/cluster/apps/wobase.policy"
grep -Fxq 'NODES=worker-4' "$activation/config/cluster/apps/wobase.policy"
[[ ! -e "$activation/.woodpecker/consumer-stage-wobase-worker-4.yml" ]]
expect_failure 'enabled app target is not an active follower: worker-4/joining' \
	run_placement "$activation" wobase --enable
grep -Fxq 'ENABLED=false' "$activation/config/cluster/apps/wobase.policy"

sed 's/^NODE_STATE=joining$/NODE_STATE=active/' "$activation/config/cluster/nodes/worker-4.env" >"$activation/worker-4.env"
mv "$activation/worker-4.env" "$activation/config/cluster/nodes/worker-4.env"
run_placement "$activation" wobase --enable >/dev/null
grep -Fxq 'ENABLED=true' "$activation/config/cluster/apps/wobase.policy"
grep -Fxq 'NODES=worker-4' "$activation/config/cluster/apps/wobase.policy"
grep -Fq 'node: worker-4' "$activation/.woodpecker/consumer-stage-wobase-worker-4.yml"
grep -Fq '/usr/local/bin/configure-app-secrets wobase --target-node worker-4 --ensure-generated' "$activation/.woodpecker/consumer-stage-wobase-worker-4.yml"
grep -Fq 'consumer-stage-wobase-worker-4' "$activation/.woodpecker/consumer-publish-wobase.yml"
grep -Fq 'consumer-publish-wobase' "$activation/.woodpecker/consumer-stop-wobase-worker-1.yml"
grep -Fq 'SINGLETON_FINAL_STOP=1 CONSUMER_APP_ID=wobase' "$activation/.woodpecker/consumer-finalize-wobase-worker-4.yml"

active_active="$(make_fixture active-active)"
run_placement "$active_active" librechat worker-2,worker-1 >/dev/null
grep -Fxq 'NODES=worker-2,worker-1' "$active_active/config/cluster/apps/librechat.policy"
grep -Fq 'consumer-stage-librechat-worker-2' "$active_active/.woodpecker/consumer-stage-librechat-worker-1.yml"
grep -Fq 'consumer-stage-librechat-worker-1' "$active_active/.woodpecker/consumer-publish-librechat.yml"
expect_failure 'singleton app cpapi requires exactly one node' \
	run_placement "$active_active" cpapi worker-1,worker-2
expect_failure 'duplicate node ID: worker-1' \
	run_placement "$active_active" librechat worker-1,worker-1
expect_failure 'consumer node must be a follower: leader' \
	run_placement "$active_active" librechat leader

rollback="$(make_fixture rollback)"
cp "$rollback/config/cluster/apps/cpapi.policy" "$rollback/cpapi.policy.before"
cat >"$rollback/failing-generator.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$rollback/failing-generator.sh"
expect_failure 'workflow generation failed; restoring the previous app policy' \
	env WORKFLOW_GENERATOR="$rollback/failing-generator.sh" bash "$rollback/ops/configure-app-placement.sh" cpapi worker-2
cmp -s "$rollback/cpapi.policy.before" "$rollback/config/cluster/apps/cpapi.policy"
if find "$rollback/config/cluster/apps" -type f \( -name '*.backup.*' -o -name '*.tmp.*' \) | grep -q .; then
	printf 'failed placement transaction left temporary policy files behind\n' >&2
	exit 1
fi

printf 'app placement configuration tests passed\n'
