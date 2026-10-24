# Edge protection rules (Cloudflare zone aichorage.de)

The origin already rejects secret-harvesting probes correctly, but untrusted scanning
traffic reaches the origin unless intercepted. Scanners like `TLM-Audit-Scanner/2.0`,
`wpbot`, `okhttp/3.`, and internet-wide reconnaissance crawlers probe for dotfiles
(`/.env`, `/.docker/config.json`, `/.aws/config`, `/.git`), service credentials
(`/serviceAccountCredentials.json`, `*.secret`), CMS vulnerabilities (`wp-admin`,
`wp-includes`, `xmlrpc.php`), unauthorized `.php` files, and nonexistent mobile app endpoints.

These zone-level Cloudflare rules stop that traffic at the edge, ensuring the origin sees
only authentic users and the Cloudflare request charts reflect legitimate usage.

Apply with `cf` (the CLI is authenticated as the zone operator; no token is stored on
any node, so a compromised node gains no edge access).

## 1. Custom firewall ruleset (`http_request_firewall_custom`)

Active ruleset configuration:

```json
{
  "description": "Platform edge protection: scanner, probe, exploit, and secret blocking",
  "rules": [
    {
      "action": "block",
      "description": "Block secret probes, hidden files, CMS exploits, and unauthorized PHP endpoints",
      "expression": "((starts_with(http.request.uri.path, "/.") and not starts_with(http.request.uri.path, "/.well-known/")) or http.request.uri.path contains "%2e" or http.request.uri.path contains "%2E" or http.request.uri.path contains "aws/credentials" or http.request.uri.path contains "serviceAccountCredentials" or http.request.uri.path contains "credentials.json" or http.request.uri.path contains ".secret" or http.request.uri.path contains "wp-includes" or http.request.uri.path contains "wp-admin" or http.request.uri.path contains "wp-content" or http.request.uri.path contains "wlwmanifest.xml" or http.request.uri.path contains "xmlrpc.php" or (ends_with(http.request.uri.path, ".php") and not (http.request.uri.path eq "/status.php")) or http.request.uri.path contains "/api/user/ismustmobile" or http.request.uri.path contains "/api/landing/check" or http.request.uri.path contains "/h5/newt.html" or http.request.uri.path contains "/index/aurl") and not (http.request.uri.path eq "/hosting/discovery")"
    },
    {
      "action": "block",
      "description": "Block known automated scanners and exploit bot user-agents",
      "expression": "(http.user_agent contains "TLM-Audit-Scanner") or (http.user_agent contains "CensysInspect") or (http.user_agent contains "InternetMeasurement") or (http.user_agent contains "zgrab") or (http.user_agent contains "ivre-masscan") or (http.user_agent contains "metabase-cve") or (http.user_agent contains "Cortex-Xpanse") or (http.user_agent contains "Palo Alto Networks") or (http.user_agent contains "wpbot") or (http.user_agent contains "okhttp/3.") or (http.user_agent contains "sqlmap") or (http.user_agent contains "nikto") or (http.user_agent contains "nuclei") or (http.user_agent contains "masscan")"
    }
  ]
}
```

Update command:

```bash
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --body @rules.json
```

Exclusion rationale:
- `starts_with(http.request.uri.path, "/.well-known/")` is excluded so Auther OpenID Connect discovery (`/.well-known/openid-configuration`) and OpenClouds WebFinger (`/.well-known/webfinger`) continue to operate without interference.
- `http.request.uri.path eq "/status.php"` is excluded because OpenClouds uses `/status.php` for upstream health checks.
- `http.request.uri.path eq "/hosting/discovery"` is excluded because Collabora uses it for WOPI discovery and Caddy health checks.

## 2. Rate limiting: not available on this plan

The zone is on the Free tier where the `http_ratelimit` phase only accepts the built-in
"Leaked credential check" rule (period 10s, 5 requests, `mitigation_timeout` 10). Rules
using `ip.src` or `cf.unique_visitor_id` are rejected with
`not entitled: the use of field ip.src is not allowed, an higher Advanced Rate Limiting plan is required`.

So per-IP throttling is **not implemented**. The two custom edge block rules above carry
the mitigation: they eliminate scanner and exploit traffic before it reaches the origin.

If a plan upgrade happens later, the prepared rate limiting rule is:

```
(http.host in {"collabora.aichorage.de" "onoffice.aichorage.de"})
  and not (ip.src in {cluster node addresses})
  and (http.request.uri.path ne "/hosting/discovery")
  → 30 requests / 10s per ip.src (+cf.colo.id) → block
```

Cluster node addresses must stay excluded: follower nodes communicate with Auther, Filer,
and WOPI endpoints across nodes.

## 3. Not applied: managed WAF ruleset

`http_request_firewall_managed` has no entrypoint on this zone, and the available
managed ruleset is the free-tier set. The two custom rules cover the exact scanner
signatures, dotfiles, and exploit paths observed in the access log without risking
false positives on custom platform APIs.

## Verification

```bash
# Blocked probe paths and secrets (expect 403 Forbidden at edge)
curl -s -o /dev/null -w "%{http_code}\n" https://outline.aichorage.de/serviceAccountCredentials.json # 403
curl -s -o /dev/null -w "%{http_code}\n" https://outline.aichorage.de/.docker/config.json           # 403
curl -s -o /dev/null -w "%{http_code}\n" https://club.aichorage.de/api/phpinfo.php                  # 403
curl -s -o /dev/null -w "%{http_code}\n" https://club.aichorage.de/wp-includes/wlwmanifest.xml      # 403
curl -s -o /dev/null -w "%{http_code}\n" https://ladocs.aichorage.de/api/user/ismustmobile          # 403

# Blocked scanner User-Agents (expect 403 Forbidden at edge)
curl -s -o /dev/null -w "%{http_code}\n" -A "TLM-Audit-Scanner/2.0" https://collabora.aichorage.de/ # 403
curl -s -o /dev/null -w "%{http_code}\n" -A "okhttp/3.14.9"         https://ladocs.aichorage.de/    # 403
curl -s -o /dev/null -w "%{http_code}\n" -A "wpbot/1.4"             https://club.aichorage.de/      # 403

# Allowed legitimate endpoints (expect 200 OK)
curl -s -o /dev/null -w "%{http_code}\n" https://auther.aichorage.de/.well-known/openid-configuration # 200
curl -s -o /dev/null -w "%{http_code}\n" https://openclouds.aichorage.de/status.php                    # 200
curl -s -o /dev/null -w "%{http_code}\n" https://outline.aichorage.de/                                 # 200
curl -s -o /dev/null -w "%{http_code}\n" https://club.aichorage.de/                                    # 200
curl -s -o /dev/null -w "%{http_code}\n" https://ladocs.aichorage.de/                                  # 200
```

Then inspect origin statistics with `ops/report-service-stats.sh`:
```bash
ops/report-service-stats.sh --since 24h
```

## Rollback

```bash
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --rules '[]'
```
