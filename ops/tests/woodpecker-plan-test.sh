#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/etc"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
	if [[ "${args[index]}" == -X && "${args[index + 1]:-}" == POST ]]; then
		printf '%s\n' "${args[${#args[@]} - 1]}" >>"${WOODPECKER_DECLINES_FILE:?}"
		exit 0
	fi
done
printf '%s\n' '[]'
EOF
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '9|pending|old' '10|pending|current' '11|pending|new' '12|success|done'
EOF
chmod 755 "$tmp/bin/curl" "$tmp/bin/jq"
cat >"$tmp/etc/woodpecker.env" <<'EOF'
WOODPECKER_AUTOMATION_ENABLED=1
WOODPECKER_API_URL=https://ci.example.invalid
WOODPECKER_API_TOKEN=test-token
WOODPECKER_REPO_ID=1
EOF
declines="$tmp/declines"
touch "$declines"

PATH="$tmp/bin:$PATH" \
	WOODPECKER_AUTOMATION_ENV="$tmp/etc/woodpecker.env" \
	WOODPECKER_DECLINES_FILE="$declines" \
	CI_REPO=uptonking/llm-hub-lite CI_COMMIT_BRANCH=main CI_PIPELINE_NUMBER=10 \
	CI_COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
	bash "$repo_root/ops/woodpecker-plan.sh" >"$tmp/output"

grep -Fq 'declined superseded pending pipeline=9 commit=old' "$tmp/output"
[[ "$(wc -l <"$declines" | tr -d ' ')" -eq 1 ]]
grep -Fq '/api/repos/1/pipelines/9/decline' "$declines"
printf 'woodpecker planner tests passed\n'
