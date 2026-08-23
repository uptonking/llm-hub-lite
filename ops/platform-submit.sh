#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
sha="${2:-}"
[[ "$mode" =~ ^(deploy|foundation-upgrade|cluster-reconcile|app-upgrade|rollback)$ ]] || {
	printf 'usage: platform-submit {deploy|foundation-upgrade|cluster-reconcile|app-upgrade|rollback} <sha-or-previous>\n' >&2
	exit 2
}
[[ -n "$sha" ]] || {
	printf 'missing target\n' >&2
	exit 2
}

platform_env_file="${PLATFORM_ENV_FILE:-/etc/llm-hub-lite/platform.env}"
configured_image="$(sed -n 's/^PLATFORM_RUNNER_IMAGE=//p' "$platform_env_file" 2>/dev/null | tail -n1 || true)"
image="${PLATFORM_CONTROLLER_IMAGE:-${configured_image:-llm-hub-lite/deploy-runner:current}}"
expected_image_id="$(sed -n 's/^PLATFORM_RUNNER_IMAGE_ID=//p' "$platform_env_file" 2>/dev/null | tail -n1 || true)"
if [[ -n "$expected_image_id" ]]; then
	actual_image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
	[[ "$actual_image_id" == "$expected_image_id" ]] || {
		printf 'deployment runner image mismatch: expected %s, got %s\n' "$expected_image_id" "${actual_image_id:-missing}" >&2
		exit 1
	}
fi
job="llm-hub-lite-platform-apply-$(printf '%s' "$mode-$sha" | tr -c 'A-Za-z0-9_.-' '-')"
docker rm -f "$job" >/dev/null 2>&1 || true
docker run -d --name "$job" \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-v /opt/apps/llm-hub-lite:/opt/apps/llm-hub-lite \
	-v /opt/platform:/opt/platform \
	-v /opt/backups/llm-hub-lite:/opt/backups/llm-hub-lite \
	-v /run/lock/llm-hub-lite:/run/lock/llm-hub-lite \
	-v /etc/llm-hub-lite:/etc/llm-hub-lite \
	-v /usr/local/bin/platformctl:/usr/local/bin/platformctl:ro \
	-v /usr/local/bin/deploy-controller:/usr/local/bin/deploy-controller:ro \
	-v /usr/local/bin/git-auth.sh:/usr/local/bin/git-auth.sh:ro \
	-v /usr/local/bin/backup-platform:/usr/local/bin/backup-platform:ro \
	"$image" /usr/local/bin/deploy-controller "$mode" "$sha" >/dev/null
status=0
wait_result="$(docker wait "$job")" || status=$?
if [[ "$status" -eq 0 ]]; then
	[[ "$wait_result" =~ ^[0-9]+$ ]] || {
		printf 'deployment runner returned an invalid status: %s\n' "$wait_result" >&2
		status=1
	}
	[[ "$status" -ne 0 ]] || status="$wait_result"
fi
docker logs "$job"
docker rm "$job" >/dev/null 2>&1 || true
if [[ "$status" -eq 0 && "$mode" == cluster-reconcile ]]; then
	touch /etc/llm-hub-lite/firewall-reconcile.request 2>/dev/null || printf '%s\n' 'warning: firewall reconciliation request could not be queued; timer will retry' >&2
fi
exit "$status"
