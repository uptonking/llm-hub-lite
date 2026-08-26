#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ "$EUID" -eq 0 ]] || {
	printf 'Run this command as root.\n' >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	printf 'jq is required to provision the Observer ingestion token\n' >&2
	exit 1
}
command -v flock >/dev/null 2>&1 || {
	printf 'flock is required to provision the Observer ingestion token\n' >&2
	exit 1
}
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
FOUNDATION_ROOT="${FOUNDATION_ROOT:-/opt/platform/foundation}"
ENV_FILE="${OBSERVER_ENV_FILE:-$FOUNDATION_ROOT/env/observer.env}"
FOUNDATION_IMAGE_ENV="${FOUNDATION_IMAGE_ENV:-/etc/llm-hub-lite/images.foundation.env}"
OBSERVER_PRIVATE_NETWORK="${OBSERVER_PRIVATE_NETWORK:-foundation-observer_private}"
LOCK_FILE="${OBSERVER_INGEST_LOCK_FILE:-/run/lock/llm-hub-lite/observer-ingest.lock}"
install -d -m 700 "$CONFIG_ROOT" "$(dirname "$ENV_FILE")"
install -d -m 700 "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w "${OBSERVER_INGEST_LOCK_WAIT:-300}" 9 || {
	printf 'timed out waiting for Observer ingestion provisioning lock\n' >&2
	exit 1
}
[[ -r "$ENV_FILE" ]] || {
	printf 'missing Observer foundation environment: %s\n' "$ENV_FILE" >&2
	exit 1
}
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }
image_value() { sed -n "s/^$1=//p" "$FOUNDATION_IMAGE_ENV" 2>/dev/null | tail -n1; }
set_key() {
	local file="$1" key="$2" value="$3" tmp
	tmp="$(mktemp "${file}.tmp.XXXXXX")"
	[[ -f "$file" ]] && sed "/^${key}=/d" "$file" >"$tmp"
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chmod 600 "$tmp"
	mv -f -- "$tmp" "$file"
}
site="$(env_value OBSERVER_SITE)"
api_base="$(env_value OBSERVER_API_URL)"
ingest_site="$(env_value OBSERVER_INGEST_SITE)"
ingest_url="$(env_value OBSERVER_INGEST_URL)"
organization="$(env_value OBSERVER_LOG_ORGANIZATION)"
stream="$(env_value OBSERVER_LOG_STREAM)"
root_user="$(env_value OBSERVER_ROOT_USER_EMAIL)"
root_password="$(env_value OBSERVER_ROOT_USER_PASSWORD)"
ingest_user="$(env_value OBSERVER_INGEST_USER)"
token="$(env_value OBSERVER_INGEST_TOKEN)"
case "$token" in bootstrap-pending | replace-with-*) token='' ;; esac
[[ "$site" =~ ^https:// ]] || {
	printf 'OBSERVER_SITE must use https://\n' >&2
	exit 1
}
api_base="${api_base:-$site}"
[[ "$api_base" =~ ^https?://[^[:space:]/]+$ ]] || {
	printf 'OBSERVER_API_URL must be an http(s):// host without a path\n' >&2
	exit 1
}
ingest_site="${ingest_site:-$site}"
ingest_url="${ingest_url:-$ingest_site}"
[[ "$ingest_site" =~ ^https?://[^[:space:]/]+$ ]] || {
	printf 'OBSERVER_INGEST_SITE must use http:// or https:// and contain no path\n' >&2
	exit 1
}
[[ "$ingest_url" =~ ^https?://[^[:space:]/]+$ ]] || {
	printf 'OBSERVER_INGEST_URL must use http:// or https:// and contain no path\n' >&2
	exit 1
}
[[ "$ingest_url" == "$ingest_site" ]] || {
	printf 'OBSERVER_INGEST_URL and OBSERVER_INGEST_SITE must match exactly\n' >&2
	exit 1
}
[[ -n "$organization" ]] || organization=default
[[ "$organization" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'OBSERVER_LOG_ORGANIZATION contains invalid path characters\n' >&2
	exit 1
}
[[ -n "$stream" ]] || stream=docker
[[ "$stream" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'OBSERVER_LOG_STREAM contains invalid path characters\n' >&2
	exit 1
}
[[ -n "$root_user" && -n "$root_password" ]] || {
	printf 'Observer root credentials are required on the Leader\n' >&2
	exit 1
}
[[ -n "$ingest_user" ]] || ingest_user=llm-hub-lite-collector
[[ -n "$ingest_user" && "${#ingest_user}" -le 256 && "$ingest_user" != *[!A-Za-z0-9_-]* ]] || {
	printf 'OBSERVER_INGEST_USER must contain only letters, numbers, hyphens, or underscores\n' >&2
	exit 1
}

# The token is the source of truth in the Observer database. Always reconcile
# it through the API; retaining a local value when the API is unavailable would
# let a restored or rotated database leave collectors with a stale credential.
valid_token() {
	local value="$1" suffix
	case "$value" in o2oi_*) suffix="${value#o2oi_}" ;; *) return 1 ;; esac
	[[ "${#suffix}" -eq 32 ]] || return 1
	case "$suffix" in *[!A-Za-z0-9]*) return 1 ;; esac
}
api="${api_base%/}/api/${organization}/ingestion-tokens"
observer_probe_image="$(image_value OBSERVER_HEALTH_PROBE_IMAGE)"
request() {
	local -a args=("$@")
	if [[ "$api_base" == http://observer-controller:* ]]; then
		command -v docker >/dev/null 2>&1 || {
			printf 'docker is required for private Observer provisioning\n' >&2
			return 1
		}
		[[ -n "$observer_probe_image" ]] || {
			printf 'OBSERVER_HEALTH_PROBE_IMAGE is required for private Observer provisioning\n' >&2
			return 1
		}
		docker run --rm --network "$OBSERVER_PRIVATE_NETWORK" "$observer_probe_image" "${args[@]}"
	else
		curl "${args[@]}"
	fi
}
response=''
list_ok=0
# /healthz can become ready before the local metadata store has completed its
# first migration. Retry both transport failures and a valid HTTP response
# whose body is not the token-list shape yet.
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
	if response="$(request -fsS --retry 3 --retry-delay 2 --retry-all-errors --max-time 20 \
		-u "$root_user:$root_password" "$api" 2>/dev/null)" &&
		printf '%s' "$response" | jq -e '.data | type == "array"' >/dev/null; then
		list_ok=1
		break
	fi
	[[ "$attempt" == 12 ]] || sleep 2
done
((list_ok)) || {
	printf 'unable to query the Observer ingestion-token API after readiness retries; refusing to reuse a local token\n' >&2
	exit 1
}
listed_token="$(printf '%s' "$response" | jq -r --arg name "$ingest_user" \
	'[.data[] | select(.name == $name and .enabled == true) | .token][0] // empty')"
if [[ -n "$listed_token" ]] && valid_token "$listed_token"; then
	token="$listed_token"
elif printf '%s' "$response" | jq -e --arg name "$ingest_user" \
	'.data[] | select(.name == $name and .enabled == true)' >/dev/null; then
	valid_token "$token" || {
		printf 'Observer ingestion token %s is enabled but its value is not available; rotate it or remove and recreate it\n' "$ingest_user" >&2
		exit 1
	}
elif printf '%s' "$response" | jq -e --arg name "$ingest_user" \
	'.data[] | select(.name == $name and .enabled == false)' >/dev/null; then
	printf 'Observer ingestion token %s exists but is disabled; enable it or choose a new OBSERVER_INGEST_USER\n' "$ingest_user" >&2
	exit 1
else
	# The configured name is absent, so any old local value is stale. Create a
	# fresh named token instead of trying to guess whether it still works.
	token=''
fi
if [[ -z "$token" ]]; then
	payload="$(jq -nc --arg name "$ingest_user" '{name:$name,description:"llm-hub-lite Docker log collector"}')"
	create_response=''
	if create_response="$(request -fsS --max-time 20 \
		-u "$root_user:$root_password" -H 'Content-Type: application/json' \
		-d "$payload" "$api" 2>/dev/null)"; then
		token="$(printf '%s' "$create_response" | jq -r '.data.token // empty')"
	fi
	if ! valid_token "$token"; then
		# A request can fail after OpenObserve has committed the token. Re-list
		# before reporting failure so a retry cannot create a duplicate name.
		if response="$(request -fsS --retry 3 --retry-delay 2 --retry-all-errors --max-time 20 \
			-u "$root_user:$root_password" "$api" 2>/dev/null)"; then
			listed_token="$(printf '%s' "$response" | jq -r --arg name "$ingest_user" \
				'[.data[] | select(.name == $name and .enabled == true) | .token][0] // empty')"
			if [[ -n "$listed_token" ]] && valid_token "$listed_token"; then token="$listed_token"; fi
		fi
	fi
fi
valid_token "$token" || {
	printf 'Observer API did not return a valid ingestion token\n' >&2
	exit 1
}
set_key "$ENV_FILE" OBSERVER_INGEST_USER "$ingest_user"
set_key "$ENV_FILE" OBSERVER_INGEST_TOKEN "$token"
set_key "$CONFIG_ROOT/shared-secrets.env" OBSERVER_INGEST_USER "$ingest_user"
set_key "$CONFIG_ROOT/shared-secrets.env" OBSERVER_INGEST_TOKEN "$token"
printf 'Observer collector ingestion credentials provisioned: user=%s\n' "$ingest_user"
