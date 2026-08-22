#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"; mkdir -p "$fake_bin"
cat >"$fake_bin/platformctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PLATFORMCTL_CALL_LOG:?}"
case "$1" in smoke) [ "${FAIL_SMOKE:-0}" = 1 ] && exit 1 ;; esac
exit 0
EOF
cat >"$fake_bin/backup-platform" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${BACKUP_CALL_LOG:?}"
EOF
cat >"$fake_bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fake_bin"/*

remote="$tmp/remote.git"; work="$tmp/work"; mkdir -p "$work"
git init --quiet --bare "$remote"; git init --quiet "$work"
git -C "$work" config user.email test@example.invalid; git -C "$work" config user.name controller-test
cp -a "$repo_root"/{apps,compose,config,ops,.env.prod.example} "$work/"
git -C "$work" add .; git -C "$work" -c commit.gpgsign=false commit --quiet -m initial
git -C "$work" remote add origin "$remote"; git -C "$work" push --quiet origin HEAD:main

app_root="$tmp/app"; platform_root="$tmp/platform"; config_root="$tmp/config"
mkdir -p "$app_root/shared/data/prod" "$platform_root/foundation/env" "$config_root" "$tmp/locks"
cp "$repo_root/.env.prod.example" "$app_root/shared/.env.prod"
cp "$repo_root/ops/images.apps.prod.env" "$config_root/images.apps.env"
cp "$repo_root/ops/images.foundation.prod.env" "$config_root/images.foundation.env"
cp "$repo_root/ops/foundation"/*.env.example "$platform_root/foundation/env/"
for f in caddy woodpecker beszel; do cp "$repo_root/compose/foundation/$f.yml" "$platform_root/foundation/$f.yml"; done
cat >"$tmp/config.env" <<EOF
APP_ROOT=$app_root
PLATFORM_ROOT=$platform_root
CONTROL_ROOT=$platform_root/control
FOUNDATION_ROOT=$platform_root/foundation
CONFIG_ROOT=$config_root
REPO_URL=$remote
MAIN_BRANCH=main
APP_ENV=$app_root/shared/.env.prod
APP_IMAGE_ENV=$config_root/images.apps.env
FOUNDATION_IMAGE_ENV=$config_root/images.foundation.env
DEPLOY_LOG=$app_root/deploy.log
PLATFORM_LOCK_FILE=$tmp/locks/platform.lock
EOF

sha1="$(git -C "$work" rev-parse HEAD)"
export PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$tmp/config.env" PLATFORMCTL_SCRIPT="$fake_bin/platformctl" BACKUP_SCRIPT="$fake_bin/backup-platform" PLATFORMCTL_CALL_LOG="$tmp/platformctl.log" BACKUP_CALL_LOG="$tmp/backup.log" PLATFORM_COMPOSE_BIN="$fake_bin/docker"
bash "$repo_root/ops/deploy-controller.sh" deploy "$sha1"
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha1" ]]
grep -q '^sync apps$' "$tmp/platformctl.log"
grep -q '^snapshot pre-app$' "$tmp/backup.log"
[[ -f "$platform_root/control/descriptors/newapi/manifest.env" ]]

mkdir -p "$work/apps/example"
cp "$repo_root/apps/newapi/compose.yml" "$work/apps/example/compose.yml"
cp "$repo_root/apps/newapi/route.caddy" "$work/apps/example/route.caddy"
sed -i.bak 's/newapi:3000/example:3000/' "$work/apps/example/route.caddy"
sed \
  -e 's/^APP_ID=newapi/APP_ID=example/' \
  -e 's/^COMPOSE_PROJECT=app-newapi/COMPOSE_PROJECT=app-example/' \
  -e 's/^SERVICE_NAME=newapi/SERVICE_NAME=example/' \
  -e 's/^NETWORK_ALIAS=newapi/NETWORK_ALIAS=example/' \
  -e 's/^IMAGE_KEYS=NEW_API_IMAGE/IMAGE_KEYS=EXAMPLE_IMAGE/' \
  "$repo_root/apps/newapi/manifest.env" >"$work/apps/example/manifest.env"
printf 'EXAMPLE_IMAGE=example/image:v1@sha256:%064d\n' 1 >>"$work/ops/images.apps.prod.env"
git -C "$work" add .; git -C "$work" -c commit.gpgsign=false commit --quiet -m add-example
git -C "$work" push --quiet origin HEAD:main
sha2="$(git -C "$work" rev-parse HEAD)"
bash "$repo_root/ops/deploy-controller.sh" deploy "$sha2"
grep -q '^EXAMPLE_IMAGE=' "$config_root/images.apps.env"
grep -q '^NEW_API_IMAGE=' "$config_root/images.apps.env"

printf '\n# foundation change must use the reviewed foundation workflow\n' >>"$work/ops/platformctl.sh"
git -C "$work" add ops/platformctl.sh
git -C "$work" -c commit.gpgsign=false commit --quiet -m foundation-change
git -C "$work" push --quiet origin HEAD:main
sha3="$(git -C "$work" rev-parse HEAD)"
if bash "$repo_root/ops/deploy-controller.sh" deploy "$sha3"; then
  printf 'expected foundation scope rejection\n' >&2; exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha2" ]]

if FAIL_SMOKE=1 bash "$repo_root/ops/deploy-controller.sh" deploy "$sha1"; then
  printf 'expected failed smoke deployment\n' >&2; exit 1
fi
[[ "$(readlink "$platform_root/control/current")" == "$platform_root/control/releases/$sha1" ]]
printf 'controller tests passed\n'
