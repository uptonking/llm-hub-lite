#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/gtea"

grep -q '^APP_ID=gtea$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=sqlite$' "$app/manifest.env"
grep -q '^HEALTH_URL=/api/v1/version$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/gtea.policy"
grep -q '^NODES=worker-2$' "$repo_root/config/cluster/apps/gtea.policy"

# Verify Compose limits and constraints
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${GTEA_MEMORY_LIMIT:-512m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${GTEA_CPUS:-0.5}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${GTEA_PIDS_LIMIT:-256}' "$app/compose.yml"
grep -Fq 'GITEA__indexer__REPO_INDEXER_ENABLED: "false"' "$app/compose.yml"
grep -Fq 'GITEA__log__MODE: "console, file"' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'GITEA__audit__RECORD_OUTPUT: ${GTEA_AUDIT_RECORD_OUTPUT:-database}' "$app/compose.yml"
[[ -x "$app/entrypoint.sh" ]]

# Verify storage mounts
grep -Fq 'data:/data' "$app/compose.yml"

# Verify Caddy reverse proxies
grep -Fq 'reverse_proxy gtea:3000' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
grep -Fq 'flush_interval -1' "$app/route.follower.caddy"
grep -Fq 'import forward_verified_client_ip' "$app/route.follower.caddy"
grep -Fq 'health_uri /api/v1/version' "$app/route.leader.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$GTEA_UPSTREAM}' "$app/route.leader.caddy"
grep -Fq 'import forward_verified_client_ip' "$app/route.leader.caddy"

# Verify origin hosts across all cluster nodes
for node in leader worker-1 worker-2 worker-3 worker-4 worker-5 worker-6; do
	prefix="${node/-/}"
	grep -q "^NODE_GTEA_ORIGIN_HOST=${prefix}-gtea-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

# Verify Fail2ban filter and jail configurations
[[ -f "$app/fail2ban/gitea.filter.conf" ]]
grep -Fq 'failregex' "$app/fail2ban/gitea.filter.conf"
[[ -f "$app/fail2ban/gtea.jail.conf" ]]
grep -Fq 'filter = gitea' "$app/fail2ban/gtea.jail.conf"

# Verify generated Woodpecker workflows
for workflow in \
	consumer-stage-gtea-worker-2.yml \
	consumer-publish-gtea.yml \
	consumer-finalize-gtea-worker-2.yml \
	consumer-secrets-gtea-worker-2.yml \
	consumer-stop-gtea-worker-1.yml \
	consumer-stop-gtea-worker-3.yml \
	consumer-stop-gtea-worker-4.yml \
	consumer-stop-gtea-worker-5.yml \
	consumer-stop-gtea-worker-6.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done

grep -Fq 'GITEA__packages__ENABLED: "false"' "$app/compose.yml"
grep -Fq 'GITEA__actions__ENABLED: "false"' "$app/compose.yml"
grep -Fq 'GITEA__mailer__ENABLED: "false"' "$app/compose.yml"
grep -Fq 'change-password' "$app/entrypoint.sh"
grep -Fq 'flush_interval -1' "$app/route.leader.caddy"
grep -Fq 'router: completed' "$app/fail2ban/gitea.filter.conf"

# Verify Fail2ban automated reconciliation hooks in configure-firewall
grep -Fq 'reconcile_app_fail2ban' "$repo_root/ops/configure-firewall.sh"
grep -Fq 'fail2ban-client reload' "$repo_root/ops/configure-firewall.sh"

# Verify Fail2ban regex parsing and match behavior for web auth, git over HTTPS, and REST API
python3 - <<'EOF'
import re

with open("apps/gtea/fail2ban/gitea.filter.conf", "r", encoding="utf-8") as fh:
    content = fh.read()

regexes = [line.split("=", 1)[-1].strip() for line in content.splitlines() if "^.*" in line]
assert len(regexes) == 2, f"Expected 2 failregex patterns, got {len(regexes)}"

# Test 1: Web UI login failure
web_line = "2026/10/17 16:02:40 ...ers/web/auth/auth.go:218:SignInPost() [W] Failed authentication attempt for admin from 192.0.2.182:0: user password invalid"
pat1 = regexes[0].replace("<HOST>", r"(?P<host>[0-9.]+)")
assert re.search(pat1, web_line), "Web auth failure must match regex 1"

# Test 2: Git over HTTPS 401 Unauthorized
git_line = "2026/10/17 16:04:54 ...eb/routing/logger.go:102:func1() [I] router: completed GET /admin/ci-test-repo.git/info/refs?service=git-upload-pack for 192.0.2.182:0, 401 Unauthorized in 113.1ms"
pat2 = regexes[1].replace("<HOST>", r"(?P<host>[0-9.]+)")
assert re.search(pat2, git_line), "Git 401 failure must match regex 2"

# Test 3: REST API 401 Unauthorized
api_line = "2026/10/17 16:02:08 ...eb/routing/logger.go:102:func1() [I] router: completed GET /api/v1/user for 192.0.2.182:0, 401 Unauthorized in 62.8ms @ v1/api.go:756(v1.Routes.apiAuth)"
assert re.search(pat2, api_line), "API 401 failure must match regex 2"
EOF

printf 'Gtea application tests passed\n'
