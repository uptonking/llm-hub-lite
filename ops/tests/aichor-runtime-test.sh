#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
launcher="$repo_root/apps/aichor/entrypoint.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/workspace"

cat >"$tmp/bin/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$AICHOR_TEST_CHOWN_LOG"
EOF
cat >"$tmp/bin/base-entrypoint" <<'EOF'
#!/bin/sh
{
	printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-unset}"
	printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-unset}"
	printf 'OPENROUTER_API_KEY=%s\n' "${OPENROUTER_API_KEY-unset}"
	printf 'args=%s\n' "$*"
} >"$AICHOR_TEST_ENTRYPOINT_LOG"
EOF
chmod 700 "$tmp/bin/chown" "$tmp/bin/base-entrypoint"

run_launcher() {
	PATH="$tmp/bin:$PATH" \
		AICHOR_HOME="$tmp/home" \
		AICHOR_WORKSPACE="$tmp/workspace" \
		AICHOR_BASE_ENTRYPOINT="$tmp/bin/base-entrypoint" \
		AICHOR_TEST_CHOWN_LOG="$tmp/chown.log" \
		AICHOR_TEST_ENTRYPOINT_LOG="$tmp/entrypoint.log" \
		"$launcher" "$@"
}

: >"$tmp/chown.log"
OPENAI_API_KEY=stale-openai ANTHROPIC_API_KEY=stale-anthropic OPENROUTER_API_KEY=stale-openrouter \
	run_launcher first-start
[[ -f "$tmp/home/.aichor-ownership-v1" ]]
grep -Fxq -- "-R 1000:1000 $tmp/home $tmp/workspace" "$tmp/chown.log"
grep -Fxq -- "-R 1000:1000 $tmp/home/.paseo $tmp/home/.pi" "$tmp/chown.log"
grep -Fxq 'OPENAI_API_KEY=unset' "$tmp/entrypoint.log"
grep -Fxq 'ANTHROPIC_API_KEY=unset' "$tmp/entrypoint.log"
grep -Fxq 'OPENROUTER_API_KEY=unset' "$tmp/entrypoint.log"
grep -Fxq 'args=first-start' "$tmp/entrypoint.log"

mkdir -p "$tmp/home/.pi/agent" "$tmp/home/.paseo/runtime"
: >"$tmp/home/.pi/agent/auth.json"
: >"$tmp/home/.paseo/cli-client-id"
: >"$tmp/chown.log"
AICHOR_PI_OPENAI_ENABLED=true AICHOR_PI_OPENAI_API_KEY=test-openai \
	AICHOR_PI_ANTHROPIC_ENABLED=true AICHOR_PI_ANTHROPIC_API_KEY=test-anthropic \
	AICHOR_PI_OPENROUTER_ENABLED=true AICHOR_PI_OPENROUTER_API_KEY=test-openrouter \
	run_launcher repeat-start
grep -Fxq "1000:1000 $tmp/home $tmp/workspace" "$tmp/chown.log"
grep -Fxq -- "-R 1000:1000 $tmp/home/.paseo $tmp/home/.pi" "$tmp/chown.log"
if grep -Fxq -- "-R 1000:1000 $tmp/home $tmp/workspace" "$tmp/chown.log"; then
	printf 'repeat startup recursively scanned the entire Aichor home\n' >&2
	exit 1
fi
grep -Fxq 'OPENAI_API_KEY=test-openai' "$tmp/entrypoint.log"
grep -Fxq 'ANTHROPIC_API_KEY=test-anthropic' "$tmp/entrypoint.log"
grep -Fxq 'OPENROUTER_API_KEY=test-openrouter' "$tmp/entrypoint.log"

if AICHOR_PI_OPENAI_ENABLED=true AICHOR_PI_OPENAI_API_KEY='' run_launcher >"$tmp/missing.log" 2>&1; then
	printf 'Aichor launcher accepted an enabled Pi provider without its key\n' >&2
	exit 1
fi
grep -Fq 'AICHOR_PI_OPENAI_API_KEY is required' "$tmp/missing.log"

printf 'Aichor runtime preparation tests passed\n'
