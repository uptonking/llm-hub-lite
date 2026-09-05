#!/usr/bin/env bash
# shellcheck disable=SC2154 # tmp and repo_root are initialized by platformctl-test.sh

cat >"$tmp/config/singleton-state/cpapi.transition.env" <<'EOF'
VERSION=1
APP_ID=cpapi
OLD_TARGET=worker-1
NEW_TARGET=worker-2
RELEASE_SHA=test
ARCHIVE_PATH=
PHASE=origin-healthy
EOF
: >"$tmp/curl.log"
CURL_FAIL_URL=https://worker2-cpapi-origin.aichorage.de/healthz SINGLETON_RELEASE_SHA=test bash "$repo_root/ops/platformctl.sh" singleton-switch cpapi >"$tmp/attested-switch.log" 2>&1 || {
	printf 'attested singleton publication unexpectedly failed\n' >&2
	exit 1
}
grep -Fq 'reusing follower origin health attestation' "$tmp/attested-switch.log"
if grep -Fq 'https://worker2-cpapi-origin.aichorage.de/healthz' "$tmp/curl.log"; then
	printf 'attested singleton publication repeated the origin probe\n' >&2
	exit 1
fi
