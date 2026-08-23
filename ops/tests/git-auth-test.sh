#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
printf 'token-value\n' >"$tmp/token"
chmod 600 "$tmp/token"
export GITHUB_TOKEN_FILE="$tmp/token"
# shellcheck disable=SC1091
source "$repo_root/ops/git-auth.sh"
setup_github_https_auth
[[ "$(printf 'Username for github.com:\n' | "$GITHUB_ASKPASS_FILE")" == x-access-token ]]
[[ "$(printf 'Password for github.com:\n' | "$GITHUB_ASKPASS_FILE")" == token-value ]]
askpass="$GITHUB_ASKPASS_FILE"
cleanup_github_https_auth
[[ ! -e "$askpass" ]]
printf 'GitHub HTTPS auth tests passed\n'
