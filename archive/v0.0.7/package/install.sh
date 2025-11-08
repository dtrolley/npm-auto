#!/bin/bash
set -euo pipefail
PLUGIN_NAME="npm-auto"
DEST="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
echo "Running install.sh for $PLUGIN_NAME"
mkdir -p "${DEST}/webGui" "${DEST}/scripts" "${DEST}/var"
if [ -f "${DEST}/scripts/npm-auto-service.sh" ]; then chmod +x "${DEST}/scripts/npm-auto-service.sh"; fi
if [ -f "${DEST}/scripts/npm-auto-daemon.sh" ]; then chmod +x "${DEST}/scripts/npm-auto-daemon.sh"; fi
echo "Install script finished."
exit 0
