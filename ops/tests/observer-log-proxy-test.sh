#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
image="$(sed -n 's/^OBSERVER_LOG_PROXY_IMAGE=//p' "$repo_root/ops/images.foundation.prod.env" | tail -n1)"
wrapper="$repo_root/compose/foundation/observer-log-proxy-entrypoint.sh"

[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'Observer socket-proxy image is not digest-pinned\n' >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'Docker is required to validate the pinned Observer socket-proxy configuration\n' >&2
	exit 1
}
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null

for timeout in 1h 24h 7d; do
	output="$(docker run --rm --pull never \
		-e OBSERVER_LOG_PROXY_STREAM_TIMEOUT="$timeout" \
		-e OBSERVER_LOG_PROXY_CONFIG_CHECK_ONLY=1 \
		-v "$wrapper:/observer-log-proxy-entrypoint.sh:ro" \
		--entrypoint /bin/sh "$image" /observer-log-proxy-entrypoint.sh 2>&1)"
	grep -Fq "observer-log-proxy: Docker stream idle timeout=$timeout" <<<"$output"
done

for timeout in 0h h1 12x 1.5h 1000000s; do
	if docker run --rm --pull never \
		-e OBSERVER_LOG_PROXY_STREAM_TIMEOUT="$timeout" \
		-e OBSERVER_LOG_PROXY_CONFIG_CHECK_ONLY=1 \
		-v "$wrapper:/observer-log-proxy-entrypoint.sh:ro" \
		--entrypoint /bin/sh "$image" /observer-log-proxy-entrypoint.sh >/dev/null 2>&1; then
		printf 'Observer socket-proxy accepted invalid stream timeout: %s\n' "$timeout" >&2
		exit 1
	fi
done

printf 'Observer socket-proxy configuration test passed\n'
