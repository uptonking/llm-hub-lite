# Edge protection rules (Cloudflare zone aichorage.de)

The origin already rejects secret-harvesting probes correctly, but every one of them
reached the origin before being rejected. `TLM-Audit-Scanner/2.0` alone produced 1,262
of 1,286 Collabora origin requests, 1,265 of them answered `400` by Caddy before
Collabora was dialled. These zone-level rules stop that traffic at the edge, so the
origin sees only real users and the Cloudflare request chart reflects the truth.

Apply with `cf` (the CLI is authenticated as the zone operator; no token is stored on
any node, so a compromised node gains no edge access).

## 1. Custom firewall ruleset (`http_request_firewall_custom`)

```json
[
  {
    "action": "block",
    "description": "Block secret-harvesting probe paths (.git/.env/aws credentials)",
    "expression": "(http.request.uri.path contains \"/.git\" or http.request.uri.path contains \"%2e\" or http.request.uri.path contains \"aws/credentials\" or http.request.uri.path contains \"/.env\") and not http.request.uri.path eq \"/hosting/discovery\""
  },
  {
    "action": "block",
    "description": "Block known automated scanners by user agent",
    "expression": "(http.user_agent contains \"TLM-Audit-Scanner\") or (http.user_agent contains \"CensysInspect\") or (http.user_agent contains \"InternetMeasurement\") or (http.user_agent contains \"zgrab\") or (http.user_agent contains \"ivre-masscan\") or (http.user_agent contains \"metabase-cve\")"
  }
]
```

```
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --body @rules.json
```

`/hosting/discovery` is excluded on purpose: it is Collabora's discovery endpoint and
the Caddy health-check target.

## 2. Rate limiting: not available on this plan

The zone is on a plan where the `http_ratelimit` phase only accepts the built-in
"Leaked credential check" rule (period 10s, 5 requests, `mitigation_timeout` 10). Rules
using `ip.src` or `cf.unique_visitor_id` are rejected with
`not entitled: the use of field ip.src is not allowed, an higher Advanced Rate Limiting
plan is required`.

So per-IP throttling of the office hosts is **not implemented**. The two block rules
above carry the mitigation: they remove the scanning traffic entirely, which is what the
rate limit was going to shape. If a plan upgrade happens later, the prepared rule is:

```
(http.host in {"collabora.aichorage.de" "onoffice.aichorage.de"})
  and not (ip.src in {cluster node addresses})
  and (http.request.uri.path ne "/hosting/discovery")
  → 30 requests / 10s per ip.src (+cf.colo.id) → block
```

Cluster node addresses must stay excluded: worker-2 posts the hourly WOPI registration,
and onoffice fetches document bytes back from `filer.aichorage.de` through Cloudflare
from worker-1. Throttling node addresses breaks document editing in a way that looks
like an application bug.

## 3. Not applied: managed WAF ruleset

`http_request_firewall_managed` has no entrypoint on this zone, and the available
managed ruleset is the free-tier set. The two custom rules already cover every scanner
signature observed in the access log, so managed rules were left for a separate
decision rather than enabled blind on a zone with this many hosts.

## Verification

```
curl -A 'TLM-Audit-Scanner/2.0' https://collabora.aichorage.de/hosting/discovery   # 403
curl -A 'Mozilla/5.0 ...'      https://collabora.aichorage.de/hosting/discovery   # 200
curl -A 'Mozilla/5.0 ...'      https://collabora.aichorage.de/.git/config         # 403
curl -A 'Mozilla/5.0 ...'      https://onoffice.aichorage.de/                     # 302
```

Then confirm the origin is quiet with `ops/report-service-stats.sh`: scanner share
should be 0 and the Collabora request count should fall to the hourly registration.

## Rollback

```
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --rules '[]'
```

No origin behaviour depends on these rules.
