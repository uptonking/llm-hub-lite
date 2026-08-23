#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/etc" "$tmp/beszel" "$tmp/control/current/config/cluster/nodes"
printf '%s\n' 'NODE_ID=worker-1' >"$tmp/etc/node.env"
: >"$tmp/app.env"
printf '%s\n' 'LEADER_NODE_ID=leader' >"$tmp/control/current/config/cluster/policy.env"
printf 'BESZEL_KEY_FILE=%s/key\nBESZEL_TOKEN_FILE=%s/token\nBESZEL_APP_URL=https://status.example\n' "$tmp/beszel" "$tmp/beszel" >"$tmp/beszel.env"
printf '%s\n' \
	'BESZEL_HUB_URL=https://status.example' \
	'BESZEL_HUB_PUBLIC_KEY=ssh-ed25519 AAA' \
	'BESZEL_UNIVERSAL_TOKEN=token' >"$tmp/etc/bundle"
APP_ENV="$tmp/app.env" BESZEL_ENV="$tmp/beszel.env" \
	NODE_CONFIG_FILE="$tmp/etc/node.env" CLUSTER_POLICY_FILE="$tmp/control/current/config/cluster/policy.env" \
	BESZEL_ENROLLMENT_BUNDLE="$tmp/etc/bundle" \
	bash "$repo_root/ops/enroll-beszel.sh" >/dev/null
[[ "$(<"$tmp/beszel/key")" == 'ssh-ed25519 AAA' ]]
[[ "$(<"$tmp/beszel/token")" == token ]]
printf 'Beszel enrollment tests passed\n'
