#!/usr/bin/env bash
set -euo pipefail

date
mode="${1:-prod}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$mode" == prod && -x /usr/local/bin/platformctl ]]; then
  exec /usr/local/bin/platformctl recover
fi
exec "$script_dir/stack.sh" "$mode" restart
