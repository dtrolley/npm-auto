#!/bin/bash
# minimal daemon placeholder
set -euo pipefail
BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="${BASE_DIR}/var"
mkdir -p "${VAR_DIR}"
LOG="${VAR_DIR}/npm-auto.log"
echo "$(date -Iseconds) npm-auto daemon started" >> "${LOG}"
# keep running to simulate daemon
while true; do sleep 60; done
