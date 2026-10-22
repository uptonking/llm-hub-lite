#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/apps/club"

grep -q '^APP_ID=club$' "$app/manifest.env"
grep -q '^UPSTREAM_MODE=singleton$' "$app/manifest.env"
grep -q '^STATE_MODE=sqlite$' "$app/manifest.env"
grep -q '^SQLITE_PATHS=sqlite3/answer.db$' "$app/manifest.env"
grep -q '^HEALTH_URL=/answer/api/v1/siteinfo$' "$app/manifest.env"
grep -q '^HEALTH_PORT=80$' "$app/manifest.env"
grep -q '^ENABLED=true$' "$repo_root/config/cluster/apps/club.policy"
grep -q '^NODES=worker-1$' "$repo_root/config/cluster/apps/club.policy"

# Keep the single-node footprint minimal and free of external data services.
# shellcheck disable=SC2016
grep -Fq 'mem_limit: ${CLUB_MEMORY_LIMIT:-384m}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'cpus: ${CLUB_CPUS:-0.5}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq 'pids_limit: ${CLUB_PIDS_LIMIT:-256}' "$app/compose.yml"
# shellcheck disable=SC2016
grep -Fq '${DATA_ROOT:-/opt/apps/llm-hub-lite/shared/data/prod}/club:/data' "$app/compose.yml"
if grep -Eiq 'redis|postgres|mysql' "$app/compose.yml"; then
	printf 'club must stay on embedded SQLite storage\n' >&2
	exit 1
fi
[[ -x "$app/entrypoint.sh" ]]
grep -Fq 'answer init &' "$app/entrypoint.sh"
grep -Fq 'answer upgrade' "$app/entrypoint.sh"
grep -Fq 'exec /usr/bin/answer run -C /data/' "$app/entrypoint.sh"
grep -Fq 'select count(*) from version;' "$app/entrypoint.sh"
# The entrypoint may only require variables Compose actually passes into the
# container; CLUB_SITE is interpolated at render time and is not present at runtime.
grep -Fq "\${SITE_URL:?SITE_URL must be set}" "$app/entrypoint.sh"
grep -Fq "\${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}" "$app/entrypoint.sh"

# Answer ships require_email_verification=true, but club has no SMTP relay, so the
# activation mail is never delivered and new accounts stay permanently inactive.
grep -q '^CLUB_REQUIRE_EMAIL_VERIFICATION=false$' "$app/config.env"
grep -Fq 'CLUB_REQUIRE_EMAIL_VERIFICATION' "$app/manifest.env"
grep -Fq 'apply_registration_policy' "$app/entrypoint.sh"
grep -Fq 'set_site_flag login .require_email_verification' "$app/entrypoint.sh"
grep -Fq 'from user where mail_status = 2 and rank = 0' "$app/entrypoint.sh"

# Club is a personal site: sign-up stays closed while existing accounts keep
# logging in with their password.
grep -q '^CLUB_ALLOW_NEW_REGISTRATIONS=false$' "$app/config.env"
grep -Fq 'CLUB_ALLOW_NEW_REGISTRATIONS' "$app/manifest.env"
grep -Fq 'CLUB_ALLOW_NEW_REGISTRATIONS' "$app/compose.yml"
grep -Fq 'set_site_flag login .allow_new_registrations' "$app/entrypoint.sh"

# Answer asks 750 reputation to create a tag while the posting rules require at
# least one tag per question, so a fresh member cannot do either.
grep -q '^CLUB_TAG_ADD_MIN_RANK=1$' "$app/config.env"
grep -Fq 'CLUB_TAG_ADD_MIN_RANK' "$app/manifest.env"
grep -Fq 'CLUB_TAG_ADD_MIN_RANK' "$app/compose.yml"
grep -Fq 'apply_privileges_policy' "$app/entrypoint.sh"
grep -Fq 'set_config_value rank.tag.add' "$app/entrypoint.sh"
grep -Fq 'rank.answer.invite_someone_to_answer' "$app/entrypoint.sh"
grep -Fq 'privilege.rank_invite_someone_to_answer_label' "$app/entrypoint.sh"
# The admin panel only reports the enforced thresholds when the values are
# stored as the custom privilege level.
grep -Fq '\"level\":99' "$app/entrypoint.sh"

# A new forum has no tags at all, so the mandatory tag cannot be supplied.
grep -q '^CLUB_REQUIRED_TAG=' "$app/config.env"
grep -q '^CLUB_BUILTIN_TAGS=' "$app/config.env"
grep -Fq 'CLUB_BUILTIN_TAGS' "$app/manifest.env"
grep -Fq 'CLUB_BUILTIN_TAGS' "$app/compose.yml"
grep -Fq 'apply_tag_policy' "$app/entrypoint.sh"
grep -Fq 'apply_tag_settings_policy' "$app/entrypoint.sh"
grep -Fq 'insert into uniqid (uniqid_type) values (3);' "$app/entrypoint.sh"
# Tags are addressed by the composed 1003-prefixed object id, and Answer reads
# the recommend flag from the tag row rather than from site info.
grep -Fq "'1003' || substr('0000000000000'" "$app/entrypoint.sh"
grep -Fq 'set recommend = 1 where slug_name' "$app/entrypoint.sh"
grep -Fq 'set_site_flag tags .required_tag' "$app/entrypoint.sh"

# Never let the installer fallback pass the container health check.
grep -Fq 'http://127.0.0.1:80/answer/api/v1/siteinfo' "$app/compose.yml"
grep -Fq 'health_uri /answer/api/v1/siteinfo' "$app/route.leader.caddy"
grep -Fq 'reverse_proxy club:80' "$app/route.follower.caddy"
grep -Fq 'tls internal' "$app/route.follower.caddy"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy {$CLUB_UPSTREAM}' "$app/route.leader.caddy"

for node in leader worker-1 worker-2 worker-3 worker-4 worker-5; do
	prefix="${node/-/}"
	grep -q "^NODE_CLUB_ORIGIN_HOST=${prefix}-club-origin.aichorage.de$" \
		"$repo_root/config/cluster/nodes/$node.env"
done

for workflow in \
	consumer-stage-club-worker-1.yml consumer-publish-club.yml \
	consumer-finalize-club-worker-1.yml consumer-secrets-club-worker-1.yml \
	consumer-stop-club-worker-2.yml consumer-stop-club-worker-3.yml \
	consumer-stop-club-worker-4.yml consumer-stop-club-worker-5.yml; do
	[[ -f "$repo_root/.woodpecker/$workflow" ]]
done
printf 'club application contract is valid\n'
