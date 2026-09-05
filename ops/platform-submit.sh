#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # cleanup_runner is invoked by traps
set -Eeuo pipefail

mode="${1:-}"
sha="${2:-}"
[[ "$mode" =~ ^(deploy|control-sync|control-verify|foundation-upgrade|cluster-reconcile|app-upgrade|rollback|consumer-stage|consumer-publish|consumer-stop|direct-publish|node-retire)$ ]] || {
	printf 'usage: platform-submit {deploy|control-sync|control-verify|consumer-stage|consumer-publish|consumer-stop|direct-publish|foundation-upgrade|cluster-reconcile|app-upgrade|node-retire|rollback} <sha-or-previous>\n' >&2
	exit 2
}
if [[ "$mode" == rollback && "$sha" == previous ]]; then
	:
else
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
		printf 'target must be a full 40-character lowercase commit SHA\n' >&2
		exit 2
	}
fi

controller_source="${PLATFORM_CONTROLLER_SOURCE:-/opt/platform/control/current/ops/deploy-controller.sh}"
platformctl_source="${PLATFORMCTL_SOURCE:-/opt/platform/control/current/ops/platformctl.sh}"
git_auth_source="${GIT_AUTH_SOURCE:-/opt/platform/control/current/ops/git-auth.sh}"
if [[ ! -r "$controller_source" ]] || ! grep -q 'control-sync)' "$controller_source"; then
	printf 'validated deployment controller is unavailable or too old for %s: %s\n' "$mode" "$controller_source" >&2
	exit 1
fi
if [[ ! -r "$platformctl_source" ]]; then
	printf 'validated platformctl is unavailable: %s\n' "$platformctl_source" >&2
	exit 1
fi
if [[ ! -r "$git_auth_source" ]] || ! grep -q '^setup_github_https_auth()' "$git_auth_source"; then
	printf 'validated Git authentication helper is unavailable or unsafe to source: %s\n' "$git_auth_source" >&2
	exit 1
fi

retire_delay=''
if [[ "$mode" == node-retire ]]; then
	retire_delay="${NODE_RETIRE_DELAY_SECONDS:-30}"
	[[ "$retire_delay" =~ ^[0-9]+$ ]] || {
		printf 'NODE_RETIRE_DELAY_SECONDS must be an integer between 0 and 300\n' >&2
		exit 2
	}
	((retire_delay <= 300)) || {
		printf 'NODE_RETIRE_DELAY_SECONDS must be an integer between 0 and 300\n' >&2
		exit 2
	}
fi

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
cleanup_runner() {
	local status="${1:-$?}"
	# Woodpecker can cancel a step while this wrapper is waiting on Docker. The
	# deployment container must be removed in that case or its child controller
	# can retain the platform flock and block all later pushes indefinitely.
	trap - EXIT INT TERM
	docker rm -f "$job" >/dev/null 2>&1 || true
	exit "$status"
}
trap cleanup_runner EXIT
trap 'cleanup_runner 143' INT TERM
set +e
# The full runner log is streamed to Woodpecker below; avoid duplicating a
# short-lived, potentially secret-bearing build log in the Observer stream.
docker run -d --name "$job" \
	--label com.aichorage.platform=llm-hub-lite \
	--label com.aichorage.application=platform \
	--label com.aichorage.component=platform-deployment-runner \
	--label com.aichorage.observer.ignore-logs=true \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-v /opt/apps/llm-hub-lite:/opt/apps/llm-hub-lite \
	-v /opt/platform:/opt/platform \
	-v /opt/backups/llm-hub-lite:/opt/backups/llm-hub-lite \
	-v /run/lock/llm-hub-lite:/run/lock/llm-hub-lite \
	-v /etc/llm-hub-lite:/etc/llm-hub-lite \
	-e DEPLOY_SKIP_SINGLETONS="${DEPLOY_SKIP_SINGLETONS:-0}" \
	-e CONSUMER_APP_ID="${CONSUMER_APP_ID:-}" \
	-e DIRECT_APP_ID="${DIRECT_APP_ID:-}" \
	-e SINGLETON_FINAL_STOP="${SINGLETON_FINAL_STOP:-0}" \
	-e PLATFORM_ONLY_APP_ID="${CONSUMER_APP_ID:-}" \
	-e ALLOW_WOODPECKER_SELF_DISABLE="${ALLOW_WOODPECKER_SELF_DISABLE:-0}" \
	-e DEPLOY_WORKFLOW="${CI_WORKFLOW_NAME:-${CI_WORKFLOW:-unknown}}" \
	-e DEPLOY_PIPELINE="${CI_PIPELINE_NUMBER:-${CI_PIPELINE:-unknown}}" \
	-e DEPLOY_BUILD="${CI_BUILD_NUMBER:-${CI_BUILD:-unknown}}" \
	-e DEPLOY_DEBUG_LEVEL="${DEPLOY_DEBUG_LEVEL:-${PLATFORM_DEBUG_LEVEL:-off}}" \
	-v "$platformctl_source:/usr/local/bin/platformctl:ro" \
	-v "$controller_source:/usr/local/bin/deploy-controller:ro" \
	-v "$git_auth_source:/usr/local/bin/git-auth.sh:ro" \
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
status=0
wait_result="$(docker wait "$job")" || status=$?
stream_status=0
# Fetch the completed log after the container exits. Following a Docker log
# stream can remain open when a child inherits the pipe, causing CI to hang
# even though the deployment runner has already returned.
docker logs "$job" || stream_status=$?
if [[ "$status" -eq 0 ]]; then
	[[ "$wait_result" =~ ^[0-9]+$ ]] || {
		printf 'deployment runner returned an invalid status: %s\n' "$wait_result" >&2
		status=1
	}
	[[ "$status" -ne 0 ]] || status="$wait_result"
fi

# Exit 78 is the controller's explicit supersession result. Surface it as a
# successful no-op so Woodpecker can continue the DAG without treating an
# obsolete queued commit as a deployment failure.
if [[ "$status" -eq 78 ]]; then
	printf 'deployment skipped: commit superseded before mutation\n'
	status=0
fi
[[ "$stream_status" -eq 0 ]] || docker logs "$job" || true
if [[ "$status" -ne 0 && -x /usr/local/bin/platformctl ]]; then
	printf '%s\n' '--- host deployment diagnostics ---' >&2
	if [[ -n "${CONSUMER_APP_ID:-}" ]]; then
		/usr/local/bin/platformctl diagnose "app:${CONSUMER_APP_ID}" || true
	else
		/usr/local/bin/platformctl diagnose all || true
	fi
	printf '%s\n' '--- end host deployment diagnostics ---' >&2
fi
if [[ "$status" -eq 0 && "$mode" == cluster-reconcile ]]; then
	touch /etc/llm-hub-lite/firewall-reconcile.request 2>/dev/null || printf '%s\n' 'warning: firewall reconciliation request could not be queued; timer will retry' >&2
fi
if [[ "$status" -eq 0 && "$mode" == direct-publish ]]; then
	firewall_script="${FIREWALL_SCRIPT:-/usr/local/bin/configure-firewall}"
	if [[ ! -x "$firewall_script" ]]; then
		printf 'direct publication requires firewall reconciler: %s\n' "$firewall_script" >&2
		touch /etc/llm-hub-lite/firewall-reconcile.request 2>/dev/null || true
		status=1
	elif ! "$firewall_script"; then
		printf 'direct publication firewall reconciliation failed; listener remains protected by the previous policy\n' >&2
		touch /etc/llm-hub-lite/firewall-reconcile.request 2>/dev/null || true
		status=1
	fi
fi
if [[ "$status" -eq 0 && "$mode" == node-retire ]]; then
	cleanup_job='llm-hub-lite-node-retire'
	docker rm -f "$cleanup_job" >/dev/null 2>&1 || true
	if ! docker run -d --name "$cleanup_job" \
		--restart on-failure:5 \
		--label com.aichorage.platform=llm-hub-lite \
		--label com.aichorage.application=platform \
		--label com.aichorage.component=node-retirement \
		--label com.aichorage.observer.ignore-logs=true \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /opt/apps/llm-hub-lite:/opt/apps/llm-hub-lite \
		-v /opt/platform:/opt/platform \
		-v /run/lock/llm-hub-lite:/run/lock/llm-hub-lite \
		-v /etc/llm-hub-lite:/etc/llm-hub-lite \
		"$image" sh -c '
			status_file=/etc/llm-hub-lite/node-retirement.status
			delay="$1"
			printf "state=waiting\ndelay_seconds=%s\nstarted_utc=%s\n" "$delay" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
			chmod 600 "$status_file"
			sleep "$delay"
			printf "node retirement cleanup starting after %s seconds\n" "$delay"
			/opt/platform/control/current/ops/platformctl.sh retire-node
			result=$?
			if [ "$result" -eq 0 ]; then
				printf "state=completed\ncompleted_utc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
			else
				printf "state=failed\nexit_status=%s\nfailed_utc=%s\n" "$result" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
			fi
			chmod 600 "$status_file"
			exit "$result"
		' sh "$retire_delay" >/dev/null; then
		printf 'unable to schedule deferred node retirement cleanup\n' >&2
		exit 1
	fi
	printf 'node retirement cleanup scheduled in %s seconds (container %s; inspect failures with docker logs %s)\n' "$retire_delay" "$cleanup_job" "$cleanup_job"
fi
exit "$status"
