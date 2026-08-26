#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$EUID" -ne 0 ]]; then
	printf 'observer ingestion integration test skipped because root is required\n'
	exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/foundation/env"

valid_token='o2oi_12345678901234567890123456789012'
listed_token='o2oi_abcdefghijklmnopqrstuvwxyz123456'
printf '%s\n' \
	'OBSERVER_SITE=https://observer.example.invalid' \
	'OBSERVER_INGEST_URL=https://observer-ingest.example.invalid' \
	'OBSERVER_INGEST_SITE=https://observer-ingest.example.invalid' \
	'OBSERVER_LOG_ORGANIZATION=default' \
	'OBSERVER_LOG_STREAM=docker' \
	'OBSERVER_ROOT_USER_EMAIL=admin@example.invalid' \
	'OBSERVER_ROOT_USER_PASSWORD=test-password' \
	'OBSERVER_INGEST_USER=llm-hub-lite-collector' \
	"OBSERVER_INGEST_TOKEN=$valid_token" >"$tmp/foundation/env/observer.env"

cat >"$tmp/bin/curl" <<EOF
#!/bin/sh
case " \$* " in
  *' -d '*) printf '%s\\n' '{"data":{"token":"$listed_token"}}' ;;
  *) printf '%s\\n' '{"data":[{"name":"llm-hub-lite-collector","token":"$listed_token","enabled":true}]}' ;;
esac
EOF
chmod +x "$tmp/bin/curl"

PATH="$tmp/bin:$PATH" CONFIG_ROOT="$tmp/config" FOUNDATION_ROOT="$tmp/foundation" \
	OBSERVER_INGEST_LOCK_FILE="$tmp/observer.lock" \
	bash "$repo_root/ops/configure-observer-ingest.sh"
grep -qx "OBSERVER_INGEST_TOKEN=$listed_token" "$tmp/foundation/env/observer.env"
grep -qx "OBSERVER_INGEST_TOKEN=$listed_token" "$tmp/config/shared-secrets.env"

printf '%s\n' \
	'OBSERVER_SITE=https://observer.example.invalid' \
	'OBSERVER_INGEST_URL=https://observer-ingest.example.invalid' \
	'OBSERVER_INGEST_SITE=https://observer-ingest.example.invalid' \
	'OBSERVER_LOG_ORGANIZATION=default' \
	'OBSERVER_LOG_STREAM=docker' \
	'OBSERVER_ROOT_USER_EMAIL=admin@example.invalid' \
	'OBSERVER_ROOT_USER_PASSWORD=test-password' \
	'OBSERVER_INGEST_USER=llm-hub-lite-collector' \
	"OBSERVER_INGEST_TOKEN=$valid_token" >"$tmp/foundation/env/observer.env"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' '{"data":[{"name":"llm-hub-lite-collector","token":"o2oi_disabled0000000000000000000000","enabled":false}]}'
EOF
chmod +x "$tmp/bin/curl"
if PATH="$tmp/bin:$PATH" CONFIG_ROOT="$tmp/config" FOUNDATION_ROOT="$tmp/foundation" \
	OBSERVER_INGEST_LOCK_FILE="$tmp/observer.lock" \
	bash "$repo_root/ops/configure-observer-ingest.sh" >/dev/null 2>&1; then
	printf 'disabled Observer token was accepted\n' >&2
	exit 1
fi

# A future OpenObserve API may mask token values in list responses. A valid
# local token remains usable only when the named token is confirmed enabled.
printf '%s\n' \
	'OBSERVER_SITE=https://observer.example.invalid' \
	'OBSERVER_INGEST_URL=https://observer-ingest.example.invalid' \
	'OBSERVER_INGEST_SITE=https://observer-ingest.example.invalid' \
	'OBSERVER_LOG_ORGANIZATION=default' \
	'OBSERVER_LOG_STREAM=docker' \
	'OBSERVER_ROOT_USER_EMAIL=admin@example.invalid' \
	'OBSERVER_ROOT_USER_PASSWORD=test-password' \
	'OBSERVER_INGEST_USER=llm-hub-lite-collector' \
	"OBSERVER_INGEST_TOKEN=$valid_token" >"$tmp/foundation/env/observer.env"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' '{"data":[{"name":"llm-hub-lite-collector","token":"***","enabled":true}]}'
EOF
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" CONFIG_ROOT="$tmp/config" FOUNDATION_ROOT="$tmp/foundation" \
	OBSERVER_INGEST_LOCK_FILE="$tmp/observer.lock" \
	bash "$repo_root/ops/configure-observer-ingest.sh" >/dev/null
grep -qx "OBSERVER_INGEST_TOKEN=$valid_token" "$tmp/foundation/env/observer.env"

printf '%s\n' \
	'OBSERVER_SITE=https://observer.example.invalid' \
	'OBSERVER_INGEST_URL=https://observer-ingest.example.invalid' \
	'OBSERVER_INGEST_SITE=https://observer-ingest.example.invalid' \
	'OBSERVER_LOG_ORGANIZATION=bad/path' \
	'OBSERVER_LOG_STREAM=docker' \
	'OBSERVER_ROOT_USER_EMAIL=admin@example.invalid' \
	'OBSERVER_ROOT_USER_PASSWORD=test-password' \
	'OBSERVER_INGEST_USER=llm-hub-lite-collector' \
	"OBSERVER_INGEST_TOKEN=$valid_token" >"$tmp/foundation/env/observer.env"
if PATH="$tmp/bin:$PATH" CONFIG_ROOT="$tmp/config" FOUNDATION_ROOT="$tmp/foundation" \
	OBSERVER_INGEST_LOCK_FILE="$tmp/observer.lock" \
	bash "$repo_root/ops/configure-observer-ingest.sh" >/dev/null 2>&1; then
	printf 'invalid Observer organization was accepted\n' >&2
	exit 1
fi

printf 'observer ingestion tests passed\n'
