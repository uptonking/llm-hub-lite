FROM docker:27.5.1-cli@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c

ARG COMPOSE_VERSION=v2.33.0
ARG COMPOSE_ARCH=x86_64
ARG COMPOSE_SHA256=6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee
ARG APK_LOCK_SHA256_AMD64
ARG APK_LOCK_SHA256_ARM64

COPY apk-packages.lock.amd64 apk-packages.lock.arm64 /tmp/
RUN set -eu; \
    case "$(apk --print-arch)" in \
      x86_64) lock=/tmp/apk-packages.lock.amd64; expected="${APK_LOCK_SHA256_AMD64}" ;; \
      aarch64) lock=/tmp/apk-packages.lock.arm64; expected="${APK_LOCK_SHA256_ARM64}" ;; \
      *) echo "unsupported runner architecture: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    test -n "$expected"; echo "$expected  $lock" | sha256sum -c -; \
    apk add --no-cache $(awk -F= '/^[A-Za-z0-9][A-Za-z0-9+.-]*=[0-9]/{print $0}' "$lock") \
 && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" -o /usr/local/bin/platform-compose \
 && echo "${COMPOSE_SHA256}  /usr/local/bin/platform-compose" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/platform-compose

WORKDIR /workspace
