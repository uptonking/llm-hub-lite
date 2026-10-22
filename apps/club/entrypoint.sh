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
sqlite() { /usr/bin/sqlite3 /data/sqlite3/answer.db "$1"; }

# Answer seeds require_email_verification=true and, with no SMTP relay
# configured, the activation mail is never delivered: "smtp host is empty, skip
# send email". The account is created anyway with mail_status=2 and rank=0, and
# MustAuth then rejects every authenticated request, so the forum cannot be used
# at all. Keep the setting aligned with CLUB_REQUIRE_EMAIL_VERIFICATION and
# repair accounts that were already stranded by it.
apply_registration_policy() {
	case "${CLUB_REQUIRE_EMAIL_VERIFICATION:-false}" in
	true | TRUE | True | 1 | yes | Yes | on | On) want=1 ;;
	*) want=0 ;;
	esac
	cache_stale=0
	current="$(sqlite "select json_extract(content,'$.require_email_verification') from site_info where type='login';")"
	if [ "$current" != "$want" ]; then
		json_value=false
		if [ "$want" -eq 1 ]; then
			json_value=true
		fi
		sqlite "update site_info set content = json_set(content, '$.require_email_verification', json('$json_value')) where type = 'login';"
		current="$(sqlite "select json_extract(content,'$.require_email_verification') from site_info where type='login';")"
		if [ "$current" != "$want" ]; then
			echo "club: could not set require_email_verification to $json_value" >&2
			exit 1
		fi
		echo "club: require_email_verification set to $json_value"
		cache_stale=1
	fi
	if [ "$want" -eq 0 ]; then
		# Answer activates a user by awarding the "user.activated" reputation and
		# an activity record. Replaying that turns previously unusable accounts
		# into ordinary members instead of leaving them half-provisioned.
		stranded="$(sqlite 'select count(*) from user where mail_status = 2 and rank = 0;')"
		case "$stranded" in
		'' | 0) ;;
		*)
			sqlite "create temp table club_stranded as select id from user where mail_status = 2 and rank = 0;
insert into activity (created_at, updated_at, user_id, trigger_user_id, object_id, original_object_id, activity_type, cancelled, rank, has_rank, revision_id)
select datetime('now'), datetime('now'), u.id, 0, 0, 0, (select cast(id as integer) from config where key = 'user.activated'), 0, (select cast(value as integer) from config where key = 'user.activated'), 1, 0
from user u join club_stranded s on s.id = u.id
where not exists (select 1 from activity a where a.user_id = u.id and a.activity_type = (select cast(id as integer) from config where key = 'user.activated'));
update user set rank = rank + (select cast(value as integer) from config where key = 'user.activated') where id in (select id from club_stranded);
update user set mail_status = 1 where id in (select id from club_stranded);
drop table club_stranded;"
			echo "club: activated $stranded previously stranded account(s)"
			cache_stale=1
			;;
		esac
	fi
	# Site info and login tokens both live in the gob-backed cache.
	if [ "$cache_stale" -eq 1 ]; then
		rm -f /data/cache/cache.db /data/cache/cache.db-shm /data/cache/cache.db-wal
	fi
}

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
apply_registration_policy
exec /usr/bin/answer run -C /data/
