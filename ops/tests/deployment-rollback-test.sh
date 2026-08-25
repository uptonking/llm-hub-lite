#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"

debug_on_failure() {
	local status="$?" file
	if ((status != 0)); then
		printf '\n--- deployment rollback test diagnostics (exit %s) ---\n' "$status" >&2
		for file in "$tmp"/deploy-*.log "$tmp"/app/deploy.log "$tmp"/platformctl.log "$tmp"/backup.log "$tmp"/docker.log; do
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
chmod +x "$tmp/bin"/*

app_root="$tmp/app"
platform_root="$tmp/platform"
config_root="$tmp/config"
cp "$repo_root/.env.prod.example" "$app_root/shared/.env.prod"
cp "$repo_root/ops/images.apps.prod.env" "$config_root/images.apps.env"
cp "$repo_root/ops/images.foundation.prod.env" "$config_root/images.foundation.env"
cp "$repo_root/ops/foundation"/*.env.example "$platform_root/foundation/env/"
cat >"$config_root/node.env" <<'EOF'
NODE_ID=leader
NODE_NEW_API_ORIGIN_HOST=worker2-newapi-origin.example.invalid
NODE_CPAPI_ORIGIN_HOST=worker2-cpapi-origin.example.invalid
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

export PATH="$tmp/bin:$PATH" DOCKER_CALL_LOG="$tmp/docker.log"
export DEPLOY_CONFIG_FILE="$tmp/config.env"
export PLATFORMCTL_CALL_LOG="$tmp/platformctl.log" BACKUP_CALL_LOG="$tmp/backup.log"
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
if grep -Eq '^pull (calciumion/new-api|eceasy/cli-proxy-api)' "$tmp/docker.log"; then
	printf 'application deployment pulled an image for a disabled consumer\n' >&2
	exit 1
fi

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
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha1" ]]
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
