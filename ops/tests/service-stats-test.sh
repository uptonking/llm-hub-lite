#!/usr/bin/env bash
# Verifies ops/report-service-stats.sh classifies scanner traffic and protects
# internal-dependency hosts from being mistaken for unused ones.
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/report-service-stats.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -x "$script" ]] || {
	printf 'report-service-stats.sh must be executable\n' >&2
	exit 1
}

fixture="$tmp/access.log"
cat >"$fixture" <<'EOF'
{"duration":0.01,"status":400,"request":{"host":"collabora.aichorage.de","uri":"/.git/config","headers":{"User-Agent":["TLM-Audit-Scanner/2.0"],"CF-Connecting-IP":["203.0.113.10"]}}}
{"duration":0.01,"status":400,"request":{"host":"collabora.aichorage.de","uri":"/%2eenv","headers":{"User-Agent":["TLM-Audit-Scanner/2.0"],"CF-Connecting-IP":["203.0.113.10"]}}}
{"duration":0.02,"status":200,"request":{"host":"collabora.aichorage.de","uri":"/hosting/discovery","headers":{"User-Agent":["Go-http-client/1.1"],"CF-Connecting-IP":["198.51.100.20"]}}}
{"duration":0.03,"status":404,"request":{"host":"onoffice.aichorage.de","uri":"/api/session/properties","headers":{"User-Agent":["metabase-cve-2026-72898-detect/1.0"],"CF-Connecting-IP":["192.0.2.30"]}}}
{"duration":0.04,"request":{"host":"auther.aichorage.de","uri":"/.well-known/openid-configuration","headers":{"User-Agent":["Mozilla/5.0"],"CF-Connecting-IP":["198.51.100.7"]}}}
this is not json and must be skipped
{"duration":0.05,"status":200,"request":{"host":"status.aichorage.de","uri":"/api/beszel","headers":{"User-Agent":["Mozilla/5.0"],"CF-Connecting-IP":["198.51.100.7"]}}}
{"duration":0.01,"status":404,"request":{"host":"outline.aichorage.de","uri":"/serviceAccountCredentials.json","headers":{"User-Agent":["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"],"CF-Connecting-IP":["198.51.100.99"]}}}
{"duration":0.01,"status":404,"request":{"host":"ladocs.aichorage.de","uri":"/api/user/ismustmobile","headers":{"User-Agent":["okhttp/3.14.9"],"CF-Connecting-IP":["198.51.100.88"]}}}
EOF

text="$(CADDY_LOG_FILE="$fixture" "$script" --since 24h)"
json="$(CADDY_LOG_FILE="$fixture" "$script" --json)"

fail=0
check() {
	local label="$1" haystack="$2" needle="$3"
	if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
		printf 'ok   %s\n' "$label"
	else
		printf 'FAIL %s (missing: %s)\n' "$label" "$needle" >&2
		fail=1
	fi
}

check_re() {
	local label="$1" haystack="$2" pattern="$3"
	if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
		printf 'ok   %s\n' "$label"
	else
		printf 'FAIL %s (no match: %s)\n' "$label" "$pattern" >&2
		fail=1
	fi
}

# Scanner traffic dominates collabora, and the probe paths are attributed to it.
check_re "collabora flagged high risk" "$text" "collabora\.aichorage\.de[[:space:]]+high"
check "scanner UA recognised" "$text" "tlm-audit"
check "path probe recognized for spoofed UA" "$text" "probe:serviceaccountcredentials"
check "legacy okhttp scanner recognized" "$text" "okhttp/3."
check "malformed line skipped" "$text" "records=8"

# The internal dependency must be surfaced so a quiet public host is not retired.
check "onoffice dependency warning" "$text" "internal dependents: filer"
check "dependency warning text" "$text" "do not treat it as unused"

# A host with only legitimate traffic stays low risk.
check_re "status host low risk" "$text" "status\.aichorage\.de[[:space:]]+low"

# Aborted requests (no Caddy status) are reported separately, not as 5xx.
check "aborted request tracked" "$text" "aborted=100%"

# JSON mode exposes the same verdict for automation.
check "json risk verdict" "$json" '"risk": "high"'
check "json scanner share" "$json" '"scanner_share": 1.0'

# Host filtering narrows the report.
filtered="$(CADDY_LOG_FILE="$fixture" "$script" --host onoffice.aichorage.de)"
check "host filter" "$filtered" "onoffice.aichorage.de"
if printf '%s' "$filtered" | grep -Fq -- "status.aichorage.de"; then
	printf 'FAIL host filter leaked other hosts\n' >&2
	fail=1
else
	printf 'ok   host filter excludes other hosts\n'
fi

# Missing input degrades with a message rather than a stack trace.
if CADDY_LOG_FILE="$tmp/does-not-exist" "$script" >/dev/null 2>&1; then
	printf 'FAIL missing log file must exit non-zero\n' >&2
	fail=1
else
	printf 'ok   missing log file rejected\n'
fi

if ((fail)); then
	printf '\nservice statistics tests FAILED\n' >&2
	exit 1
fi
printf '\nservice statistics tests passed\n'
