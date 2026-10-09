#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/change-vps-for-leader-node.sh"

bash -n "$script"
grep -Fq -- '--dry-run' "$script"
grep -Fq -- '--resume' "$script"
grep -Fq -- '--assume-yes' "$script"
grep -Fq -- '--follower-ips' "$script"
grep -Fq 'NODE_ID=leader' "$script"
grep -Fq 'BOOTSTRAP_MODE=repair' "$script"
grep -Fq 'configure-firewall' "$script"
grep -Fq 'recreate beszel-worker' "$script"
grep -Fq 'platformctl health' "$script"
grep -Fq 'platformctl maintenance begin' "$script"
grep -Fq 'preflight passed for Leader' "$script"

grep -Fq -- '--transfer-mode' "$script"
grep -Fq 'reconcile_missing_shared_secrets' "$script"
grep -Fq 'ConnectionAttempts=3' "$script"

if "$script" --help >/dev/null 2>&1; then :; else
	printf 'leader migration help failed\n' >&2
	exit 1
fi

# Reject unknown transfer mode
if "$script" --transfer-mode invalid 127.0.0.1 127.0.0.2 >/dev/null 2>&1; then
	printf 'leader migration accepted invalid transfer mode\n' >&2
	exit 1
fi

# Reject missing operands
if "$script" >/dev/null 2>&1; then
	printf 'leader migration accepted missing operands\n' >&2
	exit 1
fi

printf 'leader migration checks passed\n'
