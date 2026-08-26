#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
sha="${2:-}"
[[ "$mode" =~ ^(deploy|foundation-upgrade|cluster-reconcile|app-upgrade|rollback|singleton-stage|singleton-switch|singleton-stop)$ ]] || {
	printf 'usage: platform-submit {deploy|foundation-upgrade|cluster-reconcile|app-upgrade|rollback|singleton-stage|singleton-switch|singleton-stop} <sha-or-previous>\n' >&2
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
set +e
# The full runner log is streamed to Woodpecker below; avoid duplicating a
# short-lived, potentially secret-bearing build log in the Observer stream.
docker run -d --name "$job" \
	--label com.aichorage.platform=llm-hub-lite \
	--label com.aichorage.component=platform-deployment-runner \
	--label com.aichorage.observer.ignore-logs=true \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-v /opt/apps/llm-hub-lite:/opt/apps/llm-hub-lite \
	-v /opt/platform:/opt/platform \
	-v /opt/backups/llm-hub-lite:/opt/backups/llm-hub-lite \
	-v /run/lock/llm-hub-lite:/run/lock/llm-hub-lite \
	-v /etc/llm-hub-lite:/etc/llm-hub-lite \
	-e DEPLOY_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" \
	-e SINGLETON_APP_ID="${SINGLETON_APP_ID:-}" \
	-e PLATFORM_ONLY_APP_ID="${SINGLETON_APP_ID:-}" \
	-e DEPLOY_WORKFLOW="${CI_WORKFLOW_NAME:-${CI_WORKFLOW:-unknown}}" \
	-e DEPLOY_PIPELINE="${CI_PIPELINE_NUMBER:-${CI_PIPELINE:-unknown}}" \
	-e DEPLOY_BUILD="${CI_BUILD_NUMBER:-${CI_BUILD:-unknown}}" \
	-v /usr/local/bin/platformctl:/usr/local/bin/platformctl:ro \
	-v /usr/local/bin/deploy-controller:/usr/local/bin/deploy-controller:ro \
	-v /usr/local/bin/git-auth.sh:/usr/local/bin/git-auth.sh:ro \
	-v /usr/local/bin/backup-platform:/usr/local/bin/backup-platform:ro \
	"$image" /usr/local/bin/deploy-controller "$mode" "$sha" >/dev/null
run_status=$?
set -e
if [[ "$run_status" -ne 0 ]]; then
	printf 'deployment runner failed to start: image=%s status=%s mode=%s sha=%s\n' "$image" "$run_status" "$mode" "$sha" >&2
	if [[ -x /usr/local/bin/platformctl ]]; then
		/usr/local/bin/platformctl diagnose all 2>/dev/null || true
	fi
	exit "$run_status"
fi
log_pid=''
docker logs -f "$job" &
log_pid=$!
status=0
wait_result="$(docker wait "$job")" || status=$?
stream_status=0
if [[ -n "$log_pid" ]]; then
	wait "$log_pid" 2>/dev/null || stream_status=$?
fi
if [[ "$status" -eq 0 ]]; then
	[[ "$wait_result" =~ ^[0-9]+$ ]] || {
		printf 'deployment runner returned an invalid status: %s\n' "$wait_result" >&2
		status=1
	}
	[[ "$status" -ne 0 ]] || status="$wait_result"
fi
[[ "$stream_status" -eq 0 ]] || docker logs "$job" || true
docker rm "$job" >/dev/null 2>&1 || true
if [[ "$status" -ne 0 && -x /usr/local/bin/platformctl ]]; then
	printf '%s\n' '--- host deployment diagnostics ---' >&2
	if [[ -n "${SINGLETON_APP_ID:-}" ]]; then
		/usr/local/bin/platformctl diagnose "app:${SINGLETON_APP_ID}" || true
	else
		/usr/local/bin/platformctl diagnose all || true
	fi
	printf '%s\n' '--- end host deployment diagnostics ---' >&2
fi
if [[ "$status" -eq 0 && "$mode" == cluster-reconcile ]]; then
	touch /etc/llm-hub-lite/firewall-reconcile.request 2>/dev/null || printf '%s\n' 'warning: firewall reconciliation request could not be queued; timer will retry' >&2
fi
exit "$status"
