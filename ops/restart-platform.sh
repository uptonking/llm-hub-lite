#!/usr/bin/env bash
set -Eeuo pipefail

exec "${PLATFORMCTL_SCRIPT:-/usr/local/bin/platformctl}" restart "${1:-all}"
