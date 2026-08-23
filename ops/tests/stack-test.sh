#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK_ENV_FILE="$repo_root/.env.dev.example" STACK_RUNTIME_ROOT="$(mktemp -d)" "$repo_root/stack.sh" dev validate >/dev/null
printf 'stack role validation tests passed\n'
