#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
PLATFORM_ENV_FILE="${PLATFORM_ENV_FILE:-/etc/llm-hub-lite/platform.env}"
CONTROL_ROOT="${CONTROL_ROOT:-/opt/platform/control}"
die() {
	printf 'upgrade-runner: %s\n' "$*" >&2
	exit 1
}
[[ -r "$PLATFORM_ENV_FILE" ]] || die "missing platform env: $PLATFORM_ENV_FILE"
# shellcheck disable=SC1090
source "$PLATFORM_ENV_FILE"
policy_file="${CLUSTER_POLICY_FILE:-${CONTROL_ROOT}/current/config/cluster/policy.env}"
[[ -r "$policy_file" ]] || die "missing cluster policy: $policy_file"
image="${DEPLOY_RUNNER_IMAGE:-$(sed -n 's/^DEPLOY_RUNNER_IMAGE=//p' "$policy_file" | tail -n1)}"
[[ "$image" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || die 'DEPLOY_RUNNER_IMAGE must be digest-pinned'
docker pull "$image"
docker tag "$image" llm-hub-lite/deploy-runner:current
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
[[ -n "$image_id" ]] || die 'runner image was not created'
tmp="$(mktemp "${PLATFORM_ENV_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
sed '/^PLATFORM_RUNNER_IMAGE=/d;/^PLATFORM_RUNNER_IMAGE_ID=/d' "$PLATFORM_ENV_FILE" >"$tmp"
printf 'PLATFORM_RUNNER_IMAGE=%s\nPLATFORM_RUNNER_IMAGE_ID=%s\n' "$image" "$image_id" >>"$tmp"
chmod 600 "$tmp"
mv -f -- "$tmp" "$PLATFORM_ENV_FILE"
printf 'runner upgraded: %s (%s)\n' "$image" "$image_id"
