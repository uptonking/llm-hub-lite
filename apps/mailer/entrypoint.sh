#!/bin/sh
set -eu

mkdir -p /var/lib/stalwart/data /etc/stalwart /etc/stalwart/certs

if [ ! -f /etc/stalwart/config.json ] && [ -f /etc/stalwart-template/config.json.tmpl ]; then
	cp /etc/stalwart-template/config.json.tmpl /etc/stalwart/config.json
fi

# Sync Caddy certificates if available
sync_certs() {
	if [ -d /etc/caddy-certificates ]; then
		cert=$(find /etc/caddy-certificates -name "${MAILER_HOSTNAME:-mail.aichorage.de}.crt" 2>/dev/null | head -n 1)
		key=$(find /etc/caddy-certificates -name "${MAILER_HOSTNAME:-mail.aichorage.de}.key" 2>/dev/null | head -n 1)
		if [ -n "$cert" ] && [ -n "$key" ]; then
			cp -f "$cert" /etc/stalwart/certs/tls.crt
			cp -f "$key" /etc/stalwart/certs/tls.key
			chmod 600 /etc/stalwart/certs/tls.crt /etc/stalwart/certs/tls.key
			chown -R stalwart:stalwart /etc/stalwart/certs
		fi
	fi
}

sync_certs

chown -R stalwart:stalwart /var/lib/stalwart /etc/stalwart
chmod 700 /var/lib/stalwart/data /etc/stalwart /etc/stalwart/certs
[ -f /etc/stalwart/config.json ] && chmod 600 /etc/stalwart/config.json

export STALWART_RECOVERY_ADMIN="admin:${MAILER_ADMIN_PASSWORD}"
export STALWART_HOSTNAME="${MAILER_HOSTNAME:-mail.aichorage.de}"
export STALWART_PUBLIC_URL="${MAILER_SITE:-https://mail.aichorage.de}"
export STALWART_RECOVERY_MODE_PORT="8080"

# Background worker for periodic certificate sync and initial domain bootstrap
(
	for _ in $(seq 1 30); do
		if curl -fsS http://127.0.0.1:8080/healthz/ready >/dev/null 2>&1; then
			break
		fi
		sleep 2
	done

	if curl -fsS http://127.0.0.1:8080/healthz/ready >/dev/null 2>&1; then
		AUTH_HEADER="Basic $(printf 'admin:%s' "$MAILER_ADMIN_PASSWORD" | base64 | tr -d '\n')"

		# Ensure domain exists
		DOMAIN_QUERY='{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Domain/query",{"accountId":"d333333"},"0"]]}'
		RESP=$(curl -s -H "Content-Type: application/json" -H "Authorization: $AUTH_HEADER" -d "$DOMAIN_QUERY" http://127.0.0.1:8080/jmap/ || true)
		if ! printf '%s' "$RESP" | grep -q '"ids":\["[^"]'; then
			DOMAIN_CREATE=$(printf '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Domain/set",{"accountId":"d333333","create":{"d1":{"name":"%s","isEnabled":true}}},"0"]]}' "${MAILER_DOMAIN:-aichorage.de}")
			curl -s -H "Content-Type: application/json" -H "Authorization: $AUTH_HEADER" -d "$DOMAIN_CREATE" http://127.0.0.1:8080/jmap/ >/dev/null 2>&1 || true
		fi

		# Ensure file-backed certificate exists if cert files present
		if [ -f /etc/stalwart/certs/tls.crt ] && [ -f /etc/stalwart/certs/tls.key ]; then
			CERT_QUERY='{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/query",{"accountId":"d333333"},"0"]]}'
			CRESP=$(curl -s -H "Content-Type: application/json" -H "Authorization: $AUTH_HEADER" -d "$CERT_QUERY" http://127.0.0.1:8080/jmap/ || true)
			if ! printf '%s' "$CRESP" | grep -q '"ids":\["[^"]'; then
				CERT_CREATE='{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/set",{"accountId":"d333333","create":{"c1":{"certificate":{"@type":"File","filePath":"/etc/stalwart/certs/tls.crt"},"privateKey":{"@type":"File","filePath":"/etc/stalwart/certs/tls.key"}}}},"0"]]}'
				curl -s -H "Content-Type: application/json" -H "Authorization: $AUTH_HEADER" -d "$CERT_CREATE" http://127.0.0.1:8080/jmap/ >/dev/null 2>&1 || true
			fi
		fi
	fi

	# Periodic certificate sync
	while true; do
		sleep 21600
		sync_certs
	done
) &

exec su -s /bin/sh -c 'exec /usr/local/bin/stalwart --config /etc/stalwart/config.json' stalwart
