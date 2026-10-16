#!/bin/sh
set -eu

# Ensure log and config directories exist
mkdir -p /data/gitea/conf /data/gitea/log /data/git

# If admin credentials are provided, provision administrator idempotently in background
if [ -n "${GTEA_ADMIN_USER:-}" ] && [ -n "${GTEA_ADMIN_PASSWORD:-}" ]; then
	(
		while ! curl -fsS http://127.0.0.1:3000/api/v1/version >/dev/null 2>&1; do
			sleep 2
		done
		su-exec git gitea admin user create \
			--admin \
			--username "$GTEA_ADMIN_USER" \
			--password "$GTEA_ADMIN_PASSWORD" \
			--email "${GTEA_ADMIN_EMAIL:-admin@aichorage.de}" \
			--must-change-password=false >/dev/null 2>&1 || true
	) &
fi

exec /usr/bin/entrypoint "$@"
