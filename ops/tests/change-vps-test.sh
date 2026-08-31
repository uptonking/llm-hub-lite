#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions match literal '$var' text in the script source
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ops/change-vps-for-consumer-node.sh"
bash -n "$script"
grep -Fq 'DNS records must already be updated' "$script"
grep -Fq -- '--dry-run' "$script"
grep -Fq -- '--resume' "$script"
grep -Fq -- '--assume-yes' "$script"
grep -Fq -- '--backup-dir' "$script"
grep -Fq -- '--known-hosts' "$script"
grep -Fq -- '--strict-dns' "$script"
grep -Fq -- '--disable-restic-backup' "$script"
grep -Fq 'DNS checks are advisory' "$script"
grep -Fq 'scp_opts=(-P "$ssh_port"' "$script"
grep -Fq 'StrictHostKeyChecking=yes' "$script"
if grep -Fq 'StrictHostKeyChecking=accept-new' "$script"; then
	printf 'migration must not accept new SSH host keys automatically\n' >&2
	exit 1
fi
grep -Fq 'source and target addresses must differ' "$script"
grep -Fq 'source node must be active' "$script"
grep -Fq 'source has an active deployment or platform transaction' "$script"
grep -Fq 'PLATFORM_READ_LOCK_WAIT=120 platformctl health' "$script"
grep -Fq 'refusing to migrate the Leader node' "$script"
grep -Fq 'target is not a fresh VPS' "$script"
grep -Fq 'unsupported managed data root' "$script"
grep -Fq 'source has insufficient free space' "$script"
grep -Fq 'target has insufficient free space' "$script"
grep -Fq 'local backup volume has insufficient free space' "$script"
grep -Fq 'platformctl maintenance begin vps-migration' "$script"
grep -Fq '/etc/systemd/system/platform.target' "$script"
grep -Fq 'export PLATFORM_LOCK_HELD=1' "$script"
grep -Fq -- "--exclude='etc/llm-hub-lite/maintenance'" "$script"
grep -Fq -- "--exclude='opt/platform/observer/collector-buffer'" "$script"
grep -Fq -- "--exclude='opt/platform/*restic*'" "$script"
grep -Fq 'opt/apps/llm-hub-lite opt/platform etc/llm-hub-lite' "$script"
grep -Fq 'sha256sum' "$script"
grep -Fq 'unexpected archive path' "$script"
grep -Fq 'BOOTSTRAP_SKIP_SOURCE_UPDATE=1' "$script"
grep -Fq 'BOOTSTRAP_SKIP_POST_BACKUP=1' "$script"
grep -Fq 'BOOTSTRAP_RELEASE_SHA=' "$script"
grep -Fq 'source recovery (only if the old VPS must be restored)' "$script"
grep -Fq 'bootstrap_source="$repo_root/ops/bootstrap-vps.sh"' "$script"
grep -Fq 'migration: FAILED during phase' "$script"
grep -Fq 'preflight failed; no VPS state was changed' "$script"
grep -Fq 'unsupported migration state version' "$script"
grep -Fq 'DISABLE_RESTIC_BACKUP=%s' "$script"
grep -Fq 'requires BACKUP_ENABLED=false in the deployed' "$script"
grep -Fq 'requires BACKUP_ENABLED=false in the source runtime' "$script"
grep -Fq 'systemctl disable --now platform-backup.timer platform-backup-prune.timer platform-backup-check.timer' "$script"
grep -Fq 'Restic backups and backup maintenance timers are disabled on the target' "$script"
grep -Fq 'if phase_at_least local-copy-verified' "$script"
grep -Fq 'Restic path is inside an archived managed root' "$script"
grep -Fq 'platform units, backup state, or networks were found' "$script"
grep -Fq 'test -e /opt/backups/llm-hub-lite' "$script"
grep -Fq -- "--exclude='opt/platform/*/collector-buffer'" "$script"
grep -Fq 'archive is missing the source node identity' "$script"
grep -Fq 'archive is missing the source current release' "$script"
grep -Fq 'unsafe archive symlink target' "$script"
grep -Fq 'backup_root="$PWD/$backup_root"' "$script"
grep -Fq 'verify_local_archive()' "$script"
grep -Fq 'verify_target_archive()' "$script"
grep -Fq 'verify_target_identity()' "$script"
grep -Fq 'verify_target_health()' "$script"
grep -Fq 'PLATFORM_READ_LOCK_WAIT=120 platformctl health' "$script"
grep -Fq 'flock -w 120 -x 9' "$script"
grep -Fq 'resume Leader IP is invalid' "$script"
grep -Fq 'resume domain is invalid' "$script"
grep -Fq 'ROUTE_GROUPS=' "$script"
grep -Fq 'discover_source_origins()' "$script"
grep -Fq 'LibreChat' "$script"

if "$script" --help >/dev/null 2>&1; then :; else
	printf 'migration help failed\n' >&2
	exit 1
fi
if "$script" 192.0.2.1 192.0.2.1 >/dev/null 2>&1; then
	printf 'migration accepted identical addresses\n' >&2
	exit 1
fi
if "$script" 999.0.2.1 192.0.2.2 >/dev/null 2>&1; then
	printf 'migration accepted invalid source address\n' >&2
	exit 1
fi

# A run interrupted after the remote archive was created must be resumable
# without a local archive yet. Mock only the read-only SSH calls needed by a
# dry-run resume; the real SSH/SCP paths remain covered by the static checks.
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/change-vps-resume.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT
mkdir -p "$tmp_root/bin" "$tmp_root/backup/migration-fixture"
printf 'fixture\n' >"$tmp_root/known_hosts"
printf 'fixture\n' >"$tmp_root/backup/migration-fixture/migration.state"
cat >"$tmp_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"s/^NODE_ID="*) printf 'worker-1\n' ;;
esac
exit 0
EOF
chmod 700 "$tmp_root/bin/ssh"
printf '%s\n' \
	'VERSION=3' \
	'PHASE=archive-created' \
	'SOURCE_IP=192.0.2.1' \
	'TARGET_IP=192.0.2.2' \
	'NODE_ID=worker-1' \
	'RELEASE_SHA=0123456789012345678901234567890123456789' \
	'LEADER_IP=192.0.2.254' \
	'DOMAIN=aichorage.de' \
	'DISABLE_RESTIC_BACKUP=1' \
	"RUN_DIR=$tmp_root/backup/migration-fixture" \
	"ARCHIVE=$tmp_root/backup/migration-fixture/node-migration.tar.gz" \
	>"$tmp_root/backup/migration-fixture/migration.state"
output="$(PATH="$tmp_root/bin:$PATH" "$script" --dry-run --resume --known-hosts "$tmp_root/known_hosts" --backup-dir "$tmp_root/backup" 192.0.2.1 192.0.2.2)"
grep -Fq 'Restic backups will remain disabled for worker-1' <<<"$output"

# Storage policy cannot be changed after a migration has started. Version 2
# state predates the option and therefore always means backups were not disabled.
sed -i.bak 's/^VERSION=3$/VERSION=2/' "$tmp_root/backup/migration-fixture/migration.state"
rm -f -- "$tmp_root/backup/migration-fixture/migration.state.bak"
if PATH="$tmp_root/bin:$PATH" "$script" --dry-run --resume --disable-restic-backup --known-hosts "$tmp_root/known_hosts" --backup-dir "$tmp_root/backup" 192.0.2.1 192.0.2.2 >/dev/null 2>&1; then
	printf 'migration allowed Restic policy to change during resume\n' >&2
	exit 1
fi
printf 'change-vps migration checks passed\n'
