#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2029
set -Eeuo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
bootstrap_source="$repo_root/ops/bootstrap-vps.sh"

# shellcheck source=ops/lib/migration-common.sh
source "$script_dir/lib/migration-common.sh"

usage() {
	cat <<'EOF'
Usage: change-vps-for-leader-node.sh [--dry-run] [--resume] [--assume-yes]
  [--transfer-mode local|direct] [--backup-dir PATH] [--ssh-port PORT]
  [--known-hosts PATH] [--follower-ips NODE=IP,...] SOURCE_IP TARGET_IP

Migrate the cluster Leader node to a new VPS. The workflow quiesces the old
Leader, archives managed platform state, transfers it to the new VPS, runs
the repair bootstrap, reconciles follow-on firewalls and monitoring agents
across all active Follower nodes, and verifies end-to-end cluster health.

--transfer-mode direct (the default) uses an ephemeral restricted SSH key
to send the compressed archive directly from the source VPS to the target VPS
at datacenter speeds without routing large files through this local computer.

--transfer-mode local keeps a verified archive on this computer before uploading it.
EOF
}

die() {
	printf 'leader-migration: ERROR: %s\n' "$*" >&2
	exit 1
}
log() { printf 'leader-migration: %s\n' "$*"; }
have() { migration_have "$1"; }
sha256_file() { migration_sha256_file "$1"; }
valid_ipv4() { migration_valid_ipv4 "$1"; }
valid_sha() { migration_valid_sha "$1"; }
valid_sha256() { migration_valid_sha256 "$1"; }
valid_phase() {
	migration_valid_phase "$1" 'preflight source-stopped archive-created local-copy-verified target-copy-verified target-extracted bootstrap-complete followers-reconciled verification-complete'
}

dry_run=0
resume=0
assume_yes=0
transfer_mode=direct
ssh_port=22
backup_root="${HOME:-.}/backup-vps"
known_hosts="${HOME:-.}/.ssh/known_hosts"
follower_ips_arg=""

while (($#)); do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--resume) resume=1 ;;
	--assume-yes) assume_yes=1 ;;
	--transfer-mode)
		(($# >= 2)) || die '--transfer-mode requires direct or local'
		transfer_mode="$2"
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
	--follower-ips)
		(($# >= 2)) || die '--follower-ips requires NODE=IP,...'
		follower_ips_arg="$2"
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
case "$transfer_mode" in direct | local) ;; *) die '--transfer-mode must be direct or local' ;; esac
[[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || die 'invalid SSH port'
case "$backup_root" in
/ | /bin | /boot | /dev | /etc | /home | /opt | /proc | /root | /run | /sbin | /sys | /tmp | /usr | /var | '' | *$'\n'* | *$'\r'*) die "unsafe backup directory: $backup_root" ;;
esac
[[ -L "$backup_root" ]] && die "backup directory must not be a symlink: $backup_root"
[[ -s "$known_hosts" ]] || die "known-hosts file is missing or empty: $known_hosts"
have ssh || die 'missing command: ssh'
have scp || die 'missing command: scp'
have sftp || die 'missing command: sftp'
have tar || die 'missing command: tar'
have curl || die 'missing command: curl'
have sha256sum || have shasum || die 'missing SHA-256 utility: sha256sum or shasum'

ssh_opts=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ConnectionAttempts=3 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
scp_opts=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ConnectionAttempts=3 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
sftp_opts=(-P "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -o ConnectTimeout=10 -o ConnectionAttempts=3 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

ssh_source() { ssh "${ssh_opts[@]}" "root@$source_ip" "$@"; }
ssh_target() { ssh "${ssh_opts[@]}" "root@$target_ip" "$@"; }
ssh_node() {
	local ip="$1" attempt
	shift
	for attempt in 1 2 3; do
		if ssh "${ssh_opts[@]}" "root@$ip" "$@"; then
			return 0
		fi
		if ((attempt < 3)); then
			log "SSH to $ip failed (attempt $attempt/3); retrying in 3s..."
			sleep 3
		fi
	done
	return 1
}
scp_source() { scp "${scp_opts[@]}" "root@$source_ip:$1" "$2"; }
scp_to_source() { scp "${scp_opts[@]}" "$1" "root@$source_ip:$2"; }
scp_target() { scp "${scp_opts[@]}" "$1" "root@$target_ip:$2"; }

state_file=''
run_dir=''
archive_local=''
phase=''
node_id=''
release_sha=''
domain=''
migration_succeeded=0
source_quiesce_attempted=0
transfer_credentials_active=0
transfer_key_id=''
transfer_key_local=''
transfer_key_remote=''

cleanup_transfer_credentials() {
	[[ "$transfer_credentials_active" == 1 ]] || return 0
	migration_cleanup_direct_credentials "$target_ip" "$source_ip" "$ssh_port" "$known_hosts" "$transfer_key_id" "$transfer_key_remote" "" "$transfer_key_local" ""
	transfer_credentials_active=0
}

migration_exit() {
	local status="$?"
	cleanup_transfer_credentials || true
	if [[ "$status" -ne 0 && "$migration_succeeded" -ne 1 ]]; then
		if ((dry_run)); then
			printf 'leader-migration: dry-run failed; no VPS state or local migration artifacts were changed\n' >&2
			return
		fi
		if [[ "$source_quiesce_attempted" == 1 ]] || phase_at_least source-stopped; then
			printf 'leader-migration: FAILED during phase %s; source is intentionally not restarted\n' "${phase:-preflight}" >&2
			printf 'leader-migration: source recovery command:\n' >&2
			printf '  ssh -p %q -o UserKnownHostsFile=%q root@%s platformctl maintenance end; systemctl enable --now platform.target\n' "$ssh_port" "$known_hosts" "$source_ip" >&2
		else
			printf 'leader-migration: preflight failed; no VPS state was changed\n' >&2
		fi
		printf 'leader-migration: retain %s and use --resume after correcting the cause\n' "${run_dir:-the migration directory}" >&2
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
		printf 'VERSION=2\nPHASE=%s\nSOURCE_IP=%s\nTARGET_IP=%s\nNODE_ID=%s\nRELEASE_SHA=%s\nDOMAIN=%s\nTRANSFER_MODE=%s\nRUN_DIR=%s\nARCHIVE=%s\n' "$phase" "$source_ip" "$target_ip" "$node_id" "$release_sha" "$domain" "$transfer_mode" "$run_dir" "$archive_local"
	} >"$temporary"; then
		rm -f -- "$temporary"
		die "unable to write migration state: $state_file"
	fi
	chmod 600 "$temporary"
	mv -f -- "$temporary" "$state_file"
}

phase_at_least() {
	migration_phase_at_least "$phase" "$1" 'preflight source-stopped archive-created local-copy-verified target-copy-verified target-extracted bootstrap-complete followers-reconciled verification-complete'
}

resolve_node_ip() {
	local node="$1" origin ip item override_node override_ip
	if [[ -n "$follower_ips_arg" ]]; then
		old_ifs="$IFS"
		IFS=','
		for item in $follower_ips_arg; do
			override_node="${item%%=*}"
			override_ip="${item#*=*}"
			if [[ "$override_node" == "$node" ]] && valid_ipv4 "$override_ip"; then
				IFS="$old_ifs"
				printf '%s\n' "$override_ip"
				return 0
			fi
		done
		IFS="$old_ifs"
	fi
	local desc="$repo_root/config/cluster/nodes/$node.env"
	migration_resolve_node_origin_ip "$repo_root" "$node"
}

manifest_conditional_secret_keys() {
	migration_manifest_conditional_secret_keys "$1"
}

reconcile_missing_shared_secrets() {
	local app_manifest app_id conditional_keys key val fn fip
	log 'checking for missing shared application secrets on target Leader'
	for app_manifest in "$repo_root"/apps/*/manifest.env; do
		[[ -f "$app_manifest" ]] || continue
		app_id="$(sed -n 's/^APP_ID=//p' "$app_manifest" | tail -n1)"
		conditional_keys="$(manifest_conditional_secret_keys "$app_manifest" 2>/dev/null || true)"
		[[ -n "$conditional_keys" ]] || continue
		for key in ${conditional_keys//,/ }; do
			[[ -n "$key" ]] || continue
			if ! ssh_target "grep -q '^${key}=' /etc/llm-hub-lite/shared-secrets.env 2>/dev/null"; then
				fn="$(sed -n 's/^TARGET_NODE=//p' "$repo_root/config/cluster/apps/${app_id}.policy" 2>/dev/null | tail -n1)"
				if [[ -n "$fn" && "$fn" != leader ]]; then
					fip="$(resolve_node_ip "$fn" 2>/dev/null || true)"
					if [[ -n "$fip" ]]; then
						val="$(ssh_node "$fip" "sed -n 's/^${key}=//p' /etc/llm-hub-lite/${app_id}.env 2>/dev/null | tail -n1" || true)"
						if [[ -n "$val" ]]; then
							log "reconciling missing shared secret $key for $app_id from $fn ($fip)"
							ssh_target "printf '%s=%s\n' '$key' '$val' >> /etc/llm-hub-lite/shared-secrets.env; chmod 600 /etc/llm-hub-lite/shared-secrets.env"
						fi
					fi
				fi
			fi
		done
	done
}

load_resume() {
	local candidate matches=0
	for candidate in "$backup_root"/*/leader-migration.state; do
		[[ -f "$candidate" && ! -L "$candidate" ]] || continue
		if grep -Fqx "SOURCE_IP=$source_ip" "$candidate" && grep -Fqx "TARGET_IP=$target_ip" "$candidate"; then
			state_file="$candidate"
			matches=$((matches + 1))
		fi
	done
	[[ "$matches" -eq 1 ]] || die "--resume requires exactly one matching leader-migration.state (found $matches)"
	phase="$(sed -n 's/^PHASE=//p' "$state_file" | tail -n1)"
	node_id="$(sed -n 's/^NODE_ID=//p' "$state_file" | tail -n1)"
	release_sha="$(sed -n 's/^RELEASE_SHA=//p' "$state_file" | tail -n1)"
	domain="$(sed -n 's/^DOMAIN=//p' "$state_file" | tail -n1)"
	run_dir="$(sed -n 's/^RUN_DIR=//p' "$state_file" | tail -n1)"
	archive_local="$(sed -n 's/^ARCHIVE=//p' "$state_file" | tail -n1)"
	stored_transfer_mode="$(sed -n 's/^TRANSFER_MODE=//p' "$state_file" | tail -n1)"
	case "${stored_transfer_mode:-$transfer_mode}" in direct | local) transfer_mode="${stored_transfer_mode:-$transfer_mode}" ;; *) die 'invalid transfer mode in state' ;; esac
	valid_phase "$phase" || die "invalid migration phase in state: $phase"
	valid_sha "$release_sha" || die 'resume release SHA is invalid'
	[[ "$node_id" == leader ]] || die 'resume node identity must be leader'
}

if ((resume)); then
	load_resume
else
	run_name="leader-migration-$(date -u '+%Y%m%dT%H%M%SZ')-${source_ip//./-}-to-${target_ip//./-}"
	run_dir="$backup_root/$run_name"
	[[ ! -e "$run_dir" ]] || die "migration run already exists: $run_dir"
	state_file="$run_dir/leader-migration.state"
	archive_local="$run_dir/leader-migration.tar.gz"
fi

archive_remote="/var/tmp/llm-hub-lite-leader-$(basename "$run_dir").tar.gz"
target_root='/root/backup-vps'
target_dir="$target_root/$(basename "$run_dir")"

node_value() { ssh_source "sed -n 's/^$1=//p' /etc/llm-hub-lite/node.env 2>/dev/null | tail -n1"; }

if ! phase_at_least preflight || [[ "$resume" == 1 && "$phase" == preflight ]]; then
	log 'checking source and target SSH identity, cluster policy, and storage'
	ssh_source 'true' >/dev/null
	ssh_target 'true' >/dev/null
	source_arch="$(ssh_source 'uname -m')"
	target_arch="$(ssh_target 'uname -m')"
	[[ "$source_arch" == "$target_arch" ]] || die "architecture mismatch: source=$source_arch target=$target_arch"
	node_id="$(node_value NODE_ID)"
	[[ "$node_id" == leader ]] || die "source node is not the Leader (found: $node_id)"
	leader_policy="$(ssh_source "sed -n 's/^LEADER_NODE_ID=//p' /opt/platform/control/current/config/cluster/policy.env 2>/dev/null | tail -n1")"
	[[ "$leader_policy" == leader ]] || die "cluster policy does not designate leader (found: $leader_policy)"
	release_sha="$(ssh_source "readlink /opt/platform/control/current 2>/dev/null | sed 's#.*/##'")"
	valid_sha "$release_sha" || die 'source current release is not a valid SHA'
	domain="$(ssh_source "sed -n 's/^DOMAIN_NAME=//p' /opt/apps/llm-hub-lite/shared/.env.prod 2>/dev/null | tail -n1")"
	domain="${domain:-aichorage.de}"

	if ssh_target 'test -e /opt/platform || test -e /opt/apps/llm-hub-lite || test -e /etc/llm-hub-lite'; then
		die 'target is not a fresh VPS (managed roots were found)'
	fi
	if ssh_target 'command -v docker >/dev/null 2>&1 && test -n "$(docker ps -aq --filter label=com.aichorage.platform=llm-hub-lite 2>/dev/null)"'; then
		die 'target is not a fresh VPS (managed containers were found)'
	fi

	managed_kb="$(ssh_source 'total=0; for path in /opt/apps/llm-hub-lite /opt/platform /etc/llm-hub-lite; do set -- $(du -sk -x "$path" 2>/dev/null || true); case "${1:-}" in *[!0-9]*|"") ;; *) total=$((total + $1));; esac; done; printf "%s\n" "$total"')"
	[[ "$managed_kb" =~ ^[0-9]+$ ]] || die 'unable to estimate managed state size'
	source_free_kb="$(ssh_source "df -Pk /var/tmp | tail -n 1 | awk '{print \$4}'")"
	target_free_kb="$(ssh_target "df -Pk /root /opt | awk 'NR>1 { if (\$4 ~ /^[0-9]+$/ && (min == \"\" || \$4 < min)) min=\$4 } END {print min}'")"
	[[ "$source_free_kb" -ge $((managed_kb * 2 + 1048576)) ]] || die 'source has insufficient free space'
	[[ "$target_free_kb" -ge $((managed_kb * 3 + 1048576)) ]] || die 'target has insufficient free space'
	if [[ "$transfer_mode" == local ]]; then
		local_free_kb="$(df -Pk "$(dirname "$backup_root")" | awk 'NR==2 {print $4}')"
		[[ "$local_free_kb" -ge $((managed_kb * 2 + 1048576)) ]] || die 'local backup volume has insufficient free space'
	fi

	log 'discovering and testing SSH connectivity to all active followers'
	followers="$(ssh_source "sed -n 's/^NODE_IDS=//p' /opt/platform/control/current/config/cluster/policy.env 2>/dev/null | tail -n1")"
	old_ifs="$IFS"
	IFS=','
	for fn in $followers; do
		[[ "$fn" != leader && -n "$fn" ]] || continue
		fip="$(resolve_node_ip "$fn")" || die "unable to resolve IP for follower $fn; use --follower-ips $fn=<ip>"
		valid_ipv4 "$fip" || die "invalid resolved IP for $fn: $fip"
		log "follower $fn resolved to $fip; testing SSH"
		ssh_node "$fip" 'true' || die "unable to connect via SSH to follower $fn ($fip)"
	done
	IFS="$old_ifs"

	if ((dry_run)); then
		phase=preflight
	else
		mkdir -p "$backup_root" "$run_dir"
		chmod 700 "$backup_root" "$run_dir"
		set_phase preflight
	fi
fi

if ((dry_run)); then
	log "preflight passed for Leader ($source_ip -> $target_ip)"
	log "transfer mode: $transfer_mode"
	log 'all follower nodes were resolved and verified via SSH'
	log 'no source, target, or follower state was changed'
	exit 0
fi

if [[ "$assume_yes" != 1 && ! -t 0 ]]; then die 'non-interactive migration requires --assume-yes'; fi
if [[ "$assume_yes" != 1 ]]; then
	printf 'This will stop Leader %s, copy state to %s, and update all followers. Continue? [y/N] ' "$source_ip" "$target_ip"
	read -r answer
	[[ "$answer" == y || "$answer" == Y ]] || die 'migration cancelled'
fi

# Phase: source-stopped
if ! phase_at_least source-stopped; then
	log 'quiescing Leader services under the platform lock'
	source_quiesce_attempted=1
	ssh_source 'set -Eeuo pipefail; exec 9>/run/lock/llm-hub-lite/platform.lock; flock -w 120 -x 9 || { printf "timed out waiting for lock\n" >&2; exit 1; }; export PLATFORM_LOCK_HELD=1; platformctl maintenance begin vps-migration; for unit in /etc/systemd/system/platform-* /etc/systemd/system/platform.target; do [ -e "$unit" ] || continue; systemctl disable --now "${unit##*/}" >/dev/null 2>&1 || true; done; platformctl stop all; sync; test -z "$(docker ps --filter label=com.aichorage.platform=llm-hub-lite -q)"'
	set_phase source-stopped
fi

# Phase: archive-created
if ! phase_at_least archive-created; then
	log 'creating compressed managed-state archive on stopped Leader'
	ssh_source "set -Eeuo pipefail; archive='$archive_remote'; if [ -s \"\$archive\" ] && [ -s \"\$archive.sha256\" ] && [ \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\" ]; then exit 0; fi; rm -f \"\$archive\" \"\$archive.sha256\"; tar --numeric-owner --xattrs --acls --selinux -czf \"\$archive\" -C / --exclude='collector-buffer' --exclude='collector-buffer/*' --exclude='opt/platform/observer/collector-buffer' --exclude='opt/platform/*/collector-buffer' --exclude='opt/platform/*/*/collector-buffer' --exclude='opt/platform/*restic*' --exclude='opt/platform/*/restic*' --exclude='etc/llm-hub-lite/maintenance' --exclude='etc/llm-hub-lite/node-retirement.*' --exclude='etc/llm-hub-lite/firewall-reconcile.request' --exclude='opt/apps/llm-hub-lite/shared/runtime/transaction.*' --exclude='opt/platform/control/*/transaction.*' --exclude='opt/apps/llm-hub-lite/shared/logs' opt/apps/llm-hub-lite opt/platform etc/llm-hub-lite; chown root:root \"\$archive\"; chmod 600 \"\$archive\"; (cd /var/tmp && sha256sum \"\$(basename \"\$archive\")\" >\"\$(basename \"\$archive\").sha256\"); test \"\$(sed 's/[[:space:]].*//' \"\$archive.sha256\")\" = \"\$(sha256sum \"\$archive\" | sed 's/[[:space:]].*//')\""
	set_phase archive-created
fi

# Transfer and verify archive
if ! phase_at_least target-copy-verified; then
	ssh_target "install -d -m 700 '$target_dir'; touch '$target_dir/leader-migration.tar.gz.partial'; chmod 600 '$target_dir/leader-migration.tar.gz.partial'"
	if [[ "$transfer_mode" == direct ]]; then
		log 'transferring archive directly from source VPS to target VPS (datacenter route)'
		transfer_key_id="leader-mig-$(basename "$run_dir")"
		transfer_key_local="$run_dir/.direct-key"
		transfer_key_remote="/var/tmp/$transfer_key_id.key"
		rm -f -- "$transfer_key_local" "$transfer_key_local.pub"
		ssh-keygen -q -t ed25519 -N '' -C "$transfer_key_id" -f "$transfer_key_local"
		public_key="$(<"$transfer_key_local.pub")"
		transfer_credentials_active=1
		printf 'from="%s" %s\n' "$source_ip" "$public_key" | ssh_target "set -Eeuo pipefail; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; cat >> /root/.ssh/authorized_keys"
		scp_to_source "$transfer_key_local" "$transfer_key_remote"
		ssh_source "chmod 600 '$transfer_key_remote'; scp -P '$ssh_port' -o StrictHostKeyChecking=no -i '$transfer_key_remote' '$archive_remote' 'root@$target_ip:$target_dir/leader-migration.tar.gz.partial'; scp -P '$ssh_port' -o StrictHostKeyChecking=no -i '$transfer_key_remote' '$archive_remote.sha256' 'root@$target_ip:$target_dir/leader-migration.tar.gz.sha256'"
		cleanup_transfer_credentials
	else
		log 'transferring archive via local machine'
		scp_source "$archive_remote" "$archive_local"
		scp_source "$archive_remote.sha256" "$archive_local.sha256"
		(
			cd -- "$run_dir"
			printf 'reput %s %s\nput %s %s\n' "$(basename "$archive_local")" "$target_dir/leader-migration.tar.gz.partial" "$(basename "$archive_local.sha256")" "$target_dir/leader-migration.tar.gz.sha256" |
				sftp -b - "${sftp_opts[@]}" "root@$target_ip"
		)
	fi
	ssh_target "set -Eeuo pipefail; expected=\$(sed 's/[[:space:]].*//' '$target_dir/leader-migration.tar.gz.sha256'); actual=\$(sha256sum '$target_dir/leader-migration.tar.gz.partial' | sed 's/[[:space:]].*//'); test \"\$expected\" = \"\$actual\"; mv -f '$target_dir/leader-migration.tar.gz.partial' '$target_dir/leader-migration.tar.gz'"
	set_phase target-copy-verified
fi

# Phase: target-extracted
if ! phase_at_least target-extracted; then
	log 'validating archive manifest and extracting managed state on target Leader'
	ssh_target "set -Eeuo pipefail; tar -tzf '$target_dir/leader-migration.tar.gz' > '$target_dir/manifest.txt'; grep -Eq '^etc/llm-hub-lite/node\.env$' '$target_dir/manifest.txt'; grep -Eq '^opt/platform/control/releases/$release_sha(/|$)' '$target_dir/manifest.txt'; tar -xzf '$target_dir/leader-migration.tar.gz' -C / --same-owner --numeric-owner --xattrs --acls --selinux; rm -rf '$target_dir'"
	ssh_target "set -Eeuo pipefail; for f in /etc/llm-hub-lite/node.env /etc/llm-hub-lite/shared-secrets.env; do if [ -f \"\$f\" ]; then sed -i 's/^LEADER_PUBLIC_IP=.*/LEADER_PUBLIC_IP=$target_ip/' \"\$f\"; fi; done"
	reconcile_missing_shared_secrets
	set_phase target-extracted
fi

# Phase: bootstrap-complete
if ! phase_at_least bootstrap-complete; then
	log 'running repair bootstrap on target Leader'
	bootstrap_local="$run_dir/bootstrap-vps.sh"
	cp "$bootstrap_source" "$bootstrap_local"
	chmod 600 "$bootstrap_local"
	scp_target "$bootstrap_local" /root/llm-hub-lite-bootstrap.sh
	ssh_target "chmod 700 /root/llm-hub-lite-bootstrap.sh; NODE_ID=leader LEADER_PUBLIC_IP='$target_ip' DOMAIN_NAME='$domain' BOOTSTRAP_MODE=repair BOOTSTRAP_ASSUME_YES=1 BOOTSTRAP_SKIP_SOURCE_UPDATE=1 BOOTSTRAP_SKIP_POST_BACKUP=1 BOOTSTRAP_RELEASE_SHA='$release_sha' /root/llm-hub-lite-bootstrap.sh"
	set_phase bootstrap-complete
fi

# Phase: followers-reconciled
if ! phase_at_least followers-reconciled; then
	log "reconciling LEADER_PUBLIC_IP=$target_ip and firewalls on all followers"
	followers="$(ssh_target "sed -n 's/^NODE_IDS=//p' /opt/platform/control/current/config/cluster/policy.env 2>/dev/null | tail -n1")"
	old_ifs="$IFS"
	IFS=','
	for fn in $followers; do
		[[ "$fn" != leader && -n "$fn" ]] || continue
		fip="$(resolve_node_ip "$fn")" || die "unable to resolve follower $fn IP"
		log "updating follower $fn ($fip)..."
		ssh_node "$fip" "set -Eeuo pipefail; for f in /etc/llm-hub-lite/node.env /etc/llm-hub-lite/shared-secrets.env; do if [ -f \"\$f\" ]; then sed -i 's/^LEADER_PUBLIC_IP=.*/LEADER_PUBLIC_IP=$target_ip/' \"\$f\"; fi; done; /usr/local/bin/configure-firewall; platformctl recreate beszel-worker"
	done
	IFS="$old_ifs"
	set_phase followers-reconciled
fi

# Phase: verification-complete
if ! phase_at_least verification-complete; then
	log 'verifying target Leader platform health and follower connections'
	ssh_target 'PLATFORM_READ_LOCK_WAIT=120 platformctl health'
	ssh_source 'test -z "$(docker ps --filter label=com.aichorage.platform=llm-hub-lite -q)"; test -f /etc/llm-hub-lite/maintenance'
	set_phase verification-complete
fi

migration_succeeded=1
log "Leader migration complete! ($source_ip -> $target_ip)"
log "Next steps:"
log "  1. Verify Cloudflare DNS points to $target_ip for observer-ingest, ci-grpc, and apex/origins."
log "  2. Confirm cluster services (https://$domain, https://ci.$domain, https://status.$domain)."
log "  3. On old Leader VPS ($source_ip), copy ops/clean-vps.sh outside managed paths and run with --confirm."
log "  4. Remove local backup archive at $run_dir once verified."
