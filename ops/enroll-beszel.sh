#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
APP_ROOT="${APP_ROOT:-/opt/apps/llm-hub-lite}"
PLATFORM_ROOT="${PLATFORM_ROOT:-/opt/platform}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/llm-hub-lite}"
APP_ENV="${APP_ENV:-$APP_ROOT/shared/.env.prod}"
BESZEL_ENV="${BESZEL_ENV:-$PLATFORM_ROOT/foundation/env/beszel.env}"
CREDENTIALS_FILE="${BESZEL_CREDENTIALS_FILE:-$CONFIG_ROOT/beszel-initial-credentials}"
LOCK_FILE="${BESZEL_ENROLL_LOCK:-/run/lock/llm-hub-lite/beszel-enroll.lock}"
PLATFORMCTL_SCRIPT="${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}"

die() { printf 'enroll-beszel: %s\n' "$*" >&2; exit 1; }
value() { sed -n "s/^$1=//p" "$2" | tail -n1; }
truthy() { [[ "${1:-}" == true || "${1:-}" == TRUE || "${1:-}" == 1 ]]; }

[[ -r "$APP_ENV" && -r "$BESZEL_ENV" ]] || die 'application or Beszel environment is missing'
truthy "$(value SERVICE_BESZEL_DISABLE "$APP_ENV")" && exit 0

key_file="$(value BESZEL_KEY_FILE "$BESZEL_ENV")"
token_file="$(value BESZEL_TOKEN_FILE "$BESZEL_ENV")"
hub_url="$(value BESZEL_APP_URL "$BESZEL_ENV")"
[[ -n "$key_file" && -n "$token_file" && -n "$hub_url" ]] || die 'BESZEL_KEY_FILE, BESZEL_TOKEN_FILE, and BESZEL_APP_URL are required'

key_present=0; token_present=0
[[ -s "$key_file" ]] && key_present=1
[[ -s "$token_file" ]] && token_present=1
if (( key_present != token_present )); then
  # A single credential cannot be trusted: the pair is issued together by the
  # hub. Preserve it for diagnostics, then let enrollment issue a fresh pair.
  orphan_dir="$(dirname "$key_file")/orphaned"
  install -d -m 700 "$orphan_dir"
  orphan_stamp="$(date -u '+%Y%m%dT%H%M%SZ').$$"
  [[ -e "$key_file" ]] && mv -f -- "$key_file" "$orphan_dir/key.$orphan_stamp" || true
  [[ -e "$token_file" ]] && mv -f -- "$token_file" "$orphan_dir/token.$orphan_stamp" || true
  key_present=0; token_present=0
fi
(( key_present == 1 )) && exit 0
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
env_tmp="$(mktemp "${BESZEL_ENV}.tmp.XXXXXX")"
sed '/^BESZEL_USER_EMAIL=/d;/^BESZEL_USER_PASSWORD=/d' "$BESZEL_ENV" >"$env_tmp"
chmod 600 "$env_tmp"
mv -f -- "$env_tmp" "$BESZEL_ENV"
"$PLATFORMCTL_SCRIPT" recreate beszel
printf 'Beszel enrollment complete\n'
