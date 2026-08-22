#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
PLATFORM_ENV_FILE="${PLATFORM_ENV_FILE:-/etc/llm-hub-lite/platform.env}"
CONTROL_ROOT="${CONTROL_ROOT:-/opt/platform/control}"
RUNNER_TAG="${RUNNER_TAG:-current}"
IMAGE="llm-hub-lite/deploy-runner:$RUNNER_TAG"

die() { printf 'upgrade-runner: %s\n' "$*" >&2; exit 1; }
[[ -r "$PLATFORM_ENV_FILE" ]] || die "missing platform env: $PLATFORM_ENV_FILE"
# shellcheck disable=SC1090
source "$PLATFORM_ENV_FILE"
release="${RUNNER_SOURCE_ROOT:-${CONTROL_ROOT}/current}"
dockerfile="$release/ops/deploy-runner/Dockerfile"
[[ -f "$dockerfile" ]] || die "runner Dockerfile is missing from $release"

case "$(uname -m)" in
  x86_64|amd64) compose_arch=x86_64 ;;
  aarch64|arm64) compose_arch=aarch64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
compose_version="${COMPOSE_VERSION:-v2.33.0}"
if [[ -n "${COMPOSE_SHA256:-}" ]]; then
  compose_sha="$COMPOSE_SHA256"
elif [[ "$compose_arch" == x86_64 ]]; then
  compose_sha="${COMPOSE_SHA256_AMD64:-6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee}"
else
  compose_sha="${COMPOSE_SHA256_ARM64:-03a42a0fc0614ffc3c9ebca521cab75e02c427b68e45e3f6867d9510b9a28818}"
fi
lock_sha_amd64="$(sha256sum "$release/ops/deploy-runner/apk-packages.lock.amd64" | awk '{print $1}')"
lock_sha_arm64="$(sha256sum "$release/ops/deploy-runner/apk-packages.lock.arm64" | awk '{print $1}')"
runner_base_image="$(sed -n 's/^FROM \([^ ]*\).*$/\1/p' "$dockerfile" | head -n1)"
[[ -n "$runner_base_image" ]] || die 'unable to determine runner base image'
docker pull "$runner_base_image"
docker build --pull=false --build-arg COMPOSE_VERSION="$compose_version" --build-arg COMPOSE_ARCH="$compose_arch" \
  --build-arg COMPOSE_SHA256="$compose_sha" --build-arg APK_LOCK_SHA256_AMD64="$lock_sha_amd64" \
  --build-arg APK_LOCK_SHA256_ARM64="$lock_sha_arm64" -t "$IMAGE" "$release/ops/deploy-runner"
image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
[[ -n "$image_id" ]] || die 'runner image was not created'
tmp="$(mktemp "${PLATFORM_ENV_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
sed '/^PLATFORM_RUNNER_IMAGE=/d;/^PLATFORM_RUNNER_IMAGE_ID=/d' "$PLATFORM_ENV_FILE" >"$tmp"
printf 'PLATFORM_RUNNER_IMAGE=%s\nPLATFORM_RUNNER_IMAGE_ID=%s\n' "$IMAGE" "$image_id" >>"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$PLATFORM_ENV_FILE"
printf 'runner upgraded: %s (%s)\n' "$IMAGE" "$image_id"
