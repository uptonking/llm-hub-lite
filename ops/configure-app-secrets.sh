#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ "$EUID" -eq 0 ]] || {
	printf 'Run this command as root.\n' >&2
	exit 1
}

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="${1:-}"
config_root="${CONFIG_ROOT:-/etc/llm-hub-lite}"
reset_config=0
if [[ "${2:-}" == --reset-config ]]; then
	reset_config=1
elif [[ -n "${2:-}" ]]; then
	printf 'usage: %s <app-id> [--reset-config]\n' "$0" >&2
	exit 2
fi
[[ -n "$app_id" ]] || {
	printf 'usage: %s <app-id> [--reset-config]\n' "$0" >&2
	exit 2
}
manifest="$root/apps/$app_id/manifest.env"
[[ -r "$manifest" ]] || {
	printf 'missing app manifest: %s\n' "$manifest" >&2
	exit 1
}
value() { sed -n "s/^$1=//p" "$manifest" | tail -n1; }
policy_rel="$(value POLICY_FILE)"
runtime_rel="$(value RUNTIME_ENV_FILE)"
target_key="$(value TARGET_NODE_KEY)"
secret_keys="$(value SECRET_KEYS)"
[[ "$(value PLACEMENT)" == single-follower ]] || {
	printf '%s does not declare singleton placement\n' "$app_id" >&2
	exit 1
}
[[ -n "$runtime_rel" && -n "$target_key" && -n "$secret_keys" ]] || {
	printf '%s manifest must declare RUNTIME_ENV_FILE, TARGET_NODE_KEY, and SECRET_KEYS\n' "$app_id" >&2
	exit 1
}
[[ "$runtime_rel" != /* && "$runtime_rel" != *..* && "$runtime_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || {
	printf 'invalid runtime env path\n' >&2
	exit 1
}
[[ "$policy_rel" != /* && "$policy_rel" != *..* && "$policy_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || {
	printf 'invalid policy path\n' >&2
	exit 1
}
policy="$root/config/$policy_rel"
node_file="${NODE_CONFIG_FILE:-$config_root/node.env}"
[[ -r "$policy" && -r "$node_file" ]] || {
	printf 'missing app policy or node configuration\n' >&2
	exit 1
}
target="$(sed -n "s/^$target_key=//p" "$policy" | tail -n1)"
node="$(sed -n 's/^NODE_ID=//p' "$node_file" | tail -n1)"
[[ "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" != false ]] || {
	printf '%s is disabled in %s\n' "$app_id" "$policy_rel" >&2
	exit 1
}
[[ "$node" == "$target" ]] || {
	printf 'this node (%s) is not the configured target (%s)\n' "$node" "$target" >&2
	exit 1
}

runtime="$config_root/$runtime_rel"
install -d -m 700 "$(dirname "$runtime")"
runtime_tmp="$(mktemp "$(dirname "$runtime")/.runtime.XXXXXX")"
trap 'rm -f -- "$runtime_tmp"' EXIT
[[ -f "$runtime" ]] && cp "$runtime" "$runtime_tmp"
while IFS= read -r key; do
	[[ -n "$key" ]] || continue
	[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
		printf 'invalid secret key in manifest: %s\n' "$key" >&2
		exit 1
	}
	secret_value="${!key:-}"
	if [[ -z "$secret_value" && -f "$runtime" ]]; then
		secret_value="$(sed -n "s/^${key}=//p" "$runtime" | tail -n1)"
	fi
	if [[ -z "$secret_value" ]]; then
		read -r -s -p "$key: " secret_value
		printf '\n'
	fi
	[[ -n "$secret_value" ]] || {
		printf '%s is required\n' "$key" >&2
		exit 1
	}
	[[ "$secret_value" != *$'\n'* && "$secret_value" != *$'\r'* ]] || {
		printf '%s must be a single-line value\n' "$key" >&2
		exit 1
	}
	tmp_key="$(mktemp "$(dirname "$runtime")/.key.XXXXXX")"
	sed "/^${key}=/d" "$runtime_tmp" >"$tmp_key"
	printf '%s=%s\n' "$key" "$secret_value" >>"$tmp_key"
	mv -f "$tmp_key" "$runtime_tmp"
done < <(printf '%s\n' "$secret_keys" | tr ',' '\n')

chmod 600 "$runtime_tmp"
mv -f "$runtime_tmp" "$runtime"
trap - EXIT
printf 'Wrote %s with mode 600 for %s.\n' "$runtime" "$app_id"
if ((reset_config)); then
	app_env="${APP_ENV:-/opt/apps/llm-hub-lite/shared/.env.prod}"
	data_root="$(sed -n 's/^DATA_ROOT=//p' "$app_env" 2>/dev/null | tail -n1)"
	data_root="${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}"
	data_rel="$(value DATA_ROOT_REL)"
	marker_rel="$(value CONFIG_RESET_MARKER_REL)"
	marker_rel="${marker_rel:-.reset-config}"
	[[ "$data_rel" != /* && "$data_rel" != *..* && "$data_rel" =~ ^[A-Za-z0-9._/-]+$ && "$marker_rel" != /* && "$marker_rel" != *..* && "$marker_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || {
		printf 'invalid data or reset marker path\n' >&2
		exit 1
	}
	marker="$data_root/$data_rel/$marker_rel"
	install -d -m 700 "$(dirname "$marker")"
	: >"$marker"
	chmod 600 "$marker"
	printf 'Queued a one-shot configuration reset marker at %s.\n' "$marker"
fi
