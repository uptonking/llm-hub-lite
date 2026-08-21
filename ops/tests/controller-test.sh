#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
if [ "${FAIL_SMOKE:-0}" = 1 ] && [ ! -e "${FAIL_MARKER:?}" ]; then
  touch "$FAIL_MARKER"
  exit 1
fi
printf '{"success":true}\n'
EOF
cat >"$fake_bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$fake_bin/mv" <<'EOF'
#!/bin/sh
if [ "$1" = -Tf ]; then
  shift
  [ "${1:-}" = -- ] && shift
  source_path="$1"
  target_path="$2"
  /bin/rm -f "$target_path"
  exec /bin/mv "$source_path" "$target_path"
fi
exec /bin/mv "$@"
EOF
chmod +x "$fake_bin/docker" "$fake_bin/curl"
chmod +x "$fake_bin/flock" "$fake_bin/mv"
cat >"$fake_bin/backup-platform" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${BACKUP_CALL_LOG:?}"
EOF
chmod +x "$fake_bin/backup-platform"

remote="$tmp/remote.git"
work="$tmp/work"
app_root="$tmp/app"
mkdir -p "$work"
git init --quiet --bare "$remote"
git init --quiet "$work"
git -C "$work" config user.email test@example.invalid
git -C "$work" config user.name controller-test
cat >"$work/stack.sh" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$(cd -- "$(dirname -- "$0")" && pwd)" "$*" >>"${STACK_CALL_LOG:?}"
exit 0
EOF
chmod +x "$work/stack.sh"
mkdir -p "$work/config"
printf 'caddy\n' >"$work/config/Caddyfile"
printf 'services: {}\n' >"$work/docker-compose.base.yml"
printf 'services: {}\n' >"$work/docker-compose.prod.yml"
git -C "$work" add .
git -C "$work" -c commit.gpgsign=false commit --quiet -m initial
git -C "$work" remote add origin "$remote"
git -C "$work" push --quiet origin HEAD:main

mkdir -p "$app_root/shared/data/prod"
printf 'persisted\n' >"$app_root/shared/data/prod/state"
env_file="$app_root/shared/.env.prod"
cat >"$env_file" <<EOF
DATA_ROOT=$app_root/shared/data/prod
NEW_API_SITE=https://newapi.example.invalid
CLIPROXY_SITE=https://cpa.example.invalid
WOODPECKER_SITE=https://ci.example.invalid
BESZEL_SITE=https://status.example.invalid
SSL_EMAIL=test@example.invalid
EOF
image_env="$tmp/images.env"
cat >"$image_env" <<EOF
CADDY_IMAGE=caddy:2.10.0@sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de
NEW_API_IMAGE=calciumion/new-api:v1.0.0-rc.25@sha256:54a0b10924aa75fa5b5947208b820ced66b6ef4b445b35f122b31d80676aba2b
CLIPROXY_IMAGE=eceasy/cli-proxy-api:v7.2.137@sha256:591a09c19de769be09a2e56277365cd568b83fc7d98c94d2e7e7bef7069f7422
EOF
config="$tmp/deploy.env"
cat >"$config" <<EOF
APP_ROOT=$app_root
REPO_URL=$remote
MAIN_BRANCH=main
ENV_FILE=$env_file
IMAGE_ENV_FILE=$image_env
RETAIN_RELEASES=1
DEPLOY_LOG=$app_root/shared/logs/deploy.log
PLATFORM_LOCK_FILE=$app_root/shared/platform.lock
EOF

controller="$repo_root/ops/deploy-controller.sh"
stack_call_log="$tmp/stack-calls.log"
backup_call_log="$tmp/backup-calls.log"
fail_marker="$tmp/fail-smoke-once"
export BACKUP_SCRIPT="$fake_bin/backup-platform" BACKUP_CALL_LOG="$backup_call_log" FAIL_MARKER="$fail_marker"
sha1="$(git -C "$work" rev-parse HEAD)"
mkdir -p "$app_root/shared/runtime"
printf 'legacy compose file\n' >"$app_root/shared/runtime/docker-compose.yml"
PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" "$controller" deploy "$sha1"
[[ "$(readlink "$app_root/current")" == "$app_root/releases/$sha1" ]]
[[ -L "$app_root/current" ]]
[[ ! -e "$app_root/shared/runtime/docker-compose.yml" ]]
grep -q "^$app_root/releases/$sha1|prod validate$" "$stack_call_log"
grep -q "^$app_root/shared/runtime|prod up --wait --wait-timeout 180$" "$stack_call_log"
grep -q "^$app_root/shared/runtime|prod reload$" "$stack_call_log"
cmp "$work/config/Caddyfile" "$app_root/shared/runtime/config/Caddyfile"
grep -q '^snapshot pre-deploy$' "$backup_call_log"
PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" "$controller" deploy "$sha1"

printf 'second\n' >"$work/marker"
git -C "$work" add marker
git -C "$work" -c commit.gpgsign=false commit --quiet -m second
git -C "$work" push --quiet origin HEAD:main
sha2="$(git -C "$work" rev-parse HEAD)"
PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" "$controller" deploy "$sha2"
[[ "$(readlink "$app_root/current")" == "$app_root/releases/$sha2" ]]
[[ "$(readlink "$app_root/previous")" == "$app_root/releases/$sha1" ]]
[[ "$(grep -c "^$app_root/shared/runtime|prod up " "$stack_call_log")" -eq 3 ]]

if PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" FAIL_SMOKE=1 "$controller" deploy "$sha1"; then
  printf 'expected smoke failure\n' >&2
  exit 1
fi
grep -q '^result=rolled_back$' "$app_root/shared/deploy-status.env"
[[ "$(readlink "$app_root/current")" == "$app_root/releases/$sha2" ]]
[[ "$(readlink "$app_root/previous")" == "$app_root/releases/$sha2" ]]
PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" "$controller" rollback "$sha1"
[[ "$(readlink "$app_root/current")" == "$app_root/releases/$sha1" ]]
[[ "$(readlink "$app_root/previous")" == "$app_root/releases/$sha2" ]]

if PATH="$fake_bin:$PATH" DEPLOY_CONFIG_FILE="$config" STACK_CALL_LOG="$stack_call_log" "$controller" deploy not-a-sha; then
  printf 'expected SHA validation failure\n' >&2
  exit 1
fi

printf 'controller tests passed\n'
