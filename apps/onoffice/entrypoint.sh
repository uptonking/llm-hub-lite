#!/bin/bash
set -euo pipefail

# Provision AI assistant plugin and configuration in background once docservice is healthy
(
	AI_GUID="asc.{9DC93CDB-B576-4F0C-B55E-FCC9C48DD007}"
	PLUGIN_DIR="/var/www/onlyoffice/documentserver/sdkjs-plugins/{9DC93CDB-B576-4F0C-B55E-FCC9C48DD007}"
	LOCAL_JSON="/etc/onlyoffice/documentserver/local.json"

	# Wait for docservice healthcheck to be ready (up to 300s)
	retries=0
	while ! curl -fsS --max-time 3 http://127.0.0.1:80/healthcheck 2>/dev/null | grep -Fq "true"; do
		retries=$((retries + 1))
		if [ "$retries" -ge 100 ]; then
			exit 0
		fi
		sleep 3
	done

	# Install AI assistant plugin if not present
	if [ ! -d "$PLUGIN_DIR" ]; then
		documentserver-pluginsmanager --install="ai" >/dev/null 2>&1 || true
	fi

	# Configure autostart and CORS in local.json
	if [ -f "$LOCAL_JSON" ]; then
		python3 -c "
import json
p = '$LOCAL_JSON'
try:
    with open(p, 'r') as f:
        d = json.load(f)
    changed = False
    coauth = d.setdefault('services', {}).setdefault('CoAuthoring', {})
    plugins = coauth.setdefault('plugins', {})
    autostart = plugins.get('autostart', [])
    ai_guid = '$AI_GUID'
    if ai_guid not in autostart:
        autostart.append(ai_guid)
        plugins['autostart'] = autostart
        changed = True

    ai = d.setdefault('aiSettings', {})
    if not ai.get('enable'):
        ai['enable'] = True
        changed = True
    if not ai.get('allowBrowserProxy'):
        ai['allowBrowserProxy'] = True
        changed = True
    cors = ai.get('allowedCorsOrigins', ['https://onlyoffice.github.io', 'https://onlyoffice-plugins.github.io'])
    for origin in ['https://aichorouter.aichorage.de', 'https://filer.aichorage.de', 'https://onoffice.aichorage.de']:
        if origin not in cors:
            cors.append(origin)
            changed = True
    ai['allowedCorsOrigins'] = cors

    if changed:
        with open(p, 'w') as f:
            json.dump(d, f, indent=2)
        print('PROVISION_RELOAD_NEEDED')
except Exception:
    pass
" | grep -Fq "PROVISION_RELOAD_NEEDED" && {
			supervisorctl restart ds:docservice >/dev/null 2>&1 || true
		}
	fi
) &

# Ensure example directory permissions and compatibility symlink
EXAMPLE_DIR="/var/www/onlyoffice/documentserver-example/public/files"
EXAMPLE_LIB_DIR="/var/lib/onlyoffice/documentserver-example"
mkdir -p "$EXAMPLE_DIR" "$EXAMPLE_LIB_DIR"
chown -R ds:ds "$EXAMPLE_DIR" "$EXAMPLE_LIB_DIR"
chmod -R 775 "$EXAMPLE_DIR"
if [ ! -L "$EXAMPLE_LIB_DIR/files" ]; then
	rm -rf "$EXAMPLE_LIB_DIR/files"
	ln -s "$EXAMPLE_DIR" "$EXAMPLE_LIB_DIR/files"
fi

exec /app/ds/run-document-server.sh "$@"
