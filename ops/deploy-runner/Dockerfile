FROM docker:27.5.1-cli@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c

ARG COMPOSE_VERSION=v2.33.0
ARG COMPOSE_SHA256=6395dbb256db6ea28d5c6695bc9bc33866c07ad1c93792f8d85857f1c21c34ee

RUN apk add --no-cache \
    bash \
    curl \
    git \
    openssh-client \
    restic \
    sqlite \
    tar \
    util-linux \
 && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/platform-compose \
 && echo "${COMPOSE_SHA256}  /usr/local/bin/platform-compose" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/platform-compose

WORKDIR /workspace
