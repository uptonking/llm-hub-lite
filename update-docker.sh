#!/usr/bin/env bash
set -euo pipefail

date
mode="${1:-prod}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$mode" == prod && -x /usr/local/bin/platformctl ]]; then
  exec /usr/local/bin/platformctl upgrade
fi
cd "$script_dir"
mkdir -p bak
date >> bak/docker-image-versions.txt
docker images >> bak/docker-image-versions.txt

"$script_dir/stack.sh" "$mode" pull
"$script_dir/stack.sh" "$mode" up
