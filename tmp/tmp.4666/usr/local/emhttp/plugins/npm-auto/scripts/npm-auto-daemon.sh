#!/bin/bash

#==============================================================================
# npm-auto-daemon.sh
#
# This script runs as a daemon and automatically manages Nginx Proxy Manager
# reverse proxy entries for Docker containers.
#==============================================================================

#--- Configuration ---
BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="$BASE_DIR/var"
SETTINGS_FILE="$VAR_DIR/settings.cfg"
STATE_FILE="$VAR_DIR/state.json"
LOG_FILE="$VAR_DIR/npm-auto.log"

#--- Load settings ---
if [ -f "$SETTINGS_FILE" ]; then
  source "$SETTINGS_FILE"
fi

#--- Default settings ---
NPM_ENABLED=${NPM_ENABLED:-"false"}
NPM_HOST=${NPM_HOST:-"127.0.0.1"}
NPM_PORT=${NPM_PORT:-"81"}
NPM_USER=${NPM_USER:-"admin@example.com"}
NPM_PASS=${NPM_PASS:-"changeme"}
DEFAULT_DOMAIN=${DEFAULT_DOMAIN:-"example.com"}
LABEL_OVERRIDES=${LABEL_OVERRIDES:-"true"}

#--- Globals ---
NPM_BASE_URL="http://$NPM_HOST:$NPM_PORT"
NPM_TOKEN=""
NPM_COOKIE=""

#--- Logging ---
log() {
  echo "$(date -Iseconds) $*" | tee -a "$LOG_FILE"
}

#--- State management ---
read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "{}"
  fi
}

write_state() {
  local tmp
  tmp=$(mktemp)
  echo "$1" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

#--- NPM API functions ---
npm_login() {
  log "Attempting to log in to Nginx Proxy Manager..."

  # Try to get a JWT token
  local resp
  resp=$(curl -s -X POST "$NPM_BASE_URL/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$NPM_USER\",\"secret\":\"$NPM_PASS\"}")

  NPM_TOKEN=$(echo "$resp" | jq -r '.token // empty')

  if [ -n "$NPM_TOKEN" ]; then
    log "Successfully logged in and obtained API token."
    return 0
  fi

  # Fallback to cookie-based login
  resp=$(curl -s -c /tmp/npm_cookiejar -X POST "$NPM_BASE_URL/api/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$NPM_USER\",\"password\":\"$NPM_PASS\"}")

  if [ -f /tmp/npm_cookiejar ] && grep -q "npm" /tmp/npm_cookiejar 2>/dev/null; then
    NPM_COOKIE="/tmp/npm_cookiejar"
    log "Successfully logged in via cookie."
    return 0
  fi

  log "NPM login failed. Response: $resp"
  return 1
}

npm_api_call() {
  local method=$1
  local path=$2
  local data=${3:-}
  local url="$NPM_BASE_URL$path"
  local hdrs=(-H "Content-Type: application/json")

  if [ -n "$NPM_TOKEN" ]; then
    hdrs+=(-H "Authorization: Bearer $NPM_TOKEN")
  fi

  if [ -n "$NPM_COOKIE" ]; then
    hdrs+=(-b "$NPM_COOKIE")
  fi

  if [ -n "$data" ]; then
    curl -s -X "$method" "$url" "${hdrs[@]}" -d "$data"
  else
    curl -s -X "$method" "$url" "${hdrs[@]}"
  fi
}

#--- Main logic ---
main() {
  log "Starting npm-auto daemon..."

  if [ "$NPM_ENABLED" != "true" ]; then
    log "npm-auto is disabled in the settings."
    exit 0
  fi

  if ! npm_login; then
    log "Failed to log in to NPM. Exiting."
    exit 1
  fi

  docker events --format '{{json .}}' | while read -r event; do
    log "Processing Docker event: $event"
    # Add event processing logic here
  done
}

main "$@"
