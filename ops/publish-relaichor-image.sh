#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
release_file="${RELAICHOR_RELEASE_FILE:-$root/images/relaichor/release.env}"
source_dir="${1:-${RELAICHOR_SOURCE_DIR:-}}"
# shellcheck disable=SC1090,SC1091
source "$release_file"
# shellcheck disable=SC1091
source "$root/ops/lib/publish-image-common.sh"

[[ -n "$source_dir" ]] || {
	printf 'usage: %s <paseo-relay-source-dir>\n' "$0" >&2
	exit 2
}
[[ -d "$source_dir/.git" ]] || {
	printf 'paseo-relay source is not a Git checkout: %s\n' "$source_dir" >&2
	exit 1
}
publisher_require_commands curl docker git jq

for variable_name in RELAICHOR_SOURCE_COMMIT RELAICHOR_SOURCE_VERSION RELAICHOR_BUILDER_IMAGE RELAICHOR_RUNTIME_IMAGE RELAICHOR_IMAGE_REPOSITORY RELAICHOR_IMAGE_TAG; do
	[[ -n "${!variable_name:-}" ]] || {
		printf '%s must be set in %s\n' "$variable_name" "$release_file" >&2
		exit 1
	}
done
[[ "$RELAICHOR_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
	printf 'invalid RELAICHOR_SOURCE_COMMIT\n' >&2
	exit 1
}
[[ "$RELAICHOR_SOURCE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	printf 'invalid RELAICHOR_SOURCE_VERSION\n' >&2
	exit 1
}
[[ "$RELAICHOR_BUILDER_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'RELAICHOR_BUILDER_IMAGE must be digest-pinned\n' >&2
	exit 1
}
[[ "$RELAICHOR_RUNTIME_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'RELAICHOR_RUNTIME_IMAGE must be digest-pinned\n' >&2
	exit 1
}
[[ "$RELAICHOR_IMAGE_REPOSITORY" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
	printf 'invalid RELAICHOR_IMAGE_REPOSITORY\n' >&2
	exit 1
}
[[ "$RELAICHOR_IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
	printf 'invalid RELAICHOR_IMAGE_TAG\n' >&2
	exit 1
}

source_commit="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$source_commit" == "$RELAICHOR_SOURCE_COMMIT" ]] || {
	printf 'source revision mismatch: expected %s, found %s\n' "$RELAICHOR_SOURCE_COMMIT" "$source_commit" >&2
	exit 1
}
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || {
	printf 'paseo-relay source checkout must be clean\n' >&2
	exit 1
}
remote="$(git -C "$source_dir" remote get-url origin)"
[[ "$remote" == *getpaseo/paseo-relay* ]] || {
	printf 'unexpected paseo-relay origin remote: %s\n' "$remote" >&2
	exit 1
}

image_ref="$RELAICHOR_IMAGE_REPOSITORY:$RELAICHOR_IMAGE_TAG"
publisher_assert_tag_unused "$image_ref" Relaichor "$release_file"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
build_context="$tmp/source"
mkdir -p "$build_context"
git -C "$source_dir" archive "$RELAICHOR_SOURCE_COMMIT" | tar -x -C "$build_context"
rm -f "$build_context/.dockerignore"

metadata="$tmp/build-metadata.json"
printf 'Building and publishing %s...\n' "$image_ref"
docker buildx build \
	--platform linux/amd64 \
	--file "$root/images/relaichor/Dockerfile" \
	--build-arg "RELAICHOR_BUILDER_IMAGE=$RELAICHOR_BUILDER_IMAGE" \
	--build-arg "RELAICHOR_RUNTIME_IMAGE=$RELAICHOR_RUNTIME_IMAGE" \
	--provenance=mode=max \
	--sbom=true \
	--tag "$image_ref" \
	--metadata-file "$metadata" \
	--push "$build_context"
digest="$(publisher_extract_digest "$metadata")"
publisher_verify_digest "$image_ref" "$digest"
publisher_verify_anonymous_ghcr "$RELAICHOR_IMAGE_REPOSITORY" "$RELAICHOR_IMAGE_TAG" "$digest" "$tmp" Relaichor

printf '\nPublished and anonymously verified:\nRELAICHOR_IMAGE=%s@%s\n' "$image_ref" "$digest"
