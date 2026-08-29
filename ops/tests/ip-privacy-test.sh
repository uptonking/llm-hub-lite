#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/ops/check-ip-privacy.sh"
bash "$checker" >/dev/null
bash "$checker" --cached >/dev/null
git -C "$repo_root" check-ignore --no-index -q node.env
git -C "$repo_root" check-ignore --no-index -q shared-secrets.env
git -C "$repo_root" check-ignore --no-index -q restic-r2.env
git -C "$repo_root" check-ignore --no-index -q beszel-enrollment.env

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/ops"
cp "$checker" "$tmp/ops/check-ip-privacy.sh"
git -C "$tmp" init --quiet
git -C "$tmp" config user.email test@example.invalid
git -C "$tmp" config user.name privacy-test
printf '%s\n' '127.0.0.1 10.0.0.1 172.16.0.1 192.168.0.1' >"$tmp/allowed.txt"
printf '%s\n' '192.0.2.10 198.51.100.20 203.0.113.30' >>"$tmp/allowed.txt"
git -C "$tmp" add ops/check-ip-privacy.sh allowed.txt
bash "$tmp/ops/check-ip-privacy.sh" --cached >/dev/null

# Privacy-respecting anycast DNS addresses must be allowed (not flagged).
public_ip_one="$(printf '%s.%s.%s.%s' 8 8 8 8)"
public_ip_two="$(printf '%s.%s.%s.%s' 1 1 1 1)"
printf 'PRIVATE_RUNTIME_IPS=%s %s\n' "$public_ip_one" "$public_ip_two" >"$tmp/leak.env"
git -C "$tmp" add leak.env
set +e
bash "$tmp/ops/check-ip-privacy.sh" --cached >/dev/null 2>&1
privacy_status=$?
set -e
if ((privacy_status != 0)); then
	printf 'IP privacy checker rejected privacy-respecting DNS addresses (8.8.8.8, 1.1.1.1)\n' >&2
	exit 1
fi

# A genuinely routable address must still be rejected.
printf 'EXTERNAL_ENDPOINT=%s\n' "$(printf '%s.%s.%s.%s' 9 9 9 9)" >"$tmp/leak.env"
git -C "$tmp" add leak.env
set +e
privacy_output="$(bash "$tmp/ops/check-ip-privacy.sh" --cached 2>&1)"
privacy_status=$?
set -e
if ((privacy_status == 0)); then
	printf 'IP privacy checker accepted a globally routable address\n' >&2
	exit 1
fi
[[ "$(printf '%s\n' "$privacy_output" | grep -c 'globally routable IPv4 literal')" -eq 1 ]]

printf 'IP privacy tests passed\n'
