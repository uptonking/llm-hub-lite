#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
publisher="$repo_root/ops/publish-relaichor-image.sh"
# shellcheck disable=SC1091
source "$repo_root/images/relaichor/release.env"

if grep -R -E 'publish-relaichor-image\.sh|images/relaichor/(Dockerfile|release\.env)' \
	"$repo_root/.github/workflows" "$repo_root/.woodpecker"; then
	printf 'Relaichor image publication must remain a manual release action\n' >&2
	exit 1
fi

grep -Fq 'mix test' "$repo_root/images/relaichor/Dockerfile"
grep -Fq 'MIX_ENV=prod mix release' "$repo_root/images/relaichor/Dockerfile"
grep -Fq 'USER 65532:65532' "$repo_root/images/relaichor/Dockerfile"
grep -Fq 'libstdc++6 libsctp1 openssl ca-certificates' "$repo_root/images/relaichor/Dockerfile"
grep -Fq -- '--platform linux/amd64' "$publisher"
grep -Fq -- '--provenance=mode=max' "$publisher"
grep -Fq -- '--sbom=true' "$publisher"
# shellcheck disable=SC2016
grep -Fq 'git -C "$source_dir" archive "$RELAICHOR_SOURCE_COMMIT"' "$publisher"
grep -Eq '^RELAICHOR_(BUILDER|RUNTIME)_IMAGE=.*@sha256:[0-9a-f]{64}$' "$repo_root/images/relaichor/release.env"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/source/.git"
cat >"$tmp/bin/git" <<'EOF'
#!/bin/sh
case "$*" in
  *'rev-parse HEAD') printf '%s\n' "$TEST_SOURCE_COMMIT" ;;
  *'status --porcelain') ;;
  *'remote get-url origin') printf '%s\n' 'https://github.com/getpaseo/paseo-relay.git' ;;
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
    *) printf 'unexpected inspect result\n' >&2; exit 2 ;;
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

run_collision() {
	PATH="$tmp/bin:$PATH" TEST_SOURCE_COMMIT="$RELAICHOR_SOURCE_COMMIT" \
		TEST_DOCKER_LOG="$tmp/docker.log" TEST_DOCKER_INSPECT_RESULT="$1" \
		"$publisher" "$tmp/source" 2>&1
}

: >"$tmp/docker.log"
set +e
output="$(run_collision exists)"
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq "refusing to overwrite existing Relaichor release tag: $RELAICHOR_IMAGE_REPOSITORY:$RELAICHOR_IMAGE_TAG" <<<"$output"
if grep -Fq 'buildx build' "$tmp/docker.log"; then
	printf 'Relaichor publisher built after a tag collision\n' >&2
	exit 1
fi

: >"$tmp/docker.log"
set +e
output="$(run_collision error)"
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'unable to prove that Relaichor release tag is unused' <<<"$output"
grep -Fq 'registry connection timed out' <<<"$output"

printf 'Relaichor manual release policy tests passed\n'
