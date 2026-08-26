#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"

debug_on_failure() {
	local status="$?" file
	if ((status != 0)); then
		printf '\n--- deployment rollback test diagnostics (exit %s) ---\n' "$status" >&2
		for file in "$tmp"/deploy-*.log "$tmp"/app/deploy.log "$tmp"/platformctl.log "$tmp"/backup.log "$tmp"/docker.log "$tmp"/platform-compose.log; do
			[[ -f "$file" ]] || continue
			printf '\n[%s]\n' "${file#"$tmp"/}" >&2
			sed -n '1,240p' "$file" >&2 || true
		done
		for file in "$tmp/platform/control/current" "$tmp/platform/control/previous" "$tmp/app/current" "$tmp/app/previous"; do
			printf '[link %s] ' "${file#"$tmp"/}" >&2
			readlink "$file" 2>/dev/null || printf '<missing>\n' >&2
		done
		printf '\n[release directories]\n' >&2
		find "$tmp/platform/control/releases" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort >&2 || true
		printf '\n[worktree git state]\n' >&2
		git -C "$work" status --short 2>&1 || true
		git -C "$work" log --oneline -5 2>&1 || true
		printf '\n[mirror refs]\n' >&2
		git -C "$tmp/platform/control/mirror.git" show-ref 2>&1 || true
		printf '%s\n' '--- end deployment rollback test diagnostics ---' >&2
	fi
	rm -rf "$tmp"
	exit "$status"
}
trap debug_on_failure EXIT

remote="$tmp/remote.git"
work="$tmp/work"
mkdir -p "$work" "$tmp/bin" "$tmp/app/shared/data/prod" "$tmp/platform/foundation/env" "$tmp/config" "$tmp/locks"
git init --quiet --bare "$remote"
git init --quiet "$work"
git -C "$work" config user.email test@example.invalid
git -C "$work" config user.name deployment-test
cp -a "$repo_root/apps" "$repo_root/compose" "$repo_root/config" "$repo_root/ops" "$repo_root/.woodpecker" "$repo_root/README.md" "$work/"
git -C "$work" add .
git -C "$work" -c commit.gpgsign=false commit --quiet -m initial
git -C "$work" remote add origin "$remote"
git -C "$work" push --quiet origin HEAD:main

cat >"$tmp/bin/platformctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PLATFORMCTL_CALL_LOG:?}"
case "$1" in
  sync) [ "${FAIL_SYNC:-0}" = 1 ] && exit 1 ;;
  smoke) [ "${FAIL_SMOKE:-0}" = 1 ] && exit 1 ;;
esac
exit 0
EOF
cat >"$tmp/bin/backup-platform" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${BACKUP_CALL_LOG:?}"
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$*" in
  *"ps -aq --filter label=com.docker.compose.project=app-aichorouter"*) printf 'removed-aichorouter-container\n';;
esac
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/platform-compose" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PLATFORM_COMPOSE_CALL_LOG:?}"
exit 0
EOF
chmod +x "$tmp/bin"/*

app_root="$tmp/app"
platform_root="$tmp/platform"
config_root="$tmp/config"
cp "$repo_root/.env.prod.example" "$app_root/shared/.env.prod"
cp "$repo_root/ops/images.apps.prod.env" "$config_root/images.apps.env"
cp "$repo_root/ops/images.foundation.prod.env" "$config_root/images.foundation.env"
cp "$repo_root/ops/foundation"/*.env.example "$platform_root/foundation/env/"
cp "$repo_root/ops/foundation/observer.env.example" \
	"$platform_root/foundation/env/observer.env"
sed -e 's#^OBSERVER_ROOT_USER_EMAIL=.*#OBSERVER_ROOT_USER_EMAIL=observer-admin@aichorage.test#' \
	-e 's#^OBSERVER_ROOT_USER_PASSWORD=.*#OBSERVER_ROOT_USER_PASSWORD=test-observer-password#' \
	-e 's#^OBSERVER_INGEST_TOKEN=.*#OBSERVER_INGEST_TOKEN=o2oi_00000000000000000000000000000000#' \
	"$platform_root/foundation/env/observer.env" >"$platform_root/foundation/env/observer.env.tmp"
mv "$platform_root/foundation/env/observer.env.tmp" "$platform_root/foundation/env/observer.env"
cat >"$config_root/node.env" <<'EOF'
NODE_ID=leader
NODE_NEW_API_ORIGIN_HOST=worker2-newapi-origin.example.invalid
NODE_CPAPI_ORIGIN_HOST=worker2-cpapi-origin.example.invalid
LEADER_PUBLIC_IP=192.0.2.10
UNMANAGED_RUNTIME_VALUE=must-not-survive
EOF
cat >"$tmp/config.env" <<EOF
APP_ROOT=$app_root
PLATFORM_ROOT=$platform_root
CONTROL_ROOT=$platform_root/control
FOUNDATION_ROOT=$platform_root/foundation
CONFIG_ROOT=$config_root
REPO_URL=https://github.com/test/repo.git
MAIN_BRANCH=main
APP_ENV=$app_root/shared/.env.prod
APP_IMAGE_ENV=$config_root/images.apps.env
FOUNDATION_IMAGE_ENV=$config_root/images.foundation.env
DEPLOY_LOG=$app_root/deploy.log
PLATFORM_LOCK_FILE=$tmp/locks/platform.lock
PLATFORMCTL_SCRIPT=$tmp/bin/platformctl
BACKUP_SCRIPT=$tmp/bin/backup-platform
EOF

export PATH="$tmp/bin:$PATH" DOCKER_CALL_LOG="$tmp/docker.log" PLATFORM_COMPOSE_CALL_LOG="$tmp/platform-compose.log"
export DEPLOY_CONFIG_FILE="$tmp/config.env"
export PLATFORMCTL_CALL_LOG="$tmp/platformctl.log" BACKUP_CALL_LOG="$tmp/backup.log"
export PLATFORM_COMPOSE_BIN="$tmp/bin/platform-compose"
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$remote.insteadOf"
export GIT_CONFIG_VALUE_0=https://github.com/test/repo.git
# The test remote is intentionally a local file transport. Keep this explicit
# because newer Git versions may reject file:// fetches by default.
export GIT_CONFIG_KEY_1=protocol.file.allow
export GIT_CONFIG_VALUE_1=always

sha1="$(git -C "$work" rev-parse HEAD)"
bash "$repo_root/ops/deploy-controller.sh" deploy "$sha1" >/dev/null
current_release="$(readlink "$platform_root/control/current")"
[[ "$current_release" == "$platform_root/control/releases/$sha1" ]]
grep -qx 'sync apps' "$tmp/platformctl.log"
grep -qx 'snapshot pre-app' "$tmp/backup.log"
grep -qx 'NODE_PIGEON_ORIGIN_HOST=leader-pigeon-origin.aichorage.de' "$config_root/node.env"
grep -qx 'LEADER_PUBLIC_IP=192.0.2.10' "$config_root/node.env"
if grep -q '^UNMANAGED_RUNTIME_VALUE=' "$config_root/node.env"; then
	printf 'node inventory sync retained an undeclared runtime key\n' >&2
	exit 1
fi
if grep -Eq '^pull (calciumion/new-api|eceasy/cli-proxy-api)' "$tmp/docker.log"; then
	printf 'application deployment pulled an image for a disabled consumer\n' >&2
	exit 1
fi

# A failed inventory reconciliation must restore both the release pointer and
# the complete previous runtime node file, including the private Leader IP.
cp "$config_root/node.env" "$tmp/node.before-failed-reconcile"
sed 's/^NODE_CPAPI_ORIGIN_HOST=.*/NODE_CPAPI_ORIGIN_HOST=changed-cpapi-origin.aichorage.test/' \
	"$work/config/cluster/nodes/leader.env" >"$tmp/leader.env.changed"
mv "$tmp/leader.env.changed" "$work/config/cluster/nodes/leader.env"
git -C "$work" add config/cluster/nodes/leader.env
git -C "$work" -c commit.gpgsign=false commit --quiet -m node-inventory-change
git -C "$work" push --quiet origin HEAD:main
sha_node="$(git -C "$work" rev-parse HEAD)"
if FAIL_SYNC=1 bash "$repo_root/ops/deploy-controller.sh" cluster-reconcile "$sha_node" >"$tmp/deploy-fail-node-sync.log" 2>&1; then
	printf 'expected node inventory reconciliation failure\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha1" ]]
cmp -s "$tmp/node.before-failed-reconcile" "$config_root/node.env"
FAIL_SYNC=0 bash "$repo_root/ops/deploy-controller.sh" cluster-reconcile "$sha_node" >/dev/null
grep -qx 'NODE_CPAPI_ORIGIN_HOST=changed-cpapi-origin.aichorage.test' "$config_root/node.env"
grep -qx 'LEADER_PUBLIC_IP=192.0.2.10' "$config_root/node.env"

git -C "$work" rm --quiet -r apps/aichorouter
git -C "$work" -c commit.gpgsign=false commit --quiet -m remove-singleton
git -C "$work" push --quiet origin HEAD:main
sha_removed="$(git -C "$work" rev-parse HEAD)"
bash "$repo_root/ops/deploy-controller.sh" deploy "$sha_removed" >/dev/null
grep -Fqx 'rm -f removed-aichorouter-container' "$tmp/docker.log"

printf '\nrollback test change\n' >>"$work/README.md"
git -C "$work" add README.md
git -C "$work" -c commit.gpgsign=false commit --quiet -m change
git -C "$work" push --quiet origin HEAD:main
sha2="$(git -C "$work" rev-parse HEAD)"
: >"$tmp/platformctl.log"
if FAIL_SYNC=1 bash "$repo_root/ops/deploy-controller.sh" deploy "$sha2" >"$tmp/deploy-fail-sync.log" 2>&1; then
	printf 'expected reconciliation failure\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha_removed" ]]
grep -qx 'sync all' "$tmp/platformctl.log"

printf '\nconfig route change\n' >>"$work/config/Caddyfile"
git -C "$work" add config/Caddyfile
git -C "$work" -c commit.gpgsign=false commit --quiet -m config-change
git -C "$work" push --quiet origin HEAD:main
sha3="$(git -C "$work" rev-parse HEAD)"
if FAIL_SYNC=0 bash "$repo_root/ops/deploy-controller.sh" deploy "$sha3" >"$tmp/deploy-config-change.log" 2>&1; then
	[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha3" ]]
else
	printf 'non-cluster runtime configuration was rejected by application deployment\n' >&2
	exit 1
fi

# Environment examples are committed templates, not live host state. A
# template update may ship with an application change through the normal path.
printf '\ncombined template and app change\n' >>"$work/.env.prod.example"
printf '\n# combined app change\n' >>"$work/apps/cpapi/compose.yml"
git -C "$work" add .env.prod.example apps/cpapi/compose.yml
git -C "$work" -c commit.gpgsign=false commit --quiet -m template-and-app-change
git -C "$work" push --quiet origin HEAD:main
sha_template_app="$(git -C "$work" rev-parse HEAD)"
if ! FAIL_SYNC=0 bash "$repo_root/ops/deploy-controller.sh" deploy "$sha_template_app" >"$tmp/deploy-template-app.log" 2>&1; then
	printf 'template-plus-application change was rejected by the normal deployment path\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha_template_app" ]]

# A delayed Woodpecker build must not roll a node back implicitly. Explicit
# rollback is the only path allowed to target an older retained release.
if bash "$repo_root/ops/deploy-controller.sh" deploy "$sha3" >"$tmp/deploy-stale.log" 2>&1; then
	printf 'stale normal deployment was accepted\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha_template_app" ]]
grep -Fq 'target commit is older than the installed release' "$tmp/deploy-stale.log"

# Singleton jobs are app-scoped. An unrelated path in the same commit must be
# rejected before any backup, route, or Compose mutation occurs.
printf '\n# cpapi singleton change\n' >>"$work/apps/cpapi/compose.yml"
printf '\nunrelated file\n' >>"$work/README.md"
git -C "$work" add apps/cpapi/compose.yml README.md
git -C "$work" -c commit.gpgsign=false commit --quiet -m singleton-scope-change
git -C "$work" push --quiet origin HEAD:main
sha_singleton_scope="$(git -C "$work" rev-parse HEAD)"
if SINGLETON_APP_ID=cpapi bash "$repo_root/ops/deploy-controller.sh" singleton-stage "$sha_singleton_scope" >"$tmp/deploy-singleton-scope.log" 2>&1; then
	printf 'singleton workflow accepted an unrelated path\n' >&2
	exit 1
fi
grep -Fq 'cannot apply unrelated path: README.md' "$tmp/deploy-singleton-scope.log"

aichorouter_image="$(sed -n 's/^AICHOROUTER_IMAGE=//p' "$work/ops/images.apps.prod.env")"
aichorouter_prefix="${aichorouter_image%@sha256:*}"
aichorouter_digest="${aichorouter_image##*@sha256:}"
[[ "$aichorouter_prefix" != "$aichorouter_image" && "$aichorouter_digest" =~ ^[0-9a-f]{64}$ ]] || {
	printf 'test fixture did not contain a pinned Aichorouter image\n' >&2
	exit 1
}
aichorouter_changed_digest="${aichorouter_digest%?}0"
[[ "$aichorouter_changed_digest" != "$aichorouter_digest" ]] || aichorouter_changed_digest="${aichorouter_digest%?}1"
sed "s#^AICHOROUTER_IMAGE=.*#AICHOROUTER_IMAGE=$aichorouter_prefix@sha256:$aichorouter_changed_digest#" \
	"$work/ops/images.apps.prod.env" >"$tmp/images.apps.changed"
mv "$tmp/images.apps.changed" "$work/ops/images.apps.prod.env"
git -C "$work" add ops/images.apps.prod.env
git -C "$work" -c commit.gpgsign=false commit --quiet -m image-change
git -C "$work" push --quiet origin HEAD:main
sha_image="$(git -C "$work" rev-parse HEAD)"
if bash "$repo_root/ops/deploy-controller.sh" deploy "$sha_image" >"$tmp/deploy-image-change.log" 2>&1; then
	printf 'application image manifest change was accepted by the normal deployment path\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha_template_app" ]]
grep -Fq 'application image manifest changes require the app-upgrade or singleton workflow' "$tmp/deploy-image-change.log"

printf '\nfoundation change\n' >>"$work/compose/foundation/caddy.yml"
git -C "$work" add compose/foundation/caddy.yml
git -C "$work" -c commit.gpgsign=false commit --quiet -m foundation-change
git -C "$work" push --quiet origin HEAD:main
sha4="$(git -C "$work" rev-parse HEAD)"
if bash "$repo_root/ops/deploy-controller.sh" deploy "$sha4" >"$tmp/deploy-foundation-change.log" 2>&1; then
	printf 'foundation change was accepted by application deployment\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha3" ]]

printf '\ncluster policy change\n' >>"$work/config/cluster/policy.env"
git -C "$work" add config/cluster/policy.env
git -C "$work" -c commit.gpgsign=false commit --quiet -m cluster-change
git -C "$work" push --quiet origin HEAD:main
sha5="$(git -C "$work" rev-parse HEAD)"
if bash "$repo_root/ops/deploy-controller.sh" deploy "$sha5" >"$tmp/deploy-cluster-change.log" 2>&1; then
	printf 'cluster policy change was accepted by application deployment\n' >&2
	exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha3" ]]

printf 'deployment rollback tests passed\n'
