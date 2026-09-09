#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat >&2 <<'EOF'
usage:
  sync-paseo-pi-config.sh <app-id> install <directory> [--restart]
  sync-paseo-pi-config.sh <app-id> export <directory>
  sync-paseo-pi-config.sh <app-id> check
EOF
	exit 2
}

[[ $# -ge 2 ]] || usage
app_id="$1"
shift
[[ "$app_id" =~ ^[a-z][a-z0-9-]*$ ]] || {
	printf 'invalid Paseo app id: %s\n' "$app_id" >&2
	exit 1
}
prefix="$(printf '%s' "$app_id" | tr '[:lower:]-' '[:upper:]_')"
script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/sync-aichor-pi-config.sh"
PASEO_PI_APP_ID="$app_id" PASEO_PI_PREFIX="$prefix" exec bash "$script" "$@"
