#!/bin/sh
set -eu

mkdir -p /home/filebrowser/data /srv/shared /srv/personal

exec ./filebrowser run -c /home/filebrowser/config/config.yaml "$@"
