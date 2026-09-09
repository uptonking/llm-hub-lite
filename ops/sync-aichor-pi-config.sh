#!/usr/bin/env bash
# Safely import/export Pi's non-secret configuration for a persistent Paseo
# host. AICHOR remains the compatibility default; the generic
# sync-paseo-pi-config.sh wrapper sets PASEO_PI_APP_ID/PASEO_PI_PREFIX for
# another independent host such as Aichor3. The Compose project bind-mounts
# the complete app data directory
# at /home/paseo, so files managed here are immediately visible both on the VPS
# and inside the container.  auth.json is deliberately never copied.
set -Eeuo pipefail

usage() {
	cat >&2 <<'EOF'
usage:
  sync-aichor-pi-config.sh install <directory> [--restart]
  sync-aichor-pi-config.sh export <directory>
  sync-aichor-pi-config.sh check

The directory must contain settings.json and models.json.  The files are
installed below the persistent Aichor data root and are visible in the
container at /home/paseo/.pi/agent/.
EOF
	exit 2
}

die() {
	printf '%s Pi config: %s\n' "$app_id" "$*" >&2
	exit 1
}

app_id="${PASEO_PI_APP_ID:-aichor}"
prefix="${PASEO_PI_PREFIX:-AICHOR}"
[[ "$app_id" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid Paseo app id: $app_id"
[[ "$prefix" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid Paseo prefix: $prefix"
data_root="${PASEO_PI_DATA_ROOT:-${AICHOR_PI_DATA_ROOT:-}}"
if [[ -z "$data_root" && -f /opt/apps/llm-hub-lite/shared/.env.prod ]]; then
	data_root="$(sed -n 's/^DATA_ROOT=//p' /opt/apps/llm-hub-lite/shared/.env.prod | tail -n 1)"
fi
data_root="${data_root:-/opt/apps/llm-hub-lite/shared/data/prod}"
agent_dir="$data_root/$app_id/.pi/agent"

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

validate_json() {
	local file="$1"
	if command -v node >/dev/null 2>&1; then
		node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$file"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file"
	else
		printf 'warning: neither node nor python3 is available; JSON syntax was not checked for %s\n' "$file" >&2
	fi
}

container_name() {
	command -v docker >/dev/null 2>&1 || return 0
	docker ps --filter label=com.aichorage.application="$app_id" --format '{{.Names}}' | head -n 1
}

install_one() {
	local source="$1" target="$agent_dir/$2" staged backup stamp suffix=0
	[[ -f "$source" ]] || die "missing source file: $source"
	validate_json "$source" || die "invalid JSON: $source"
	mkdir -p "$agent_dir"
	staged="$(mktemp "$agent_dir/.$app_id-pi-config.XXXXXX")"
	trap 'rm -f -- "${staged:-}"' RETURN
	cp "$source" "$staged"
	chmod 600 "$staged"
	if [[ "$(id -u)" -eq 0 ]]; then
		chown 1000:1000 "$staged"
	fi
	if [[ -f "$target" ]]; then
		stamp="$(date -u +%Y%m%dT%H%M%SZ)"
		backup="$target.bak.$stamp"
		while [[ -e "$backup" ]]; do
			suffix=$((suffix + 1))
			backup="$target.bak.$stamp.$suffix"
		done
		cp -p "$target" "$backup"
		if [[ "$(id -u)" -eq 0 ]]; then
			chown 1000:1000 "$backup"
		fi
		printf 'backed up %s to %s\n' "$target" "$backup"
	fi
	mv -f "$staged" "$target"
	trap - RETURN
	printf 'installed %s (sha256 %s)\n' "$target" "$(hash_file "$target")"
}

install_config() {
	local source_dir="$1" restart=0 container
	[[ -d "$source_dir" ]] || die "source directory does not exist: $source_dir"
	[[ -r "$source_dir/settings.json" ]] || die "source directory lacks settings.json"
	[[ -r "$source_dir/models.json" ]] || die "source directory lacks models.json"
	install_one "$source_dir/settings.json" settings.json
	install_one "$source_dir/models.json" models.json
	if grep -Eq '"apiKey"[[:space:]]*:[[:space:]]*"[^$]' "$source_dir/models.json"; then
		printf 'warning: models.json contains a literal apiKey; prefer an environment reference and Woodpecker secret\n' >&2
	fi
	if [[ "${2:-}" == --restart ]]; then
		restart=1
	elif [[ -n "${2:-}" ]]; then
		usage
	fi
	if ((restart)); then
		container="$(container_name)"
		[[ -n "$container" ]] || die 'Aichor container is not running; cannot restart it'
		docker restart "$container" >/dev/null
		printf 'restarted %s\n' "$container"
	fi
}

export_config() {
	local destination="$1" name source target
	mkdir -p "$destination"
	for name in settings.json models.json; do
		source="$agent_dir/$name"
		target="$destination/$name"
		[[ -f "$source" ]] || die "persistent file is missing: $source"
		validate_json "$source" || die "invalid JSON in $source"
		cp "$source" "$target"
		chmod 600 "$target"
		printf 'exported %s (sha256 %s)\n' "$target" "$(hash_file "$target")"
	done
}

check_config() {
	local name source container inside_hash host_hash
	[[ -d "$agent_dir" ]] || die "Pi agent directory is missing: $agent_dir"
	for name in settings.json models.json; do
		source="$agent_dir/$name"
		[[ -f "$source" ]] || die "missing persistent file: $source"
		validate_json "$source" || die "invalid JSON in $source"
		host_hash="$(hash_file "$source")"
		printf '%s: %s\n' "$name" "$host_hash"
	done
	container="$(container_name)"
	if [[ -z "$container" ]]; then
		printf 'container: not running (disk files are still ready for the next start)\n'
		return 0
	fi
	for name in settings.json models.json; do
		inside_hash="$(docker exec "$container" sha256sum "/home/paseo/.pi/agent/$name" 2>/dev/null | awk '{print $1}')"
		[[ -n "$inside_hash" ]] || die "container cannot read /home/paseo/.pi/agent/$name"
		host_hash="$(hash_file "$agent_dir/$name")"
		[[ "$host_hash" == "$inside_hash" ]] || die "$name differs between disk and container"
	done
	printf 'disk/container Pi configuration is synchronized for %s (container %s)\n' "$app_id" "$container"
}

[[ $# -ge 1 ]] || usage
case "$1" in
install)
	[[ $# -ge 2 && $# -le 3 ]] || usage
	install_config "$2" "${3:-}"
	;;
export)
	[[ $# -eq 2 ]] || usage
	export_config "$2"
	;;
check)
	[[ $# -eq 1 ]] || usage
	check_config
	;;
*)
	usage
	;;
esac
