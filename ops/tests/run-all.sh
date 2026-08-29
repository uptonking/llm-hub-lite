#!/usr/bin/env bash
# Run the repository test suites with deterministic, bounded scheduling.
# Suites use isolated temporary roots; bounded parallel batches reduce local
# and CI wall-clock time without allowing Docker-heavy tests to overwhelm a
# developer laptop.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
profile="${1:-fast}"

case "$profile" in
fast)
	# Keep the two Git/worktree-heavy suites in their dedicated CI jobs and out
	# of the default local loop.
	tests=(
		backup-test clean-vps-test configure-cluster-node-test controller-test
		enroll-beszel-test firewall-test git-auth-test ip-privacy-test
		observer-ingest-test observer-log-proxy-test observer-vector-test
		platform-submit-test restore-test secret-validation-test stack-test
		cursorapi-release-test woodpecker-agent-repair-test workflow-generator-test bootstrap-policy-test
	)
	;;
full)
	tests=(
		backup-test bootstrap-policy-test clean-vps-test configure-cluster-node-test
		controller-test cursorapi-release-test deployment-rollback-test
		enroll-beszel-test firewall-test git-auth-test ip-privacy-test
		observer-ingest-test observer-log-proxy-test observer-vector-test
		platform-submit-test platformctl-test restore-test secret-validation-test woodpecker-agent-repair-test
		stack-test workflow-generator-test
	)
	;;
*)
	printf 'usage: %s [fast|full]\n' "$0" >&2
	exit 2
	;;
esac

# Keep argument validation cheap and deterministic; CI/local callers can use
# TEST_PARALLELISM=1 when diagnosing an order-sensitive failure.

start_all="$(date +%s)"
parallelism="${TEST_PARALLELISM:-}"
if [[ -z "$parallelism" ]]; then
	case "$(uname -s 2>/dev/null || printf unknown)" in
	Darwin) parallelism=2 ;;
	*) parallelism=4 ;;
	esac
fi
[[ "$parallelism" =~ ^[1-9][0-9]*$ && "$parallelism" -le 16 ]] || {
	printf 'TEST_PARALLELISM must be an integer between 1 and 16\n' >&2
	exit 2
}
printf 'test profile: %s (parallelism=%s; suites=%s)\n' "$profile" "$parallelism" "${#tests[@]}"

log_root="$(mktemp -d "${TMPDIR:-/tmp}/llm-hub-lite-tests.XXXXXX")"
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` below
cleanup() {
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
	return "$rc"
}

overall_rc=0
total="${#tests[@]}"
offset=0
while ((offset < total)); do
	pids=()
	batch_names=()
	batch_logs=()
	for ((slot = 0; slot < parallelism && offset + slot < total; slot++)); do
		test_name="${tests[offset + slot]}"
		log_file="$log_root/$slot.log"
		printf '\n>>> %s\n' "$test_name"
		run_one "$test_name" "$log_file" &
		pids+=("$!")
		batch_names+=("$test_name")
		batch_logs+=("$log_file")
	done
	for ((slot = 0; slot < ${#pids[@]}; slot++)); do
		set +e
		wait "${pids[slot]}"
		rc=$?
		set -e
		cat "${batch_logs[slot]}"
		duration="$(cat "${batch_logs[slot]}.duration" 2>/dev/null || printf '?')"
		printf '<<< %s (%ss)\n' "${batch_names[slot]}" "$duration"
		if ((rc != 0)); then
			((overall_rc == 0)) && overall_rc="$rc"
			printf 'FAILED: %s (exit %s)\n' "${batch_names[slot]}" "$rc" >&2
		fi
	done
	offset=$((offset + ${#pids[@]}))
done
end_all="$(date +%s)"
if ((overall_rc == 0)); then
	printf '\nall tests passed (%ss)\n' "$((end_all - start_all))"
else
	printf '\nTESTS FAILED (first exit %s; elapsed %ss)\n' "$overall_rc" "$((end_all - start_all))" >&2
fi
exit "$overall_rc"
