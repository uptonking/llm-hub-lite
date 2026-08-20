#!/usr/bin/env bash
set -euo pipefail

date
mode="${1:-prod}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"
mkdir -p bak
date >> bak/docker-image-versions.txt
docker images >> bak/docker-image-versions.txt

"$script_dir/stack.sh" "$mode" pull
"$script_dir/stack.sh" "$mode" up
