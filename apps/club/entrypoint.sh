#!/bin/sh
set -eu
: "${SITE_URL:?SITE_URL must be set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"
mkdir -p /data/sqlite3 /data/cache /data/uploads /data/i18n
schema_ready() {
	[ -f /data/conf/config.yaml ] || return 1
	rows="$(/usr/bin/sqlite3 /data/sqlite3/answer.db 'select count(*) from version;' 2>/dev/null || printf 0)"
	case "$rows" in
	'' | 0 | *[!0-9]*) return 1 ;;
	esac
	[ "$rows" -gt 0 ]
}
# "answer init" falls back to the interactive installer when it cannot install
# from the environment, and that fallback also answers GET /healthz. Gate on the
# real schema instead of trusting the process exit code.
if ! schema_ready; then
	echo "club: initialising Apache Answer from the environment"
	/usr/bin/answer init &
	init_pid=$!
	waited=0
	until schema_ready; do
		if ! kill -0 "$init_pid" 2>/dev/null; then
			wait "$init_pid" || true
			echo "club: answer init exited before creating the schema" >&2
			exit 1
		fi
		if [ "$waited" -ge 120 ]; then
			kill "$init_pid" 2>/dev/null || true
			wait "$init_pid" 2>/dev/null || true
			echo "club: answer init did not create the schema within 180s" >&2
			exit 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
	kill "$init_pid" 2>/dev/null || true
	wait "$init_pid" 2>/dev/null || true
	echo "club: schema initialised in ${waited}s"
fi
if ! timeout 300 /usr/bin/answer upgrade; then
	echo "club: answer upgrade failed" >&2
	exit 1
fi
rows="$(/usr/bin/sqlite3 /data/sqlite3/answer.db 'select count(*) from version;' 2>/dev/null || printf 0)"
case "$rows" in
'' | 0)
	echo "club: schema is missing; refusing to start in installer mode" >&2
	exit 1
	;;
esac
echo "club: schema version rows=$rows"
exec /usr/bin/answer run -C /data/
