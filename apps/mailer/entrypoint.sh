#!/bin/sh
set -eu

mkdir -p /var/lib/stalwart/data /etc/stalwart

if [ ! -f /etc/stalwart/config.json ] && [ -f /etc/stalwart-template/config.json.tmpl ]; then
	cp /etc/stalwart-template/config.json.tmpl /etc/stalwart/config.json
fi

chown -R stalwart:stalwart /var/lib/stalwart /etc/stalwart
chmod 700 /var/lib/stalwart/data /etc/stalwart
[ -f /etc/stalwart/config.json ] && chmod 600 /etc/stalwart/config.json

export STALWART_RECOVERY_ADMIN="admin:${MAILER_ADMIN_PASSWORD}"
export STALWART_HOSTNAME="${MAILER_HOSTNAME:-mail.aichorage.de}"
export STALWART_PUBLIC_URL="${MAILER_SITE:-https://mail.aichorage.de}"
export STALWART_RECOVERY_MODE_PORT="8080"

exec su -s /bin/sh -c 'exec /usr/local/bin/stalwart --config /etc/stalwart/config.json' stalwart
