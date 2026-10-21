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

# Prune ghost agents for nodes that are no longer in NODE_IDS
if [[ -f "$POLICY_FILE" ]]; then
	node_ids="$(env_value NODE_IDS "$POLICY_FILE")"
	if [[ -n "$node_ids" ]]; then
		while IFS='|' read -r a_id a_node a_contact; do
			[[ -n "$a_id" && -n "$a_node" ]] || continue
			if [[ ",${node_ids//[[:space:]]/}," != *",$a_node,"* ]]; then
				if [[ -z "$a_contact" || "$a_contact" -gt 180 ]]; then
					printf 'woodpecker-repair: removing retired agent id=%s node=%s (offline %ss)\n' "$a_id" "$a_node" "${a_contact:-unknown}"
					sqlite3 "$db" "DELETE FROM agents WHERE id = $a_id;" || true
				fi
			fi
		done < <(sqlite3 -separator '|' "$db" "SELECT id, json_extract(custom_labels, '$.node'), unixepoch('now') - max(last_contact) FROM agents GROUP BY id;" 2>/dev/null || true)
	fi
fi

# Cancel running pipelines with workflows stuck on offline or missing agents
while IFS='|' read -r p_num p_repo wf_name; do
	[[ -n "$p_num" && "$p_num" =~ ^[0-9]+$ ]] || continue
	p_repo="${p_repo:-1}"
	printf 'woodpecker-repair: cancelling pipeline=%s step=%s stuck on offline agent\n' "$p_num" "$wf_name"
	curl -fsS -X POST -H "Authorization: Bearer $token" \
		"$woodpecker_host/api/repos/${p_repo}/pipelines/${p_num}/cancel" >/dev/null 2>&1 || true
done < <(sqlite3 -separator '|' "$db" "
	SELECT p.number, p.repo_id, w.name
	FROM workflows w
	JOIN pipelines p ON p.id = w.pipeline_id
	WHERE w.state = 'pending'
	  AND p.status IN ('running', 'pending')
	  AND (unixepoch('now') - p.created) > 180
	  AND (
	    w.agent_id = 0
	    OR w.agent_id IN (
	      SELECT id FROM agents WHERE (unixepoch('now') - last_contact) > 180
	    )
	  )
	GROUP BY p.number;
" 2>/dev/null || true)
