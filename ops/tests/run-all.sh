#!/usr/bin/env bash
# Run the repository test suites with bounded, input-ordered scheduling.
# Suites use isolated temporary roots; a bounded worker queue reduces local and
# CI wall-clock time without allowing Docker-heavy tests to overwhelm a
# developer laptop. The queue avoids Bash 4-only `wait -n` so macOS Bash 3.2
# remains supported.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
profile="${1:-fast}"

case "$profile" in
fast)
	# Schedule longest-processing-time suites first so worker slots stay
	# saturated, with faster suites filling the tail.
	tests=(
		workflow-generator-test stack-test configure-cluster-node-test configure-app-placement-test
		controller-test backup-test app-identity-migration-test change-vps-test clean-vps-test
		enroll-beszel-test firewall-test git-auth-test ip-privacy-test observer-ingest-test
		observer-log-proxy-test observer-vector-test platform-submit-test restore-test
		secret-validation-test aichor-release-test aichor-runtime-test paseo-runtime-test
		aichor-pi-config-test cursorapi-release-test relaichor-app-test relaichor1-app-test
		paperlex-app-test filer-app-test outline-app-test openclouds-app-test collabora-app-test
		onoffice-app-test gtea-app-test relaichor-release-test woodpecker-agent-repair-test
		woodpecker-webhook-repair-test woodpecker-plan-test bootstrap-policy-test
	)
	;;
full)
	# Schedule the longest-running test suites first (platformctl-test,
	# deployment-rollback-test, workflow-generator-test, stack-test) so they
	# execute in parallel from the beginning, avoiding idle worker starvation.
	tests=(
		platformctl-test deployment-rollback-test workflow-generator-test stack-test
		configure-cluster-node-test configure-app-placement-test controller-test backup-test
		app-identity-migration-test bootstrap-policy-test change-vps-test clean-vps-test
		aichor-release-test aichor-runtime-test paseo-runtime-test aichor-pi-config-test
		cursorapi-release-test relaichor-app-test relaichor1-app-test paperlex-app-test
		filer-app-test outline-app-test openclouds-app-test collabora-app-test onoffice-app-test
		gtea-app-test relaichor-release-test enroll-beszel-test firewall-test git-auth-test
		ip-privacy-test observer-ingest-test observer-log-proxy-test observer-vector-test
		platform-submit-test restore-test secret-validation-test woodpecker-agent-repair-test
		woodpecker-webhook-repair-test woodpecker-plan-test
	)
	;;
*)
	printf 'usage: %s [fast|full]\n' "$0" >&2
	exit 2
	;;
esac

# Keep argument validation cheap and deterministic; CI/local callers can use
# TEST_PARALLELISM=1 when diagnosing an order-sensitive failure.

detect_parallelism() {
	local cpus='' os
	os="$(uname -s 2>/dev/null || printf unknown)"
	if command -v getconf >/dev/null 2>&1; then
		cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
	fi
	if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]] && command -v nproc >/dev/null 2>&1; then
		cpus="$(nproc 2>/dev/null || true)"
	fi
	if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]] && command -v sysctl >/dev/null 2>&1; then
		cpus="$(sysctl -n hw.ncpu 2>/dev/null || true)"
	fi
	if [[ "$cpus" =~ ^[1-9][0-9]*$ ]]; then
		local p="$cpus"
		case "$os" in
		Darwin)
			# macOS fork/exec overhead and kernel IPC thrash when more than
			# 3 suites run subshell-heavy validation simultaneously on a laptop.
			((p > 3)) && p=3
			;;
		*)
			# Linux clones processes efficiently; cap at 4 to prevent I/O contention.
			((p > 4)) && p=4
			;;
		esac
		((p < 2)) && p=2
		printf '%s\n' "$p"
	else
		case "$os" in
		Darwin) printf '2\n' ;;
		*) printf '4\n' ;;
		esac
	fi
}

start_all="$(date +%s)"
parallelism="${TEST_PARALLELISM:-}"
if [[ -z "$parallelism" ]]; then
	parallelism="$(detect_parallelism)"
fi
[[ "$parallelism" =~ ^[1-9][0-9]*$ && "$parallelism" -le 16 ]] || {
	printf 'TEST_PARALLELISM must be an integer between 1 and 16\n' >&2
	exit 2
}
printf 'test profile: %s (parallelism=%s; suites=%s)\n' "$profile" "$parallelism" "${#tests[@]}"

log_root="$(mktemp -d "${TMPDIR:-/tmp}/llm-hub-lite-tests.XXXXXX")"
active_pids=()
active_names=()
active_logs=()
# shellcheck disable=SC2317,SC2329 # cleanup is invoked indirectly via EXIT trap
cleanup() {
	local pid
	for pid in "${active_pids[@]:-}"; do
		[[ -n "$pid" ]] || continue
		kill "$pid" 2>/dev/null || true
	done
	rm -rf -- "$log_root"
}
trap cleanup EXIT
run_one() {
	local test_name="$1" log_file="$2" start end rc
	start="$(date +%s)"
	if bash "$repo_root/ops/tests/$test_name.sh" >"$log_file" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	end="$(date +%s)"
	printf '%s\n' "$rc" >"$log_file.rc"
	printf '%s\n' "$((end - start))" >"$log_file.duration"
	# Publish completion only after the result and duration are fully written.
	: >"$log_file.done"
	return "$rc"
}

overall_rc=0
total="${#tests[@]}"
started=0
finished=0
active_count=0
while ((finished < total)); do
	# Fill every available slot in input order.
	while ((started < total && active_count < parallelism)); do
		for ((slot = 0; slot < parallelism; slot++)); do
			[[ -z "${active_pids[slot]:-}" ]] || continue
			test_name="${tests[started]}"
			log_file="$log_root/$started.log"
			printf '\n>>> %s\n' "$test_name"
			run_one "$test_name" "$log_file" &
			active_pids[slot]="$!"
			active_names[slot]="$test_name"
			active_logs[slot]="$log_file"
			started=$((started + 1))
			active_count=$((active_count + 1))
			break
		done
	done

	progress=0
	for ((slot = 0; slot < parallelism; slot++)); do
		pid="${active_pids[slot]:-}"
		[[ -n "$pid" ]] || continue
		log_file="${active_logs[slot]}"
		# A completed marker means wait can now reap the child without blocking.
		if [[ -f "$log_file.done" ]] || ! kill -0 "$pid" 2>/dev/null; then
			if [[ ! -f "$log_file.done" ]]; then
				printf 'test runner: %s exited before publishing its result\n' "${active_names[slot]}" >&2
			fi
			set +e
			wait "$pid"
			rc=$?
			set -e
			cat "$log_file"
			duration="$(cat "$log_file.duration" 2>/dev/null || printf '?')"
			printf '<<< %s (%ss)\n' "${active_names[slot]}" "$duration"
			if ((rc != 0)); then
				((overall_rc == 0)) && overall_rc="$rc"
				printf 'FAILED: %s (exit %s)\n' "${active_names[slot]}" "$rc" >&2
			fi
			active_pids[slot]=''
			active_names[slot]=''
			active_logs[slot]=''
			active_count=$((active_count - 1))
			finished=$((finished + 1))
			progress=1
		fi
	done
	((finished == total || progress == 1)) || sleep 0.1
done
end_all="$(date +%s)"
if ((overall_rc == 0)); then
	printf '\nall tests passed (%ss)\n' "$((end_all - start_all))"
else
	printf '\nTESTS FAILED (first observed exit %s; elapsed %ss)\n' "$overall_rc" "$((end_all - start_all))" >&2
fi
exit "$overall_rc"
