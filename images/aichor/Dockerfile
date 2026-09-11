# syntax=docker/dockerfile:1.7

ARG AICHOR_BASE_IMAGE
FROM ${AICHOR_BASE_IMAGE} AS runtime

ARG AICHOR_CODEX_VERSION
ARG AICHOR_CLAUDE_CODE_VERSION
ARG AICHOR_OPENCODE_VERSION
ARG AICHOR_PI_CODING_AGENT_VERSION
ARG AICHOR_GH_VERSION
ARG AICHOR_GH_SHA256

LABEL org.opencontainers.image.title="aichor" \
      org.opencontainers.image.description="Paseo with bundled remote coding agents" \
      org.opencontainers.image.source="https://github.com/getpaseo/paseo" \
      org.opencontainers.image.version="${AICHOR_CODEX_VERSION}-${AICHOR_CLAUDE_CODE_VERSION}-${AICHOR_OPENCODE_VERSION}-${AICHOR_PI_CODING_AGENT_VERSION}" \
      org.opencontainers.image.gh.version="${AICHOR_GH_VERSION}"

USER root
RUN set -eux; \
    test -n "$AICHOR_GH_VERSION"; \
    test -n "$AICHOR_GH_SHA256"; \
    gh_archive="gh_${AICHOR_GH_VERSION}_linux_amd64.tar.gz"; \
    gh_url="https://github.com/cli/cli/releases/download/v${AICHOR_GH_VERSION}/${gh_archive}"; \
    curl --fail --silent --show-error --location --retry 3 "$gh_url" --output "/tmp/$gh_archive"; \
    printf '%s  %s\n' "$AICHOR_GH_SHA256" "/tmp/$gh_archive" | sha256sum --check --status; \
    tar --extract --gzip --file "/tmp/$gh_archive" --strip-components=2 --directory /usr/local/bin "gh_${AICHOR_GH_VERSION}_linux_amd64/bin/gh"; \
    command -v gh; \
    gh --version | head -n 1; \
    rm -f "/tmp/$gh_archive"

RUN npm install --global \
      "@openai/codex@${AICHOR_CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${AICHOR_CLAUDE_CODE_VERSION}" \
      "opencode-ai@${AICHOR_OPENCODE_VERSION}" \
      "@earendil-works/pi-coding-agent@${AICHOR_PI_CODING_AGENT_VERSION}" \
    && command -v codex \
    && command -v claude \
    && command -v opencode \
    && command -v pi \
    && npm cache clean --force

# Keep provider command names stable if a package exposes a Windows-suffixed
# bin entry in its npm metadata.
RUN for command_path in /usr/local/bin/codex.exe /usr/local/bin/claude.exe /usr/local/bin/opencode.exe; do \
      if [ -e "$command_path" ]; then ln -sf "$(basename "$command_path")" "${command_path%.exe}"; fi; \
    done

# Paseo's base entrypoint prepares mounted volumes and drops runtime processes
# to the non-root paseo user.
