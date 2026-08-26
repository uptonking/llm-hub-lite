#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns intentionally match literal '$var' text
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/clean-vps.sh"
bash -n "$script"
grep -Fq 'DELETE LLM-HUB-LITE DATA' "$script"
grep -Fq 'docker stop --time 90' "$script"
grep -Fq 'log "deleting managed path: $path"' "$script"
grep -Fq 'app-pigeon' "$script"
grep -Fq 'app-pigeon_private' "$script"
if grep -Eq 'local -n|declare -n' "$script"; then
	printf 'cleanup must remain compatible with Bash 3.2\n' >&2
	exit 1
fi
if grep -Fq 'docker rm -f' "$script"; then
	printf 'cleanup must stop containers before removing them\n' >&2
	exit 1
fi
if grep -Eq '(^|[[:space:]])(ufw|iptables)([[:space:]]|$)' "$script"; then
	printf 'cleanup must not mutate firewall state\n' >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "ps -aq") exit 0 ;;
  "network inspect") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/docker"
output="$(PATH="$tmp/bin:$PATH" CLEAN_VPS_TEST_MODE=1 bash "$script" --dry-run)"
grep -Fq 'Dry run only; no changes were made.' <<<"$output"
grep -Fq 'preserve /opt/backups/llm-hub-lite (default)' <<<"$output"
grep -Fq 'Docker images: preserve (default)' <<<"$output"

if CLEAN_VPS_TEST_MODE=1 bash "$script" --confirm </dev/null >/dev/null 2>&1; then
	printf 'non-interactive confirmation unexpectedly succeeded\n' >&2
	exit 1
fi

printf 'clean-vps tests passed\n'
