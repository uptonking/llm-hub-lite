#!/bin/sh
set -eu

export PASEO_APP_PREFIX=AICHOR
export PASEO_HOME="${AICHOR_HOME:-${PASEO_HOME:-/home/paseo}}"
export PASEO_WORKSPACE="${AICHOR_WORKSPACE:-${PASEO_WORKSPACE:-/workspace}}"
export PASEO_OWNERSHIP_MARKER=.aichor-ownership-v1
export PASEO_BASE_ENTRYPOINT="${AICHOR_BASE_ENTRYPOINT:-${PASEO_BASE_ENTRYPOINT:-/usr/local/bin/paseo-docker-entrypoint}}"
common="${PASEO_COMMON_ENTRYPOINT:-/paseo-entrypoint-common.sh}"
if [ ! -x "$common" ]; then
	common="$(cd -- "$(dirname -- "$0")/../paseo" && pwd)/entrypoint-common.sh"
fi
exec "$common" "$@"
