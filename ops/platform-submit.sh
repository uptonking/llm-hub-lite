#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
sha="${2:-}"
[[ "$mode" =~ ^(deploy|foundation-upgrade|app-upgrade|rollback)$ ]] || { printf 'usage: platform-submit {deploy|foundation-upgrade|app-upgrade|rollback} <sha-or-previous>\n' >&2; exit 2; }
[[ -n "$sha" ]] || { printf 'missing target\n' >&2; exit 2; }

image="${PLATFORM_CONTROLLER_IMAGE:-llm-hub-lite/deploy-runner:0.3.0}"
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
  -v /usr/local/bin/backup-platform:/usr/local/bin/backup-platform:ro \
  "$image" /usr/local/bin/deploy-controller "$mode" "$sha" >/dev/null
status=0
docker wait "$job" >/dev/null || status=$?
docker logs "$job"
docker rm "$job" >/dev/null 2>&1 || true
exit "$status"
