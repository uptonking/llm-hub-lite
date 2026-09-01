#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Exercise both validators without requiring root. This catches accidental
# newline matching (for example, from a Bash here-string) before production.
bootstrap_validator="$(sed -n '/^valid_mongo_uri() {/,/^}/p; /^valid_input_value() {/,/^}/p' "$repo_root/ops/bootstrap-vps.sh")"
VALIDATOR="$bootstrap_validator" bash -c '
		set -Eeuo pipefail
		eval "$VALIDATOR"
		valid_input_value test-value valid
		valid_input_value LIBRECHAT_MONGO_URI mongodb+srv://user:password@cluster.mongodb.net/LibreChat
		if valid_input_value LIBRECHAT_MONGO_URI mongodb+srv://clmongodb+srv://user:password@cluster.mongodb.net/LibreChat; then
			exit 1
		fi
		if valid_input_value test-value short 12; then
			exit 1
		fi
		valid_input_value test-value sufficiently-long 12
		bad_value="$(printf "bad\\033value")"
		if valid_input_value test-value "$bad_value"; then
			exit 1
		fi
	'
secret_validator="$(sed -n '/^placeholder_value() {/,/^}/p; /^valid_mongo_uri() {/,/^}/p; /^secret_regex() {/,/^}/p; /^validate_secret() {/,/^}/p' "$repo_root/ops/configure-app-secrets.sh")"
VALIDATOR="$secret_validator" bash -c '
	set -Eeuo pipefail
	secret_regexes=""
	eval "$VALIDATOR"
	validate_secret test-value valid 1
	validate_secret LIBRECHAT_MONGO_URI mongodb+srv://user:password@cluster.mongodb.net/LibreChat 1
	if validate_secret LIBRECHAT_MONGO_URI mongodb+srv://clmongodb+srv://user:password@cluster.mongodb.net/LibreChat 1; then
		exit 1
	fi
	if validate_secret test-value short 12; then
		exit 1
	fi
	validate_secret test-value sufficiently-long 12
	bad_value="$(printf "bad\\033value")"
	if validate_secret test-value "$bad_value" 1; then
		exit 1
	fi
'

# Planned-target provisioning is intentionally explicit: it lets an operator
# prepare a future follower without changing committed placement policy.
grep -Fq -- '--target-node <node-id>' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'explicit target must be a follower' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'target node is absent from NODE_IDS' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'target descriptor NODE_ID mismatch' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'target node is not active' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'cluster policy was not changed' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq -- '--ensure-generated' "$repo_root/ops/configure-app-secrets.sh"
grep -Fq 'Automatic deployment may create only explicitly node-local keys' "$repo_root/ops/configure-app-secrets.sh"
# shellcheck disable=SC2016 # Assert the literal command in the implementation.
grep -Fq 'node_keys="$(generated_subset "$node_keys")"' "$repo_root/ops/configure-app-secrets.sh"

if [[ "$EUID" -ne 0 ]]; then
	printf 'secret validation unit tests passed; integration test skipped because root is required by configure-app-secrets.sh\n'
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config"
target_node="$(sed -n 's/^NODES=//p' "$repo_root/config/cluster/apps/aichorouter.policy" | tail -n1)"
[[ -n "$target_node" && "$target_node" != *,* ]]
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

cursorapi_target="$(sed -n 's/^NODES=//p' "$repo_root/config/cluster/apps/cursorapi.policy" | tail -n1)"
[[ -n "$cursorapi_target" && "$cursorapi_target" != *,* ]]
printf 'NODE_ID=%s\n' "$cursorapi_target" >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	CURSORAPI_CURSOR_API_KEY=too-short CURSORAPI_BRIDGE_API_KEY=also-too-short \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi 2>&1)"; then
	printf 'weak Cursorapi secrets were accepted\n' >&2
	exit 1
fi
grep -Fq 'must contain at least 16 characters' <<<"$output"

CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	CURSORAPI_CURSOR_API_KEY=cursor-key-123456 CURSORAPI_BRIDGE_API_KEY=0123456789abcdef0123456789abcdef \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi >/dev/null
grep -qx 'CURSORAPI_CURSOR_API_KEY=cursor-key-123456' "$tmp/config/cursorapi.env"
grep -qx 'CURSORAPI_BRIDGE_API_KEY=0123456789abcdef0123456789abcdef' "$tmp/config/cursorapi.env"

printf 'NODE_ID=worker-2\n' >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	CURSORAPI_CURSOR_API_KEY=cursor-key-123456 CURSORAPI_BRIDGE_API_KEY=0123456789abcdef0123456789abcdef \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi 2>&1)"; then
	printf 'future target accepted provisioning without --target-node\n' >&2
	exit 1
fi
grep -Fq 'is not placed on this follower' <<<"$output"

output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	CURSORAPI_CURSOR_API_KEY=cursor-key-654321 CURSORAPI_BRIDGE_API_KEY=fedcba9876543210fedcba9876543210 \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi --target-node worker-2)"
grep -Fq 'cluster policy was not changed' <<<"$output"
grep -qx 'NODES=worker-1' "$repo_root/config/cluster/apps/cursorapi.policy"
grep -qx 'CURSORAPI_CURSOR_API_KEY=cursor-key-654321' "$tmp/config/cursorapi.env"

printf 'NODE_ID=leader\n' >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi --target-node leader 2>&1)"; then
	printf 'Leader accepted planned singleton secrets\n' >&2
	exit 1
fi
grep -Fq 'explicit target must be a follower' <<<"$output"

printf 'NODE_ID=unknown-worker\n' >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi --target-node unknown-worker 2>&1)"; then
	printf 'unknown planned target accepted singleton secrets\n' >&2
	exit 1
fi
grep -Fq 'target node is absent from NODE_IDS' <<<"$output"

# NODE_IDS membership alone is insufficient: planned secret provisioning must
# reject a corrupt or non-active inventory descriptor before writing anything.
mkdir -p "$tmp/target-repo/ops" "$tmp/target-repo/apps/cursorapi" \
	"$tmp/target-repo/config/cluster/apps" "$tmp/target-repo/config/cluster/nodes" "$tmp/target-config"
cp "$repo_root/ops/configure-app-secrets.sh" "$tmp/target-repo/ops/"
cp "$repo_root/apps/cursorapi/manifest.env" "$tmp/target-repo/apps/cursorapi/"
cp "$repo_root/config/cluster/policy.env" "$tmp/target-repo/config/cluster/"
cp "$repo_root/config/cluster/apps/cursorapi.policy" "$tmp/target-repo/config/cluster/apps/"
cp "$repo_root/config/cluster/nodes/worker-2.env" "$tmp/target-repo/config/cluster/nodes/"
sed 's/^NODE_ID=.*/NODE_ID=wrong-worker/' "$repo_root/config/cluster/nodes/worker-2.env" \
	>"$tmp/target-repo/config/cluster/nodes/worker-2.env"
printf 'NODE_ID=worker-2\n' >"$tmp/target-node.env"
if output="$(CONFIG_ROOT="$tmp/target-config" NODE_CONFIG_FILE="$tmp/target-node.env" \
	"$tmp/target-repo/ops/configure-app-secrets.sh" cursorapi --target-node worker-2 2>&1)"; then
	printf 'planned target with a mismatched descriptor identity was accepted\n' >&2
	exit 1
fi
grep -Fq 'target descriptor NODE_ID mismatch' <<<"$output"
sed 's/^NODE_STATE=.*/NODE_STATE=draining/' "$repo_root/config/cluster/nodes/worker-2.env" \
	>"$tmp/target-repo/config/cluster/nodes/worker-2.env"
if output="$(CONFIG_ROOT="$tmp/target-config" NODE_CONFIG_FILE="$tmp/target-node.env" \
	"$tmp/target-repo/ops/configure-app-secrets.sh" cursorapi --target-node worker-2 2>&1)"; then
	printf 'planned target with a draining descriptor was accepted\n' >&2
	exit 1
fi
grep -Fq 'target node is not active' <<<"$output"
[[ ! -e "$tmp/target-config/cursorapi.env" ]]

printf 'NODE_ID=worker-1\n' >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	"$repo_root/ops/configure-app-secrets.sh" cursorapi --target-node worker-2 2>&1)"; then
	printf 'planned target provisioning accepted a local-node mismatch\n' >&2
	exit 1
fi
grep -Fq 'is not the requested explicit target' <<<"$output"

pigeon_target="$(sed -n 's/^NODES=//p' "$repo_root/config/cluster/apps/pigeon.policy" | tail -n1)"
[[ -n "$pigeon_target" && "$pigeon_target" != *,* ]]
printf 'NODE_ID=%s\n' "$pigeon_target" >"$tmp/node.env"
if output="$(CONFIG_ROOT="$tmp/config" NODE_CONFIG_FILE="$tmp/node.env" \
	PIGEON_SECRET_KEY=too-short PIGEON_LOGIN_PASSWORD=also-too-short \
	"$repo_root/ops/configure-app-secrets.sh" pigeon 2>&1)"; then
	printf 'disabled Pigeon accepted secret provisioning\n' >&2
	exit 1
fi
grep -Fq 'pigeon is disabled' <<<"$output"

# Validate Pigeon's dormant secret contract using an isolated opt-in checkout.
mkdir -p "$tmp/pigeon-repo/ops" "$tmp/pigeon-repo/apps" "$tmp/pigeon-repo/config/cluster/apps" \
	"$tmp/pigeon-repo/config/cluster/nodes" "$tmp/pigeon-config"
cp "$repo_root/ops/configure-app-secrets.sh" "$tmp/pigeon-repo/ops/"
cp -R "$repo_root/apps/pigeon" "$tmp/pigeon-repo/apps/"
cp "$repo_root/config/cluster/policy.env" "$tmp/pigeon-repo/config/cluster/"
cp "$repo_root/config/cluster/nodes/$pigeon_target.env" "$tmp/pigeon-repo/config/cluster/nodes/"
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
