#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app" "$tmp/foundation" "$tmp/secrets" "$tmp/config"
printf 'SERVICE_BESZEL_DISABLE=false\n' >"$tmp/app/.env"
printf 'BESZEL_APP_URL=http://127.0.0.1:1\nBESZEL_KEY_FILE=%s/key\nBESZEL_TOKEN_FILE=%s/token\n' "$tmp/secrets" "$tmp/secrets" >"$tmp/foundation/beszel.env"
printf '%s\n' orphan >"$tmp/secrets/key"
if APP_ENV="$tmp/app/.env" BESZEL_ENV="$tmp/foundation/beszel.env" CONFIG_ROOT="$tmp/config" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" bash "$repo_root/ops/enroll-beszel.sh" 2>"$tmp/error"; then
  printf 'enrollment should wait for initial credentials\n' >&2
  exit 1
fi
if grep -q 'partial Beszel enrollment state' "$tmp/error"; then exit 1; fi
compgen -G "$tmp/secrets/orphaned/key.*" >/dev/null
printf 'SERVICE_BESZEL_DISABLE=true\n' >"$tmp/app/.env"
APP_ENV="$tmp/app/.env" BESZEL_ENV="$tmp/foundation/beszel.env" CONFIG_ROOT="$tmp/config" APP_ROOT="$tmp/app" PLATFORM_ROOT="$tmp" bash "$repo_root/ops/enroll-beszel.sh"
printf 'enrollment tests passed\n'
