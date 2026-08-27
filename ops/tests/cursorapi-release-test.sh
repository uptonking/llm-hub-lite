#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
publisher="$repo_root/ops/publish-cursorapi-image.sh"

if grep -R -E 'publish-cursorapi-image\.sh|images/cursorapi/(Dockerfile|release\.env)|ghcr\.io/uptonking/cursor-api-proxy' \
	"$repo_root/.github/workflows" "$repo_root/.woodpecker"; then
	printf 'Cursorapi image publication must not run from GitHub or Woodpecker workflows\n' >&2
	exit 1
fi

# Exercise the tag-collision path with command stubs. No source archive,
# download, image build, or registry mutation may occur after a collision.
# shellcheck disable=SC1091
source "$repo_root/images/cursorapi/release.env"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/source/.git"

cat >"$tmp/bin/git" <<'EOF'
#!/bin/sh
case "$*" in
	*'rev-parse HEAD') printf '%s\n' "$TEST_SOURCE_COMMIT" ;;
	*'status --porcelain') ;;
	*'remote get-url origin') printf '%s\n' 'https://github.com/anyrobert/cursor-api-proxy.git' ;;
	*) printf 'unexpected git invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DOCKER_LOG"
if [ "$1 $2 $3" = 'buildx imagetools inspect' ]; then
	case "$TEST_DOCKER_INSPECT_RESULT" in
		exists) exit 0 ;;
		error) printf 'registry connection timed out\n' >&2; exit 2 ;;
		*) printf 'unexpected inspect result fixture\n' >&2; exit 2 ;;
	esac
fi
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 2
EOF

for command_name in curl jq; do
	cat >"$tmp/bin/$command_name" <<'EOF'
#!/bin/sh
printf 'unexpected command invocation: %s\n' "$0" >&2
exit 2
EOF
done
chmod 700 "$tmp/bin/git" "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/jq"

docker_log="$tmp/docker.log"
set +e
output="$(
	PATH="$tmp/bin:$PATH" \
		TEST_SOURCE_COMMIT="$CURSORAPI_SOURCE_COMMIT" \
		TEST_DOCKER_LOG="$docker_log" \
		TEST_DOCKER_INSPECT_RESULT=exists \
		"$publisher" "$tmp/source" 2>&1
)"
status=$?
set -e

[[ "$status" -ne 0 ]]
grep -Fq "refusing to overwrite existing Cursorapi release tag: $CURSORAPI_IMAGE_REPOSITORY:$CURSORAPI_IMAGE_TAG" <<<"$output"
grep -Fq "choose a new CURSORAPI_IMAGE_TAG in $repo_root/images/cursorapi/release.env" <<<"$output"
grep -Fxq "buildx imagetools inspect $CURSORAPI_IMAGE_REPOSITORY:$CURSORAPI_IMAGE_TAG" "$docker_log"
if grep -Fq 'buildx build' "$docker_log"; then
	printf 'Cursorapi publisher continued to an image build after detecting an existing tag\n' >&2
	exit 1
fi

: >"$docker_log"
set +e
output="$(
	PATH="$tmp/bin:$PATH" \
		TEST_SOURCE_COMMIT="$CURSORAPI_SOURCE_COMMIT" \
		TEST_DOCKER_LOG="$docker_log" \
		TEST_DOCKER_INSPECT_RESULT=error \
		"$publisher" "$tmp/source" 2>&1
)"
status=$?
set -e

[[ "$status" -ne 0 ]]
grep -Fq "unable to prove that Cursorapi release tag is unused: $CURSORAPI_IMAGE_REPOSITORY:$CURSORAPI_IMAGE_TAG" <<<"$output"
grep -Fq 'registry connection timed out' <<<"$output"
if grep -Fq 'buildx build' "$docker_log"; then
	printf 'Cursorapi publisher continued after an inconclusive registry check\n' >&2
	exit 1
fi

printf 'Cursorapi manual release policy tests passed\n'
