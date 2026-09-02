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
	git --git-dir="$MIRROR_PATH" show --format= --name-only "$sha" | sed '/^$/d'
fi

# API pruning is opt-in and Leader-only. Never cancel a running pipeline: the
# deployment controller's own supersession checkpoint is the final guard.
[[ -r "$config_file" ]] || exit 0
# shellcheck disable=SC1090
source "$config_file"
[[ "${WOODPECKER_AUTOMATION_ENABLED:-0}" == 1 ]] || exit 0
[[ "${WOODPECKER_API_URL:-}" == https://* || "${WOODPECKER_API_URL:-}" == http://* ]] || exit 0
[[ -n "${WOODPECKER_API_TOKEN:-}" && "${WOODPECKER_REPO_ID:-}" =~ ^[0-9]+$ ]] || exit 0
[[ "$branch" == "main" && "$current_pipeline" =~ ^[0-9]+$ ]] || exit 0

api="${WOODPECKER_API_URL%/}/api/repos/${WOODPECKER_REPO_ID}/pipelines"
response="$(curl -fsS -H "Authorization: Bearer $WOODPECKER_API_TOKEN" "$api?branch=main&per_page=50" 2>/dev/null || true)"
[[ -n "$response" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

while IFS='|' read -r number status commit; do
	[[ "$number" =~ ^[0-9]+$ && "$number" != "$current_pipeline" ]] || continue
	case "$status" in
	pending | blocked | enqueued | waiting)
		curl -fsS -X POST -H "Authorization: Bearer $WOODPECKER_API_TOKEN" \
			"${api}/${number}/decline" >/dev/null 2>&1 || true
		printf 'declined superseded pending pipeline=%s commit=%s\n' "$number" "$commit"
		;;
	esac
done < <(printf '%s' "$response" | jq -r '.[] | [(.number // .id), (.status // ""), (.commit // "")] | @tsv' | tr '\t' '|')
