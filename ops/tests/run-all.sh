#!/usr/bin/env bash
# Run the repository test suites with deterministic, bounded scheduling.
# Docker-backed suites are intentionally serialized: parallel Compose mocks
# consume more CPU on macOS and do not improve coverage for this repository.
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
		cursorapi-release-test workflow-generator-test bootstrap-policy-test
	)
	;;
full)
	tests=(
		backup-test bootstrap-policy-test clean-vps-test configure-cluster-node-test
		controller-test cursorapi-release-test deployment-rollback-test
		enroll-beszel-test firewall-test git-auth-test ip-privacy-test
		observer-ingest-test observer-log-proxy-test observer-vector-test
		platform-submit-test platformctl-test restore-test secret-validation-test
		stack-test workflow-generator-test
	)
	;;
*)
	printf 'usage: %s [fast|full]\n' "$0" >&2
	exit 2
	;;
esac

printf 'test profile: %s (serialized; suites=%s)\n' "$profile" "${#tests[@]}"
start_all="$(date +%s)"
for test_name in "${tests[@]}"; do
	test_start="$(date +%s)"
	printf '\n>>> %s\n' "$test_name"
	bash "$repo_root/ops/tests/$test_name.sh"
	test_end="$(date +%s)"
	printf '<<< %s (%ss)\n' "$test_name" "$((test_end - test_start))"
done
end_all="$(date +%s)"
printf '\nall tests passed (%ss)\n' "$((end_all - start_all))"
