#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
image="$(sed -n 's/^OBSERVER_LOG_SHIPPER_IMAGE=//p' "$repo_root/ops/images.foundation.prod.env" | tail -n1)"
tmp="$(mktemp -d)"
network="observer-vector-test-$$"
receiver="observer-vector-receiver-$$"
cleanup() {
	docker rm -f "$receiver" >/dev/null 2>&1 || true
	docker network rm "$network" >/dev/null 2>&1 || true
	rm -rf -- "$tmp"
}
trap cleanup EXIT
[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || {
	printf 'Observer Vector image is not digest-pinned\n' >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'Docker is required to validate the pinned Observer Vector configuration\n' >&2
	exit 1
}
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
docker run --rm --pull never \
	-e NODE_ID=test \
	-e OBSERVER_INGEST_URL=https://observer-ingest.example.invalid \
	-e OBSERVER_INGEST_USER=collector \
	-e OBSERVER_INGEST_TOKEN=o2oi_00000000000000000000000000000000 \
	-e OBSERVER_LOG_ORGANIZATION=default \
	-e OBSERVER_LOG_STREAM=docker \
	-e OBSERVER_LOG_BUFFER_MAX_BYTES=536870912 \
	-e OBSERVER_LOG_BUFFER_WHEN_FULL=block \
	-v "$repo_root/compose/foundation/observer-vector.toml:/etc/vector/vector.toml:ro" \
	"$image" validate --skip-healthchecks /etc/vector/vector.toml

# Exercise the pinned encoder on the wire. Vector's JSON encoder already emits
# a batch as an array. Adding another payload wrapper produces [[{...}]], which
# OpenObserve accepts at the HTTP layer but rejects record by record.
awk '
  BEGIN { skip_source=0; skip_buffer=0 }
  /^\[sources\.docker_logs\]$/ {
    print "[sources.docker_logs]"
    print "type = \"stdin\""
    print "decoding.codec = \"json\""
    skip_source=1
    next
  }
  skip_source && /^\[transforms\.exclude_observer_sidecars\]$/ { skip_source=0 }
  skip_source { next }
  /^\[sinks\.openobserve\.buffer\]$/ { skip_buffer=1; next }
  skip_buffer && /^\[api\]$/ { skip_buffer=0 }
  !skip_buffer { print }
' "$repo_root/compose/foundation/observer-vector.toml" >"$tmp/vector.toml"
cat >"$tmp/receiver.sh" <<'EOF'
#!/bin/sh
set -eu
headers=/capture/headers
body=/capture/body.gz
: >"$headers"
length=
while IFS= read -r line; do
	clean="$(printf '%s' "$line" | tr -d '\r')"
	printf '%s\n' "$clean" >>"$headers"
	[ -n "$clean" ] || break
	case "$clean" in
	[Cc]ontent-[Ll]ength:*) length="${clean#*:}"; length="${length# }" ;;
	esac
done
case "$length" in '' | *[!0-9]*) exit 1 ;; esac
dd bs=1 count="$length" of="$body" 2>/dev/null
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}'
EOF
chmod 700 "$tmp/receiver.sh"
docker network create "$network" >/dev/null
docker run -d --name "$receiver" --network "$network" --network-alias observer-vector-receiver \
	--entrypoint nc -v "$tmp:/capture" "$image" -l -p 8080 -e /capture/receiver.sh >/dev/null
printf '%s\n' \
	'{"message":"observer-wire-one","container_id":"one","container_name":"one","image":"test","stream":"stdout","label":{"com.aichorage.platform":"llm-hub-lite","com.aichorage.application":"wire-test","com.aichorage.component":"emitter","com.docker.compose.project":"wire-project","com.docker.compose.service":"wire-service"}}' \
	'{"message":"observer-wire-two","container_id":"two","container_name":"two","image":"test","stream":"stdout","label":{"com.aichorage.platform":"llm-hub-lite","com.aichorage.application":"wire-test","com.aichorage.component":"emitter","com.docker.compose.project":"wire-project","com.docker.compose.service":"wire-service"}}' |
	docker run --rm -i --network "$network" \
		-e NODE_ID=test-node \
		-e OBSERVER_INGEST_URL=http://observer-vector-receiver:8080 \
		-e OBSERVER_INGEST_USER=collector \
		-e OBSERVER_INGEST_TOKEN=o2oi_00000000000000000000000000000000 \
		-e OBSERVER_LOG_ORGANIZATION=default \
		-e OBSERVER_LOG_STREAM=docker \
		-v "$tmp/vector.toml:/etc/vector/vector.toml:ro" \
		"$image" --config /etc/vector/vector.toml >/dev/null
docker wait "$receiver" >/dev/null
grep -Fqi 'content-encoding: gzip' "$tmp/headers"
docker run --rm --entrypoint gzip -v "$tmp:/capture:ro" "$image" -dc /capture/body.gz >"$tmp/body.json"
jq -e 'type == "array" and length == 2 and all(.[]; type == "object")' "$tmp/body.json" >/dev/null
grep -Fq '"message":"observer-wire-one"' "$tmp/body.json"
grep -Fq '"message":"observer-wire-two"' "$tmp/body.json"
grep -Fq '"node_id":"test-node"' "$tmp/body.json"
grep -Fq '"application":"wire-test"' "$tmp/body.json"
grep -Fq '"component":"emitter"' "$tmp/body.json"
grep -Fq '"compose_project":"wire-project"' "$tmp/body.json"
grep -Fq '"compose_service":"wire-service"' "$tmp/body.json"

printf 'Observer Vector configuration test passed\n'
