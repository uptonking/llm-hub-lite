#!/usr/bin/env bash
set -euo pipefail

date
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/stack.sh" "${1:-prod}" reload
