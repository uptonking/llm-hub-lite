# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --ignore-scripts
COPY src ./src
COPY public ./public
COPY docs ./docs
RUN npm run typecheck \
    && npm test -- --maxWorkers=2 \
    && npm run build \
    && find dist -type f \( -name '*.test.*' -o -name '*.spec.*' \) -delete \
    && npm prune --omit=dev --ignore-scripts \
    && npm cache clean --force

FROM ${NODE_IMAGE} AS runtime
ARG CURSORAPI_SOURCE_COMMIT
ARG CURSORAPI_SOURCE_VERSION
ARG CURSOR_AGENT_VERSION
LABEL org.opencontainers.image.title="cursor-api-proxy" \
      org.opencontainers.image.description="Cursor API proxy with a checksum-pinned Cursor Agent" \
      org.opencontainers.image.source="https://github.com/anyrobert/cursor-api-proxy" \
      org.opencontainers.image.revision="${CURSORAPI_SOURCE_COMMIT}" \
      org.opencontainers.image.version="${CURSORAPI_SOURCE_VERSION}-agent-${CURSOR_AGENT_VERSION}"

WORKDIR /app
COPY --from=build --chown=node:node /src/package.json /src/package-lock.json ./
COPY --from=build --chown=node:node /src/node_modules ./node_modules
COPY --from=build --chown=node:node /src/dist ./dist
COPY --from=build --chown=node:node /src/public ./public
COPY --from=build --chown=node:node /src/docs ./docs
COPY --from=cursor_agent /cursor-agent.tar.gz /tmp/cursor-agent.tar.gz
RUN install -d -m 755 /opt/cursor-agent \
    && tar --strip-components=1 -xzf /tmp/cursor-agent.tar.gz -C /opt/cursor-agent \
    && test -x /opt/cursor-agent/cursor-agent \
    && ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/agent \
    && ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/cursor-agent \
    && rm -f /tmp/cursor-agent.tar.gz

# The Cursor Agent is a self-contained binary that links its own OpenSSL and
# reads CA certs from the system store. The slim base image ships no
# ca-certificates, so outbound TLS to agent*.cursor.sh consistently fails with
# "Cannot open directory /etc/ssl/certs" plus exit code 1. Install the CA store
# here (as root, before dropping to USER node). Also export the store so any
# OpenSSL-based helper resolves it deterministically.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    HOME=/home/node \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CURSOR_AGENT_BIN=/usr/local/bin/cursor-agent \
    CURSOR_BRIDGE_HOST=0.0.0.0 \
    CURSOR_BRIDGE_PORT=8765 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs
USER node
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=5 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8765/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]
ENTRYPOINT ["node", "/app/dist/cli.js"]
