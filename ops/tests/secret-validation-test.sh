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
		if "$VALIDATOR_NAME" test-value short 12; then
			exit 1
		fi
		"$VALIDATOR_NAME" test-value sufficiently-long 12
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

pigeon_target="$(sed -n 's/^PIGEON_TARGET_NODE_ID=//p' "$repo_root/config/cluster/apps/pigeon.policy" | tail -n1)"
printf 'NODE_ID=%s\n' "$pigeon_target" >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	PIGEON_SECRET_KEY=too-short PIGEON_LOGIN_PASSWORD=also-too-short \
	"$repo_root/ops/configure-app-secrets.sh" pigeon 2>&1)"; then
	printf 'disabled Pigeon accepted secret provisioning\n' >&2
	exit 1
fi
grep -Fq 'pigeon is disabled' <<<"$output"

# Validate Pigeon's dormant secret contract using an isolated opt-in checkout.
mkdir -p "$tmp/pigeon-repo/ops" "$tmp/pigeon-repo/apps" "$tmp/pigeon-repo/config/cluster/apps" "$tmp/pigeon-config"
cp "$repo_root/ops/configure-app-secrets.sh" "$tmp/pigeon-repo/ops/"
cp -R "$repo_root/apps/pigeon" "$tmp/pigeon-repo/apps/"
sed 's/^ENABLED=.*/ENABLED=true/' "$repo_root/config/cluster/apps/pigeon.policy" >"$tmp/pigeon-repo/config/cluster/apps/pigeon.policy"
if output="$(CONFIG_ROOT="$tmp/pigeon-config" NODE_CONFIG_FILE="$tmp/node.env" \
	PIGEON_SECRET_KEY=too-short PIGEON_LOGIN_PASSWORD=also-too-short \
	"$tmp/pigeon-repo/ops/configure-app-secrets.sh" pigeon 2>&1)"; then
	printf 'weak Pigeon secrets were accepted by the opt-in fixture\n' >&2
	exit 1
fi
grep -Fq 'must contain at least 32 characters' <<<"$output"

CONFIG_ROOT="$tmp/pigeon-config" NODE_CONFIG_FILE="$tmp/node.env" \
	PIGEON_SECRET_KEY=0123456789abcdef0123456789abcdef \
	PIGEON_LOGIN_PASSWORD=strong-login-password \
	"$tmp/pigeon-repo/ops/configure-app-secrets.sh" pigeon >/dev/null
grep -qx 'PIGEON_SECRET_KEY=0123456789abcdef0123456789abcdef' "$tmp/pigeon-config/pigeon.env"
grep -qx 'PIGEON_LOGIN_PASSWORD=strong-login-password' "$tmp/pigeon-config/pigeon.env"

printf 'secret validation tests passed\n'
