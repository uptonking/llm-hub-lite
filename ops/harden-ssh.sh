#!/usr/bin/env bash
# llm-hub-lite: refuse SSH password logins on a platform node.
#
# Why this exists
# ---------------
# DartNode Ubuntu images ship `PasswordAuthentication yes` (and even
# `PermitRootLogin yes` in /etc/ssh/sshd_config.d/01-dartnode.conf). On
# 2026-09-29 and 2026-10-04 worker-2 was compromised through exactly that
# vector: 22 successful root password logins from five external addresses in
# the 104.28.x, 185.121.108.x and 108.165.12.x ranges (the exact source
# addresses stay in the node-local quarantine and out of this repository).
# The attacker then installed an XMRig miner disguised as
# `/opt/.cache/khugepaged` (2.28 GiB RSS) and a Bitping container dropper in
# /tmp. Deleting the malware is not a fix while password logins stay possible,
# so every node must refuse them.
#
# Callers
# -------
# * ops/bootstrap-vps.sh      - hardens each freshly provisioned node.
# * ops/configure-firewall.sh - re-applies the policy on every existing node
#   from the current control release, so drift is corrected without a manual
#   SSH procedure. That path passes PLATFORM_SSH_HARDENING_QUIET=1 to keep the
#   five-minute timer silent while the policy is already correct.
#
# Ordering
# --------
# sshd honours the FIRST value obtained for a keyword. Because
# `/etc/ssh/sshd_config` includes `sshd_config.d/*.conf` before its own
# directives, and the glob is read in sorted order, a `00-` drop-in wins over
# the provider's `01-dartnode.conf` and `50-cloud-init.conf`. The policy
# therefore survives the provider rewriting its own files.
#
# Safety
# ------
# Password authentication is only disabled while a usable public key is already
# installed, so this script cannot lock an operator out. The configuration is
# syntax-checked before reload and restored if sshd rejects it or the reload
# fails. Set PLATFORM_SSH_HARDENING=0 in /etc/llm-hub-lite/platform.env to opt
# out on a node that intentionally keeps password logins.
set -Eeuo pipefail
umask 077

DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
DROPIN_NAME='00-llm-hub-lite-hardening.conf'
DROPIN="$DROPIN_DIR/$DROPIN_NAME"

# Capture explicit caller intent before the committed environment is sourced,
# mirroring ops/configure-firewall.sh, so an operator can still override it.
caller_hardening="${PLATFORM_SSH_HARDENING:-}"
caller_force="${PLATFORM_SSH_HARDENING_FORCE:-}"
caller_quiet="${PLATFORM_SSH_HARDENING_QUIET:-}"
config_file="${DEPLOY_CONFIG_FILE:-/etc/llm-hub-lite/platform.env}"
if [[ -r "$config_file" ]]; then
	# shellcheck disable=SC1090
	source "$config_file"
fi
PLATFORM_SSH_HARDENING="${caller_hardening:-${PLATFORM_SSH_HARDENING:-1}}"
PLATFORM_SSH_HARDENING_FORCE="${caller_force:-${PLATFORM_SSH_HARDENING_FORCE:-0}}"
PLATFORM_SSH_HARDENING_QUIET="${caller_quiet:-${PLATFORM_SSH_HARDENING_QUIET:-0}}"

log() { printf 'harden-ssh: %s\n' "$*"; }
note() { truthy "$PLATFORM_SSH_HARDENING_QUIET" || log "$*"; }
skip() {
	note "$*"
	exit 0
}
die() {
	printf 'harden-ssh: %s\n' "$*" >&2
	exit 1
}

truthy() {
	case "${1:-}" in
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	*) return 1 ;;
	esac
}

truthy "$PLATFORM_SSH_HARDENING" || skip 'disabled by PLATFORM_SSH_HARDENING'
command -v sshd >/dev/null 2>&1 || skip 'sshd is not installed'

# A key counts only when it is a real public key line, never an empty or
# comment-only file left behind by a provisioning script.
has_authorized_key() {
	local file
	for file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
		[[ -s "$file" ]] || continue
		if grep -qE '^[[:space:]]*(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]' "$file" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

if ! has_authorized_key && ! truthy "$PLATFORM_SSH_HARDENING_FORCE"; then
	log 'no usable SSH public key found; leaving password authentication enabled'
	log 'install a key, then re-run with PLATFORM_SSH_HARDENING_FORCE=1 to enforce'
	exit 0
fi

new_config="$DROPIN.tmp.$$"
backup_config="$DROPIN.backup.$$"
cleanup() { rm -f -- "$new_config" "$backup_config"; }
trap cleanup EXIT

cat >"$new_config" <<'EOF'
# Managed by llm-hub-lite (ops/harden-ssh.sh). Do not edit by hand.
# Closes the SSH password brute-force vector that compromised worker-2.
# This file sorts before the provider drop-ins (01-dartnode.conf,
# 50-cloud-init.conf); sshd honours the first obtained value, so it wins.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
chmod 600 "$new_config"

install -d -m 755 "$DROPIN_DIR"
previous_digest=''
[[ -f "$DROPIN" ]] && previous_digest="$(sha256sum "$DROPIN" | awk '{print $1}')"
new_digest="$(sha256sum "$new_config" | awk '{print $1}')"

restore_previous() {
	if [[ -f "$backup_config" ]]; then
		install -o root -g root -m 600 "$backup_config" "$DROPIN"
	else
		rm -f -- "$DROPIN"
	fi
}

if [[ "$previous_digest" != "$new_digest" ]]; then
	[[ -f "$DROPIN" ]] && cp -p -- "$DROPIN" "$backup_config"
	install -o root -g root -m 600 "$new_config" "$DROPIN"
	if ! sshd -t 2>/dev/null; then
		restore_previous
		die 'sshd rejected the hardening drop-in; previous configuration restored'
	fi
	if ! systemctl reload ssh 2>/dev/null && ! systemctl reload sshd 2>/dev/null; then
		restore_previous
		systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
		die 'unable to reload sshd; previous configuration restored'
	fi
	log "wrote $DROPIN and reloaded sshd"
else
	note 'policy already applied'
fi

# Report the configuration sshd actually resolved, not the file we wrote.
effective="$(sshd -T 2>/dev/null || true)"
if [[ -n "$effective" ]]; then
	password_auth="$(sed -n 's/^passwordauthentication //p' <<<"$effective" | head -n1)"
	root_login="$(sed -n 's/^permitrootlogin //p' <<<"$effective" | head -n1)"
	[[ "$password_auth" == 'no' ]] || die "password authentication is still '$password_auth'"
	note "effective policy: passwordauthentication=$password_auth permitrootlogin=$root_login"
fi
