#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/ops/deploy-runner/release.env"
# shellcheck disable=SC1091
source "$root/ops/lib/publish-image-common.sh"

publisher_require_commands docker jq curl gh sha256sum
[[ "$DEPLOY_RUNNER_BASE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'runner base image must be digest-pinned\n' >&2
	exit 1
}
[[ "$DEPLOY_RUNNER_IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
	printf 'invalid runner image tag\n' >&2
	exit 1
}
image_ref="$DEPLOY_RUNNER_IMAGE_REPOSITORY:$DEPLOY_RUNNER_IMAGE_TAG"
publisher_assert_tag_unused "$image_ref" 'deploy-runner' "$root/ops/deploy-runner/release.env"
lock_amd64="$(sha256sum "$root/ops/deploy-runner/apk-packages.lock.amd64" | awk '{print $1}')"
lock_arm64="$(sha256sum "$root/ops/deploy-runner/apk-packages.lock.arm64" | awk '{print $1}')"
docker buildx build --platform linux/amd64,linux/arm64 \
	--file "$root/ops/deploy-runner/Dockerfile" \
	--build-arg "COMPOSE_SHA256_AMD64=6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee" \
	--build-arg "COMPOSE_SHA256_ARM64=03a42a0fc0614ffc3c9ebca521cab75e02c427b68e45e3f6867d9510b9a28818" \
	--build-arg "APK_LOCK_SHA256_AMD64=$lock_amd64" --build-arg "APK_LOCK_SHA256_ARM64=$lock_arm64" \
	--tag "$image_ref" --provenance=mode=max --sbom=true --push "$root/ops/deploy-runner"
digest="$(docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest.Digest}}' | tr -d '"')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
	printf 'runner publication did not return a digest\n' >&2
	exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
publisher_verify_anonymous_ghcr "$DEPLOY_RUNNER_IMAGE_REPOSITORY" "$DEPLOY_RUNNER_IMAGE_TAG" "$digest" "$tmp" 'deploy-runner'
printf 'DEPLOY_RUNNER_IMAGE=%s@%s\n' "$image_ref" "$digest"
