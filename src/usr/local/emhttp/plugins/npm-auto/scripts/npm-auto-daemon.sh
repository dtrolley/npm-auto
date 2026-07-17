#!/bin/bash

#==============================================================================
# npm-auto-daemon.sh
#
# Reconciliation daemon: converges Nginx Proxy Manager proxy hosts with the
# desired state selected via the Docker-tab toggles.
#
# Ownership split (avoids write races with the webGui PHP):
#   state.json   - written ONLY by webGui (desired state: which containers on)
#   managed.json - written ONLY by this daemon (proxy host IDs it created)
#==============================================================================

#--- Configuration ---
BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="$BASE_DIR/var"
SETTINGS_FILE="$VAR_DIR/settings.json"
STATE_FILE="$VAR_DIR/state.json"
MANAGED_FILE="$VAR_DIR/managed.json"
LOG_FILE="/var/log/npm-auto.log"
RECONCILE_INTERVAL=15

#--- Load settings (settings.json written by the plugin settings page) ---
setting() {
  # setting <key> <default>
  local val=""
  if [ -f "$SETTINGS_FILE" ]; then
    val=$(jq -r --arg k "$1" '.[$k] // empty' "$SETTINGS_FILE" 2>/dev/null)
  fi
  echo "${val:-$2}"
}

load_settings() {
  NPM_ENABLED=$(setting NPM_ENABLED "false")
  NPM_HOST=$(setting NPM_HOST "127.0.0.1")
  NPM_PORT=$(setting NPM_PORT "81")
  NPM_USER=$(setting NPM_USER "")
  NPM_PASS=$(setting NPM_PASS "")
  DEFAULT_DOMAIN=$(setting DEFAULT_DOMAIN "")
  LABEL_OVERRIDES=$(setting LABEL_OVERRIDES "true")
  NPM_BASE_URL="http://$NPM_HOST:$NPM_PORT"
}

#--- Logging ---
log() {
  echo "$(date -Iseconds) $*" >> "$LOG_FILE"
}

#--- Managed-hosts bookkeeping (container -> NPM proxy host id) ---
managed_get_id() {
  # managed_get_id <container>  -> id or empty
  [ -f "$MANAGED_FILE" ] || { echo ""; return; }
  jq -r --arg c "$1" '.[$c].id // empty' "$MANAGED_FILE" 2>/dev/null
}

managed_set() {
  # managed_set <container> <id> <domain>
  local tmp
  tmp=$(mktemp)
  jq --arg c "$1" --argjson id "$2" --arg d "$3" '.[$c] = {id: $id, domain: $d}' \
    "$(managed_file_or_empty)" > "$tmp" && mv "$tmp" "$MANAGED_FILE"
}

managed_del() {
  # managed_del <container>
  local tmp
  tmp=$(mktemp)
  jq --arg c "$1" 'del(.[$c])' "$(managed_file_or_empty)" > "$tmp" && mv "$tmp" "$MANAGED_FILE"
}

managed_file_or_empty() {
  if [ -f "$MANAGED_FILE" ]; then
    echo "$MANAGED_FILE"
  else
    echo "{}" > "$MANAGED_FILE"
    echo "$MANAGED_FILE"
  fi
}

#--- NPM API ---
NPM_TOKEN=""

npm_login() {
  local resp
  resp=$(curl -s -m 15 -X POST "$NPM_BASE_URL/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$NPM_USER\",\"secret\":\"$NPM_PASS\"}")
  NPM_TOKEN=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null)
  if [ -n "$NPM_TOKEN" ]; then
    log "NPM login OK ($NPM_BASE_URL)"
    return 0
  fi
  log "NPM login FAILED: $(echo "$resp" | head -c 300)"
  return 1
}

npm_api() {
  # npm_api <method> <path> [json-data]  -> response body; retries once on 401
  local method=$1 path=$2 data=${3:-} resp http_code out
  for attempt in 1 2; do
    if [ -z "$NPM_TOKEN" ]; then
      npm_login || return 1
    fi
    if [ -n "$data" ]; then
      resp=$(curl -s -m 20 -w $'\n%{http_code}' -X "$method" "$NPM_BASE_URL$path" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $NPM_TOKEN" \
        -d "$data")
    else
      resp=$(curl -s -m 20 -w $'\n%{http_code}' -X "$method" "$NPM_BASE_URL$path" \
        -H "Authorization: Bearer $NPM_TOKEN")
    fi
    http_code=$(echo "$resp" | tail -n1)
    out=$(echo "$resp" | sed '$d')
    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
      NPM_TOKEN=""
      continue
    fi
    if [ "${http_code:0:1}" = "2" ]; then
      echo "$out"
      return 0
    fi
    log "NPM API $method $path failed (HTTP $http_code): $(echo "$out" | head -c 300)"
    return 1
  done
  return 1
}

#--- Container introspection ---
container_label() {
  # container_label <container> <label>
  docker inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null
}

container_port() {
  # Best published host port for <container>:
  #   npm-auto.port label > Unraid WebUI label port > lowest published host port
  local c=$1 port=""

  if [ "$LABEL_OVERRIDES" = "true" ]; then
    port=$(container_label "$c" "npm-auto.port")
    if [ -n "$port" ] && [ "$port" != "<no value>" ]; then
      echo "$port"
      return 0
    fi
  fi

  # Unraid template WebUI label, e.g. "http://[IP]:[PORT:8989]/"
  local webui inner
  webui=$(container_label "$c" "net.unraid.docker.webui")
  if [[ "$webui" =~ \[PORT:([0-9]+)\] ]]; then
    inner="${BASH_REMATCH[1]}"
    # Map internal port to the published host port
    port=$(docker inspect --format \
      "{{ range \$p, \$conf := .NetworkSettings.Ports }}{{ if \$conf }}{{ \$p }} {{ (index \$conf 0).HostPort }}{{ \"\n\" }}{{ end }}{{ end }}" \
      "$c" 2>/dev/null | awk -v p="$inner" '$1 ~ "^"p"/" {print $2; exit}')
    if [ -n "$port" ]; then
      echo "$port"
      return 0
    fi
  fi

  # Fallback: lowest published host port
  port=$(docker inspect --format \
    "{{ range \$p, \$conf := .NetworkSettings.Ports }}{{ if \$conf }}{{ (index \$conf 0).HostPort }}{{ \"\n\" }}{{ end }}{{ end }}" \
    "$c" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | head -n1)
  [ -n "$port" ] && { echo "$port"; return 0; }
  return 1
}

container_domain() {
  # npm-auto.domain label > <lowercased-container>.<DEFAULT_DOMAIN>
  local c=$1 domain=""
  if [ "$LABEL_OVERRIDES" = "true" ]; then
    domain=$(container_label "$c" "npm-auto.domain")
    if [ -n "$domain" ] && [ "$domain" != "<no value>" ]; then
      echo "$domain"
      return 0
    fi
  fi
  [ -n "$DEFAULT_DOMAIN" ] || return 1
  echo "$(echo "$c" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-').$DEFAULT_DOMAIN"
}

#--- Proxy host management ---
create_proxy_host() {
  # create_proxy_host <container> <domain> <port>
  local c=$1 domain=$2 port=$3 payload resp id

  # Adopt an existing NPM host for this domain if one exists
  resp=$(npm_api GET "/api/nginx/proxy-hosts") || return 1
  id=$(echo "$resp" | jq -r --arg d "$domain" \
    '[.[] | select(.domain_names | index($d))][0].id // empty')
  if [ -n "$id" ]; then
    log "Adopting existing proxy host #$id for $c ($domain)"
    managed_set "$c" "$id" "$domain"
    return 0
  fi

  payload=$(jq -n --arg d "$domain" --arg h "$FORWARD_HOST" --argjson p "$port" '{
    domain_names: [$d],
    forward_scheme: "http",
    forward_host: $h,
    forward_port: $p,
    access_list_id: 0,
    certificate_id: 0,
    ssl_forced: false,
    caching_enabled: false,
    block_exploits: true,
    advanced_config: "",
    allow_websocket_upgrade: true,
    http2_support: false,
    hsts_enabled: false,
    hsts_subdomains: false,
    enabled: true,
    meta: { npm_auto: true }
  }')
  resp=$(npm_api POST "/api/nginx/proxy-hosts" "$payload") || return 1
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then
    log "Create proxy host for $c ($domain) returned no id: $(echo "$resp" | head -c 300)"
    return 1
  fi
  log "Created proxy host #$id: $domain -> $FORWARD_HOST:$port ($c)"
  managed_set "$c" "$id" "$domain"
}

delete_proxy_host() {
  # delete_proxy_host <container> <id>
  local c=$1 id=$2
  if npm_api DELETE "/api/nginx/proxy-hosts/$id" >/dev/null; then
    log "Deleted proxy host #$id ($c)"
  else
    log "Delete of proxy host #$id ($c) failed; removing from managed list anyway"
  fi
  managed_del "$c"
}

#--- Reconcile ---
reconcile() {
  local desired containers c enabled id domain port

  desired=$(cat "$STATE_FILE" 2>/dev/null)
  [ -n "$desired" ] || desired="{}"

  # Containers currently known to docker
  containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
  if [ -z "$containers" ]; then
    log "docker not responding; skipping reconcile"
    return
  fi

  # 1) Ensure proxy hosts exist for enabled + running containers
  while IFS= read -r c; do
    enabled=$(echo "$desired" | jq -r --arg c "$c" '.[$c].enabled // false')
    id=$(managed_get_id "$c")
    running=$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)

    if [ "$enabled" = "true" ] && [ "$running" = "true" ]; then
      if [ -z "$id" ]; then
        domain=$(container_domain "$c") || { log "No domain for $c (set DEFAULT_DOMAIN or npm-auto.domain label); skipping"; continue; }
        port=$(container_port "$c") || { log "No published port found for $c; skipping"; continue; }
        create_proxy_host "$c" "$domain" "$port"
      fi
    else
      # Toggled off, or container stopped/removed
      if [ -n "$id" ]; then
        delete_proxy_host "$c" "$id"
      fi
    fi
  done <<< "$containers"

  # 2) Clean up managed entries whose containers no longer exist
  if [ -f "$MANAGED_FILE" ]; then
    for c in $(jq -r 'keys[]' "$MANAGED_FILE" 2>/dev/null); do
      if ! echo "$containers" | grep -qxF "$c"; then
        id=$(managed_get_id "$c")
        [ -n "$id" ] && delete_proxy_host "$c" "$id"
      fi
    done
  fi
}

#--- Main ---
main() {
  mkdir -p "$VAR_DIR"
  log "npm-auto daemon starting (pid $$)"

  while true; do
    load_settings

    if [ "$NPM_ENABLED" != "true" ]; then
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    if [ -z "$FORWARD_HOST" ]; then
      FORWARD_HOST=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
      [ -n "$FORWARD_HOST" ] || { log "Cannot determine host LAN IP; retrying"; sleep "$RECONCILE_INTERVAL"; continue; }
      log "Forwarding target host: $FORWARD_HOST"
    fi

    reconcile
    sleep "$RECONCILE_INTERVAL"
  done
}

main "$@"
