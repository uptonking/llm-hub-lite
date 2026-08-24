#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_ROOT=/opt/apps/llm-hub-lite
PLATFORM_ROOT=/opt/platform
CONFIG_ROOT=/etc/llm-hub-lite
BACKUP_ROOT=/opt/backups/llm-hub-lite
LOCK_ROOT=/run/lock/llm-hub-lite
BOOTSTRAP_FILE=/root/llm-hub-lite-bootstrap.sh
SYSTEMD_ROOT=/etc/systemd/system
BIN_ROOT=/usr/local/bin

dry_run=1
delete_backups=0
delete_images=0
TEST_MODE="${CLEAN_VPS_TEST_MODE:-0}"

die() {
	printf 'clean-vps: ERROR: %s\n' "$*" >&2
	exit 1
}
log() { printf 'clean-vps: %s\n' "$*"; }
usage() {
	cat <<'EOF'
Usage: clean-vps.sh [--dry-run] [--confirm] [--delete-local-backups] [--delete-images]

The default is a read-only cleanup preview. Destructive cleanup requires an
interactive --confirm and the exact phrase DELETE LLM-HUB-LITE DATA.
EOF
}

while (($#)); do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--confirm) dry_run=0 ;;
	--delete-local-backups) delete_backups=1 ;;
	--delete-images) delete_images=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown option: $1"
		;;
	esac
	shift
done
[[ "$EUID" -eq 0 || "$TEST_MODE" == 1 ]] || die 'run as root on the VPS'

for target in "$APP_ROOT" "$PLATFORM_ROOT" "$CONFIG_ROOT" "$BACKUP_ROOT" "$LOCK_ROOT" "$BOOTSTRAP_FILE"; do
	case "$target" in / | /opt | /etc | /run | /root | /var | /usr | '') die "unsafe target: $target" ;; esac
	[[ ! -L "$target" ]] || die "refusing to delete symlink target: $target"
done
if [[ "$TEST_MODE" != 1 ]]; then
	script_path="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
	case "$script_path" in
	"$APP_ROOT"/* | "$PLATFORM_ROOT"/* | "$CONFIG_ROOT"/* | "$BACKUP_ROOT"/*)
		die 'copy this script outside the managed paths before confirming cleanup'
		;;
	esac
fi

have() { command -v "$1" >/dev/null 2>&1; }
append_unique() {
	local name="$1" value="$2" item
	local -n values="$name"
	for item in "${values[@]}"; do [[ "$item" == "$value" ]] && return 0; done
	values+=("$value")
}
owned_container() {
	local id="$1" label name
	label="$(docker inspect --format '{{ index .Config.Labels "com.aichorage.platform" }}' "$id" 2>/dev/null || true)"
	[[ "$label" == llm-hub-lite ]] && return 0
	name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null || true)"
	[[ "$name" == /llm-hub-lite-platform-apply-* ]]
}

units=(platform.target platform-network.service platform-firewall.service
	platform-firewall.timer platform-firewall.path platform-recovery.service
	platform-recovery-retry.service platform-recovery.timer platform-health.service
	platform-health.timer platform-backup.service platform-backup.timer
	platform-backup-prune.service platform-backup-prune.timer
	platform-backup-check.service platform-backup-check.timer
	platform-beszel-enroll.service platform-beszel-enroll.timer)
wrappers=(platformctl restart-platform backup-platform restore-platform configure-beszel
	configure-firewall enroll-beszel upgrade-runner platform-submit deploy-controller
	generate-woodpecker-workflows git-auth.sh platform-compose)
projects=(foundation-caddy foundation-beszel-controller foundation-beszel-worker
	foundation-woodpecker-controller foundation-woodpecker-worker foundation-woodpecker-deployer
	app-librechat app-newapi app-aichorouter app-cpapi)
containers=() networks=(platform_edge foundation-woodpecker_private app-librechat_private
	app-newapi_private app-aichorouter_private app-cpapi_private) images=(llm-hub-lite/deploy-runner:current)

collect_systemd_units() {
	local path base
	for path in "$SYSTEMD_ROOT"/platform-*; do
		[[ -f "$path" ]] || continue
		base="${path##*/}"
		case "$base" in
		platform.target | platform-*.service | platform-*.timer | platform-*.path) append_unique units "$base" ;;
		esac
	done
}

collect_manifest_images() {
	local file key value
	for file in "$CONFIG_ROOT/images.foundation.env" "$CONFIG_ROOT/images.apps.env" \
		"$PLATFORM_ROOT/source/ops/images.foundation.prod.env" "$PLATFORM_ROOT/source/ops/images.apps.prod.env"; do
		[[ -r "$file" ]] || continue
		while IFS='=' read -r key value; do
			[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$value" && "$value" != \#* ]] || continue
			append_unique images "$value"
		done <"$file"
	done
}

collect_descriptor_networks() {
	local manifest project
	for manifest in "$PLATFORM_ROOT/source"/apps/*/manifest.env; do
		[[ -r "$manifest" ]] || continue
		project="$(sed -n 's/^COMPOSE_PROJECT=//p' "$manifest" | tail -n1)"
		[[ "$project" =~ ^app-[a-z0-9-]+$ ]] || continue
		append_unique networks "${project}_private"
	done
}

collect_docker() {
	local id project image
	have docker || return 0
	while IFS= read -r id; do
		[[ -n "$id" ]] && owned_container "$id" && append_unique containers "$id"
	done < <(docker ps -aq --filter label=com.aichorage.platform=llm-hub-lite 2>/dev/null || true)
	while IFS= read -r id; do
		[[ -n "$id" ]] && owned_container "$id" && append_unique containers "$id"
	done < <(docker ps -aq --filter name='^/llm-hub-lite-platform-apply-' 2>/dev/null || true)
	for project in "${projects[@]}"; do
		while IFS= read -r id; do
			[[ -n "$id" ]] && owned_container "$id" && append_unique containers "$id"
		done < <(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
	done
	for id in "${containers[@]-}"; do
		[[ -n "$id" ]] || continue
		image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"
		if [[ -n "$image" ]]; then append_unique images "$image"; fi
	done
	return 0
}
collect_docker
collect_systemd_units
collect_manifest_images
collect_descriptor_networks

print_plan() {
	local path unit id network
	printf 'llm-hub-lite VPS cleanup plan\n\nManaged paths:\n'
	for path in "$APP_ROOT" "$PLATFORM_ROOT" "$CONFIG_ROOT" "$LOCK_ROOT" "$BOOTSTRAP_FILE"; do
		[[ -e "$path" || -L "$path" ]] && printf '  delete %s\n' "$path" || printf '  absent %s\n' "$path"
	done
	if ((delete_backups)); then printf '  delete %s (explicitly selected)\n' "$BACKUP_ROOT"; else printf '  preserve %s (default)\n' "$BACKUP_ROOT"; fi
	printf '\nSystemd units:\n'
	for unit in "${units[@]}"; do [[ -e "$SYSTEMD_ROOT/$unit" || -L "$SYSTEMD_ROOT/$unit" ]] && printf '  disable/remove %s\n' "$unit"; done
	printf '\nContainers:\n'
	if [[ -z "${containers[*]-}" ]]; then printf '  none\n'; else for id in "${containers[@]}"; do printf '  remove %s\n' "$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null || printf '%s' "$id")"; done; fi
	printf '\nNetworks (removed only when empty after container cleanup):\n'
	for network in "${networks[@]}"; do have docker && docker network inspect "$network" >/dev/null 2>&1 && printf '  %s\n' "$network"; done
	if ((delete_images)); then
		printf '\nImages eligible when unused by unrelated containers:\n'
		printf '  %s\n' "${images[@]}"
	else printf '\nDocker images: preserve (default)\n'; fi
	printf '\nFirewall/UFW and remote Restic/R2, Atlas, and Upstash data: unchanged.\n'
}

print_plan
if ((dry_run)); then
	printf '\nDry run only; no changes were made.\n'
	exit 0
fi
[[ -t 0 && -t 1 ]] || die '--confirm requires an interactive terminal'
read -r -p $'Type DELETE LLM-HUB-LITE DATA to continue: ' confirmation
[[ "$confirmation" == 'DELETE LLM-HUB-LITE DATA' ]] || die 'confirmation did not match; nothing was deleted'

if have systemctl; then
	for unit in "${units[@]}"; do
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			log "stopping systemd unit: $unit"
		fi
		systemctl disable --now "$unit" >/dev/null 2>&1 || true
	done
fi
if have docker; then
	for id in "${containers[@]-}"; do
		[[ -n "$id" ]] || continue
		name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null || printf '%s' "$id")"
		if docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null | grep -qx true; then
			log "stopping Docker container: $name"
			docker stop --time 90 "$id" >/dev/null 2>&1 || die "unable to stop Docker container: $name"
		fi
	done
	for id in "${containers[@]-}"; do
		[[ -n "$id" ]] || continue
		name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null || printf '%s' "$id")"
		log "removing Docker container: $name"
		docker rm "$id" >/dev/null 2>&1 || die "unable to remove Docker container: $name"
	done
	for network in "${networks[@]}"; do
		docker network inspect "$network" >/dev/null 2>&1 || continue
		attached="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$id}} {{end}}' "$network" 2>/dev/null || true)"
		safe=1
		for id in $attached; do owned_container "$id" || safe=0; done
		if ((safe)); then
			if docker network rm "$network" >/dev/null 2>&1; then
				log "removing Docker network: $network"
			else
				printf 'clean-vps: preserved network (not removable): %s\n' "$network" >&2
			fi
		else
			printf 'clean-vps: preserved network with unrelated containers: %s\n' "$network" >&2
		fi
	done
fi
for wrapper in "${wrappers[@]}"; do
	path="$BIN_ROOT/$wrapper"
	if [[ -e "$path" || -L "$path" ]]; then
		log "deleting wrapper: $path"
		rm -f -- "$path"
	fi
done
for unit in "${units[@]}"; do
	path="$SYSTEMD_ROOT/$unit"
	if [[ -e "$path" || -L "$path" ]]; then
		log "deleting systemd unit file: $path"
		rm -f -- "$path"
	fi
done
if have systemctl; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
for path in "$APP_ROOT" "$PLATFORM_ROOT" "$CONFIG_ROOT" "$LOCK_ROOT" "$BOOTSTRAP_FILE"; do
	if [[ -e "$path" || -L "$path" ]]; then
		log "deleting managed path: $path"
		rm -rf -- "$path"
	fi
done
if ((delete_backups)) && [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
	log "deleting local backups: $BACKUP_ROOT"
	rm -rf -- "$BACKUP_ROOT"
fi

if ((delete_images)) && have docker; then
	for image in "${images[@]}"; do
		if docker image rm "$image" >/dev/null 2>&1; then
			log "deleting Docker image: $image"
		else
			printf 'clean-vps: preserved image (still used or unavailable): %s\n' "$image" >&2
		fi
	done
fi
printf '\nCleanup complete. Firewall/UFW and remote backups were left unchanged.\n'
((delete_backups)) || printf 'Local Restic backups remain at %s.\n' "$BACKUP_ROOT"
((delete_images)) || printf 'Docker images were preserved.\n'
