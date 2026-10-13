#!/bin/sh
# Ladocs backend entrypoint: signs the RS256 keypair, ensures the versioned
# media bucket exists in the node-local object storage, applies Django
# migrations, then execs the image's original entrypoint (uvicorn). Every step
# is idempotent so the container recovers cleanly after a VPS restart.
set -eu
umask 077

log() { printf 'ladocs-backend-entrypoint: %s\n' "$*" >&2; }

# Signs the short-lived tokens the backend presents to the collaboration
# server and the conversion service. Rotate by deleting /keys/private.pem and
# recreating the container; tokens are short-lived so the outage is brief.
if [ ! -s /keys/private.pem ]; then
	python - <<'PY'
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = key.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption(),
)
with open("/keys/private.pem.tmp", "wb") as handle:
    handle.write(pem)
PY
	mv /keys/private.pem.tmp /keys/private.pem
	log 'generated /keys/private.pem'
fi

# The store may still be formatting on the very first boot; retry for a while
# before letting the restart policy take over.
attempt=0
until python /ladocs/bootstrap_s3.py; do
	attempt=$((attempt + 1))
	if [ "$attempt" -ge 20 ]; then
		log 'media bucket bootstrap did not succeed'
		exit 1
	fi
	sleep 3
done

attempt=0
until python manage.py migrate --noinput; do
	attempt=$((attempt + 1))
	if [ "$attempt" -ge 20 ]; then
		log 'Django migrations did not succeed'
		exit 1
	fi
	sleep 3
done

exec /usr/local/bin/entrypoint "$@"
