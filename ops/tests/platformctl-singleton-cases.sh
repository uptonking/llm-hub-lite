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
CURL_FAIL_URL=https://worker2-cpapi-origin.aichorage.de/healthz SINGLETON_ORIGIN_PRECHECKED=1 SINGLETON_RELEASE_SHA=test bash "$repo_root/ops/platformctl.sh" singleton-switch cpapi >"$tmp/attested-switch.log" 2>&1 || {
	printf 'attested singleton publication unexpectedly failed\n' >&2
	exit 1
}
grep -Fq 'reusing follower origin health attestation' "$tmp/attested-switch.log"
if grep -Fq 'https://worker2-cpapi-origin.aichorage.de/healthz' "$tmp/curl.log"; then
	printf 'attested singleton publication repeated the origin probe\n' >&2
	exit 1
fi

# Recovery must refuse a stateful singleton whose durable Paseo identity was
# lost, rather than starting an empty home and later overwriting the public
# route. This fixture exercises the manifest contract without Docker I/O.
recovery_root="$tmp/app/shared/data/prod/aichor/.paseo"
mkdir -p "$recovery_root"
: >"$recovery_root/daemon-keypair.json"
: >"$recovery_root/config.json"
printf 'server-id\n' >"$recovery_root/server-id"
rm -f "$recovery_root/server-id"
recovery_env="$tmp/recovery.env"
printf 'DATA_ROOT=%s\n' "$tmp/app/shared/data/prod" >"$recovery_env"
if (PLATFORM_RECOVERY_MODE=1 APP_ENV="$recovery_env" recovery_state_check_descriptor "$tmp/control/current/apps/aichor") 2>"$tmp/recovery-state.err"; then
	printf 'recovery accepted missing Aichor durable state\n' >&2
	exit 1
fi
grep -Fq 'required recovery state is missing for aichor' "$tmp/recovery-state.err"
