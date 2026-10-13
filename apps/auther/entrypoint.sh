#!/bin/sh
# Auther entrypoint: self-provisions the Authelia identity provider on the
# node's persistent /config volume, renders the OIDC client registrations with
# hashed secrets, and execs Authelia with the static configuration plus the
# generated runtime config files. Runs as root (the platform drops all
# capabilities; PUID/PGID delegation is intentionally not supported here).
set -eu
umask 077

log() { printf 'auther-entrypoint: %s\n' "$*" >&2; }

# Idempotent bootstrap admin account. Rotate by deleting users_database.yml
# and recreating the container after changing AUTHER_BOOTSTRAP_ADMIN_PASSWORD.
if [ ! -s /config/users_database.yml ]; then
	[ -n "${AUTHER_BOOTSTRAP_ADMIN_PASSWORD:-}" ] || {
		log 'AUTHER_BOOTSTRAP_ADMIN_PASSWORD is not set'
		exit 1
	}
	digest="$(authelia crypto hash generate argon2 --password "$AUTHER_BOOTSTRAP_ADMIN_PASSWORD" --no-confirm | sed -n 's/^Digest: //p')"
	[ -n "$digest" ] || {
		log 'failed to generate the bootstrap admin argon2 digest'
		exit 1
	}
	{
		printf 'users:\n'
		printf '  admin:\n'
		printf '    displayname: Admin\n'
		printf '    password: %s\n' "$digest"
		printf '    email: admin@aichorage.de\n'
		printf '    groups:\n'
		printf '      - admins\n'
	} >/config/users_database.yml.tmp
	mv /config/users_database.yml.tmp /config/users_database.yml
	log 'generated /config/users_database.yml'
fi

# Idempotent RS256 signing key for OIDC ID tokens and the /jwks.json endpoint.
if [ ! -s /config/oidc-rsa-private.pem ]; then
	authelia crypto pair rsa generate --bits 2048 --directory /config --file.private-key oidc-rsa-private.pem --file.public-key oidc-rsa-public.pem >/dev/null
	log 'generated /config/oidc-rsa-private.pem'
fi

mkdir -p /run/auther

# The JWKS section embeds the private key; a block scalar must be indented
# past its parent key.
{
	printf 'identity_providers:\n  oidc:\n    jwks:\n      - key: |\n'
	sed 's/^/        /' /config/oidc-rsa-private.pem
} >/run/auther/jwks.yml

# Render the committed clients list, replacing every secret placeholder with
# a pbkdf2 digest of the matching environment secret. Authelia verifies the
# relying party's presented plaintext secret against this digest, so only the
# hashed form ever reaches a file.
cp /config-template/clients.yml /run/auther/clients.yml
for placeholder in $(sed -n 's/.*\(__AUTHER_OIDC_[A-Z0-9_]*_CLIENT_SECRET__\).*/\1/p' /run/auther/clients.yml | sort -u); do
	var_name="${placeholder%__}"
	var_name="${var_name#__AUTHER_}"
	eval "secret=\${$var_name:-}"
	[ -n "$secret" ] || {
		log "$var_name is not set"
		exit 1
	}
	digest="$(authelia crypto hash generate pbkdf2 --password "$secret" --no-confirm | sed -n 's/^Digest: //p')"
	case "$digest" in
	'$pbkdf2-sha512$'*) ;;
	*)
		log "unexpected pbkdf2 digest for $var_name"
		exit 1
		;;
	esac
	# Restrict the digest to characters that are literal in both the sed
	# replacement and the shell expansion below it.
	case "$digest" in
	*[!\$A-Za-z0-9+./-]*)
		log "digest for $var_name contains characters unsafe for substitution"
		exit 1
		;;
	esac
	sed -i "s|$placeholder|$digest|g" /run/auther/clients.yml
done

exec authelia "$@"
