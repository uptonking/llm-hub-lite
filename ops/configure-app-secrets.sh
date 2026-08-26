#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$-" == *x* ]]; then
	set +x
	printf 'WARNING: shell xtrace was disabled before loading application secrets.\n' >&2
fi
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
secret_min_lengths="$(value SECRET_MIN_LENGTHS)"
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
secret_min_length() {
	local wanted="$1" rule key min_length
	while IFS= read -r rule; do
		[[ -n "$rule" ]] || continue
		key="${rule%%:*}"
		min_length="${rule#*:}"
		[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$min_length" =~ ^[1-9][0-9]*$ ]] || {
			printf 'invalid SECRET_MIN_LENGTHS entry: %s\n' "$rule" >&2
			exit 1
		}
		if [[ "$key" == "$wanted" ]]; then
			printf '%s\n' "$min_length"
			return 0
		fi
	done < <(printf '%s\n' "$secret_min_lengths" | tr ',' '\n')
	printf '1\n'
}
valid_secret_value() {
	local key="$1" value="$2" min_length="${3:-1}"
	[[ -n "$value" ]] || {
		printf '%s is required\n' "$key" >&2
		return 1
	}
	[[ "$min_length" =~ ^[1-9][0-9]*$ ]] || {
		printf 'invalid minimum length for %s: %s\n' "$key" "$min_length" >&2
		return 1
	}
	if ((${#value} < min_length)); then
		printf '%s must contain at least %s characters\n' "$key" "$min_length" >&2
		return 1
	fi
	# Avoid a Bash here-string: its implicit newline would reject every value.
	if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then
		printf '%s contains control characters; provide a clean replacement\n' "$key" >&2
		return 1
	fi
}
while IFS= read -r key; do
	[[ -n "$key" ]] || continue
	[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
		printf 'invalid secret key in manifest: %s\n' "$key" >&2
		exit 1
	}
	secret_value="${!key:-}"
	min_length="$(secret_min_length "$key")"
	if [[ -z "$secret_value" && -f "$runtime" ]]; then
		secret_value="$(sed -n "s/^${key}=//p" "$runtime" | tail -n1)"
	fi
	while :; do
		if [[ -n "$secret_value" ]]; then
			if valid_secret_value "$key" "$secret_value" "$min_length"; then break; fi
			[[ -t 0 ]] || {
				printf '%s is invalid; provide a clean replacement through the environment\n' "$key" >&2
				exit 1
			}
			secret_value=''
		fi
		if ! read -r -s -p "$key: " secret_value; then
			printf '%s input was not received\n' "$key" >&2
			exit 1
		fi
		printf '\n'
		if valid_secret_value "$key" "$secret_value" "$min_length"; then break; fi
		printf 'Please enter %s again.\n' "$key" >&2
	done
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
