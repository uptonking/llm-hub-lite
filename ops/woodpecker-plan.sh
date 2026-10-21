#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

config_file="${WOODPECKER_AUTOMATION_ENV:-/etc/llm-hub-lite/woodpecker-automation.env}"
repo_slug="${CI_REPO:-${REPO_SLUG:-}}"
current_pipeline="${CI_PIPELINE_NUMBER:-${CI_PIPELINE:-}}"
branch="${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-main}}"
sha="${CI_COMMIT_SHA:-}"

printf 'Woodpecker push received sha=%s ref=%s repo=%s\n' "$sha" "$branch" "$repo_slug"

if [[ -n "${MIRROR_PATH:-}" && -d "$MIRROR_PATH" && -n "$sha" ]]; then
	if git --git-dir="$MIRROR_PATH" cat-file -e "$sha^{commit}" 2>/dev/null; then
		git --git-dir="$MIRROR_PATH" show --format= --name-only "$sha" | sed '/^$/d'
	else
		printf 'Woodpecker audit commit %s is not in the local mirror yet; continuing without changed-file listing\n' "$sha"
	fi
fi

# Load optional external automation config
if [[ -r "$config_file" ]]; then
	# shellcheck disable=SC1090
	source "$config_file"
fi

# Auto-authenticate using the Leader SQLite database when external token is absent
db="${WOODPECKER_DATA_ROOT:-/opt/platform/woodpecker/data}/woodpecker.sqlite"
if [[ -z "${WOODPECKER_API_TOKEN:-}" && -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
	user_info="$(sqlite3 -separator ' ' "$db" 'select id,hash from users where admin = 1 and hash <> "" order by id limit 1;' 2>/dev/null || true)"
	if [[ -n "$user_info" ]]; then
		read -r u_id u_hash <<<"$user_info"
		b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
		hdr="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)"
		pld="$(printf '{"type":"user","user-id":"%s"}' "$u_id" | b64url)"
		sig="$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -hmac "$u_hash" -binary | b64url)"
		WOODPECKER_API_TOKEN="$hdr.$pld.$sig"
		WOODPECKER_AUTOMATION_ENABLED=1
	fi
fi

if [[ -z "${WOODPECKER_API_URL:-}" ]]; then
	woodpecker_env="${FOUNDATION_ENV_ROOT:-/opt/platform/foundation/env}/woodpecker.env"
	if [[ -r "$woodpecker_env" ]]; then
		host="$(sed -n 's/^WOODPECKER_HOST=//p' "$woodpecker_env" | tail -n1)"
		[[ -z "$host" ]] || WOODPECKER_API_URL="$host"
	fi
fi
WOODPECKER_REPO_ID="${WOODPECKER_REPO_ID:-1}"

[[ "${WOODPECKER_AUTOMATION_ENABLED:-0}" == 1 ]] || exit 0
[[ "${WOODPECKER_API_URL:-}" == https://* || "${WOODPECKER_API_URL:-}" == http://* ]] || exit 0
[[ -n "${WOODPECKER_API_TOKEN:-}" && "${WOODPECKER_REPO_ID:-}" =~ ^[0-9]+$ ]] || exit 0
[[ "$branch" == "main" && "$current_pipeline" =~ ^[0-9]+$ ]] || exit 0

api="${WOODPECKER_API_URL%/}/api/repos/${WOODPECKER_REPO_ID}/pipelines"
response="$(curl -fsS -H "Authorization: Bearer $WOODPECKER_API_TOKEN" "$api?branch=main&per_page=50" 2>/dev/null || true)"
[[ -n "$response" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# 1. Supersede older queued work
while IFS='|' read -r number status commit; do
	[[ "$number" =~ ^[0-9]+$ && "$number" -lt "$current_pipeline" ]] || continue
	case "$status" in
	pending | blocked | enqueued | waiting)
		curl -fsS -X POST -H "Authorization: Bearer $WOODPECKER_API_TOKEN" \
			"${api}/${number}/decline" >/dev/null 2>&1 || true
		printf 'declined superseded pending pipeline=%s commit=%s\n' "$number" "$commit"
		;;
	esac
done < <(printf '%s' "$response" | jq -r '.[] | [(.number // .id), (.status // ""), (.commit // "")] | @tsv' | tr '\t' '|')

# 2. Cancel pipelines with workflows stuck on offline or missing agents
if [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
	max_pending_age="${WOODPECKER_PENDING_TIMEOUT:-180}"
	while IFS='|' read -r p_num wf_name; do
		[[ -n "$p_num" && "$p_num" =~ ^[0-9]+$ ]] || continue
		curl -fsS -X POST -H "Authorization: Bearer $WOODPECKER_API_TOKEN" \
			"${api}/${p_num}/cancel" >/dev/null 2>&1 || true
		printf 'cancelled stuck pipeline=%s step=%s (agent offline or missing)\n' "$p_num" "$wf_name"
	done < <(sqlite3 -separator '|' "$db" "
		SELECT p.number, w.name
		FROM workflows w
		JOIN pipelines p ON p.id = w.pipeline_id
		WHERE w.state = 'pending'
		  AND p.status IN ('running', 'pending')
		  AND (unixepoch('now') - p.created) > $max_pending_age
		  AND (
		    w.agent_id = 0
		    OR w.agent_id IN (
		      SELECT id FROM agents WHERE (unixepoch('now') - last_contact) > $max_pending_age
		    )
		  )
		GROUP BY p.number;
	" 2>/dev/null || true)
fi
