#!/bin/sh
# Ladocs collaboration server entrypoint: signs its own RS256 keypair (never
# the backend's), creates or upgrades its database schema with the idempotent
# upstream init-db script, then execs the image's original entrypoint.
set -eu
umask 077

log() { printf 'ladocs-yhub-entrypoint: %s\n' "$*" >&2; }

if [ ! -s /keys/yhub-private.pem ]; then
	node - <<'JS'
const crypto = require("crypto");
const fs = require("fs");
const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
fs.writeFileSync(
  "/keys/yhub-private.pem.tmp",
  privateKey.export({ type: "pkcs8", format: "pem" })
);
JS
	mv /keys/yhub-private.pem.tmp /keys/yhub-private.pem
	log 'generated /keys/yhub-private.pem'
fi

# init-db creates the yhub database when missing and applies every table and
# index the installed version needs; re-running it after an image upgrade is
# the upstream-documented upgrade path.
attempt=0
until node node_modules/@y/hub/bin/init-db.js; do
	attempt=$((attempt + 1))
	if [ "$attempt" -ge 20 ]; then
		log 'yhub schema initialization did not succeed'
		exit 1
	fi
	sleep 3
done

exec /usr/local/bin/entrypoint "$@"
