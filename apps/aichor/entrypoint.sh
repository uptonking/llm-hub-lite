#!/bin/sh
set -eu

aichor_home="${AICHOR_HOME:-/home/paseo}"
aichor_workspace="${AICHOR_WORKSPACE:-/workspace}"
ownership_marker="$aichor_home/.aichor-ownership-v1"

mkdir -p "$aichor_home/.paseo" "$aichor_home/.pi" "$aichor_workspace"
if [ ! -e "$ownership_marker" ]; then
	chown -R 1000:1000 "$aichor_home" "$aichor_workspace"
	touch "$ownership_marker"
	chown 1000:1000 "$ownership_marker"
else
	chown 1000:1000 "$aichor_home" "$aichor_workspace"
fi

# Docker exec and maintenance commands can leave nested state root-owned.
# Repair the two active state trees on every start without scanning all agents.
chown -R 1000:1000 "$aichor_home/.paseo" "$aichor_home/.pi"

if [ "${AICHOR_PI_OPENAI_ENABLED:-false}" = true ]; then
	: "${AICHOR_PI_OPENAI_API_KEY:?AICHOR_PI_OPENAI_API_KEY is required when AICHOR_PI_OPENAI_ENABLED=true}"
	export OPENAI_API_KEY="$AICHOR_PI_OPENAI_API_KEY"
else
	unset OPENAI_API_KEY
fi
if [ "${AICHOR_PI_ANTHROPIC_ENABLED:-false}" = true ]; then
	: "${AICHOR_PI_ANTHROPIC_API_KEY:?AICHOR_PI_ANTHROPIC_API_KEY is required when AICHOR_PI_ANTHROPIC_ENABLED=true}"
	export ANTHROPIC_API_KEY="$AICHOR_PI_ANTHROPIC_API_KEY"
else
	unset ANTHROPIC_API_KEY
fi
if [ "${AICHOR_PI_OPENROUTER_ENABLED:-false}" = true ]; then
	: "${AICHOR_PI_OPENROUTER_API_KEY:?AICHOR_PI_OPENROUTER_API_KEY is required when AICHOR_PI_OPENROUTER_ENABLED=true}"
	export OPENROUTER_API_KEY="$AICHOR_PI_OPENROUTER_API_KEY"
else
	unset OPENROUTER_API_KEY
fi

exec "${AICHOR_BASE_ENTRYPOINT:-/usr/local/bin/paseo-docker-entrypoint}" "$@"
