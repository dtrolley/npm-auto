#!/bin/bash
set -e
PLUGIN_NAME="npm-auto"
SRC_DIR="$(pwd)"
DEST_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"

echo "Installing ${PLUGIN_NAME}..."
mkdir -p "${DEST_DIR}"
cp -r ./* "${DEST_DIR}/"
chmod -R 755 "${DEST_DIR}/scripts"
chmod 644 "${DEST_DIR}/webGui/"* || true
chmod 600 "${DEST_DIR}/var/settings.cfg" || true

# Add startup to go
GO_FILE="/boot/config/go"
START_CMD="/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start # npm-auto"
if ! grep -F "${START_CMD}" "${GO_FILE}" >/dev/null 2>&1; then
  echo "${START_CMD}" >> "${GO_FILE}"
  echo "Added startup command to ${GO_FILE}"
fi

echo "Done. Start service with:"
echo "  /usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/npm-auto-service.sh start"
