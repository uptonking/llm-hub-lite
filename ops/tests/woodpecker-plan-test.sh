#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/etc" "$tmp/data"
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

# Set up mock sqlite db with a stuck pipeline on an offline agent
db="$tmp/data/woodpecker.sqlite"
sqlite3 "$db" "
	CREATE TABLE users (id INTEGER PRIMARY KEY, hash TEXT, admin INTEGER);
	INSERT INTO users VALUES (1, 'test-admin-hash', 1);
	CREATE TABLE agents (id INTEGER PRIMARY KEY, name TEXT, last_contact INTEGER, custom_labels TEXT);
	INSERT INTO agents VALUES (1, 'offline-node', unixepoch('now') - 3600, '{\"node\":\"worker-offline\"}');
	CREATE TABLE pipelines (id INTEGER PRIMARY KEY, number INTEGER, status TEXT, created INTEGER);
	INSERT INTO pipelines VALUES (8, 8, 'running', unixepoch('now') - 600);
	CREATE TABLE workflows (id INTEGER PRIMARY KEY, pipeline_id INTEGER, name TEXT, state TEXT, agent_id INTEGER, environ TEXT);
	INSERT INTO workflows VALUES (1, 8, 'control-sync-worker-offline', 'pending', 0, '{\"CI_PIPELINE_NODE\":\"worker-offline\"}');
"

cat >"$tmp/etc/woodpecker.env" <<EOF
WOODPECKER_AUTOMATION_ENABLED=1
WOODPECKER_API_URL=https://ci.example.invalid
WOODPECKER_API_TOKEN=test-token
WOODPECKER_REPO_ID=1
WOODPECKER_DATA_ROOT=$tmp/data
EOF
declines="$tmp/declines"
touch "$declines"

PATH="$tmp/bin:$PATH" \
	WOODPECKER_AUTOMATION_ENV="$tmp/etc/woodpecker.env" \
	WOODPECKER_DECLINES_FILE="$declines" \
	WOODPECKER_DATA_ROOT="$tmp/data" \
	CI_REPO=uptonking/llm-hub-lite CI_COMMIT_BRANCH=main CI_PIPELINE_NUMBER=10 \
	CI_COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
	bash "$repo_root/ops/woodpecker-plan.sh" >"$tmp/output"

grep -Fq 'declined superseded pending pipeline=9 commit=old' "$tmp/output"
grep -Fq 'cancelled stuck pipeline=8' "$tmp/output"
[[ "$(wc -l <"$declines" | tr -d ' ')" -eq 2 ]]
grep -Fq '/api/repos/1/pipelines/9/decline' "$declines"
grep -Fq '/api/repos/1/pipelines/8/cancel' "$declines"

printf 'woodpecker planner tests passed\n'
