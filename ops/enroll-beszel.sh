#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
CLUSTER_POLICY_FILE="${CLUSTER_POLICY_FILE:-$PLATFORM_ROOT/control/current/config/cluster/policy.env}"
BESZEL_ENV="${BESZEL_ENV:-$PLATFORM_ROOT/foundation/env/beszel.env}"
CREDENTIALS_FILE="${BESZEL_CREDENTIALS_FILE:-$CONFIG_ROOT/beszel-initial-credentials}"
BUNDLE_FILE="${BESZEL_ENROLLMENT_BUNDLE:-$CONFIG_ROOT/beszel-enrollment.env}"
LOCK_FILE="${BESZEL_ENROLL_LOCK:-/run/lock/llm-hub-lite/beszel-enroll.lock}"
PLATFORMCTL_SCRIPT="${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}"

die() {
	printf 'enroll-beszel: %s\n' "$*" >&2
	exit 1
}
value() { sed -n "s/^$1=//p" "$2" | tail -n1; }
truthy() { [[ "${1:-}" == true || "${1:-}" == TRUE || "${1:-}" == 1 ]]; }
write_secret() {
	local target="$1" value="$2" tmp
	install -d -m 700 "$(dirname "$target")"
	tmp="$(mktemp "${target}.tmp.XXXXXX")"
	printf '%s\n' "$value" >"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$target"
}

[[ -r "$APP_ENV" && -r "$BESZEL_ENV" ]] || die 'application or Beszel environment is missing'
node_id="$(value NODE_ID "$NODE_CONFIG_FILE")"
leader_id="$(value LEADER_NODE_ID "$CLUSTER_POLICY_FILE")"
[[ -n "$node_id" && -n "$leader_id" ]] || die 'node identity or cluster policy is incomplete'
[[ "$node_id" == "$leader_id" ]] && node_role=leader || node_role=follower

key_file="$(value BESZEL_KEY_FILE "$BESZEL_ENV")"
token_file="$(value BESZEL_TOKEN_FILE "$BESZEL_ENV")"
hub_url="$(value BESZEL_APP_URL "$BESZEL_ENV")"
[[ -n "$key_file" && -n "$token_file" && -n "$hub_url" ]] || die 'BESZEL_KEY_FILE, BESZEL_TOKEN_FILE, and BESZEL_APP_URL are required'

if [[ "$node_role" == follower ]]; then
	[[ -s "$BUNDLE_FILE" ]] || die "missing Beszel enrollment bundle: $BUNDLE_FILE"
	bundle_hub="$(value BESZEL_HUB_URL "$BUNDLE_FILE")"
	bundle_key="$(value BESZEL_HUB_PUBLIC_KEY "$BUNDLE_FILE")"
	bundle_token="$(value BESZEL_UNIVERSAL_TOKEN "$BUNDLE_FILE")"
	[[ "$bundle_hub" == "$hub_url" ]] || die 'Beszel enrollment bundle Hub URL does not match local configuration'
	[[ -n "$bundle_key" && -n "$bundle_token" ]] || die 'Beszel enrollment bundle is incomplete'
	key_present=0
	token_present=0
	[[ -s "$key_file" ]] && key_present=1
	[[ -s "$token_file" ]] && token_present=1
	if ((key_present == 1 && token_present == 1)); then
		[[ "$(tr -d '\r\n' <"$key_file")" == "$bundle_key" && "$(tr -d '\r\n' <"$token_file")" == "$bundle_token" ]] || die 'existing Beszel credentials differ from the cluster enrollment bundle'
		exit 0
	fi
	write_secret "$key_file" "$bundle_key"
	write_secret "$token_file" "$bundle_token"
	[[ -x "$PLATFORMCTL_SCRIPT" ]] && "$PLATFORMCTL_SCRIPT" recreate beszel-worker
	printf 'Beszel follower credentials provisioned from enrollment bundle\n'
	exit 0
fi
[[ "$node_role" == leader ]] || die 'only the derived Leader role can create a Beszel enrollment bundle'

key_present=0
token_present=0
[[ -s "$key_file" ]] && key_present=1
[[ -s "$token_file" ]] && token_present=1
if ((key_present != token_present)); then
	# A single credential cannot be trusted: the pair is issued together by the
	# hub. Preserve it for diagnostics, then let enrollment issue a fresh pair.
	orphan_dir="$(dirname "$key_file")/orphaned"
	install -d -m 700 "$orphan_dir"
	orphan_stamp="$(date -u '+%Y%m%dT%H%M%SZ').$$"
	if [[ -e "$key_file" ]]; then
		mv -f -- "$key_file" "$orphan_dir/key.$orphan_stamp"
	fi
	if [[ -e "$token_file" ]]; then
		mv -f -- "$token_file" "$orphan_dir/token.$orphan_stamp"
	fi
	key_present=0
	token_present=0
fi
if ((key_present == 1)); then
	if [[ ! -s "$BUNDLE_FILE" ]]; then
		bundle_tmp="$(mktemp "${BUNDLE_FILE}.tmp.XXXXXX")"
		printf 'BESZEL_HUB_URL=%s\nBESZEL_HUB_PUBLIC_KEY=%s\nBESZEL_UNIVERSAL_TOKEN=%s\n' "$hub_url" "$(tr -d '\r\n' <"$key_file")" "$(tr -d '\r\n' <"$token_file")" >"$bundle_tmp"
		chmod 600 "$bundle_tmp"
		install -d -m 700 "$(dirname "$BUNDLE_FILE")"
		mv -f -- "$bundle_tmp" "$BUNDLE_FILE"
	fi
	exit 0
fi
[[ -s "$CREDENTIALS_FILE" ]] || die "missing initial credentials: $CREDENTIALS_FILE"

install -d -m 700 "$(dirname "$LOCK_FILE")" "$(dirname "$key_file")" "$(dirname "$token_file")"
exec 9>"$LOCK_FILE"
flock -w 30 9 || die 'timed out waiting for enrollment lock'
[[ -s "$key_file" && -s "$token_file" ]] && exit 0

email="$(value email "$CREDENTIALS_FILE")"
password="$(value password "$CREDENTIALS_FILE")"
[[ -n "$email" && -n "$password" ]] || die 'initial Beszel credentials are incomplete'

payload="$(jq -n --arg identity "$email" --arg password "$password" '{identity:$identity,password:$password}')"
auth_response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 -H 'Content-Type: application/json' -d "$payload" "$hub_url/api/collections/users/auth-with-password")"
auth_token="$(jq -er '.token' <<<"$auth_response")"
hub_key="$(curl -fsS -H "Authorization: $auth_token" "$hub_url/api/beszel/info" | jq -er '.key')"
agent_token="$(openssl rand -hex 24)"
curl -fsS -H "Authorization: $auth_token" "$hub_url/api/beszel/universal-token?enable=1&permanent=1&token=$agent_token" | jq -e '.active == true and .permanent == true' >/dev/null

key_tmp="$(mktemp "${key_file}.tmp.XXXXXX")"
token_tmp="$(mktemp "${token_file}.tmp.XXXXXX")"
env_tmp=""
trap 'rm -f -- "$key_tmp" "$token_tmp"; [[ -z "${env_tmp:-}" ]] || rm -f -- "$env_tmp"' EXIT
printf '%s\n' "$hub_key" >"$key_tmp"
printf '%s\n' "$agent_token" >"$token_tmp"
chmod 600 "$key_tmp" "$token_tmp"
mv -f -- "$key_tmp" "$key_file"
mv -f -- "$token_tmp" "$token_file"
bundle_tmp="$(mktemp "${BUNDLE_FILE}.tmp.XXXXXX")"
printf 'BESZEL_HUB_URL=%s\nBESZEL_HUB_PUBLIC_KEY=%s\nBESZEL_UNIVERSAL_TOKEN=%s\n' "$hub_url" "$hub_key" "$agent_token" >"$bundle_tmp"
chmod 600 "$bundle_tmp"
install -d -m 700 "$(dirname "$BUNDLE_FILE")"
mv -f -- "$bundle_tmp" "$BUNDLE_FILE"
env_tmp="$(mktemp "${BESZEL_ENV}.tmp.XXXXXX")"
sed '/^BESZEL_USER_EMAIL=/d;/^BESZEL_USER_PASSWORD=/d' "$BESZEL_ENV" >"$env_tmp"
chmod 600 "$env_tmp"
mv -f -- "$env_tmp" "$BESZEL_ENV"
"$PLATFORMCTL_SCRIPT" recreate beszel-worker
printf 'Beszel enrollment complete\n'
