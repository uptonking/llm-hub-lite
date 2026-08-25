#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Exercise both validators without requiring root. This catches accidental
# newline matching (for example, from a Bash here-string) before production.
bootstrap_validator="$(sed -n '/^valid_input_value() {/,/^}/p' "$repo_root/ops/bootstrap-vps.sh")"
secret_validator="$(sed -n '/^valid_secret_value() {/,/^}/p' "$repo_root/ops/configure-app-secrets.sh")"
for validator_name in valid_input_value valid_secret_value; do
	if [[ "$validator_name" == valid_input_value ]]; then definition="$bootstrap_validator"; else definition="$secret_validator"; fi
	VALIDATOR="$definition" VALIDATOR_NAME="$validator_name" bash -c '
		set -Eeuo pipefail
		eval "$VALIDATOR"
		"$VALIDATOR_NAME" test-value valid
		bad_value="$(printf "bad\\033value")"
		if "$VALIDATOR_NAME" test-value "$bad_value"; then
			exit 1
		fi
	'
done

if [[ "$EUID" -ne 0 ]]; then
	printf 'secret validation unit tests passed; integration test skipped because root is required by configure-app-secrets.sh\n'
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config"
target_key="$(sed -n 's/^TARGET_NODE_KEY=//p' "$repo_root/apps/aichorouter/manifest.env" | tail -n1)"
target_node="$(sed -n "s/^$target_key=//p" "$repo_root/config/cluster/apps/aichorouter.policy" | tail -n1)"
printf 'NODE_ID=%s\n' "$target_node" >"$tmp/node.env"
bad_secret="$(printf 'invalid\033session')"

if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	AICHOROUTER_SESSION_SECRET="$bad_secret" AICHOROUTER_CRYPTO_SECRET=valid-crypto \
	"$repo_root/ops/configure-app-secrets.sh" aichorouter 2>&1)"; then
	printf 'control-byte session secret was accepted\n' >&2
	exit 1
fi
grep -Fq 'contains control characters' <<<"$output"

CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	AICHOROUTER_SESSION_SECRET=valid-session AICHOROUTER_CRYPTO_SECRET=valid-crypto \
	"$repo_root/ops/configure-app-secrets.sh" aichorouter >/dev/null
grep -qx 'AICHOROUTER_SESSION_SECRET=valid-session' "$tmp/config/aichorouter.env"
grep -qx 'AICHOROUTER_CRYPTO_SECRET=valid-crypto' "$tmp/config/aichorouter.env"

printf 'secret validation tests passed\n'
