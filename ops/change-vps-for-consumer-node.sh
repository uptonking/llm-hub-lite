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
  [--strict-dns] [--disable-restic-backup] [--backup-dir PATH]
  [--transfer-mode local|direct] [--ssh-port PORT] [--known-hosts PATH]
  SOURCE_IP TARGET_IP

DNS records must already be updated. DNS results are advisory by default because
local VPN/proxy resolvers may synthesize answers; use --strict-dns to reject a
mismatch. The source is left stopped after a successful migration.

--disable-restic-backup requires BACKUP_ENABLED=false in the source's committed
node descriptor, disables the target backup timers, and verifies the setting.

--transfer-mode local (the default) keeps a verified archive on this computer
before uploading it. direct uses a temporary restricted SSH key so the source
can send the compressed archive over the VPS-to-VPS route; the verified
archive remains on the stopped source instead of being copied locally.
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
valid_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
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
disable_restic_backup=0
transfer_mode=local
transfer_mode_explicit=0
ssh_port=22
backup_root="${HOME:-.}/backup-vps"
known_hosts="${HOME:-.}/.ssh/known_hosts"
while (($#)); do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--resume) resume=1 ;;
	--assume-yes) assume_yes=1 ;;
	--strict-dns) strict_dns=1 ;;
	--disable-restic-backup) disable_restic_backup=1 ;;
	--transfer-mode)
		(($# >= 2)) || die '--transfer-mode requires local or direct'
		transfer_mode="$2"
		transfer_mode_explicit=1
		shift
		;;
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
case "$transfer_mode" in local | direct) ;; *) die '--transfer-mode must be local or direct' ;; esac
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

ssh_opts=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
scp_opts=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
sftp_opts=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
ssh_source() { ssh "${ssh_opts[@]}" "root@$source_ip" "$@"; }
ssh_target() { ssh "${ssh_opts[@]}" "root@$target_ip" "$@"; }
scp_source() { scp "${scp_opts[@]}" "root@$source_ip:$1" "$2"; }
scp_to_source() { scp "${scp_opts[@]}" "$1" "root@$source_ip:$2"; }
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
transfer_credentials_active=0
transfer_key_id=''
transfer_key_local=''
transfer_known_hosts_local=''
transfer_key_remote=''
transfer_known_hosts_remote=''
cleanup_transfer_credentials() {
	local marker
	[[ "$transfer_credentials_active" == 1 ]] || return 0
	marker="$transfer_key_id"
	if [[ -n "$marker" ]]; then
		ssh_target "set -Eeuo pipefail; file=/root/.ssh/authorized_keys; if [ -f \"\$file\" ]; then tmp=\$(mktemp /root/.ssh/authorized_keys.XXXXXX); awk -v marker='$marker' 'index(\$0, \" \" marker) == 0' \"\$file\" >\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" \"\$file\"; fi" >/dev/null 2>&1 || true
	fi
	if [[ -n "$transfer_key_remote" && -n "$transfer_known_hosts_remote" ]]; then
		ssh_source "rm -f '$transfer_key_remote' '$transfer_known_hosts_remote'" >/dev/null 2>&1 || true
	fi
	[[ -z "$transfer_key_local" ]] || rm -f -- "$transfer_key_local" "$transfer_key_local.pub"
	[[ -z "$transfer_known_hosts_local" ]] || rm -f -- "$transfer_known_hosts_local"
	transfer_credentials_active=0
}
purge_stale_transfer_credentials() {
	local marker="$transfer_key_id"
	[[ -n "$marker" ]] || return 0
	ssh_target "set -Eeuo pipefail; file=/root/.ssh/authorized_keys; if [ -f \"\$file\" ]; then tmp=\$(mktemp /root/.ssh/authorized_keys.XXXXXX); trap 'rm -f \"\$tmp\"' EXIT HUP INT TERM; awk -v marker='$marker' 'index(\$0, \" \" marker) == 0' \"\$file\" >\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" \"\$file\"; trap - EXIT HUP INT TERM; fi"
	ssh_source "rm -f '$transfer_key_remote' '$transfer_known_hosts_remote'" >/dev/null 2>&1 || true
	rm -f -- "$transfer_key_local" "$transfer_key_local.pub" "$transfer_known_hosts_local"
}
print_source_recovery() {
	local recovery='platformctl maintenance end; for unit in /etc/systemd/system/platform-* /etc/systemd/system/platform.target; do [ -e "$unit" ] || continue; systemctl enable "${unit##*/}" >/dev/null 2>&1 || true; done; systemctl daemon-reload; systemctl enable --now platform.target'
	printf 'migration: source recovery (only if the old VPS must be restored):\n'
	printf '  ssh -p %q -o UserKnownHostsFile=%q root@%s %q\n' "$ssh_port" "$known_hosts" "$source_ip" "$recovery"
}
migration_exit() {
	local status="$?"
	cleanup_transfer_credentials || true
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
	return "$status"
}
trap migration_exit EXIT
set_phase() {
	phase="$1"
	valid_phase "$phase" || die "invalid migration phase: $phase"
	local temporary
	temporary="$(mktemp "$state_file.XXXXXX")"
	if ! {
		printf 'VERSION=4\nPHASE=%s\nSOURCE_IP=%s\nTARGET_IP=%s\nNODE_ID=%s\nRELEASE_SHA=%s\nLEADER_IP=%s\nDOMAIN=%s\nDISABLE_RESTIC_BACKUP=%s\nTRANSFER_MODE=%s\nRUN_DIR=%s\nARCHIVE=%s\n' "$phase" "$source_ip" "$target_ip" "$node_id" "$release_sha" "$leader_ip" "$domain" "$disable_restic_backup" "$transfer_mode" "$run_dir" "$archive_local"
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
	local candidate matches=0 version stored_disable_restic_backup=0 stored_transfer_mode=local requested_disable_restic_backup="$disable_restic_backup" requested_transfer_mode="$transfer_mode"
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
	case "$version" in
	2) stored_disable_restic_backup=0 ;;
	3) stored_disable_restic_backup="$(sed -n 's/^DISABLE_RESTIC_BACKUP=//p' "$state_file" | tail -n1)" ;;
	4)
		stored_disable_restic_backup="$(sed -n 's/^DISABLE_RESTIC_BACKUP=//p' "$state_file" | tail -n1)"
		stored_transfer_mode="$(sed -n 's/^TRANSFER_MODE=//p' "$state_file" | tail -n1)"
		;;
	*) die 'unsupported migration state version' ;;
	esac
	[[ "$stored_disable_restic_backup" == 0 || "$stored_disable_restic_backup" == 1 ]] || die 'invalid Restic backup setting in migration state'
	if [[ "$requested_disable_restic_backup" == 1 && "$stored_disable_restic_backup" != 1 ]]; then
		die '--disable-restic-backup cannot be added to an existing migration'
	fi
	disable_restic_backup="$stored_disable_restic_backup"
	if [[ "$version" == 4 ]]; then
		case "$stored_transfer_mode" in local | direct) ;; *) die 'invalid transfer mode in migration state' ;; esac
		if ((transfer_mode_explicit)) && [[ "$requested_transfer_mode" != "$stored_transfer_mode" ]]; then
			die '--transfer-mode cannot be changed for this migration'
		fi
		transfer_mode="$stored_transfer_mode"
	elif ((transfer_mode_explicit)); then
		# Version 2/3 did not persist a transfer route. It is safe to choose direct
		# only before either copy phase has completed.
		[[ "$phase" == preflight || "$phase" == source-stopped || "$phase" == archive-created || "$requested_transfer_mode" == local ]] || die '--transfer-mode cannot be changed after archive transfer'
		transfer_mode="$requested_transfer_mode"
	fi
	valid_phase "$phase" || die "invalid migration phase in state: $phase"
	run_name="${run_dir##*/}"
	[[ -d "$run_dir" && ! -L "$run_dir" && "$run_dir" == "$backup_root"/migration-* && "$run_name" =~ ^migration-[A-Za-z0-9._-]+$ && "$archive_local" == "$run_dir/node-migration.tar.gz" && "$node_id" =~ ^[a-z][a-z0-9-]*$ ]] || die 'resume metadata or artifacts are invalid'
	valid_sha "$release_sha" || die 'resume release SHA is invalid'
	valid_ipv4 "$leader_ip" || die 'resume Leader IP is invalid'
	[[ -n "$domain" && "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'resume domain is invalid'
	if [[ "$transfer_mode" == local ]] && phase_at_least local-copy-verified; then
		[[ -s "$archive_local" && -s "$archive_local.sha256" ]] || die 'resume archive artifacts are missing'
	fi
	[[ "$version" == 4 || "$dry_run" == 1 ]] || set_phase "$phase"
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
if ! phase_at_least target-copy-verified; then
	if [[ "$transfer_mode" == local ]]; then
		have sftp || die 'local transfer requires sftp on this computer'
	else
		have ssh-keygen || die 'direct transfer requires ssh-keygen on this computer'
	fi
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
	if [[ "$transfer_mode" == direct ]]; then
		ssh_source 'command -v sftp >/dev/null 2>&1' || die 'direct transfer requires the SFTP client on the source VPS'
	fi
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
	if ((disable_restic_backup)); then
		inventory_backup_enabled="$(ssh_source "sed -n 's/^BACKUP_ENABLED=//p' /opt/platform/control/current/config/cluster/nodes/$node_id.env 2>/dev/null | tail -n1")"
		[[ "$inventory_backup_enabled" == false ]] || die "--disable-restic-backup requires BACKUP_ENABLED=false in the deployed $node_id descriptor"
		runtime_backup_enabled="$(node_value BACKUP_ENABLED)"
		[[ "$runtime_backup_enabled" == false ]] || die "--disable-restic-backup requires BACKUP_ENABLED=false in the source runtime node configuration"
	fi
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
	[[ "$source_free_kb" =~ ^[0-9]+$ && "$source_free_kb" -ge "$source_required_kb" ]] || die 'source has insufficient free space for the migration archive'
	[[ "$target_free_kb" =~ ^[0-9]+$ && "$target_free_kb" -ge "$target_required_kb" ]] || die 'target has insufficient free space for staging and extraction'
	if [[ "$transfer_mode" == local ]]; then
		local_free_kb="$(df -Pk "$(dirname "$backup_root")" | awk 'NR==2 {print $4}')"
		[[ "$local_free_kb" =~ ^[0-9]+$ && "$local_free_kb" -ge "$local_required_kb" ]] || die 'local backup volume has insufficient free space'
	fi
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
	log "transfer mode: $transfer_mode (compressed tar.gz archive)"
	((disable_restic_backup)) && log "Restic backups will remain disabled for $node_id"
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
target_root='/root/backup-vps'
target_dir="$target_root/$(basename "$run_dir")"
configure_direct_transfer_paths() {
	transfer_key_id="llm-hub-lite-$run_name"
	transfer_key_local="$run_dir/.direct-transfer-key"
	transfer_known_hosts_local="$run_dir/.direct-target-known-hosts"
	transfer_key_remote="/var/tmp/$transfer_key_id.key"
	transfer_known_hosts_remote="/var/tmp/$transfer_key_id.known-hosts"
}
if [[ "$transfer_mode" == direct ]]; then
	# A SIGKILL after upload can bypass the EXIT trap. Remove deterministic key
	# artifacts before reusing a completed upload or starting another attempt.
	configure_direct_transfer_paths
	purge_stale_transfer_credentials
fi
local_archive_is_valid() {
	local expected actual
	[[ -f "$archive_local" && ! -L "$archive_local" && -f "$archive_local.sha256" && ! -L "$archive_local.sha256" ]] || return 1
	expected="$(sed 's/[[:space:]].*//' "$archive_local.sha256")"
	valid_sha256 "$expected" || return 1
	actual="$(sha256_file "$archive_local")"
	[[ "$expected" == "$actual" ]] || return 1
	tar -tzf "$archive_local" >/dev/null 2>&1
}
verify_local_archive() {
	local_archive_is_valid || die 'local archive artifacts are missing, unsafe, unreadable, or fail checksum verification'
}
ensure_target_transfer_dir() {
	ssh_target "set -Eeuo pipefail; for path in '$target_root' '$target_dir'; do if [ -L \"\$path\" ] || { [ -e \"\$path\" ] && [ ! -d \"\$path\" ]; }; then printf 'unsafe target migration directory: %s\\n' \"\$path\" >&2; exit 1; fi; done; install -d -m 700 '$target_dir'"
}
verify_target_archive() {
	ssh_target "set -Eeuo pipefail; test -d '$target_root' && test ! -L '$target_root'; test -d '$target_dir' && test ! -L '$target_dir'; archive='$target_dir/node-migration.tar.gz'; checksum=\"\${archive}.sha256\"; test -f \"\$archive\" && test ! -L \"\$archive\" && test -s \"\$archive\"; test -f \"\$checksum\" && test ! -L \"\$checksum\" && test -s \"\$checksum\"; expected=\$(sed 's/[[:space:]].*//' \"\$checksum\"); printf '%s\\n' \"\$expected\" | grep -Eq '^[0-9a-f]{64}\$'; actual=\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""
}
validate_target_archive_manifest() {
	ssh_target "archive='$target_dir/node-migration.tar.gz' release_sha='$release_sha' bash -s" <<'REMOTE_VALIDATE_ARCHIVE'
set -Eeuo pipefail
manifest="${archive}.manifest"
rm -f "$manifest"
tar -tzf "$archive" >"$manifest"
chmod 600 "$manifest"
grep -Eq '^etc/llm-hub-lite/node\.env$' "$manifest" || { printf 'archive is missing the source node identity\n' >&2; exit 1; }
grep -Eq "^opt/platform/control/releases/$release_sha(/|$)" "$manifest" || { printf 'archive is missing the source current release\n' >&2; exit 1; }
while IFS= read -r link_target; do
	case "$link_target" in *'..'*) printf 'unsafe archive symlink target: %s\n' "$link_target" >&2; exit 1 ;; esac
	case "$link_target" in
	/opt/apps/llm-hub-lite | /opt/apps/llm-hub-lite/* | /opt/platform | /opt/platform/* | /etc/llm-hub-lite | /etc/llm-hub-lite/*) ;;
	/*) printf 'unsafe archive symlink target: %s\n' "$link_target" >&2; exit 1 ;;
	esac
done < <(tar -tvzf "$archive" | awk '/^l/ { sub(/^.* -> /, ""); print }')
while IFS= read -r link_target; do
	case "$link_target" in opt/apps/llm-hub-lite | opt/apps/llm-hub-lite/* | opt/platform | opt/platform/* | etc/llm-hub-lite | etc/llm-hub-lite/*) ;;
	*) printf 'unsafe archive hard-link target: %s\n' "$link_target" >&2; exit 1 ;;
	esac
	case "$link_target" in /* | *'..'*) printf 'unsafe archive hard-link target: %s\n' "$link_target" >&2; exit 1 ;; esac
done < <(tar -tvzf "$archive" | awk '/^h/ { sub(/^.* link to /, ""); print }')
while IFS= read -r path; do
	case "$path" in opt/apps/llm-hub-lite | opt/apps/llm-hub-lite/* | opt/platform | opt/platform/* | etc/llm-hub-lite | etc/llm-hub-lite/*) ;; *) printf 'unexpected archive path: %s\n' "$path" >&2; exit 1 ;; esac
	case "$path" in /* | *'..'*) printf 'unsafe archive path: %s\n' "$path" >&2; exit 1 ;; esac
	case "$path" in */collector-buffer | */collector-buffer/*) printf 'excluded collector buffer leaked into archive: %s\n' "$path" >&2; exit 1 ;; esac
done <"$manifest"
REMOTE_VALIDATE_ARCHIVE
}
adopt_legacy_local_partial() {
	local stable="$archive_local.partial" candidate largest='' size largest_size=0
	if [[ -e "$stable" || -L "$stable" ]]; then
		if [[ -f "$stable" && ! -L "$stable" ]]; then
			return 0
		fi
		log 'discarding an unsafe local partial archive'
		rm -f -- "$stable"
		[[ ! -e "$stable" && ! -L "$stable" ]] || die "unable to remove unsafe local partial archive: $stable"
	fi
	for candidate in "$archive_local.partial."*; do
		[[ -f "$candidate" && ! -L "$candidate" ]] || continue
		size="$(wc -c <"$candidate" | tr -d '[:space:]')"
		[[ "$size" =~ ^[0-9]+$ ]] || continue
		if ((size > largest_size)); then
			largest="$candidate"
			largest_size="$size"
		fi
	done
	if [[ -n "$largest" ]]; then
		log "adopting interrupted local transfer ($(basename "$largest"), $largest_size bytes)"
		mv -f -- "$largest" "$stable"
	fi
}
download_source_archive_resumable() {
	local partial="$archive_local.partial" checksum_partial="$archive_local.sha256.partial" remote_size local_size attempt expected_hash
	if local_archive_is_valid; then
		log 'reusing the complete checksum-verified archive already on this computer'
		rm -f -- "$partial" "$checksum_partial" "$archive_local.partial."* "$archive_local.sha256.partial."*
		return 0
	fi
	rm -f -- "$archive_local" "$archive_local.sha256" "$checksum_partial"
	adopt_legacy_local_partial
	remote_size="$(ssh_source "stat -c %s '$archive_remote'")"
	local_size=0
	[[ ! -f "$partial" ]] || local_size="$(wc -c <"$partial" | tr -d '[:space:]')"
	[[ "$remote_size" =~ ^[0-9]+$ && "$local_size" =~ ^[0-9]+$ ]] || die 'unable to determine archive transfer size'
	if ((local_size > remote_size)); then
		log 'discarding an oversized partial local archive'
		rm -f -- "$partial"
	fi
	for attempt in 1 2; do
		if ! (
			cd -- "$run_dir"
			printf 'reget %s %s\n' "$archive_remote" "$(basename "$partial")" | sftp -b - "${sftp_opts[@]}" "root@$source_ip"
		); then
			if ((attempt == 1)); then
				log 'local archive download was interrupted; resuming once'
				continue
			fi
			die 'local archive download failed twice; rerun with --resume to keep the partial transfer'
		fi
		rm -f -- "$checksum_partial"
		if ! scp_source "$archive_remote.sha256" "$checksum_partial"; then
			if ((attempt == 1)); then
				log 'archive checksum download failed; retrying once'
				continue
			fi
			die 'archive checksum download failed twice; rerun with --resume'
		fi
		chmod 600 "$partial" "$checksum_partial"
		expected_hash="$(sed 's/[[:space:]].*//' "$checksum_partial")"
		if valid_sha256 "$expected_hash" && [[ "$expected_hash" == "$(sha256_file "$partial")" ]]; then
			mv -f -- "$partial" "$archive_local"
			mv -f -- "$checksum_partial" "$archive_local.sha256"
			rm -f -- "$archive_local.partial."* "$archive_local.sha256.partial."*
			return 0
		fi
		if ((attempt == 1)); then
			log 'partial local archive failed checksum verification; retrying once from zero'
			rm -f -- "$partial" "$checksum_partial"
		fi
	done
	die 'local archive checksum mismatch after a clean retry'
}
prepare_direct_transfer_credentials() {
	local lookup public_key
	ssh_source 'command -v sftp >/dev/null 2>&1' || die 'direct transfer requires the SFTP client on the source VPS'
	configure_direct_transfer_paths
	lookup="$target_ip"
	[[ "$ssh_port" == 22 ]] || lookup="[$target_ip]:$ssh_port"
	ssh-keygen -F "$lookup" -f "$known_hosts" 2>/dev/null | awk '!/^#/ && NF >= 3 {print}' >"$transfer_known_hosts_local"
	[[ -s "$transfer_known_hosts_local" ]] || die "target host key is absent from known-hosts for direct transfer: $lookup"
	rm -f -- "$transfer_key_local" "$transfer_key_local.pub"
	ssh-keygen -q -t ed25519 -N '' -C "$transfer_key_id" -f "$transfer_key_local"
	chmod 600 "$transfer_key_local" "$transfer_key_local.pub" "$transfer_known_hosts_local"
	public_key="$(<"$transfer_key_local.pub")"
	transfer_credentials_active=1
	printf 'from="%s",restrict,command="internal-sftp" %s\n' "$source_ip" "$public_key" | ssh_target "set -Eeuo pipefail; umask 077; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; tmp=\$(mktemp /root/.ssh/authorized_keys.XXXXXX); trap 'rm -f \"\$tmp\"' EXIT HUP INT TERM; grep -Fv ' $transfer_key_id' /root/.ssh/authorized_keys >\"\$tmp\" || true; cat >>\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" /root/.ssh/authorized_keys; trap - EXIT HUP INT TERM"
	scp_to_source "$transfer_key_local" "$transfer_key_remote"
	scp_to_source "$transfer_known_hosts_local" "$transfer_known_hosts_remote"
	ssh_source "chmod 600 '$transfer_key_remote' '$transfer_known_hosts_remote'; printf 'pwd\\n' | sftp -q -b - -P '$ssh_port' -i '$transfer_key_remote' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$transfer_known_hosts_remote' -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 root@'$target_ip' >/dev/null"
}
transfer_archive_direct() {
	local attempt
	ensure_target_transfer_dir
	# Direct-mode partials are deliberately not resumed. A fresh upload avoids
	# combining bytes from separate attempts or from the former local route.
	rm -f -- "$archive_local.partial" "$archive_local.sha256.partial" "$archive_local.partial."* "$archive_local.sha256.partial."*
	ssh_target "rm -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.partial.'* '$target_dir/node-migration.tar.gz.sha256.partial' '$target_dir/node-migration.tar.gz.sha256.partial.'*"
	if verify_target_archive >/dev/null 2>&1; then
		log 'reusing the complete checksum-verified archive already on the target'
		return 0
	fi
	ssh_target "rm -f '$target_dir/node-migration.tar.gz' '$target_dir/node-migration.tar.gz.sha256' '$target_dir/node-migration.tar.gz.manifest'"
	prepare_direct_transfer_credentials
	for attempt in 1 2; do
		if ! ssh_source "set -Eeuo pipefail; printf 'put %s %s\\nput %s %s\\n' '$archive_remote' '$target_dir/node-migration.tar.gz.partial' '$archive_remote.sha256' '$target_dir/node-migration.tar.gz.sha256' | sftp -b - -P '$ssh_port' -i '$transfer_key_remote' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$transfer_known_hosts_remote' -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 root@'$target_ip'"; then
			if ((attempt == 1)); then
				log 'direct archive transfer was interrupted; deleting partials and retrying once from zero'
				ssh_target "rm -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.sha256'"
				continue
			fi
			die 'direct archive transfer failed twice; rerun with --resume to start a clean transfer'
		fi
		if ssh_target "set -Eeuo pipefail; test -f '$target_dir/node-migration.tar.gz.partial' && test ! -L '$target_dir/node-migration.tar.gz.partial'; test -f '$target_dir/node-migration.tar.gz.sha256' && test ! -L '$target_dir/node-migration.tar.gz.sha256'; expected=\$(sed 's/[[:space:]].*//' '$target_dir/node-migration.tar.gz.sha256'); printf '%s\\n' \"\$expected\" | grep -Eq '^[0-9a-f]{64}\$'; actual=\$(sha256sum '$target_dir/node-migration.tar.gz.partial' | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""; then
			ssh_target "set -Eeuo pipefail; chmod 600 '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.sha256'; mv -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz'"
			purge_stale_transfer_credentials
			transfer_credentials_active=0
			return 0
		fi
		if ((attempt == 1)); then
			log 'direct archive failed checksum verification; deleting partials and retrying once from zero'
			ssh_target "rm -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.sha256'"
		fi
	done
	die 'direct archive checksum mismatch after a clean retry'
}
upload_local_archive_resumable() {
	local local_size remote_size attempt
	verify_local_archive
	ensure_target_transfer_dir
	if verify_target_archive >/dev/null 2>&1; then
		log 'reusing the complete checksum-verified archive already on the target'
		return 0
	fi
	ssh_target "rm -f '$target_dir/node-migration.tar.gz' '$target_dir/node-migration.tar.gz.sha256' '$target_dir/node-migration.tar.gz.manifest'"
	local_size="$(wc -c <"$archive_local" | tr -d '[:space:]')"
	remote_size="$(ssh_target "set -Eeuo pipefail; partial='$target_dir/node-migration.tar.gz.partial'; if [ -L \"\$partial\" ]; then rm -f \"\$partial\"; fi; if [ -e \"\$partial\" ] && [ ! -f \"\$partial\" ]; then printf 'unsafe target partial archive: %s\\n' \"\$partial\" >&2; exit 1; fi; if [ -f \"\$partial\" ]; then stat -c %s \"\$partial\"; else printf '0\\n'; fi")"
	[[ "$local_size" =~ ^[0-9]+$ && "$remote_size" =~ ^[0-9]+$ ]] || die 'unable to determine local upload size'
	if ((remote_size > local_size)); then
		log 'discarding an oversized partial archive on the target'
		ssh_target "rm -f '$target_dir/node-migration.tar.gz.partial'"
	fi
	for attempt in 1 2; do
		if ! (
			cd -- "$run_dir"
			printf 'reput %s %s\nput %s %s\n' "$(basename "$archive_local")" "$target_dir/node-migration.tar.gz.partial" "$(basename "$archive_local.sha256")" "$target_dir/node-migration.tar.gz.sha256" |
				sftp -b - "${sftp_opts[@]}" "root@$target_ip"
		); then
			if ((attempt == 1)); then
				log 'target archive upload was interrupted; resuming once'
				continue
			fi
			die 'target archive upload failed twice; rerun with --resume to keep the partial transfer'
		fi
		if ssh_target "set -Eeuo pipefail; test -f '$target_dir/node-migration.tar.gz.partial' && test ! -L '$target_dir/node-migration.tar.gz.partial'; test -f '$target_dir/node-migration.tar.gz.sha256' && test ! -L '$target_dir/node-migration.tar.gz.sha256'; chmod 600 '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.sha256'; expected=\$(sed 's/[[:space:]].*//' '$target_dir/node-migration.tar.gz.sha256'); printf '%s\\n' \"\$expected\" | grep -Eq '^[0-9a-f]{64}\$'; actual=\$(sha256sum '$target_dir/node-migration.tar.gz.partial' | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\""; then
			ssh_target "set -Eeuo pipefail; mv -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz'"
			return 0
		fi
		if ((attempt == 1)); then
			log 'target partial failed checksum verification; retrying once from zero'
			ssh_target "rm -f '$target_dir/node-migration.tar.gz.partial' '$target_dir/node-migration.tar.gz.sha256'"
		fi
	done
	die 'target archive checksum mismatch after a clean retry'
}
verify_target_identity() {
	ssh_target "test \"\$(sed -n 's/^NODE_ID=//p' /etc/llm-hub-lite/node.env | tail -n1)\" = '$node_id'; test \"\$(readlink /opt/platform/control/current | sed 's#.*/##')\" = '$release_sha'; if [ '$disable_restic_backup' = 1 ]; then test \"\$(sed -n 's/^BACKUP_ENABLED=//p' /etc/llm-hub-lite/node.env | tail -n1)\" = false; fi"
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
if [[ "$transfer_mode" == local ]] && phase_at_least local-copy-verified; then verify_local_archive; fi
if [[ "$phase" == target-copy-verified ]]; then verify_target_archive; fi
if phase_at_least target-extracted; then
	verify_target_identity
	# A crash immediately after advancing the extraction phase may occur before
	# its cleanup. Repeating this removal is safe and preserves low disk usage.
	ssh_target "rm -f '$target_dir/node-migration.tar.gz' '$target_dir/node-migration.tar.gz.sha256' '$target_dir/node-migration.tar.gz.manifest'"
fi
if ! phase_at_least archive-created; then
	log 'creating the gzip-compressed managed-state archive on the stopped source'
	ssh_source "set -Eeuo pipefail; archive='$archive_remote'; if [ -s \"\$archive\" ] && [ -s \"\$archive.sha256\" ] && [ \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\" ]; then exit 0; fi; rm -f \"\$archive\" \"\$archive.sha256\"; tar --numeric-owner --xattrs --acls --selinux -czf \"\$archive\" -C / --exclude='collector-buffer' --exclude='collector-buffer/*' --exclude='opt/platform/observer/collector-buffer' --exclude='opt/platform/*/collector-buffer' --exclude='opt/platform/*/*/collector-buffer' --exclude='opt/platform/*restic*' --exclude='opt/platform/*/restic*' --exclude='etc/llm-hub-lite/maintenance' --exclude='etc/llm-hub-lite/node-retirement.*' --exclude='etc/llm-hub-lite/firewall-reconcile.request' --exclude='opt/apps/llm-hub-lite/shared/runtime/transaction.*' --exclude='opt/platform/control/*/transaction.*' --exclude='opt/apps/llm-hub-lite/shared/logs' opt/apps/llm-hub-lite opt/platform etc/llm-hub-lite; chown root:root \"\$archive\"; chmod 600 \"\$archive\"; (cd /var/tmp && sha256sum \"\$(basename \"\$archive\")\" >\"\$(basename \"\$archive\").sha256\"); test \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\""
	set_phase archive-created
fi
if [[ "$transfer_mode" == local ]] && ! phase_at_least local-copy-verified; then
	log 'verifying the local checksum and archive manifest'
	download_source_archive_resumable
	rm -f -- "$run_dir/manifest.txt"
	tar -tzf "$archive_local" >"$run_dir/manifest.txt"
	chmod 600 "$run_dir/manifest.txt"
	grep -Eq '^etc/llm-hub-lite/node\.env$' "$run_dir/manifest.txt" || die 'archive is missing the source node identity'
	grep -Eq "^opt/platform/control/releases/$release_sha(/|$)" "$run_dir/manifest.txt" || die 'archive is missing the source current release'
	while IFS= read -r link_target; do
		case "$link_target" in *'..'*) die "unsafe archive symlink target: $link_target" ;; esac
		case "$link_target" in
		/opt/apps/llm-hub-lite | /opt/apps/llm-hub-lite/* | /opt/platform | /opt/platform/* | /etc/llm-hub-lite | /etc/llm-hub-lite/*) ;;
		/*) die "unsafe archive symlink target: $link_target" ;;
		esac
	done < <(tar -tvzf "$archive_local" | awk '/^l/ { sub(/^.* -> /, ""); print }')
	while IFS= read -r link_target; do
		case "$link_target" in opt/apps/llm-hub-lite | opt/apps/llm-hub-lite/* | opt/platform | opt/platform/* | etc/llm-hub-lite | etc/llm-hub-lite/*) ;;
		*) die "unsafe archive hard-link target: $link_target" ;;
		esac
		case "$link_target" in /* | *'..'*) die "unsafe archive hard-link target: $link_target" ;; esac
	done < <(tar -tvzf "$archive_local" | awk '/^h/ { sub(/^.* link to /, ""); print }')
	while IFS= read -r path; do
		case "$path" in opt/apps/llm-hub-lite | opt/apps/llm-hub-lite/* | opt/platform | opt/platform/* | etc/llm-hub-lite | etc/llm-hub-lite/*) ;; *) die "unexpected archive path: $path" ;; esac
		case "$path" in /* | *'..'*) die "unsafe archive path: $path" ;; esac
		case "$path" in */collector-buffer | */collector-buffer/*) die "excluded collector buffer leaked into archive: $path" ;; esac
	done <"$run_dir/manifest.txt"
	set_phase local-copy-verified
fi
if ! phase_at_least target-copy-verified; then
	if [[ "$transfer_mode" == direct ]]; then
		log 'copying the compressed archive directly from source to target'
		transfer_archive_direct
	else
		log 'copying the verified archive from this computer to the fresh target'
		upload_local_archive_resumable
	fi
	verify_target_archive
	validate_target_archive_manifest
	set_phase target-copy-verified
fi
if ! phase_at_least target-extracted; then
	log 'validating and extracting managed state on the target'
	ssh_target "set -Eeuo pipefail; stage='$target_dir/stage'; rm -rf \"\$stage\"; install -d -m 700 \"\$stage\"; tar -xzf '$target_dir/node-migration.tar.gz' -C \"\$stage\" --no-same-owner; test \"\$(sed -n 's/^NODE_ID=//p' \"\$stage/etc/llm-hub-lite/node.env\" | tail -n1)\" = '$node_id'; test \"\$(readlink \"\$stage/opt/platform/control/current\" | sed 's#.*/##')\" = '$release_sha'; tar -xzf '$target_dir/node-migration.tar.gz' -C / --same-owner --numeric-owner --xattrs --acls --selinux; rm -rf \"\$stage\""
	set_phase target-extracted
	# The source archive (and, in local mode, the local archive) remains the
	# recovery copy. Free scarce target disk before bootstrap pulls images.
	ssh_target "rm -f '$target_dir/node-migration.tar.gz' '$target_dir/node-migration.tar.gz.sha256' '$target_dir/node-migration.tar.gz.manifest'"
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
	if ((disable_restic_backup)); then
		log 'disabling Restic backup timers on the target'
		ssh_target "set -Eeuo pipefail; test \"\$(sed -n 's/^BACKUP_ENABLED=//p' /etc/llm-hub-lite/node.env | tail -n1)\" = false; systemctl disable --now platform-backup.timer platform-backup-prune.timer platform-backup-check.timer >/dev/null"
	fi
	set_phase bootstrap-complete
fi
if ! phase_at_least verification-complete; then
	log 'verifying target platform health and source shutdown'
	verify_target_identity
	if ((disable_restic_backup)); then
		ssh_target 'test "$(systemctl is-enabled platform-backup.timer 2>/dev/null || true)" = disabled; test "$(systemctl is-enabled platform-backup-prune.timer 2>/dev/null || true)" = disabled; test "$(systemctl is-enabled platform-backup-check.timer 2>/dev/null || true)" = disabled'
	fi
	verify_target_health
	ssh_source 'test -z "$(docker ps --filter label=com.aichorage.platform=llm-hub-lite -q)"; test -f /etc/llm-hub-lite/maintenance'
	set_phase verification-complete
fi
migration_succeeded=1
log "migration complete for $node_id"
((disable_restic_backup)) && log 'Restic backups and backup maintenance timers are disabled on the target'
if [[ "$transfer_mode" == local ]]; then
	log "archive retained at $run_dir; remove it manually after verification"
else
	log "compressed archive retained on source at $archive_remote until source cleanup"
	log "local migration metadata retained at $run_dir; no full local archive was created"
fi
log 'on the old VPS, copy ops/clean-vps.sh outside managed paths and run it manually'
