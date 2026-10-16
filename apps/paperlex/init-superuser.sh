#!/usr/bin/env bash
# Paperlex custom container init: ensures the superuser is created
# idempotently at the end of container initialization, avoiding races
# with initial SQLite migrations.
set -eu

if [ -n "${PAPERLESS_ADMIN_USER:-}" ] && [ -n "${PAPERLESS_ADMIN_PASSWORD:-}" ]; then
	python3 /usr/src/paperless/src/manage.py manage_superuser
fi
