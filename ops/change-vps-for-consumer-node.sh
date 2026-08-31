#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2029
# SC2016: ssh_source/ssh_target run remote shell snippets; single-quoted
# strings intentionally keep '$...' literal so the *target* host expands it.
# SC2029: the wrappers pass "$@" as the remote command by design; callers are
# responsible for quoting (all remote calls below are single-quoted or have
# interpolated values nested inside escaped quotes).

set -Eeuo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
bootstrap_source="$repo_root/ops/bootstrap-vps.sh"

usage() {
	cat <<'EOF'
Usage: change-vps-for-consumer-node.sh [--dry-run] [--resume] [--assume-yes]
  [--strict-dns] [--backup-dir PATH] [--ssh-port PORT] [--known-hosts PATH] SOURCE_IP TARGET_IP

DNS records must already be updated. DNS results are advisory by default because
local VPN/proxy resolvers may synthesize answers; use --strict-dns to reject a
mismatch. The source is left stopped after a successful migration.
EOF
}
die() {
	printf 'migration: ERROR: %s\n' "$*" >&2
	exit 1
}
log() { printf 'migration: %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
sha256_file() { if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
valid_ipv4() {
	local ip="$1" octet old_ifs
	[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	old_ifs="$IFS"
	IFS=.
	for octet in $ip; do
		[[ "$octet" =~ ^[0-9]+$ && "$octet" -le 255 ]] || {
			IFS="$old_ifs"
			return 1
		}
	done
	IFS="$old_ifs"
}
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
csv_has() {
	local csv=",${1//[[:space:]]/},"
	[[ "$csv" == *",$2,"* ]]
}
valid_phase() {
	case "$1" in
	preflight | source-stopped | archive-created | local-copy-verified | target-copy-verified | target-extracted | bootstrap-complete | verification-complete) return 0 ;;
	*) return 1 ;;
	esac
}

dry_run=0
resume=0
assume_yes=0
strict_dns=0
ssh_port=22
backup_root="${HOME:-.}/backup-vps"
known_hosts="${HOME:-.}/.ssh/known_hosts"
while (($#)); do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--resume) resume=1 ;;
	--assume-yes) assume_yes=1 ;;
	--strict-dns) strict_dns=1 ;;
	--backup-dir)
		(($# >= 2)) || die '--backup-dir requires a path'
		backup_root="$2"
		shift
		;;
	--ssh-port)
		(($# >= 2)) || die '--ssh-port requires a port'
		ssh_port="$2"
		shift
		;;
	--known-hosts)
		(($# >= 2)) || die '--known-hosts requires a path'
		known_hosts="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage >&2
		die "unknown option: $1"
		;;
	*) break ;;
	esac
	shift
done
[[ $# -eq 2 ]] || {
	usage >&2
	exit 2
}
case "$backup_root" in /*) ;; *) backup_root="$PWD/$backup_root" ;; esac
source_ip="$1"
target_ip="$2"
valid_ipv4 "$source_ip" || die "invalid source IPv4 address: $source_ip"
valid_ipv4 "$target_ip" || die "invalid target IPv4 address: $target_ip"
[[ "$source_ip" != "$target_ip" ]] || die 'source and target addresses must differ'
[[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || die 'invalid SSH port'
case "$backup_root" in
/ | /bin | /boot | /dev | /etc | /home | /opt | /proc | /root | /run | /sbin | /sys | /tmp | /usr | /var | '' | *$'\n'* | *$'\r'*) die "unsafe backup directory: $backup_root" ;;
esac
[[ -L "$backup_root" ]] && die "backup directory must not be a symlink: $backup_root"
[[ -s "$known_hosts" ]] || die "known-hosts file is missing or empty: $known_hosts"
have ssh || die 'missing command: ssh'
have scp || die 'missing command: scp'
have tar || die 'missing command: tar'
have dig || die 'missing command: dig (DNS preflight is mandatory)'
have sha256sum || have shasum || die 'missing SHA-256 utility: sha256sum or shasum'

ssh_opts=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
scp_opts=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10)
ssh_source() { ssh "${ssh_opts[@]}" "root@$source_ip" "$@"; }
ssh_target() { ssh "${ssh_opts[@]}" "root@$target_ip" "$@"; }
scp_source() { scp "${scp_opts[@]}" "root@$source_ip:$1" "$2"; }
scp_target() { scp "${scp_opts[@]}" "$1" "root@$target_ip:$2"; }

state_file=''
run_dir=''
archive_local=''
phase=''
node_id=''
release_sha=''
leader_ip=''
domain=''
migration_succeeded=0
source_quiesce_attempted=0
print_source_recovery() {
	local recovery='platformctl maintenance end; for unit in /etc/systemd/system/platform-* /etc/systemd/system/platform.target; do [ -e "$unit" ] || continue; systemctl enable "${unit##*/}" >/dev/null 2>&1 || true; done; systemctl daemon-reload; systemctl enable --now platform.target'
	printf 'migration: source recovery (only if the old VPS must be restored):\n'
	printf '  ssh -p %q -o UserKnownHostsFile=%q root@%s %q\n' "$ssh_port" "$known_hosts" "$source_ip" "$recovery"
}
migration_exit() {
	local status="$?"
	if [[ "$status" -ne 0 && "$migration_succeeded" -ne 1 ]]; then
		if ((dry_run)); then
			printf 'migration: dry-run failed; no VPS state or local migration artifacts were changed\n' >&2
			return
		fi
		if [[ "$source_quiesce_attempted" == 1 ]] || phase_at_least source-stopped; then
			printf 'migration: FAILED during phase %s; source is intentionally not restarted\n' "${phase:-preflight}" >&2
			print_source_recovery >&2
		else
			printf 'migration: preflight failed; no VPS state was changed\n' >&2
		fi
		printf 'migration: retain %s and use --resume after correcting the cause\n' "${run_dir:-the migration directory}" >&2
	fi
}
trap migration_exit EXIT
set_phase() {
	phase="$1"
	valid_phase "$phase" || die "invalid migration phase: $phase"
	local temporary
	temporary="$(mktemp "$state_file.XXXXXX")"
	if ! {
		printf 'VERSION=2\nPHASE=%s\nSOURCE_IP=%s\nTARGET_IP=%s\nNODE_ID=%s\nRELEASE_SHA=%s\nLEADER_IP=%s\nDOMAIN=%s\nRUN_DIR=%s\nARCHIVE=%s\n' "$phase" "$source_ip" "$target_ip" "$node_id" "$release_sha" "$leader_ip" "$domain" "$run_dir" "$archive_local"
	} >"$temporary"; then
		rm -f -- "$temporary"
		die "unable to write migration state: $state_file"
	fi
	chmod 600 "$temporary"
	mv -f -- "$temporary" "$state_file"
}
phase_at_least() {
	local wanted="$1" order='preflight source-stopped archive-created local-copy-verified target-copy-verified target-extracted bootstrap-complete verification-complete' p n=-1 w=-1 i=0
	for p in $order; do
		[[ "$p" == "$phase" ]] && n="$i"
		[[ "$p" == "$wanted" ]] && w="$i"
		i=$((i + 1))
	done
	[[ "$n" -ge "$w" ]]
}
load_resume() {
	local candidate matches=0 version
	for candidate in "$backup_root"/*/migration.state; do
		[[ -f "$candidate" ]] || continue
		[[ ! -L "$candidate" ]] || continue
		if grep -Fqx "SOURCE_IP=$source_ip" "$candidate" && grep -Fqx "TARGET_IP=$target_ip" "$candidate"; then
			state_file="$candidate"
			matches=$((matches + 1))
		fi
	done
	[[ "$matches" -eq 1 ]] || die "--resume requires exactly one matching migration.state (found $matches)"
	version="$(sed -n 's/^VERSION=//p' "$state_file" | tail -n1)"
	phase="$(sed -n 's/^PHASE=//p' "$state_file" | tail -n1)"
	node_id="$(sed -n 's/^NODE_ID=//p' "$state_file" | tail -n1)"
	release_sha="$(sed -n 's/^RELEASE_SHA=//p' "$state_file" | tail -n1)"
	leader_ip="$(sed -n 's/^LEADER_IP=//p' "$state_file" | tail -n1)"
	domain="$(sed -n 's/^DOMAIN=//p' "$state_file" | tail -n1)"
	run_dir="$(sed -n 's/^RUN_DIR=//p' "$state_file" | tail -n1)"
	archive_local="$(sed -n 's/^ARCHIVE=//p' "$state_file" | tail -n1)"
	[[ "$version" == 2 ]] || die 'unsupported migration state version'
	valid_phase "$phase" || die "invalid migration phase in state: $phase"
	run_name="${run_dir##*/}"
	[[ -d "$run_dir" && ! -L "$run_dir" && "$run_dir" == "$backup_root"/migration-* && "$run_name" =~ ^migration-[A-Za-z0-9._-]+$ && "$archive_local" == "$run_dir/node-migration.tar.gz" && "$node_id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'resume metadata or artifacts are invalid'
	valid_sha "$release_sha" || die 'resume release SHA is invalid'
	valid_ipv4 "$leader_ip" || die 'resume Leader IP is invalid'
	[[ -n "$domain" && "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'resume domain is invalid'
	if phase_at_least local-copy-verified; then
		[[ -s "$archive_local" && -s "$archive_local.sha256" ]] || die 'resume archive artifacts are missing'
	fi
}
if ((resume)); then
	load_resume
else
	run_name="migration-$(date -u '+%Y%m%dT%H%M%SZ')-${source_ip//./-}-to-${target_ip//./-}"
	run_dir="$backup_root/$run_name"
	[[ ! -e "$run_dir" ]] || die "migration run already exists: $run_dir"
	state_file="$run_dir/migration.state"
	archive_local="$run_dir/node-migration.tar.gz"
fi

node_value() { ssh_source "sed -n 's/^$1=//p' /etc/llm-hub-lite/node.env 2>/dev/null | tail -n1"; }
discover_source_origins() {
	# A consumer manifest may expose one origin (singleton apps) or several
	# origins (LibreChat's public and admin routes). Read route groups so every
	# enabled origin on the node is checked before DNS cutover.
	ssh_source "node_id='$node_id' bash -s" <<'REMOTE_ORIGIN_DISCOVERY'
set -Eeuo pipefail
current=/opt/platform/control/current
node_file=/etc/llm-hub-lite/node.env
csv_has() { case ",${1//[[:space:]]/}," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
for manifest in "$current"/apps/*/manifest.env; do
	[ -f "$manifest" ] || continue
	app="${manifest%/manifest.env}"
	app="${app##*/}"
	rel="$(sed -n 's/^POLICY_FILE=//p' "$manifest" | tail -n1)"
	policy="$current/config/$rel"
	[ "$(sed -n 's/^ENABLED=//p' "$policy" | tail -n1)" = true ] || continue
	nodes="$(sed -n 's/^NODES=//p' "$policy" | tail -n1)"
	csv_has "$nodes" "$node_id" || continue
	groups="$(sed -n 's/^ROUTE_GROUPS=//p' "$manifest" | tail -n1)"
	[ -n "$groups" ] || continue
	while IFS= read -r group; do
		[ -n "$group" ] || continue
		IFS='|' read -r public_key origin_key upstream_key <<EOF_GROUP
$group
EOF_GROUP
		printf '%s\n' "$origin_key" | grep -Eq '^[A-Z][A-Z0-9_]*$' || {
			printf 'invalid origin key for %s: %s\n' "$app" "$origin_key" >&2
			exit 1
		}
		origin="$(sed -n "s/^$origin_key=//p" "$node_file" | tail -n1)"
		[ -n "$origin" ] || {
			printf 'missing origin value for %s/%s\n' "$app" "$origin_key" >&2
			exit 1
		}
		printf '%s\t%s\t%s\n' "$origin" "$app" "${public_key:-route}"
	done <<EOF_GROUPS
$(printf '%s\n' "$groups" | tr ';' '\n')
EOF_GROUPS
done | sort -u
REMOTE_ORIGIN_DISCOVERY
}
if ! phase_at_least preflight || [[ "$resume" == 1 && "$phase" == preflight ]]; then
	log 'checking source and target SSH identity, policy, health, storage, and DNS'
	ssh_source 'true' >/dev/null
	ssh_target 'true' >/dev/null
	source_arch="$(ssh_source 'uname -m')"
	target_arch="$(ssh_target 'uname -m')"
	[[ "$source_arch" == "$target_arch" ]] || die "architecture mismatch: source=$source_arch target=$target_arch"
	node_id="$(node_value NODE_ID)"
	node_state="$(node_value NODE_STATE)"
	[[ "$node_id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'source node identity is missing or invalid'
	[[ "$node_state" == active ]] || die "source node must be active (found $node_state)"
	leader_node_id="$(ssh_source "sed -n 's/^LEADER_NODE_ID=//p' /opt/platform/control/current/config/cluster/policy.env 2>/dev/null | tail -n1")"
	[[ -n "$leader_node_id" && "$node_id" != "$leader_node_id" ]] || die 'refusing to migrate the Leader node'
	inventory_state="$(ssh_source "sed -n 's/^NODE_STATE=//p' /opt/platform/control/current/config/cluster/nodes/$node_id.env 2>/dev/null | tail -n1")"
	[[ "$inventory_state" == active ]] || die "source inventory is not active: $inventory_state"
	release_sha="$(ssh_source "readlink /opt/platform/control/current 2>/dev/null | sed 's#.*/##'")"
	valid_sha "$release_sha" || die 'source current release is not a full Git SHA'
	leader_ip="$(node_value LEADER_PUBLIC_IP)"
	valid_ipv4 "$leader_ip" || leader_ip="$(ssh_source "sed -n 's/^LEADER_PUBLIC_IP=//p' /opt/platform/control/current/config/cluster/nodes/leader.env 2>/dev/null | tail -n1")"
	valid_ipv4 "$leader_ip" || die 'unable to discover the Leader public IPv4 address'
	domain="$(ssh_source "sed -n 's/^DOMAIN_NAME=//p' /opt/apps/llm-hub-lite/shared/.env.prod 2>/dev/null | tail -n1")"
	domain="${domain:-aichorage.de}"
	printf '%s\n' "$domain" | grep -Eq '^[A-Za-z0-9.-]+$' || die 'invalid configured domain'
	# Let platformctl hold the read lock while it checks health. This both waits
	# for an in-flight deployment to finish and closes the race where a new
	# transaction starts between a separate lock probe and the health call.
	if ! ssh_source 'PLATFORM_READ_LOCK_WAIT=120 platformctl health >/dev/null'; then
		die 'source has an active deployment or platform transaction, or is unhealthy; retry after it finishes'
	fi
	if ssh_target 'test -e /opt/platform || test -L /opt/platform || test -e /opt/apps/llm-hub-lite || test -L /opt/apps/llm-hub-lite || test -e /etc/llm-hub-lite || test -L /etc/llm-hub-lite'; then die 'target is not a fresh VPS (managed roots were found)'; fi
	if ssh_target 'command -v docker >/dev/null 2>&1 && test -n "$(docker ps -aq --filter label=com.aichorage.platform=llm-hub-lite 2>/dev/null)"'; then die 'target is not a fresh VPS (managed containers were found)'; fi
	if ssh_target 'test -e /root/llm-hub-lite-bootstrap.sh || test -e /root/backup-vps || test -e /opt/backups/llm-hub-lite || test -L /opt/backups/llm-hub-lite || for path in /etc/systemd/system/platform-*; do test -e "$path" && exit 0; done; command -v docker >/dev/null 2>&1 && docker network ls --format "{{.Name}}" 2>/dev/null | grep -Eq "^(platform_edge|foundation-(woodpecker|observer)_private|app-[a-z0-9-]+_private)$"'; then die 'target is not a fresh VPS (bootstrap artifacts, platform units, backup state, or networks were found)'; fi
	ssh_source 'check_root(){ case "$1" in ""|/opt/apps/llm-hub-lite|/opt/apps/llm-hub-lite/*|/opt/platform|/opt/platform/*) return 0;; *) printf "unsupported managed data root: %s\n" "$1" >&2; return 1;; esac; }; check_restic_path(){ case "$1" in ""|auto|false|true|s3:*|rest:*|b2:*|rclone:*|azure:*|gs:*|swift:*|sftp:*) return 0;; /opt/apps/llm-hub-lite|/opt/apps/llm-hub-lite/*|/opt/platform|/opt/platform/*|/etc/llm-hub-lite|/etc/llm-hub-lite/*) printf "Restic path is inside an archived managed root: %s\n" "$1" >&2; return 1;; esac; }; for spec in "/opt/apps/llm-hub-lite/shared/.env.prod:DATA_ROOT" "/opt/platform/foundation/env/caddy.env:CADDY_DATA_ROOT" "/opt/platform/foundation/env/woodpecker.env:WOODPECKER_DATA_ROOT" "/opt/platform/foundation/env/beszel.env:BESZEL_DATA_ROOT" "/opt/platform/foundation/env/observer.env:OBSERVER_DATA_ROOT"; do file=${spec%%:*}; key=${spec#*:}; [ -r "$file" ] || continue; value=$(sed -n "s/^$key=//p" "$file" | tail -n1); check_root "$value" || exit 1; done; for file in /etc/llm-hub-lite/platform.env /opt/apps/llm-hub-lite/shared/.env.prod; do [ -r "$file" ] || continue; for key in RESTIC_REPOSITORY RESTIC_CACHE_DIR RESTIC_STAGE_ROOT BACKUP_ROOT; do value=$(sed -n "s/^$key=//p" "$file" | tail -n1); check_restic_path "$value" || exit 1; done; done'
	managed_kb="$(ssh_source 'total=0; for path in /opt/apps/llm-hub-lite /opt/platform /etc/llm-hub-lite; do set -- $(du -sk -x "$path" 2>/dev/null || true); case "${1:-}" in *[!0-9]*|"") ;; *) total=$((total + $1));; esac; done; printf "%s\n" "$total"')"
	[[ "$managed_kb" =~ ^[0-9]+$ ]] || die 'unable to estimate managed state size'
	source_required_kb=$((managed_kb * 2 + 1048576))
	target_required_kb=$((managed_kb * 3 + 1048576))
	local_required_kb=$((managed_kb + managed_kb / 2 + 1048576))
	source_free_kb="$(ssh_source "df -Pk /var/tmp | tail -n 1 | tr -s ' ' | cut -d ' ' -f 4")"
	target_free_kb="$(ssh_target "df -Pk /root /opt | awk 'NR>1 { if (\$4 ~ /^[0-9]+$/ && (min == \"\" || \$4 < min)) min=\$4 } END {print min}'")"
	local_free_kb="$(df -Pk "$(dirname "$backup_root")" | awk 'NR==2 {print $4}')"
	[[ "$source_free_kb" =~ ^[0-9]+$ && "$source_free_kb" -ge "$source_required_kb" ]] || die 'source has insufficient free space for the migration archive'
	[[ "$target_free_kb" =~ ^[0-9]+$ && "$target_free_kb" -ge "$target_required_kb" ]] || die 'target has insufficient free space for staging and extraction'
	[[ "$local_free_kb" =~ ^[0-9]+$ && "$local_free_kb" -ge "$local_required_kb" ]] || die 'local backup volume has insufficient free space'
	active_origins="$(discover_source_origins)"
	[[ -n "$active_origins" ]] || die 'no active origin records were discovered'
	while IFS='	' read -r origin app route; do
		[[ "$origin" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid origin hostname for $app"
		resolved_a="$(dig +short A "$origin" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
		resolved_aaaa="$(dig +short AAAA "$origin" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
		log "DNS: $origin ($app/${route:-route}) A=${resolved_a:-<none>} AAAA=${resolved_aaaa:-<none>}"
		if ! printf '%s\n' "$resolved_a" | tr ' ' '\n' | grep -Fxq "$target_ip" || [[ -n "$resolved_aaaa" ]]; then
			if ((strict_dns)); then
				die "DNS for $origin does not match target $target_ip (A: ${resolved_a:-<none>}; AAAA: ${resolved_aaaa:-<none>})"
			fi
			log "WARNING: DNS for $origin did not resolve cleanly to $target_ip (A: ${resolved_a:-<none>}; AAAA: ${resolved_aaaa:-<none>}); continuing because DNS checks are advisory"
		fi
	done <<<"$active_origins"
	observer_origin="observer-ingest.$domain"
	observer_a="$(dig +short A "$observer_origin" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
	if ! printf '%s\n' "$observer_a" | tr ' ' '\n' | grep -Fxq "$leader_ip"; then
		if ((strict_dns)); then
			die "$observer_origin does not resolve directly to Leader $leader_ip (A: ${observer_a:-<none>})"
		fi
		log "WARNING: $observer_origin did not resolve to Leader $leader_ip (A: ${observer_a:-<none>}); continuing because DNS checks are advisory"
	fi
	if ((dry_run)); then
		phase=preflight
	else
		mkdir -p "$backup_root" "$run_dir"
		chmod 700 "$backup_root" "$run_dir"
		set_phase preflight
	fi
else
	ssh_source 'true' >/dev/null
	ssh_target 'true' >/dev/null
	[[ "$(node_value NODE_ID)" == "$node_id" ]] || die 'source node identity changed while resuming'
fi
if ((dry_run)); then
	log "preflight passed for follower $node_id ($source_ip -> $target_ip)"
	log 'no source, target, DNS, or local migration state was changed'
	exit 0
fi
if [[ "$assume_yes" != 1 && ! -t 0 ]]; then die 'non-interactive migration requires --assume-yes'; fi
if [[ "$assume_yes" != 1 ]]; then
	printf 'This will stop %s, copy managed state, and leave the source stopped. Continue? [y/N] ' "$source_ip"
	read -r answer
	[[ "$answer" == y || "$answer" == Y ]] || die 'migration cancelled'
fi

if ! phase_at_least source-stopped; then
	log 'quiescing source services under the platform lock'
	source_quiesce_attempted=1
	ssh_source 'set -Eeuo pipefail; exec 9>/run/lock/llm-hub-lite/platform.lock; flock -w 120 -x 9 || { printf "timed out waiting for source platform lock\n" >&2; exit 1; }; export PLATFORM_LOCK_HELD=1; platformctl maintenance begin vps-migration; for unit in /etc/systemd/system/platform-* /etc/systemd/system/platform.target; do [ -e "$unit" ] || continue; systemctl disable --now "${unit##*/}" >/dev/null 2>&1 || true; done; platformctl stop all; sync; test -z "$(docker ps --filter label=com.aichorage.platform=llm-hub-lite -q)"'
	set_phase source-stopped
fi
archive_remote="/var/tmp/llm-hub-lite-${node_id}-$(basename "$run_dir").tar.gz"
target_dir="/root/backup-vps/$(basename "$run_dir")"
verify_local_archive() {
	local expected
	[[ -s "$archive_local" && -s "$archive_local.sha256" ]] || die 'local archive artifacts are missing'
	expected="$(sed 's/[[:space:]].*//' "$archive_local.sha256")"
	[[ "$expected" == "$(sha256_file "$archive_local")" ]] || die 'local archive checksum mismatch'
	tar -tzf "$archive_local" >/dev/null || die 'local migration archive is unreadable'
}
verify_target_archive() {
	ssh_target "test -s '$target_dir/node-migration.tar.gz' -a -s '$target_dir/node-migration.tar.gz.sha256'; expected=\$(sed 's/[[:space:]].*//' '$target_dir/node-migration.tar.gz.sha256'); actual=\$(sha256sum '$target_dir/node-migration.tar.gz' | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""
}
verify_target_identity() {
	ssh_target "test \"\$(sed -n 's/^NODE_ID=//p' /etc/llm-hub-lite/node.env | tail -n1)\" = '$node_id'; test \"\$(readlink /opt/platform/control/current | sed 's#.*/##')\" = '$release_sha'"
}
verify_target_health() {
	local attempt
	# Bootstrap enables the recovery timer before this final check. Recovery and
	# read-only health share the platform lock, so allow a full recovery pass to
	# finish and retry instead of treating lock contention as service failure.
	for attempt in 1 2 3 4; do
		if ssh_target 'PLATFORM_READ_LOCK_WAIT=120 platformctl health >/dev/null'; then
			return 0
		fi
		if ((attempt < 4)); then
			log "target health check was busy or failed; retrying (${attempt}/4)"
			sleep 5
		fi
	done
	die 'target platform health did not pass after retries; inspect target platformctl diagnose output'
}
if phase_at_least local-copy-verified; then verify_local_archive; fi
if phase_at_least target-copy-verified; then verify_target_archive; fi
if phase_at_least target-extracted; then verify_target_identity; fi
if ! phase_at_least archive-created; then
	log 'creating the managed-state archive on the stopped source'
	ssh_source "set -Eeuo pipefail; archive='$archive_remote'; if [ -s \"\$archive\" ] && [ -s \"\$archive.sha256\" ] && [ \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\" ]; then exit 0; fi; rm -f \"\$archive\" \"\$archive.sha256\"; tar --ignore-failed-read --numeric-owner --xattrs --acls --selinux -czf \"\$archive\" -C / --exclude='collector-buffer' --exclude='collector-buffer/*' --exclude='opt/platform/observer/collector-buffer' --exclude='opt/platform/*/collector-buffer' --exclude='opt/platform/*/*/collector-buffer' --exclude='opt/platform/*restic*' --exclude='opt/platform/*/restic*' --exclude='etc/llm-hub-lite/maintenance' --exclude='etc/llm-hub-lite/node-retirement.*' --exclude='etc/llm-hub-lite/firewall-reconcile.request' --exclude='opt/apps/llm-hub-lite/shared/runtime/transaction.*' --exclude='opt/platform/control/*/transaction.*' --exclude='opt/apps/llm-hub-lite/shared/logs' opt/apps/llm-hub-lite opt/platform etc/llm-hub-lite; chown root:root \"\$archive\"; chmod 600 \"\$archive\"; (cd /var/tmp && sha256sum \"\$(basename \"\$archive\")\" >\"\$(basename \"\$archive\").sha256\"); test \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\""
	set_phase archive-created
fi
if ! phase_at_least local-copy-verified; then
	log 'verifying the local checksum and archive manifest'
	archive_partial="$archive_local.partial.$$"
	checksum_partial="$archive_local.sha256.partial.$$"
	rm -f -- "$archive_partial" "$checksum_partial"
	scp_source "$archive_remote" "$archive_partial"
	scp_source "$archive_remote.sha256" "$checksum_partial"
	chmod 600 "$archive_partial" "$checksum_partial"
	expected_hash="$(sed 's/[[:space:]].*//' "$checksum_partial")"
	[[ "$expected_hash" == "$(sha256_file "$archive_partial")" ]] || die 'local archive checksum mismatch'
	mv -f -- "$archive_partial" "$archive_local"
	mv -f -- "$checksum_partial" "$archive_local.sha256"
	tar -tzf "$archive_local" >"$run_dir/manifest.txt"
	chmod 600 "$run_dir/manifest.txt"
	grep -Eq '^etc/llm-hub-lite/node\.env$' "$run_dir/manifest.txt" || die 'archive is missing the source node identity'
	grep -Eq "^opt/platform/control/releases/$release_sha(/|$)" "$run_dir/manifest.txt" || die 'archive is missing the source current release'
	while IFS= read -r link_target; do
		case "$link_target" in
		/opt/apps/llm-hub-lite | /opt/apps/llm-hub-lite/* | /opt/platform | /opt/platform/* | /etc/llm-hub-lite | /etc/llm-hub-lite/*) ;;
		/* | *'..'*) die "unsafe archive symlink target: $link_target" ;;
		esac
	done < <(tar -tvzf "$archive_local" | awk '/^l/ { sub(/^.* -> /, ""); print }')
	while IFS= read -r path; do
		case "$path" in opt/apps/llm-hub-lite | opt/apps/llm-hub-lite/* | opt/platform | opt/platform/* | etc/llm-hub-lite | etc/llm-hub-lite/*) ;; *) die "unexpected archive path: $path" ;; esac
		case "$path" in /* | *'..'*) die "unsafe archive path: $path" ;; esac
		case "$path" in */collector-buffer | */collector-buffer/*) die "excluded collector buffer leaked into archive: $path" ;; esac
	done <"$run_dir/manifest.txt"
	set_phase local-copy-verified
fi
if ! phase_at_least target-copy-verified; then
	log 'copying the verified archive to the fresh target'
	ssh_target "install -d -m 700 '$target_dir'"
	scp_target "$archive_local" "$target_dir/node-migration.tar.gz"
	scp_target "$archive_local.sha256" "$target_dir/node-migration.tar.gz.sha256"
	ssh_target "chmod 600 '$target_dir/'*; expected=\$(sed 's/[[:space:]].*//' '$target_dir/node-migration.tar.gz.sha256'); actual=\$(sha256sum '$target_dir/node-migration.tar.gz' | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""
	set_phase target-copy-verified
fi
if ! phase_at_least target-extracted; then
	log 'validating and extracting managed state on the target'
	ssh_target "set -Eeuo pipefail; stage='$target_dir/stage'; rm -rf \"\$stage\"; install -d -m 700 \"\$stage\"; tar -xzf '$target_dir/node-migration.tar.gz' -C \"\$stage\" --no-same-owner; test \"\$(sed -n 's/^NODE_ID=//p' \"\$stage/etc/llm-hub-lite/node.env\" | tail -n1)\" = '$node_id'; test \"\$(readlink \"\$stage/opt/platform/control/current\" | sed 's#.*/##')\" = '$release_sha'; tar -xzf '$target_dir/node-migration.tar.gz' -C / --same-owner --numeric-owner --xattrs --acls --selinux; rm -rf \"\$stage\""
	set_phase target-extracted
fi
if ! phase_at_least bootstrap-complete; then
	log 'installing and running the exact repair bootstrap on the target'
	[[ -s "$bootstrap_source" ]] || die "bootstrap script is missing: $bootstrap_source"
	bootstrap_local="$run_dir/bootstrap-vps.sh"
	cp "$bootstrap_source" "$bootstrap_local"
	chmod 600 "$bootstrap_local"
	bootstrap_hash="$(sha256_file "$bootstrap_local")"
	scp_target "$bootstrap_local" /root/llm-hub-lite-bootstrap.sh
	ssh_target "chmod 700 /root/llm-hub-lite-bootstrap.sh; test \"\$(sha256sum /root/llm-hub-lite-bootstrap.sh | sed 's/[[:space:]].*//')\" = '$bootstrap_hash'"
	ssh_target "NODE_ID='$node_id' LEADER_PUBLIC_IP='$leader_ip' DOMAIN_NAME='$domain' BOOTSTRAP_MODE=repair BOOTSTRAP_ASSUME_YES=1 BOOTSTRAP_SKIP_SOURCE_UPDATE=1 BOOTSTRAP_SKIP_POST_BACKUP=1 BOOTSTRAP_RELEASE_SHA='$release_sha' /root/llm-hub-lite-bootstrap.sh"
	set_phase bootstrap-complete
fi
if ! phase_at_least verification-complete; then
	log 'verifying target platform health and source shutdown'
	ssh_target "test \"\$(sed -n 's/^NODE_ID=//p' /etc/llm-hub-lite/node.env | tail -n1)\" = '$node_id'; test \"\$(readlink /opt/platform/control/current | sed 's#.*/##')\" = '$release_sha'"
	verify_target_health
	ssh_source 'test -z "$(docker ps --filter label=com.aichorage.platform=llm-hub-lite -q)"; test -f /etc/llm-hub-lite/maintenance'
	set_phase verification-complete
fi
migration_succeeded=1
log "migration complete for $node_id"
log "archive retained at $run_dir; remove it manually after verification"
log 'on the old VPS, copy ops/clean-vps.sh outside managed paths and run it manually'
