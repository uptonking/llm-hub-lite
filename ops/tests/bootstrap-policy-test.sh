#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap="$repo_root/ops/bootstrap-vps.sh"
bash -n "$bootstrap"
grep -Fq 'missing cluster policy' "$bootstrap"
grep -Fq 'newapi_enabled=0' "$bootstrap"
grep -Fq 'cliproxy_enabled=0' "$bootstrap"
grep -Fq 'librechat_enabled=0' "$bootstrap"
grep -Fq 'prompt_required LIBRECHAT_MONGO_URI' "$bootstrap"
grep -Fq 'prompt_required LIBRECHAT_REDIS_URI' "$bootstrap"
grep -Fq 'generate_shared_secret LIBRECHAT_JWT_SECRET' "$bootstrap"
grep -Fq 'prompt_required NEW_API_SQL_DSN' "$bootstrap"
grep -Fq 'prompt_required NEW_API_SESSION_SECRET' "$bootstrap"
grep -Fq 'generate_shared_secret WOODPECKER_AGENT_SECRET' "$bootstrap"
grep -Fq "prompt_required LEADER_PUBLIC_IP 'Leader public IPv4 address'" "$bootstrap"
grep -Fq "set_key \"\$CONFIG_ROOT/node.env\" LEADER_PUBLIC_IP \"\$LEADER_PUBLIC_IP\"" "$bootstrap"
grep -Fq "set_key \"\$CONFIG_ROOT/shared-secrets.env\" LEADER_PUBLIC_IP \"\$LEADER_PUBLIC_IP\"" "$bootstrap"
grep -Fq 'shared_key is required and cannot be empty' "$bootstrap"
grep -Fq '/usr/local/bin/git-auth.sh' "$bootstrap"
grep -Fq 'production bootstrap requires RESTIC_REMOTE_ENABLED=true' "$bootstrap"
grep -Fq 'remote Restic repository is unavailable or uninitialized' "$bootstrap"
grep -Fq 'restic snapshots --no-lock' "$bootstrap"
bundle_functions="$(sed -n '/^bundle_value() {/,/^}/p; /^load_bundle_value() {/,/^}/p' "$bootstrap")"
loader_result="$(BUNDLE_FUNCTIONS="$bundle_functions" bash -c '
	set -Eeuo pipefail
	eval "$BUNDLE_FUNCTIONS"
	SHARED_SECRET_BUNDLE_FILE=/missing/optional-bundle.env
	OPTIONAL_TEST_VALUE=
	load_bundle_value OPTIONAL_TEST_VALUE
	printf "continued\n"
')"
[[ "$loader_result" == continued ]] || {
	printf 'optional shared bundle lookup terminated bootstrap under set -e\n' >&2
	exit 1
}
if grep -Fq "NEW_API_SQL_DSN:-\$(openssl rand" "$bootstrap"; then
	printf 'bootstrap still generates a divergent New API DSN\n' >&2
	exit 1
fi
if grep -Fq "WOODPECKER_AGENT_SECRET:-\$(openssl rand" "$bootstrap"; then
	printf 'bootstrap still generates an unshared Woodpecker secret\n' >&2
	exit 1
fi
printf 'bootstrap policy tests passed\n'
