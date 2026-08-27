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

[[ -n "$source_dir" ]] || {
	printf 'usage: %s <cursor-api-proxy-source-dir>\n' "$0" >&2
	exit 2
}
[[ -d "$source_dir/.git" ]] || {
	printf 'cursor-api-proxy source is not a Git checkout: %s\n' "$source_dir" >&2
	exit 1
}
for command_name in curl docker git jq; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'required command is unavailable: %s\n' "$command_name" >&2
		exit 1
	}
done

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
if inspect_error="$(docker buildx imagetools inspect "$image_ref" 2>&1)"; then
	printf 'refusing to overwrite existing Cursorapi release tag: %s\n' "$image_ref" >&2
	printf 'choose a new CURSORAPI_IMAGE_TAG in %s\n' "$release_file" >&2
	exit 1
fi
if ! printf '%s\n' "$inspect_error" | grep -Eiq 'manifest unknown|not found|status[^0-9]*404'; then
	printf 'unable to prove that Cursorapi release tag is unused: %s\n' "$image_ref" >&2
	printf '%s\n' "$inspect_error" >&2
	exit 1
fi

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

digest="$(jq -r '."containerimage.digest" // empty' "$metadata")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
	printf 'build did not return a valid registry digest\n' >&2
	exit 1
}
docker buildx imagetools inspect "$image_ref@$digest" >/dev/null

if [[ "$CURSORAPI_IMAGE_REPOSITORY" == ghcr.io/uptonking/* ]]; then
	package_name="${CURSORAPI_IMAGE_REPOSITORY##*/}"
	settings_url="https://github.com/users/uptonking/packages/container/$package_name/settings"
	anonymous_token="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:uptonking/$package_name:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)"
	[[ -n "$anonymous_token" ]] || {
		printf 'GHCR package is not anonymously pullable. Make it public once at:\n%s\n' "$settings_url" >&2
		exit 1
	}
	manifest_headers="$tmp/manifest.headers"
	if ! curl -fsSI \
		-H "Authorization: Bearer $anonymous_token" \
		-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
		-o "$manifest_headers" \
		"https://ghcr.io/v2/uptonking/$package_name/manifests/$CURSORAPI_IMAGE_TAG"; then
		printf 'GHCR package manifest is not anonymously readable. Make it public once at:\n%s\n' "$settings_url" >&2
		exit 1
	fi
	registry_digest="$(awk 'BEGIN { IGNORECASE=1 } /^docker-content-digest:/ { gsub("\r", ""); print $2 }' "$manifest_headers" | tail -n1)"
	[[ "$registry_digest" == "$digest" ]] || {
		printf 'anonymous registry digest mismatch: expected %s, found %s\n' "$digest" "$registry_digest" >&2
		exit 1
	}
fi

printf '\nPublished and anonymously verified:\n'
printf 'CURSORAPI_IMAGE=%s@%s\n' "$image_ref" "$digest"
