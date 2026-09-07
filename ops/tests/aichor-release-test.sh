#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
publisher="$repo_root/ops/publish-aichor-image.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/npm" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
  'view @openai/codex version') printf '%s\n' "${TEST_CODEX_VERSION:-0.153.4}" ;;
  'view @anthropic-ai/claude-code version') printf '%s\n' "${TEST_CLAUDE_VERSION:-2.1.263}" ;;
  'view opencode-ai version') printf '%s\n' "${TEST_OPENCODE_VERSION:-1.18.29}" ;;
  'view @earendil-works/pi-coding-agent version') printf '%s\n' "${TEST_PI_VERSION:-0.85.1}" ;;
  *) printf 'unexpected npm invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DOCKER_LOG"
if [ "$1 $2 $3" = 'buildx imagetools inspect' ]; then
  case "$4" in
    *@sha256:*) exit 0 ;;
  esac
  case "$TEST_DOCKER_INSPECT_RESULT" in
    exists) exit 0 ;;
    inconclusive) printf 'registry connection timed out\n' >&2; exit 2 ;;
    not-found) printf 'manifest unknown\n' >&2; exit 1 ;;
    *) printf 'unexpected inspect fixture\n' >&2; exit 2 ;;
  esac
fi
if [ "$1 $2" = 'buildx build' ]; then
  metadata=''
  previous=''
  for arg in "$@"; do
    if [ "$previous" = '--metadata-file' ]; then metadata="$arg"; fi
    previous="$arg"
  done
  [ -n "$metadata" ] || { printf 'metadata file was not passed\n' >&2; exit 2; }
  printf '{"containerimage.digest":"%s"}\n' "$TEST_DIGEST" >"$metadata"
  exit 0
fi
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 2
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *ghcr.io/token*) printf '{"token":"anonymous-test-token"}\n' ;;
  *)
    output=''
    previous=''
    for arg in "$@"; do
      if [ "$previous" = '-o' ]; then output="$arg"; fi
      previous="$arg"
    done
    [ -n "$output" ] || { printf 'unexpected curl invocation: %s\n' "$*" >&2; exit 2; }
    printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$TEST_DIGEST" >"$output"
    ;;
esac
EOF

cat >"$tmp/bin/jq" <<'EOF'
#!/bin/sh
case "$*" in
  *containerimage.digest*) printf '%s\n' "$TEST_DIGEST" ;;
  *.token*) printf '%s\n' 'anonymous-test-token' ;;
  *) printf '%s\n' '' ;;
esac
EOF
chmod 700 "$tmp/bin/npm" "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/jq"

release="$tmp/release.env"
cp "$repo_root/images/aichor/release.env" "$release"
sed -i.bak \
	-e 's/^AICHOR_CODEX_VERSION=.*/AICHOR_CODEX_VERSION=/' \
	-e 's/^AICHOR_CLAUDE_CODE_VERSION=.*/AICHOR_CLAUDE_CODE_VERSION=/' \
	-e 's/^AICHOR_OPENCODE_VERSION=.*/AICHOR_OPENCODE_VERSION=/' \
	-e 's/^AICHOR_PI_CODING_AGENT_VERSION=.*/AICHOR_PI_CODING_AGENT_VERSION=/' \
	-e 's/^AICHOR_IMAGE_TAG=.*/AICHOR_IMAGE_TAG=test-release-unique/' "$release"
rm -f "$release.bak"

run_publisher() {
	PATH="$tmp/bin:$PATH" \
		AICHOR_RELEASE_FILE="$release" \
		TEST_DOCKER_LOG="$tmp/docker.log" \
		TEST_DOCKER_INSPECT_RESULT="${TEST_DOCKER_INSPECT_RESULT:-not-found}" \
		TEST_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
		"$publisher" >"$tmp/publisher.out" 2>&1 || {
		cat "$tmp/publisher.out" >&2
		return 1
	}
}

: >"$tmp/docker.log"
run_publisher
grep -Fxq 'AICHOR_CODEX_VERSION=0.153.4' "$release"
grep -Fxq 'AICHOR_CLAUDE_CODE_VERSION=2.1.263' "$release"
grep -Fxq 'AICHOR_OPENCODE_VERSION=1.18.29' "$release"
grep -Fxq 'AICHOR_PI_CODING_AGENT_VERSION=0.85.1' "$release"
grep -Fq 'buildx build' "$tmp/docker.log"

set +e
: >"$tmp/docker.log"
TEST_DOCKER_INSPECT_RESULT=exists run_publisher
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'refusing to overwrite existing Aichor release tag' "$tmp/publisher.out"
if grep -Fq 'buildx build' "$tmp/docker.log"; then
	printf 'Aichor publisher built after tag collision\n' >&2
	exit 1
fi

set +e
: >"$tmp/docker.log"
TEST_DOCKER_INSPECT_RESULT=inconclusive run_publisher
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'unable to prove that Aichor release tag is unused' "$tmp/publisher.out"

sed -i.bak 's/^AICHOR_CODEX_VERSION=.*/AICHOR_CODEX_VERSION=/' "$release"
rm -f "$release.bak"
set +e
: >"$tmp/docker.log"
TEST_CODEX_VERSION='not-a-version' TEST_DOCKER_INSPECT_RESULT=not-found run_publisher
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'invalid npm version for @openai/codex' "$tmp/publisher.out"

printf 'Aichor manual release policy tests passed\n'
