#!/usr/bin/env bash
# Summarise service traffic and risk from the Caddy JSON access log.
#
# Answers the recurring "why is this host busy" and "is this host being probed"
# questions from the same records the platform already ships to OpenObserve, so
# nobody has to reconstruct an investigation by hand. Read-only: it only reads
# the container log or a file.
set -Eeuo pipefail

usage() {
	cat <<'EOF'
usage: report-service-stats.sh [--since DURATION] [--host HOST] [--json]

  --since DURATION  log window handed to docker logs (default: 24h)
  --host HOST       limit the report to one request host
  --json            emit machine-readable JSON instead of text

Environment:
  CADDY_CONTAINER   container to read logs from (default: foundation-caddy-caddy-1)
  CADDY_LOG_FILE    read this file instead of the container log (fixtures, offline review)
EOF
}

since="24h"
host_filter=""
json_out=0
while (($#)); do
	case "$1" in
	--since)
		[[ $# -ge 2 ]] || {
			printf 'missing value for --since\n' >&2
			exit 2
		}
		since="$2"
		shift 2
		;;
	--host)
		[[ $# -ge 2 ]] || {
			printf 'missing value for --host\n' >&2
			exit 2
		}
		host_filter="$2"
		shift 2
		;;
	--json)
		json_out=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

command -v python3 >/dev/null 2>&1 || {
	printf 'python3 is required to parse the Caddy JSON access log\n' >&2
	exit 1
}

container="${CADDY_CONTAINER:-foundation-caddy-caddy-1}"
log_file="${CADDY_LOG_FILE:-}"
work="$(mktemp)"
trap 'rm -f "$work"' EXIT

if [[ -n "$log_file" ]]; then
	[[ -r "$log_file" ]] || {
		printf 'cannot read log file: %s\n' "$log_file" >&2
		exit 1
	}
	cat "$log_file" >"$work"
elif command -v docker >/dev/null 2>&1; then
	docker logs --since "$since" "$container" >"$work" 2>&1 || {
		printf 'cannot read logs from container: %s\n' "$container" >&2
		exit 1
	}
else
	printf 'neither CADDY_LOG_FILE nor docker is available\n' >&2
	exit 1
fi

exec python3 - "$work" "$host_filter" "$json_out" "$since" <<'PY'
import collections
import json
import sys

path, host_filter, json_out, window = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

SCANNER_MARKERS = (
    "tlm-audit", "censys", "internetmeasurement", "zgrab", "ivre-masscan",
    "metabase-cve", "nuclei", "sqlmap", "nikto", "expanse", "shodan",
    "masscan", "internet-measurement", "wpbot", "okhttp/3.", "palo alto networks",
    "fasthttp", "nginx-ssl early hints",
)
SCANNER_LABEL = {
    "tlm-audit": "secret-harvesting scanner (.env/.git/aws probes)",
    "censys": "internet-wide scanner",
    "internetmeasurement": "internet-wide scanner",
    "zgrab": "internet-wide scanner",
    "ivre-masscan": "port scanner",
    "metabase-cve": "opportunistic CVE probe",
    "nuclei": "template scanner",
    "wpbot": "WordPress crawler bot",
    "okhttp/3.": "legacy OkHttp scanner/probe",
    "palo alto networks": "Cortex-Xpanse reconnaissance scanner",
    "fasthttp": "fasthttp probe/crawler",
    "nginx-ssl early hints": "early hints scanner",
}

PROBE_PREFIXES = (
    "/.git", "/.env", "/.docker", "/.aws", "/.claude", "/.cursor", "/.kube",
    "/.s3cfg", "/.netrc", "/.npmrc", "/.pypirc", "/.boto", "/.amplifyrc",
    "/.terraform", "/appxz", "/user-panel", "/wap", "/h5",
    "/wp-includes", "/wp-admin", "/wp-content",
)
PROBE_KEYWORDS = (
    "serviceaccountcredentials", "credentials.json", ".secret",
    "terraform.tf", "service-account", "firebase", "gcp-credentials",
    "wlwmanifest.xml", "xmlrpc.php", "wp-config",
    "/wordpress/", "livewire", "/api/init", "/api/common/country",
    "/api/user/ismustmobile", "/api/landing/check", "/h5/newt.html",
)

# Hosts whose public traffic is not the whole story: an internal consumer depends
# on them, so a quiet public host is not an unused one.
DEPENDENTS = {
    "onoffice.aichorage.de": "filer (FileBrowser document preview)",
    "collabora.aichorage.de": "openclouds, ladocs",
}


def header_value(request, name):
    headers = request.get("headers") or {}
    for key, value in headers.items():
        if key.lower() == name:
            if isinstance(value, list):
                return value[0] if value else "-"
            return str(value)
    return "-"


def scanner_marker(user_agent):
    low = user_agent.lower()
    for marker in SCANNER_MARKERS:
        if marker in low:
            return marker
    return None


def probe_marker(uri):
    if not uri:
        return None
    low = uri.lower()
    for prefix in PROBE_PREFIXES:
        if low.startswith(prefix):
            return "probe:" + prefix.lstrip("/")
    for kw in PROBE_KEYWORDS:
        if kw in low:
            return "probe:" + kw.strip("/")
    if low.endswith(".php") and low != "/status.php":
        return "probe:unauthorized-php"
    if "/." in low and not low.startswith("/.well-known/"):
        return "probe:hidden-file"
    return None


def describe_marker(marker):
    if marker in SCANNER_LABEL:
        return SCANNER_LABEL[marker]
    if marker.startswith("probe:"):
        return "suspicious probe target (%s)" % marker[len("probe:"):]
    return "automated probe/scanner"


def status_class(status):
    if status is None:
        return "aborted"
    try:
        code = int(status)
    except (TypeError, ValueError):
        return "unknown"
    return "%dxx" % (code // 100)


hosts = collections.defaultdict(lambda: {
    "requests": 0, "status": collections.Counter(), "ua": collections.Counter(),
    "ip": collections.Counter(), "scanner": 0, "markers": collections.Counter(),
    "paths": collections.Counter(),
})

parsed = 0
with open(path, "r", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if "duration" not in record:
            continue
        parsed += 1
        request = record.get("request") or {}
        host = request.get("host") or "-"
        if host_filter and host != host_filter:
            continue
        entry = hosts[host]
        entry["requests"] += 1
        entry["status"][status_class(record.get("status"))] += 1
        agent = header_value(request, "user-agent")
        entry["ua"][agent[:80]] += 1
        entry["ip"][header_value(request, "cf-connecting-ip")] += 1
        entry["paths"][(request.get("uri") or "-")[:80]] += 1
        marker = scanner_marker(agent) or probe_marker(request.get("uri"))
        if marker:
            entry["scanner"] += 1
            entry["markers"][marker] += 1

report = {"window": window, "records_parsed": parsed, "hosts": {}}
for host, entry in hosts.items():
    total = entry["requests"]
    scanner_share = entry["scanner"] / total if total else 0.0
    rejected = entry["status"]["4xx"]
    reject_share = rejected / total if total else 0.0
    aborted = entry["status"]["aborted"] / total if total else 0.0
    if scanner_share >= 0.5 or reject_share >= 0.5:
        verdict = "high"
    elif scanner_share >= 0.1 or reject_share >= 0.2:
        verdict = "medium"
    else:
        verdict = "low"
    report["hosts"][host] = {
        "requests": total,
        "status": dict(entry["status"]),
        "scanner_requests": entry["scanner"],
        "scanner_share": round(scanner_share, 3),
        "rejected_share": round(reject_share, 3),
        "aborted_share": round(aborted, 3),
        "risk": verdict,
        "scanner_kinds": dict(entry["markers"]),
        "top_user_agents": entry["ua"].most_common(3),
        "top_callers": entry["ip"].most_common(3),
        "top_paths": entry["paths"].most_common(5),
        "internal_dependents": DEPENDENTS.get(host, ""),
    }

if json_out:
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    raise SystemExit(0)

print("service statistics: window=%s records=%d hosts=%d" % (window, parsed, len(report["hosts"])))
print("")
print("== volume ==")
for host, info in sorted(report["hosts"].items(), key=lambda kv: -kv[1]["requests"]):
    print("  %-34s %6d" % (host, info["requests"]))

print("")
print("== status mix ==")
for host, info in sorted(report["hosts"].items(), key=lambda kv: -kv[1]["requests"]):
    mix = " ".join("%s=%d" % (k, v) for k, v in sorted(info["status"].items(), key=lambda kv: -kv[1]))
    print("  %-34s %s" % (host, mix))

print("")
print("== callers (verified CF-Connecting-IP) ==")
for host, info in sorted(report["hosts"].items(), key=lambda kv: -kv[1]["requests"]):
    if not info["top_callers"]:
        continue
    callers = ", ".join("%s (%d)" % (ip, count) for ip, count in info["top_callers"])
    print("  %-34s %s" % (host, callers))

print("")
print("== risk ==")
for host, info in sorted(report["hosts"].items(), key=lambda kv: -kv[1]["requests"]):
    kinds = ""
    if info["scanner_kinds"]:
        kinds = " [" + ", ".join(sorted(info["scanner_kinds"])) + "]"
    print("  %-34s %-6s scanner=%d (%.0f%%) rejected=%.0f%% aborted=%.0f%%%s" % (
        host, info["risk"], info["scanner_requests"], info["scanner_share"] * 100,
        info["rejected_share"] * 100, info["aborted_share"] * 100, kinds))
    for marker in sorted(info["scanner_kinds"]):
        label = describe_marker(marker)
        print("      %-18s %s" % (marker, label))
    if info["internal_dependents"]:
        print("      internal dependents: %s" % info["internal_dependents"])
        if info["requests"] and info["scanner_share"] >= 0.5:
            print("      WARNING: most public traffic is scanning, but this host serves %s; "
                  "do not treat it as unused." % info["internal_dependents"])

high = [h for h, i in report["hosts"].items() if i["risk"] == "high"]
if high:
    print("")
    print("hosts needing edge mitigation: %s" % ", ".join(sorted(high)))
PY
