#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
release_file="$root/images/cursorapi/release.env"
source_dir="${1:-${CURSORAPI_SOURCE_DIR:-}}"
[[ -r "$release_file" ]] || {
	printf 'missing release metadata: %s\n' "$release_file" >&2
	exit 1
}
# shellcheck disable=SC1090
source "$release_file"
# shellcheck disable=SC1091
source "$root/ops/lib/publish-image-common.sh"

[[ -n "$source_dir" ]] || {
	printf 'usage: %s <cursor-api-proxy-source-dir>\n' "$0" >&2
	exit 2
}
[[ -d "$source_dir/.git" ]] || {
	printf 'cursor-api-proxy source is not a Git checkout: %s\n' "$source_dir" >&2
	exit 1
}
publisher_require_commands curl docker git jq

source_commit="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$source_commit" == "$CURSORAPI_SOURCE_COMMIT" ]] || {
	printf 'source revision mismatch: expected %s, found %s\n' "$CURSORAPI_SOURCE_COMMIT" "$source_commit" >&2
	exit 1
}
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || {
	printf 'cursor-api-proxy source checkout must be clean\n' >&2
	exit 1
}
[[ "$(git -C "$source_dir" remote get-url origin)" == *anyrobert/cursor-api-proxy* ]] || {
	printf 'unexpected cursor-api-proxy origin remote\n' >&2
	exit 1
}

image_ref="$CURSORAPI_IMAGE_REPOSITORY:$CURSORAPI_IMAGE_TAG"
publisher_assert_tag_unused "$image_ref" Cursorapi "$release_file"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
archive="$tmp/cursor-agent.tar.gz"
build_context="$tmp/source"
mkdir -p "$build_context"
git -C "$source_dir" archive "$CURSORAPI_SOURCE_COMMIT" | tar -x -C "$build_context"
# The upstream ignore file omits its tests. This is a disposable, commit-pinned
# archive, so include those tests in the reproducible image build context.
rm -f "$build_context/.dockerignore"
printf 'Downloading Cursor Agent %s...\n' "$CURSOR_AGENT_VERSION"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
	-o "$archive" "$CURSOR_AGENT_LINUX_AMD64_URL"
if command -v sha256sum >/dev/null 2>&1; then
	printf '%s  %s\n' "$CURSOR_AGENT_LINUX_AMD64_SHA256" "$archive" | sha256sum -c - >/dev/null
else
	[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$CURSOR_AGENT_LINUX_AMD64_SHA256" ]] || {
		printf 'Cursor Agent checksum verification failed\n' >&2
		exit 1
	}
fi

metadata="$tmp/build-metadata.json"
printf 'Building and publishing %s...\n' "$image_ref"
docker buildx build \
	--platform linux/amd64 \
	--file "$root/images/cursorapi/Dockerfile" \
	--build-context "cursor_agent=$tmp" \
	--build-arg "CURSORAPI_SOURCE_COMMIT=$CURSORAPI_SOURCE_COMMIT" \
	--build-arg "CURSORAPI_SOURCE_VERSION=$CURSORAPI_SOURCE_VERSION" \
	--build-arg "CURSOR_AGENT_VERSION=$CURSOR_AGENT_VERSION" \
	--provenance=mode=max \
	--sbom=true \
	--tag "$image_ref" \
	--metadata-file "$metadata" \
	--push \
	"$build_context"

digest="$(publisher_extract_digest "$metadata")"
publisher_verify_digest "$image_ref" "$digest"
publisher_verify_anonymous_ghcr "$CURSORAPI_IMAGE_REPOSITORY" "$CURSORAPI_IMAGE_TAG" "$digest" "$tmp" Cursorapi

printf '\nPublished and anonymously verified:\n'
printf 'CURSORAPI_IMAGE=%s@%s\n' "$image_ref" "$digest"
