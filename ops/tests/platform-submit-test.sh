#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "$1 $2 $3" in
  "image inspect --format") printf '%s\n' 'sha256:runner-id' ;;
  wait*) printf '0\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/docker"
cat >"$tmp/platform.env" <<'EOF'
PLATFORM_RUNNER_IMAGE=llm-hub-lite/deploy-runner:0.4.0
PLATFORM_RUNNER_IMAGE_ID=sha256:runner-id
EOF
export PATH="$tmp/bin:$PATH" PLATFORM_ENV_FILE="$tmp/platform.env" DOCKER_CALL_LOG="$tmp/docker.log"
bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef0123456789abcdef01234567"
grep -Fq -- 'run -d --name' "$tmp/docker.log"
grep -Fq -- 'llm-hub-lite/deploy-runner:0.4.0' "$tmp/docker.log"
grep -Fq -- '/usr/local/bin/git-auth.sh:/usr/local/bin/git-auth.sh:ro' "$tmp/docker.log"
grep -Fq -- 'logs -f llm-hub-lite-platform-apply-deploy-0123456789abcdef0123456789abcdef01234567' "$tmp/docker.log"
grep -Fq -- 'PLATFORM_ONLY_APP_ID=' "$tmp/docker.log"
printf 'platform-submit tests passed\n'
