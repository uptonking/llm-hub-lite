#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ENV="${APP_ENV:-/opt/apps/llm-hub-lite/shared/.env.prod}"
CREDENTIALS_FILE="${BESZEL_CREDENTIALS_FILE:-/etc/llm-hub-lite/beszel-initial-credentials}"
[[ -r "$APP_ENV" ]] || {
	printf 'missing application environment: %s\n' "$APP_ENV" >&2
	exit 1
}
if [[ ! -r "$CREDENTIALS_FILE" ]]; then
	printf 'Beszel credentials file is absent; skipping automatic alert configuration\n' >&2
	exit 0
fi

beszel_url="$(sed -n 's/^BESZEL_SITE=//p' "$APP_ENV" | tail -n1)"
email="$(sed -n 's/^email=//p' "$CREDENTIALS_FILE" | tail -n1)"
password="$(sed -n 's/^password=//p' "$CREDENTIALS_FILE" | tail -n1)"
[[ -n "$beszel_url" && -n "$email" && -n "$password" ]] || {
	printf 'incomplete Beszel configuration\n' >&2
	exit 1
}

auth_payload="$(jq -n --arg identity "$email" --arg password "$password" '{identity:$identity,password:$password}')"
auth_response="$(curl -fsS --retry 12 --retry-delay 5 --retry-all-errors --max-time 20 \
	-H 'Content-Type: application/json' -d "$auth_payload" "$beszel_url/api/collections/users/auth-with-password")"
auth_token="$(jq -er '.token' <<<"$auth_response")"
systems_response="$(curl -fsS -H "Authorization: $auth_token" "$beszel_url/api/collections/systems/records?perPage=200")"
system_ids=()
while IFS= read -r system_id; do [[ -n "$system_id" ]] && system_ids+=("$system_id"); done < <(jq -r '.items[] | select(.status != "pending") | .id' <<<"$systems_response")
((${#system_ids[@]} > 0)) || {
	printf 'no enrolled Beszel system is ready for alerts\n' >&2
	exit 0
}
systems_json="$(printf '%s\n' "${system_ids[@]}" | jq -R . | jq -s .)"

upsert_alert() {
	local name="$1" value="$2" minutes="$3" payload
	payload="$(jq -n --arg name "$name" --argjson value "$value" --argjson min "$minutes" --argjson systems "$systems_json" \
		'{name:$name,value:$value,min:$min,systems:$systems,overwrite:true}')"
	curl -fsS -H "Authorization: $auth_token" -H 'Content-Type: application/json' \
		-X POST -d "$payload" "$beszel_url/api/beszel/user-alerts" >/dev/null
}

upsert_alert Status 0 2
upsert_alert CPU 90 10
upsert_alert Memory 90 5
upsert_alert Disk 85 5
printf 'Beszel baseline alerts configured for %s system(s)\n' "${#system_ids[@]}"
