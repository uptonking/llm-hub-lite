#!/usr/bin/env bash
# shellcheck disable=SC2016 # fixture intentionally writes literal shell text
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
mkdir -p "$tmp/controller"
printf '%s\n' 'case "$1" in control-sync) ;; esac' >"$tmp/controller/deploy-controller.sh"
printf '%s\n' '#!/bin/sh' >"$tmp/controller/platformctl.sh"
printf '%s\n' '#!/usr/bin/env bash' 'setup_github_https_auth() { :; }' 'cleanup_github_https_auth() { :; }' >"$tmp/controller/git-auth.sh"
printf '%s\n' '#!/bin/sh' 'exec /opt/platform/control/current/ops/git-auth.sh "$@"' >"$tmp/controller/git-auth-wrapper.sh"
chmod 700 "$tmp/controller/deploy-controller.sh" "$tmp/controller/platformctl.sh" "$tmp/controller/git-auth.sh" "$tmp/controller/git-auth-wrapper.sh"
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
cat >"$tmp/bin/firewall" <<'EOF'
#!/bin/sh
printf '%s\n' firewall >>"${FIREWALL_CALL_LOG:?}"
EOF
chmod +x "$tmp/bin/firewall"
cat >"$tmp/platform.env" <<'EOF'
PLATFORM_RUNNER_IMAGE=llm-hub-lite/deploy-runner:0.4.0
PLATFORM_RUNNER_IMAGE_ID=sha256:runner-id
EOF
export PATH="$tmp/bin:$PATH" PLATFORM_ENV_FILE="$tmp/platform.env" DOCKER_CALL_LOG="$tmp/docker.log"
export PLATFORM_CONTROLLER_SOURCE="$tmp/controller/deploy-controller.sh" PLATFORMCTL_SOURCE="$tmp/controller/platformctl.sh"
export GIT_AUTH_SOURCE="$tmp/controller/git-auth.sh"
export FIREWALL_CALL_LOG="$tmp/firewall.log"
bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef0123456789abcdef01234567"
grep -Fq -- 'run -d --name' "$tmp/docker.log"
grep -Fq -- 'llm-hub-lite/deploy-runner:0.4.0' "$tmp/docker.log"
grep -Fq -- "$tmp/controller/deploy-controller.sh:/usr/local/bin/deploy-controller:ro" "$tmp/docker.log"
grep -Fq -- "$tmp/controller/platformctl.sh:/usr/local/bin/platformctl:ro" "$tmp/docker.log"
grep -Fq -- "$tmp/controller/git-auth.sh:/usr/local/bin/git-auth.sh:ro" "$tmp/docker.log"
grep -Fq -- 'logs llm-hub-lite-platform-apply-deploy-0123456789abcdef0123456789abcdef01234567' "$tmp/docker.log"
grep -Fq -- 'PLATFORM_ONLY_APP_ID=' "$tmp/docker.log"

: >"$tmp/firewall.log"
FIREWALL_SCRIPT="$tmp/bin/firewall" DIRECT_APP_ID=verge bash "$repo_root/ops/platform-submit.sh" direct-publish "0123456789abcdef0123456789abcdef01234567"
grep -Fqx firewall "$tmp/firewall.log"

if output="$(bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef" 2>&1)"; then
	printf 'platform-submit accepted a short deployment target\n' >&2
	exit 1
fi
grep -Fq 'target must be a full 40-character lowercase commit SHA' <<<"$output"

if output="$(PLATFORM_CONTROLLER_SOURCE="$tmp/controller/missing" bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef0123456789abcdef01234567" 2>&1)"; then
	printf 'platform-submit accepted a missing controller wrapper\n' >&2
	exit 1
fi
grep -Fq 'validated deployment controller is unavailable or too old' <<<"$output"

if output="$(PLATFORMCTL_SOURCE="$tmp/controller/missing" bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef0123456789abcdef01234567" 2>&1)"; then
	printf 'platform-submit accepted a missing validated platformctl\n' >&2
	exit 1
fi
grep -Fq 'validated platformctl is unavailable' <<<"$output"

if output="$(GIT_AUTH_SOURCE="$tmp/controller/git-auth-wrapper.sh" bash "$repo_root/ops/platform-submit.sh" deploy "0123456789abcdef0123456789abcdef01234567" 2>&1)"; then
	printf 'platform-submit accepted an executable Git authentication wrapper as a source library\n' >&2
	exit 1
fi
grep -Fq 'validated Git authentication helper is unavailable or unsafe to source' <<<"$output"

: >"$tmp/docker.log"
NODE_RETIRE_DELAY_SECONDS=0 bash "$repo_root/ops/platform-submit.sh" node-retire "0123456789abcdef0123456789abcdef01234567"
grep -Fq -- 'run -d --name llm-hub-lite-node-retire --restart on-failure:5' "$tmp/docker.log"
grep -Fq -- '/opt/platform/control/current/ops/platformctl.sh retire-node' "$tmp/docker.log"
grep -Fq -- 'sh 0' "$tmp/docker.log"

: >"$tmp/docker.log"
if output="$(NODE_RETIRE_DELAY_SECONDS=301 bash "$repo_root/ops/platform-submit.sh" node-retire "0123456789abcdef0123456789abcdef01234567" 2>&1)"; then
	printf 'platform-submit accepted an excessive retirement delay\n' >&2
	exit 1
fi
grep -Fq 'NODE_RETIRE_DELAY_SECONDS must be an integer between 0 and 300' <<<"$output"
if grep -Fq 'run -d --name llm-hub-lite-platform-apply' "$tmp/docker.log"; then
	printf 'invalid retirement delay started a deployment runner\n' >&2
	exit 1
fi
printf 'platform-submit tests passed\n'
