#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
release_file="${AICHOR_RELEASE_FILE:-$root/images/aichor/release.env}"
# shellcheck disable=SC1090,SC1091
source "$release_file"
# shellcheck disable=SC1091
source "$root/ops/lib/publish-image-common.sh"

publisher_require_commands curl docker jq npm
for variable_name in AICHOR_BASE_IMAGE AICHOR_IMAGE_REPOSITORY AICHOR_IMAGE_TAG; do
	[[ -n "${!variable_name:-}" ]] || {
		printf '%s must be set in %s\n' "$variable_name" "$release_file" >&2
		exit 1
	}
done
[[ "$AICHOR_BASE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'AICHOR_BASE_IMAGE must be digest-pinned\n' >&2
	exit 1
}
[[ "$AICHOR_IMAGE_REPOSITORY" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
	printf 'AICHOR_IMAGE_REPOSITORY must be a GHCR owner/repository\n' >&2
	exit 1
}
[[ "$AICHOR_IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
	printf 'AICHOR_IMAGE_TAG is invalid\n' >&2
	exit 1
}

packages=(
	AICHOR_CODEX_VERSION:@openai/codex
	AICHOR_CLAUDE_CODE_VERSION:@anthropic-ai/claude-code
	AICHOR_OPENCODE_VERSION:opencode-ai
	AICHOR_PI_CODING_AGENT_VERSION:@earendil-works/pi-coding-agent
)
metadata_tmp="$(mktemp "${release_file}.tmp.XXXXXX")"
trap 'rm -f -- "$metadata_tmp"' EXIT
cp "$release_file" "$metadata_tmp"
for package_rule in "${packages[@]}"; do
	variable_name="${package_rule%%:*}"
	package_name="${package_rule#*:}"
	version="${!variable_name:-}"
	if [[ -z "$version" ]]; then
		version="$(npm view "$package_name" version --json | tr -d '\r\n\"')"
		publisher_validate_version "$version" "$package_name"
		publisher_set_release_var "$metadata_tmp" "$variable_name" "$version"
	fi
	publisher_validate_version "$version" "$package_name"
	eval "$variable_name=\$version"
done
mv "$metadata_tmp" "$release_file"
trap - EXIT

image_ref="$AICHOR_IMAGE_REPOSITORY:$AICHOR_IMAGE_TAG"
publisher_assert_tag_unused "$image_ref" Aichor "$release_file"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
metadata="$tmp/build-metadata.json"
printf 'Building and publishing %s...\n' "$image_ref"
docker buildx build --platform linux/amd64 --file "$root/images/aichor/Dockerfile" \
	--build-arg "AICHOR_BASE_IMAGE=$AICHOR_BASE_IMAGE" \
	--build-arg "AICHOR_CODEX_VERSION=$AICHOR_CODEX_VERSION" \
	--build-arg "AICHOR_CLAUDE_CODE_VERSION=$AICHOR_CLAUDE_CODE_VERSION" \
	--build-arg "AICHOR_OPENCODE_VERSION=$AICHOR_OPENCODE_VERSION" \
	--build-arg "AICHOR_PI_CODING_AGENT_VERSION=$AICHOR_PI_CODING_AGENT_VERSION" \
	--provenance=mode=max --sbom=true --tag "$image_ref" --metadata-file "$metadata" --push "$root/images/aichor"
digest="$(publisher_extract_digest "$metadata")"
publisher_verify_digest "$image_ref" "$digest"
publisher_verify_anonymous_ghcr "$AICHOR_IMAGE_REPOSITORY" "$AICHOR_IMAGE_TAG" "$digest" "$tmp" Aichor
printf '\nPublished and anonymously verified:\nAICHOR_IMAGE=%s@%s\n' "$image_ref" "$digest"
