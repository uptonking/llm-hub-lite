#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
PLATFORM_ENV="${PLATFORM_ENV:-$CONFIG_ROOT/platform.env}"
NODE_ENV="${NODE_CONFIG_FILE:-$CONFIG_ROOT/node.env}"
POLICY_FILE="${CLUSTER_POLICY_FILE:-}"
env_value() {
	local key="$1" file="$2" line value=''
	[[ -r "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "$key="* ]] || continue
		value="${line#*=}"
	done <"$file"
	printf '%s\n' "$value"
}
platform_root="$(env_value PLATFORM_ROOT "$PLATFORM_ENV")"
platform_root="${platform_root:-/opt/platform}"
POLICY_FILE="${POLICY_FILE:-$platform_root/control/current/config/cluster/policy.env}"
node_id="$(env_value NODE_ID "$NODE_ENV")"
leader_id="$(env_value LEADER_NODE_ID "$POLICY_FILE")"
[[ -n "$node_id" && "$node_id" == "$leader_id" ]] || exit 0
woodpecker_env="${WOODPECKER_ENV:-$platform_root/foundation/env/woodpecker.env}"
woodpecker_host="$(env_value WOODPECKER_HOST "$woodpecker_env")"
woodpecker_host="${woodpecker_host%/}"
data_root="$(env_value WOODPECKER_DATA_ROOT "$woodpecker_env")"
db="${data_root:-$platform_root/woodpecker/data}/woodpecker.sqlite"
[[ -n "$woodpecker_host" && -f "$db" ]] || exit 0
command -v sqlite3 >/dev/null 2>&1 || {
	printf 'woodpecker-repair: sqlite3 is required\n' >&2
	exit 1
}
command -v openssl >/dev/null 2>&1 || {
	printf 'woodpecker-repair: openssl is required\n' >&2
	exit 1
}
command -v curl >/dev/null 2>&1 || {
	printf 'woodpecker-repair: curl is required\n' >&2
	exit 1
}
user_id=''
user_hash=''
while IFS='|' read -r candidate_id candidate_hash; do
	[[ -n "$candidate_id" && -n "$candidate_hash" ]] || continue
	user_id="$candidate_id"
	user_hash="$candidate_hash"
	break
done < <(sqlite3 -separator '|' "$db" 'select id,hash from users where admin = 1 and hash <> "" order by id limit 1;')
[[ -n "$user_id" && -n "$user_hash" ]] || exit 0
b64url() {
	if [[ "$#" -gt 0 ]]; then
		printf '%s' "$1" | openssl base64 -A
	else
		openssl base64 -A
	fi | tr '+/' '-_' | tr -d '='
}
header="$(b64url '{"alg":"HS256","typ":"JWT"}')"
payload="$(printf '{"type":"user","user-id":"%s"}' "$user_id" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$user_hash" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
token="$header.$payload.$signature"
status="$(curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 90 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $token" "$woodpecker_host/api/repos/repair")" || {
	printf 'woodpecker-repair: repair API request failed (host=%s)\n' "$woodpecker_host" >&2
	exit 1
}
case "$status" in
200 | 204) printf 'Woodpecker repository webhooks repaired\n' ;;
401 | 403)
	printf 'woodpecker-repair: API authorization failed (HTTP %s)\n' "$status" >&2
	exit 1
	;;
*)
	printf 'woodpecker-repair: unexpected repair API status (HTTP %s)\n' "$status" >&2
	exit 1
	;;
esac
