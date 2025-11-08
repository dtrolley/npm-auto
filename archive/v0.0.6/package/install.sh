#!/bin/bash
set -euo pipefail
PLUGIN_NAME="npm-auto"
SRC_DIR="$(pwd)/package"
DEST_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"

echo "Installing ${PLUGIN_NAME}..."

mkdir -p "${DEST_DIR}"
cp -a "${SRC_DIR}/." "${DEST_DIR}/"

chmod -R 755 "${DEST_DIR}/scripts" || true
find "${DEST_DIR}/webGui" -type f -exec chmod 644 {} \; || true
chmod 600 "${DEST_DIR}/var/settings.cfg" 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: 'jq' not found. Please install jq on Unraid for full functionality."
fi

# add startup to /boot/config/go
GO_FILE="/boot/config/go"
START_CMD="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start # npm-auto"
if ! grep -F "${START_CMD}" "${GO_FILE}" >/dev/null 2>&1; then
  echo "${START_CMD}" >> "${GO_FILE}"
  echo "Added startup command to ${GO_FILE}"
fi

# start service now
if [ -f "${DEST_DIR}/scripts/npm-auto-service.sh" ]; then
  bash "${DEST_DIR}/scripts/npm-auto-service.sh" start
  echo "Service started."
fi

echo "Installation complete. Configure via Unraid UI -> Plugins -> npm-auto or /plugins/npm-auto/settings_ui.php"
exit 0
