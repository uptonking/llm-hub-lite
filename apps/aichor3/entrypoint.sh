#!/bin/sh
set -eu

export PASEO_APP_PREFIX=AICHOR3
parent_home="${AICHOR3_HOME:-}"
if [ -z "$parent_home" ]; then
	case "${PASEO_HOME:-}" in
	*/.paseo) parent_home="${PASEO_HOME%/.paseo}" ;;
	*) parent_home="${PASEO_HOME:-/home/paseo}" ;;
	esac
fi
export PASEO_PARENT_HOME="$parent_home"
export PASEO_HOME="${PASEO_HOME:-$PASEO_PARENT_HOME/.paseo}"
export PASEO_WORKSPACE="${AICHOR3_WORKSPACE:-${PASEO_WORKSPACE:-/workspace}}"
export PASEO_OWNERSHIP_MARKER=.aichor3-ownership-v1
export PASEO_BASE_ENTRYPOINT="${AICHOR3_BASE_ENTRYPOINT:-${PASEO_BASE_ENTRYPOINT:-/usr/local/bin/paseo-docker-entrypoint}}"
common="${PASEO_COMMON_ENTRYPOINT:-/paseo-entrypoint-common.sh}"
if [ ! -x "$common" ]; then
	common="$(cd -- "$(dirname -- "$0")/../paseo" && pwd)/entrypoint-common.sh"
fi
exec "$common" "$@"
