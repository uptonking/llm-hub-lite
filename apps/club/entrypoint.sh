#!/bin/sh
set -eu
: "${SITE_URL:?SITE_URL must be set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"
mkdir -p /data/sqlite3 /data/cache /data/uploads /data/i18n

DB=/data/sqlite3/answer.db
schema_ready() {
	[ -f /data/conf/config.yaml ] || return 1
	rows="$(/usr/bin/sqlite3 "$DB" 'select count(*) from version;' 2>/dev/null || printf 0)"
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
			echo "club: answer init did not create the schema within ${waited}s" >&2
			exit 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
	kill "$init_pid" 2>/dev/null || true
	wait "$init_pid" 2>/dev/null || true
	echo "club: schema initialised in ${waited}s"
fi

sqlite() { /usr/bin/sqlite3 "$DB" "$1"; }
# Multi-statement scripts are fed on stdin: quoting a dozen statements through a
# single argument trips over the escape rules of both the shell and sqlite3.
sql_script() { /usr/bin/sqlite3 "$DB"; }
sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }
as_bool() {
	case "${1:-false}" in
	true | TRUE | True | 1 | yes | Yes | on | On) printf 'true' ;;
	*) printf 'false' ;;
	esac
}

# Site info, the rank config rows and every login token share the gob file at
# /data/cache/cache.db, so it may only be dropped when a policy really changed;
# dropping it logs every user out.
cache_stale=0

# json_extract reports booleans as 1/0, which keeps the comparisons below plain
# and avoids depending on the JSON1 -> and ->> operators.
site_field() { sqlite "select coalesce(json_extract(content, '\$$2'), '') from site_info where type = '$1';"; }

site_row_exists() { [ "$(sqlite "select count(*) from site_info where type = '$1';")" != "0" ]; }

# set_site_flag <type> <json path> <true|false>
set_site_flag() {
	if ! site_row_exists "$1"; then
		echo "club: site_info has no '$1' row yet; leaving it alone" >&2
		return 0
	fi
	want=0
	if [ "$3" = "true" ]; then
		want=1
	fi
	if [ "$(site_field "$1" "$2")" = "$want" ]; then
		return 0
	fi
	sqlite "update site_info set content = json_set(content, '\$$2', json('$3')) where type = '$1';"
	if [ "$(site_field "$1" "$2")" != "$want" ]; then
		echo "club: could not set $1$2 to $3" >&2
		exit 1
	fi
	echo "club: $1$2 = $3"
	cache_stale=1
}

config_value() { sqlite "select value from config where key = '$1';"; }

set_config_value() {
	if [ "$(config_value "$1")" = "$2" ]; then
		return 0
	fi
	sqlite "update config set value = '$2' where key = '$1';"
	if [ "$(config_value "$1")" != "$2" ]; then
		echo "club: could not set config $1 to $2" >&2
		exit 1
	fi
	echo "club: config $1 = $2"
	cache_stale=1
}

# Answer ships require_email_verification=true and club has no SMTP relay, so the
# activation mail is never delivered ("smtp host is empty, skip send email"). The
# account is still created, with mail_status=2 and rank=0, and MustAuth then
# rejects every authenticated request, so the forum cannot be used at all. Keep
# the setting aligned with the environment and repair accounts it already
# stranded.
apply_registration_policy() {
	require_verification="$(as_bool "${CLUB_REQUIRE_EMAIL_VERIFICATION:-false}")"
	allow_registrations="$(as_bool "${CLUB_ALLOW_NEW_REGISTRATIONS:-false}")"
	set_site_flag login .require_email_verification "$require_verification"
	# Club is a personal site: accounts are handed out from the admin panel and a
	# public sign-up form only invites noise. Existing accounts keep logging in
	# because allow_password_login stays true.
	set_site_flag login .allow_new_registrations "$allow_registrations"

	if [ "$require_verification" = "false" ]; then
		# Answer activates a user by awarding the "user.activated" reputation plus
		# an activity record. Replaying that turns previously unusable accounts
		# into ordinary members instead of leaving them half-provisioned.
		stranded="$(sqlite 'select count(*) from user where mail_status = 2 and rank = 0;')"
		case "$stranded" in
		'' | 0) ;;
		*)
			sql_script <<'SQL'
create temp table club_stranded as select id from user where mail_status = 2 and rank = 0;
insert into activity (created_at, updated_at, user_id, trigger_user_id, object_id, original_object_id, activity_type, cancelled, rank, has_rank, revision_id)
select datetime('now'), datetime('now'), u.id, 0, 0, 0, (select cast(id as integer) from config where key = 'user.activated'), 0, (select cast(value as integer) from config where key = 'user.activated'), 1, 0
from user u join club_stranded s on s.id = u.id
where not exists (select 1 from activity a where a.user_id = u.id and a.activity_type = (select cast(id as integer) from config where key = 'user.activated'));
update user set rank = rank + (select cast(value as integer) from config where key = 'user.activated') where id in (select id from club_stranded);
update user set mail_status = 1 where id in (select id from club_stranded);
drop table club_stranded;
SQL
			echo "club: activated $stranded previously stranded account(s)"
			cache_stale=1
			;;
		esac
	fi
}

# The stock "level 2" privilege set asks 750 reputation for creating a tag while
# the shipped content rules demand at least one tag per question, so a fresh
# member can neither tag nor post. Keep every other threshold as it is, lower
# only the tag threshold, and store the result as the "custom" level so the admin
# panel reports the values that are actually enforced.
# Same order as constant.RankAllPrivileges, so the admin panel lists the rows in
# the order it expects.
CLUB_PRIVILEGE_KEYS='rank.question.add rank.answer.add rank.comment.add rank.report.add
rank.comment.vote_up rank.link.url_limit rank.question.vote_up rank.answer.vote_up
rank.question.vote_down rank.answer.vote_down rank.answer.invite_someone_to_answer
rank.tag.add rank.tag.edit rank.question.edit rank.answer.edit
rank.question.edit_without_review rank.answer.edit_without_review rank.question.audit
rank.answer.audit rank.tag.audit rank.tag.edit_without_review rank.tag.synonym'

# All but one label follow "privilege.rank_<key>_label"; the exception is spelled
# out in internal/base/reason/privilege.go.
privilege_label() {
	if [ "$1" = "rank.answer.invite_someone_to_answer" ]; then
		printf '%s' 'privilege.rank_invite_someone_to_answer_label'
		return 0
	fi
	printf 'privilege.rank_%s_label' "$(printf '%s' "${1#rank.}" | tr '.' '_')"
}

apply_privileges_policy() {
	tag_rank="${CLUB_TAG_ADD_MIN_RANK:-1}"
	case "$tag_rank" in
	'' | *[!0-9]*)
		echo "club: CLUB_TAG_ADD_MIN_RANK must be a positive integer, got '$tag_rank'" >&2
		exit 1
		;;
	esac
	if [ "$tag_rank" -lt 1 ]; then
		# Privilege values validate as gte=1 and -1 would mean "nobody".
		echo "club: CLUB_TAG_ADD_MIN_RANK must be at least 1" >&2
		exit 1
	fi
	# checkUserRank reads the config row, not the site info document.
	set_config_value rank.tag.add "$tag_rank"

	privileges=''
	for key in $CLUB_PRIVILEGE_KEYS; do
		value="$(config_value "$key")"
		case "$value" in
		'' | *[!0-9]*)
			echo "club: config $key is missing or not a non-negative integer: '$value'" >&2
			exit 1
			;;
		esac
		[ -z "$privileges" ] || privileges="$privileges,"
		privileges="$privileges{\"key\":\"$key\",\"label\":\"$(privilege_label "$key")\",\"value\":$value}"
	done
	want="{\"level\":99,\"custom_privileges\":[$privileges]}"

	if ! site_row_exists privileges; then
		echo "club: site_info has no 'privileges' row yet; leaving it alone" >&2
		return 0
	fi
	if [ "$(sqlite "select content from site_info where type = 'privileges';")" = "$want" ]; then
		return 0
	fi
	sqlite "update site_info set content = '$want' where type = 'privileges';"
	if [ "$(site_field privileges .level)" != "99" ]; then
		echo "club: could not store the custom privilege level" >&2
		exit 1
	fi
	echo "club: privilege level custom, rank.tag.add = $tag_rank"
	cache_stale=1
}

# A brand new forum has no tags at all, so the question form offers an empty
# dropdown and the mandatory tag cannot be supplied. Seed a small starter set and
# flag it as recommended, which is what makes the selector list it before the
# member types. The loop is idempotent and never resurrects a tag that an admin
# deleted on purpose.
apply_tag_policy() {
	specs="${CLUB_BUILTIN_TAGS:-}"
	if [ -z "$specs" ]; then
		return 0
	fi
	author_id="$(sqlite 'select id from user order by id asc limit 1;')"
	case "$author_id" in
	'' | *[!0-9]*) author_id=1 ;;
	esac

	while IFS= read -r spec; do
		[ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || continue
		slug="$(printf '%s' "${spec%%|*}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
		rest="${spec#*|}"
		display="${rest%%|*}"
		description="${rest#*|}"
		[ "$description" != "$rest" ] || description="$display"
		case "$slug" in
		'' | *[!a-z0-9-]*)
			echo "club: skipping built-in tag with invalid slug '$slug'" >&2
			continue
			;;
		esac
		display="$(sql_quote "$display")"
		description="$(sql_quote "$description")"

		if [ "$(sqlite "select count(*) from tag where slug_name = '$slug';")" != "0" ]; then
			# Tags shipped by the installer are kept, only promoted to recommended
			# so the selector offers them without a search.
			if [ "$(sqlite "select recommend from tag where slug_name = '$slug';")" != "1" ]; then
				sqlite "update tag set recommend = 1 where slug_name = '$slug';"
				echo "club: promoted existing tag '$slug' to recommended"
				cache_stale=1
			fi
			continue
		fi
		# Mirror TagCommonService.AddTag: reserve an id from uniqid (type 3 is the
		# tag object), insert the tag, then a revision whose id is copied back.
		if ! sql_script <<SQL; then
insert into uniqid (uniqid_type) values (3);
insert into tag (id, created_at, updated_at, main_tag_id, main_tag_slug_name, slug_name, display_name, original_text, parsed_text, follow_count, question_count, status, recommend, reserved, revision_id, user_id)
values ('1003' || substr('0000000000000' || (select max(id) from uniqid where uniqid_type = 3), -13), datetime('now'), datetime('now'), 0, '', '$slug', '$display', '$description', '<p>$description</p>', 0, 0, 1, 1, 0, 0, $author_id);
insert into revision (created_at, updated_at, user_id, object_type, object_id, title, content, status, review_user_id)
select datetime('now'), datetime('now'), user_id, 3, id, slug_name, json_object(
'ID', cast(id as text), 'CreatedAt', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
'UpdatedAt', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
'MainTagID', 0, 'MainTagSlugName', '', 'SlugName', slug_name, 'DisplayName', display_name,
'OriginalText', original_text, 'ParsedText', parsed_text, 'FollowCount', 0, 'QuestionCount', 0,
'Status', 1, 'Recommend', json('true'), 'Reserved', json('false'), 'RevisionID', '0',
'UserID', cast(user_id as text)), 1, 0
from tag where slug_name = '$slug';
update tag set revision_id = (select max(id) from revision where object_type = 3 and object_id = (select id from tag where slug_name = '$slug')) where slug_name = '$slug';
SQL
			echo "club: could not seed built-in tag '$slug'" >&2
			exit 1
		fi
		echo "club: seeded built-in tag '$slug'"
		cache_stale=1
	done <<EOF
$(printf '%s' "$specs" | tr ';' '\n')
EOF
}

# site_info only stores the required flag; the recommended list the selector
# renders is read from the tag rows themselves.
apply_tag_settings_policy() {
	set_site_flag tags .required_tag "$(as_bool "${CLUB_REQUIRED_TAG:-false}")"
}

if ! timeout 300 /usr/bin/answer upgrade; then
	echo "club: answer upgrade failed" >&2
	exit 1
fi
rows="$(/usr/bin/sqlite3 "$DB" 'select count(*) from version;' 2>/dev/null || printf 0)"
case "$rows" in
'' | 0)
	echo "club: schema is missing; refusing to start in installer mode" >&2
	exit 1
	;;
esac
echo "club: schema version rows=$rows"
apply_registration_policy
apply_privileges_policy
apply_tag_policy
apply_tag_settings_policy
if [ "$cache_stale" -eq 1 ]; then
	rm -f /data/cache/cache.db /data/cache/cache.db-shm /data/cache/cache.db-wal
fi
exec /usr/bin/answer run -C /data/
