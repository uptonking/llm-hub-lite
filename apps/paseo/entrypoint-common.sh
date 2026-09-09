#!/bin/sh
set -eu

# Shared runtime preparation for repository-owned Paseo hosts.  Each thin app
# wrapper sets PASEO_APP_PREFIX and optionally overrides the home/workspace
# paths, leaving state and credentials isolated per application.
prefix="${PASEO_APP_PREFIX:?PASEO_APP_PREFIX must be set}"
home="${PASEO_PARENT_HOME:-/home/paseo}"
daemon_home="${PASEO_HOME:-$home/.paseo}"
workspace="${PASEO_WORKSPACE:-/workspace}"
marker="${PASEO_OWNERSHIP_MARKER:-.$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')-ownership-v1}"
ownership_marker="$home/$marker"

mkdir -p "$home/.paseo" "$home/.pi" "$workspace"

# Aichor3 was initially released with the parent home as PASEO_HOME. Preserve
# its freshly-created durable identity when switching to the image's standard
# /home/paseo/.paseo layout. Copies are intentionally retained at the legacy
# location until an operator removes them.
if [ "$daemon_home" != "$home" ] && [ -f "$home/server-id" ] && [ ! -e "$daemon_home/server-id" ]; then
	mkdir -p "$daemon_home"
	for item in server-id daemon-keypair.json config.json daemon.log paseo.pid models schedules runtime; do
		if [ -e "$home/$item" ] && [ ! -e "$daemon_home/$item" ]; then
			cp -a "$home/$item" "$daemon_home/$item"
		fi
	done
fi
if [ ! -e "$ownership_marker" ]; then
	chown -R 1000:1000 "$home" "$workspace"
	touch "$ownership_marker"
	chown 1000:1000 "$ownership_marker"
else
	chown 1000:1000 "$home" "$workspace"
fi

# Docker exec and maintenance commands can leave nested state root-owned.
# Repair only the active state trees on every start.
if [ "$daemon_home" = "$home/.paseo" ]; then
	chown -R 1000:1000 "$home/.paseo" "$home/.pi"
else
	chown -R 1000:1000 "$home/.paseo" "$home/.pi" "$daemon_home"
fi

provider_env() {
	provider="$1"
	key=''
	enabled=''
	case "$provider" in
	OPENAI)
		key_var="${prefix}_PI_OPENAI_API_KEY"
		enabled_var="${prefix}_PI_OPENAI_ENABLED"
		export_var=OPENAI_API_KEY
		;;
	ANTHROPIC)
		key_var="${prefix}_PI_ANTHROPIC_API_KEY"
		enabled_var="${prefix}_PI_ANTHROPIC_ENABLED"
		export_var=ANTHROPIC_API_KEY
		;;
	OPENROUTER)
		key_var="${prefix}_PI_OPENROUTER_API_KEY"
		enabled_var="${prefix}_PI_OPENROUTER_ENABLED"
		export_var=OPENROUTER_API_KEY
		;;
	*) return 2 ;;
	esac
	eval "enabled=\${$enabled_var:-false}"
	if [ "$enabled" = true ]; then
		eval "key=\${$key_var:-}"
		[ -n "$key" ] || {
			printf '%s is required when %s=true\n' "$key_var" "$enabled_var" >&2
			exit 1
		}
		eval "export $export_var=\"\$key\""
	else
		unset "$export_var"
	fi
}

provider_env OPENAI
provider_env ANTHROPIC
provider_env OPENROUTER

exec "${PASEO_BASE_ENTRYPOINT:-/usr/local/bin/paseo-docker-entrypoint}" "$@"
