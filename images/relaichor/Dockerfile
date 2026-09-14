# syntax=docker/dockerfile:1.7

ARG RELAICHOR_BUILDER_IMAGE
ARG RELAICHOR_RUNTIME_IMAGE
# The release embeds the BEAM/ERTS runtime, so the builder must match the
# target architecture (using BUILDPLATFORM would copy host-architecture ERTS
# into a cross-built image).
FROM --platform=$TARGETPLATFORM ${RELAICHOR_BUILDER_IMAGE} AS build
WORKDIR /app
ENV MIX_ENV=prod
RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs jq \
    && rm -rf /var/lib/apt/lists/*
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && MIX_ENV=test mix deps.get
COPY config config
COPY lib lib
COPY test test
COPY deployment deployment
# Keep the image build self-contained and deterministic.  The upstream suite
# also contains Fly.io/load-generator tests that require external tooling and
# long-running stress conditions; those run in repository CI.  These focused
# tests cover release configuration and the handshake contract used by every
# deployment mode before producing the production release.
RUN MIX_ENV=test mix test test/paseo_relay/config_test.exs test/paseo_relay/handshake_validation_test.exs \
    && MIX_ENV=prod mix compile \
    && MIX_ENV=prod mix release

ARG RELAICHOR_RUNTIME_IMAGE
FROM ${RELAICHOR_RUNTIME_IMAGE} AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 libsctp1 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 65532 relay \
    && useradd --system --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin relay
WORKDIR /app
COPY --from=build --chown=65532:65532 /app/_build/prod/rel/paseo_relay ./
ENV HOME=/tmp \
    PASEO_RELAY_HOST=0.0.0.0 \
    PASEO_RELAY_PORT=4000 \
    PASEO_RELAY_DRAIN=false
USER 65532:65532
EXPOSE 4000
ENTRYPOINT ["/app/bin/paseo_relay"]
CMD ["start"]
