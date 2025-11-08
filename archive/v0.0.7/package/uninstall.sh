#!/bin/bash
set -euo pipefail
PLUGIN_NAME="npm-auto"
DEST="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
GO_FILE="/boot/config/go"
START_CMD="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start # npm-auto"
echo "Stopping and removing npm-auto..."
if [ -f "${DEST}/scripts/npm-auto-service.sh" ]; then "${DEST}/scripts/npm-auto-service.sh" stop || true; fi
if [ -f "${GO_FILE}" ]; then sed -i "\|${START_CMD}|d" "${GO_FILE}" || true; fi
rm -rf "${DEST}"
echo "Uninstalled."
exit 0
