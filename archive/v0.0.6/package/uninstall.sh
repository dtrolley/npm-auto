#!/bin/bash
set -euo pipefail
PLUGIN_NAME="npm-auto"
DEST_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
GO_FILE="/boot/config/go"
START_CMD="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start # npm-auto"

echo "Uninstalling ${PLUGIN_NAME}..."

# stop service
if [ -f "${DEST_DIR}/scripts/npm-auto-service.sh" ]; then
  "${DEST_DIR}/scripts/npm-auto-service.sh" stop || true
fi

# remove startup line
if [ -f "${GO_FILE}" ]; then
  sed -i "\|${START_CMD}|d" "${GO_FILE}" || true
fi

# remove files
rm -rf "${DEST_DIR}" || true

echo "Uninstalled ${PLUGIN_NAME}."
exit 0
