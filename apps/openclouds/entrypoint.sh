#!/bin/sh
set -eu

# Ensure runtime directories exist
mkdir -p /etc/opencloud /var/lib/opencloud/storage/users /var/lib/opencloud/web/assets/apps

# Ensure proxy.yaml is rendered with the configured quota (default: 5GB = 5368709120 bytes)
quota="${OPENCLOUDS_DEFAULT_QUOTA_BYTES:-5368709120}"
cat <<EOF >/etc/opencloud/proxy.yaml
# Rendered OpenClouds role quota configuration
role_quotas:
  'd7beeea8-8ff4-406b-8fb6-ab2dd81e6b11': $quota
  '2aadd357-682c-406b-8874-293091995fdd': $quota
  '71881883-1768-46bd-a24d-a356a2afdf7f': $quota
  '38071a68-456a-4553-846a-fa67bf5596cc': $quota
EOF

# Ensure CSP configuration is synced from template
if [ -f /etc/opencloud-template/csp.yaml ]; then
	cp /etc/opencloud-template/csp.yaml /etc/opencloud/csp.yaml
fi

# Ensure ownership and permissions for non-root opencloud-user (UID 1000)
chown -R 1000:1000 /etc/opencloud /var/lib/opencloud
chmod 750 /etc/opencloud /var/lib/opencloud

# Run opencloud init to seed /etc/opencloud/opencloud.yaml with random secrets on first start,
# then exec opencloud server as opencloud-user
exec su -s /bin/sh opencloud-user -c "opencloud init || true; exec opencloud server"
