#!/bin/bash
set -e
PLUGIN_NAME="npm-auto"
DEST_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
GO_FILE="/boot/config/go"
START_CMD="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start # npm-auto"

echo "Stopping service..."
if [ -f "${DEST_DIR}/scripts/npm-auto-service.sh" ]; then
  "${DEST_DIR}/scripts/npm-auto-service.sh" stop || true
fi

echo "Removing plugin files..."
rm -rf "${DEST_DIR}"

echo "Removing startup line from ${GO_FILE}..."
sed -i "\|${START_CMD}|d" "${GO_FILE}" || true

echo "Uninstalled."
