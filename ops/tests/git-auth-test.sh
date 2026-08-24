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
[[ "$("$GITHUB_ASKPASS_FILE" 'Username for github.com:')" == x-access-token ]]
[[ "$("$GITHUB_ASKPASS_FILE" 'Password for github.com:')" == token-value ]]
askpass="$GITHUB_ASKPASS_FILE"
cleanup_github_https_auth
[[ ! -e "$askpass" ]]
printf 'GitHub HTTPS auth tests passed\n'
