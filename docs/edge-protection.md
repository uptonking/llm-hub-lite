# Edge protection rules (Cloudflare zone aichorage.de)

The origin already rejects secret-harvesting probes correctly, but untrusted scanning
traffic reaches the origin unless intercepted. Scanners like `TLM-Audit-Scanner/2.0`,
`wpbot`, `okhttp/3.`, `fasthttp`, `nginx-ssl early hints`, and internet-wide reconnaissance
crawlers probe for dotfiles (`/.env`, `/.docker/config.json`, `/.aws/config`, `/.git`, `/.terraform`),
cloud service credentials (`service-account.json`, `firebase-adminsdk.json`, `terraform.tfvars`, `gcp-credentials.json`),
CMS vulnerabilities (`wp-admin`, `wp-includes`, `wp-config`, `xmlrpc.php`, `/wordpress/`),
unauthorized `.php` files, and nonexistent mobile app endpoints (`/appxz`, `/wap`, `/h5`).

These zone-level Cloudflare rules stop that traffic at the edge, ensuring the origin sees
only authentic users and the Cloudflare request charts reflect legitimate usage.

Apply with `cf` (the CLI is authenticated as the zone operator; no token is stored on
any node, so a compromised node gains no edge access).

## 1. Custom firewall ruleset (`http_request_firewall_custom`)

Active ruleset configuration (Version 3):

```json
{
  "description": "Platform edge protection: scanner, probe, exploit, and secret blocking",
  "rules": [
    {
      "action": "block",
      "description": "Block secret probes, hidden files, CMS exploits, and unauthorized PHP endpoints",
      "expression": "((http.request.uri.path contains "/." and not (http.request.uri.path contains "/.well-known/")) or http.request.uri.path contains "%2e" or http.request.uri.path contains "%2E" or http.request.uri.path contains "aws/credentials" or http.request.uri.path contains "serviceAccountCredentials" or http.request.uri.path contains "credentials.json" or http.request.uri.path contains ".secret" or http.request.uri.path contains "terraform.tf" or http.request.uri.path contains "service-account" or http.request.uri.path contains "firebase" or http.request.uri.path contains "gcp-credentials" or http.request.uri.path contains "wp-includes" or http.request.uri.path contains "wp-admin" or http.request.uri.path contains "wp-content" or http.request.uri.path contains "wlwmanifest.xml" or http.request.uri.path contains "xmlrpc.php" or http.request.uri.path contains "wp-config" or http.request.uri.path contains "/wordpress/" or http.request.uri.path contains "livewire" or (ends_with(http.request.uri.path, ".php") and not (http.request.uri.path eq "/status.php")) or starts_with(http.request.uri.path, "/appxz") or starts_with(http.request.uri.path, "/user-panel") or (starts_with(http.request.uri.path, "/wap/") or http.request.uri.path eq "/wap") or (starts_with(http.request.uri.path, "/h5/") or http.request.uri.path eq "/h5") or http.request.uri.path contains "/api/user/ismustmobile" or http.request.uri.path contains "/api/landing/check" or http.request.uri.path contains "/api/common/country" or http.request.uri.path contains "/api/init" or http.request.uri.path contains "/index/aurl") and not (http.request.uri.path eq "/hosting/discovery")"
    },
    {
      "action": "block",
      "description": "Block known automated scanners and exploit bot user-agents",
      "expression": "(http.user_agent contains "TLM-Audit-Scanner") or (http.user_agent contains "CensysInspect") or (http.user_agent contains "InternetMeasurement") or (http.user_agent contains "zgrab") or (http.user_agent contains "ivre-masscan") or (http.user_agent contains "metabase-cve") or (http.user_agent contains "Cortex-Xpanse") or (http.user_agent contains "Palo Alto Networks") or (http.user_agent contains "wpbot") or (http.user_agent contains "okhttp/3.") or (http.user_agent contains "sqlmap") or (http.user_agent contains "nikto") or (http.user_agent contains "nuclei") or (http.user_agent contains "masscan") or (http.user_agent contains "fasthttp") or (http.user_agent contains "nginx-ssl early hints")"
    },
    {
      "action": "block",
      "description": "Block persistent reconnaissance and illegal probe scanner IPs",
      "expression": "ip.src in {198.51.100.10 198.51.100.11 203.0.113.20 203.0.113.21}"
    }
  ]
}
```

Update command:

```bash
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --body @rules.json
```

Exclusion rationale:
- `http.request.uri.path contains "/.well-known/"` is excluded so Auther OpenID Connect discovery (`/.well-known/openid-configuration`) and OpenClouds WebFinger (`/.well-known/webfinger`) continue to operate without interference.
- `http.request.uri.path eq "/status.php"` is excluded because OpenClouds uses `/status.php` for upstream health checks.
- `http.request.uri.path eq "/hosting/discovery"` is excluded because Collabora uses it for WOPI discovery and Caddy health checks.

## 2. SPA edge vs. origin false alarms

Applications built as Single Page Applications (SPAs) like OpenClouds (Vue/Vite frontend)
and Authelia (Go/React frontend) return `200 OK` with the frontend `index.html` shell for any
unmatched non-API path.
- When an automated crawler probes `/appxz/index.html` or `/user-panel/.env` on `openclouds.aichorage.de`,
  OpenCloud returns `200 OK` with OpenCloud's HTML shell. This is **not a breach**: no sensitive file was served.
- However, because the scanner sees `200 OK`, it continues requesting referenced JS assets (`/js/index.html-*.mjs`).
  Rule 1 blocks these probe prefixes at the edge with `403 Forbidden`, terminating scanner loops immediately.
- On `searx.aichorage.de`, Caddy enforces HTTP Basic Authentication (`basic_auth`) on all paths except `/healthz`.
  All 302 origin requests recorded were rejected with `401 Unauthorized`.

## 3. Rate limiting: not available on this plan

The zone is on the Free tier where the `http_ratelimit` phase only accepts the built-in
"Leaked credential check" rule. Rules using `ip.src` or `cf.unique_visitor_id` are rejected with
`not entitled: the use of field ip.src is not allowed, an higher Advanced Rate Limiting plan is required`.

So per-IP throttling is **not implemented**. The three custom edge block rules above carry
the mitigation: they eliminate scanner and exploit traffic before it reaches the origin.

## Verification

```bash
# Blocked probe paths and secrets (expect 403 Forbidden at edge)
curl -s -o /dev/null -w "%{http_code}\n" https://openclouds.aichorage.de/appxz/index.html  # 403
curl -s -o /dev/null -w "%{http_code}\n" https://openclouds.aichorage.de/wap/              # 403
curl -s -o /dev/null -w "%{http_code}\n" https://searx.aichorage.de/terraform.tfvars       # 403
curl -s -o /dev/null -w "%{http_code}\n" https://searx.aichorage.de/service-account.json   # 403
curl -s -o /dev/null -w "%{http_code}\n" https://auther.aichorage.de/wordpress/            # 403
curl -s -o /dev/null -w "%{http_code}\n" https://auther.aichorage.de/livewire/update       # 403

# Blocked scanner User-Agents (expect 403 Forbidden at edge)
curl -s -o /dev/null -w "%{http_code}\n" -A "fasthttp"              https://openclouds.aichorage.de/ # 403
curl -s -o /dev/null -w "%{http_code}\n" -A "TLM-Audit-Scanner/2.0" https://collabora.aichorage.de/ # 403
curl -s -o /dev/null -w "%{http_code}\n" -A "okhttp/3.14.9"         https://ladocs.aichorage.de/    # 403
curl -s -o /dev/null -w "%{http_code}\n" -A "wpbot/1.4"             https://club.aichorage.de/      # 403

# Allowed legitimate endpoints (expect 200 OK)
curl -s -o /dev/null -w "%{http_code}\n" https://auther.aichorage.de/.well-known/openid-configuration # 200
curl -s -o /dev/null -w "%{http_code}\n" https://openclouds.aichorage.de/status.php                    # 200
curl -s -o /dev/null -w "%{http_code}\n" https://searx.aichorage.de/healthz                            # 200
curl -s -o /dev/null -w "%{http_code}\n" https://outline.aichorage.de/                                 # 200
curl -s -o /dev/null -w "%{http_code}\n" https://club.aichorage.de/                                    # 200
```

Then inspect origin statistics with `ops/report-service-stats.sh`:
```bash
ops/report-service-stats.sh --since 24h
```

## Rollback

```bash
cf -z aichorage.de rulesets entrypoint update http_request_firewall_custom --rules '[]'
```
