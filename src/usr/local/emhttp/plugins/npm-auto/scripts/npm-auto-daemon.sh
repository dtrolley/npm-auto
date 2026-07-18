#!/bin/bash

#==============================================================================
# npm-auto-daemon.sh
#
# Reconciliation daemon: converges Nginx Proxy Manager proxy hosts with the
# desired state selected via the Docker-tab toggles.
#
# Ownership split (avoids write races with the webGui PHP):
#   state.json           - written ONLY by webGui (desired state)
#   managed.json         - written ONLY by this daemon (hosts it manages)
#   cleanup_request.json - written by webGui, consumed (deleted) by daemon
#
# managed.json entry: { id, domain, disabled }
# Created and adopted hosts are treated identically once managed: domain,
# port and certificate are enforced, and the toggle-off policy applies.
# Adoption only happens when the existing entry's domain AND forward
# target both already match what the plugin would configure; anything else
# is a conflict (rejected up-front by the webGui, re-checked here).
#==============================================================================

#--- Configuration ---
BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="$BASE_DIR/var"
SETTINGS_FILE="$VAR_DIR/settings.json"
STATE_FILE="$VAR_DIR/state.json"
MANAGED_FILE="$VAR_DIR/managed.json"
CLEANUP_FILE="$VAR_DIR/cleanup_request.json"
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
  TOGGLE_OFF_ACTION=$(setting TOGGLE_OFF_ACTION "disable")   # keep|disable|delete
  AUTO_SSL=$(setting AUTO_SSL "true")
  NPM_BASE_URL="http://$NPM_HOST:$NPM_PORT"
}

#--- Logging ---
log() {
  echo "$(date -Iseconds) $*" >> "$LOG_FILE"
}

#--- Managed-hosts bookkeeping ---
managed_file_or_empty() {
  [ -f "$MANAGED_FILE" ] || echo "{}" > "$MANAGED_FILE"
  echo "$MANAGED_FILE"
}

managed_get() {
  # managed_get <container> -> compact json object or empty
  jq -c --arg c "$1" '.[$c] // empty' "$(managed_file_or_empty)" 2>/dev/null
}

managed_put() {
  # managed_put <container> <json-object>
  local tmp
  tmp=$(mktemp)
  jq --arg c "$1" --argjson v "$2" '.[$c] = $v' "$(managed_file_or_empty)" > "$tmp" && mv "$tmp" "$MANAGED_FILE"
}

managed_del() {
  # managed_del <container>
  local tmp
  tmp=$(mktemp)
  jq --arg c "$1" 'del(.[$c])' "$(managed_file_or_empty)" > "$tmp" && mv "$tmp" "$MANAGED_FILE"
}

#--- NPM API ---
# Token is cached in a file because npm_api usually runs in $(...) subshells,
# where shell-variable writes would not survive back to the parent.
TOKEN_FILE="/var/run/npm-auto.token"
HOSTS_CACHE="[]"
CERTS_CACHE="[]"

npm_login() {
  local resp token
  resp=$(curl -s -m 15 -X POST "$NPM_BASE_URL/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$NPM_USER\",\"secret\":\"$NPM_PASS\"}")
  token=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null)
  if [ -n "$token" ]; then
    (umask 077; echo "$token" > "$TOKEN_FILE")
    log "NPM login OK ($NPM_BASE_URL)"
    return 0
  fi
  log "NPM login FAILED: $(echo "$resp" | head -c 300)"
  return 1
}

npm_api() {
  # npm_api <method> <path> [json-data] -> response body; retries once on 401
  local method=$1 path=$2 data=${3:-} resp http_code out NPM_TOKEN
  for attempt in 1 2; do
    NPM_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
    if [ -z "$NPM_TOKEN" ]; then
      npm_login || return 1
      NPM_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
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
      rm -f "$TOKEN_FILE"
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

HOSTS_SNAPSHOT="/var/run/npm-auto-hosts.json"

refresh_caches() {
  local h c tmp
  h=$(npm_api GET "/api/nginx/proxy-hosts") || return 1
  c=$(npm_api GET "/api/nginx/certificates") || c="[]"
  HOSTS_CACHE=$h
  CERTS_CACHE=$c
  # Publish a snapshot so the webGui can conflict-check toggles synchronously
  tmp=$(mktemp)
  printf '%s' "$HOSTS_CACHE" > "$tmp" && mv "$tmp" "$HOSTS_SNAPSHOT" && chmod 644 "$HOSTS_SNAPSHOT"
  return 0
}

host_live() {
  # host_live <id> -> compact json of the live proxy host, or empty
  echo "$HOSTS_CACHE" | jq -c --argjson id "$1" '.[] | select(.id == $id)' 2>/dev/null
}

host_update() {
  # host_update <id> <jq-mutation-filter>  e.g. '.enabled = true'
  # Fetches the live object, applies the mutation, strips read-only fields, PUTs.
  local id=$1 filter=$2 live payload
  live=$(host_live "$id")
  [ -n "$live" ] || return 1
  payload=$(echo "$live" | jq -c "$filter
    | del(.id, .created_on, .modified_on, .owner_user_id, .owner,
          .certificate, .access_list, .use_default_location, .ipv6,
          .nginx_online, .nginx_err)") || return 1
  npm_api PUT "/api/nginx/proxy-hosts/$id" "$payload" >/dev/null
}

pick_cert() {
  # pick_cert <fqdn> -> certificate id (or empty). Prefers exact/wildcard
  # domain match, skips expired certs, picks the latest expiry.
  echo "$CERTS_CACHE" | jq -r --arg f "$1" '
    [ .[]
      | select(.domain_names != null)
      | select([ .domain_names[]
          | (. == $f)
            or ( startswith("*.")
                 and ($f | endswith(.[1:]))
                 and (($f | rtrimstr(.[1:])) | length > 0)
                 and (($f | rtrimstr(.[1:])) | contains(".") | not) )
        ] | any)
      | select( try ((.expires_on
                       | sub("\\.[0-9]+";"") | sub(" ";"T")
                       | (if endswith("Z") then . else . + "Z" end)
                       | fromdateiso8601) > now)
                catch true )
    ] | sort_by(.expires_on) | reverse | .[0].id // empty'
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
create_or_adopt() {
  # create_or_adopt <container> <domain> <port>
  # Adopt only on an exact domain + forward-target match; anything partial
  # is a conflict (webGui rejects these up-front; this is the backstop).
  local c=$1 domain=$2 port=$3 payload resp id cert_id match

  match=$(echo "$HOSTS_CACHE" | jq -c --arg d "$domain" \
    '[.[] | select(.domain_names | index($d))][0] // empty')
  if [ -n "$match" ]; then
    id=$(echo "$match" | jq -r '.id')
    if [ "$(echo "$match" | jq -r '.forward_host')" = "$FORWARD_HOST" ] \
       && [ "$(echo "$match" | jq -r '.forward_port')" = "$port" ]; then
      log "Adopting proxy host #$id for $c ($domain -> $FORWARD_HOST:$port) - now fully managed"
      managed_put "$c" "{\"id\": $id, \"domain\": \"$domain\", \"disabled\": false}"
      if [ "$(echo "$match" | jq -r '.enabled')" = "false" ] || [ "$(echo "$match" | jq -r '.enabled')" = "0" ]; then
        host_update "$id" '.enabled = true' && log "Re-enabled adopted host #$id ($c)"
      fi
    else
      log "CONFLICT: $c wants $domain -> $FORWARD_HOST:$port but NPM entry #$id already proxies $domain -> $(echo "$match" | jq -r '.forward_host'):$(echo "$match" | jq -r '.forward_port'); not touching it"
    fi
    return 0
  fi

  # No domain match; refuse to create if the forward target is already proxied
  match=$(echo "$HOSTS_CACHE" | jq -c --arg h "$FORWARD_HOST" --argjson p "$port" \
    '[.[] | select(.forward_host == $h and .forward_port == $p)][0] // empty')
  if [ -n "$match" ]; then
    log "CONFLICT: $c wants target $FORWARD_HOST:$port but NPM entry #$(echo "$match" | jq -r '.id') ($(echo "$match" | jq -r '.domain_names[0]')) already proxies it; skipping"
    return 1
  fi

  cert_id=""
  [ "$AUTO_SSL" = "true" ] && cert_id=$(pick_cert "$domain")

  payload=$(jq -n --arg d "$domain" --arg h "$FORWARD_HOST" --argjson p "$port" \
    --argjson cert "${cert_id:-0}" '{
    domain_names: [$d],
    forward_scheme: "http",
    forward_host: $h,
    forward_port: $p,
    access_list_id: 0,
    certificate_id: $cert,
    ssl_forced: ($cert != 0),
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
  log "Created proxy host #$id: $domain -> $FORWARD_HOST:$port ($c)${cert_id:+ [cert #$cert_id, SSL forced]}"
  managed_put "$c" "{\"id\": $id, \"domain\": \"$domain\", \"disabled\": false}"
}

reconcile_managed_host() {
  # reconcile_managed_host <container> <managed-json> <domain> <port>
  # Bring an already-managed host in line with desired config (drift repair).
  local c=$1 m=$2 domain=$3 port=$4
  local id live cert_id
  id=$(echo "$m" | jq -r '.id')
  live=$(host_live "$id")

  if [ -z "$live" ]; then
    # Deleted out from under us (externally); forget and recreate next pass
    log "Managed host #$id ($c) no longer exists in NPM; forgetting it"
    managed_del "$c"
    return 0
  fi

  # Re-enable if we (or someone) disabled it while the toggle is on
  if [ "$(echo "$live" | jq -r '.enabled')" = "false" ] || [ "$(echo "$live" | jq -r '.enabled')" = "0" ]; then
    if host_update "$id" '.enabled = true'; then
      log "Re-enabled host #$id ($c)"
      m=$(echo "$m" | jq -c '.disabled = false')
      managed_put "$c" "$m"
    fi
    live=$(host_live "$id" | jq -c '.enabled = true')
  fi

  # Enforce desired domain, forward target, and certificate on every managed
  # host. forward_host enforcement is what bulk-updates all managed entries
  # if the Unraid host's LAN IP ever changes.
  local drift=""
  if [ "$(echo "$live" | jq -r --arg d "$domain" '.domain_names == [$d]')" != "true" ]; then
    drift=".domain_names = [\"$domain\"]"
  fi
  if [ "$(echo "$live" | jq -r '.forward_host')" != "$FORWARD_HOST" ]; then
    drift="${drift:+$drift | }.forward_host = \"$FORWARD_HOST\""
  fi
  if [ "$(echo "$live" | jq -r '.forward_port')" != "$port" ]; then
    drift="${drift:+$drift | }.forward_port = $port"
  fi
  if [ "$AUTO_SSL" = "true" ] && [ "$(echo "$live" | jq -r '.certificate_id // 0')" = "0" ]; then
    cert_id=$(pick_cert "$domain")
    if [ -n "$cert_id" ]; then
      drift="${drift:+$drift | }.certificate_id = $cert_id | .ssl_forced = true"
    fi
  fi

  if [ -n "$drift" ]; then
    if host_update "$id" "$drift"; then
      log "Updated host #$id ($c): $drift"
      managed_put "$c" "$(echo "$m" | jq -c --arg d "$domain" '.domain = $d | .disabled = false')"
    fi
  fi
}

apply_off_action() {
  # apply_off_action <container> <managed-json> [action-override]
  local c=$1 m=$2 action=${3:-$TOGGLE_OFF_ACTION}
  local id
  id=$(echo "$m" | jq -r '.id')

  case "$action" in
    keep)
      log "Releasing host #$id ($c) per keep policy - entry left in NPM"
      managed_del "$c"
      ;;
    disable)
      if [ "$(echo "$m" | jq -r '.disabled // false')" != "true" ]; then
        if [ -z "$(host_live "$id")" ]; then
          managed_del "$c"
        elif host_update "$id" '.enabled = false'; then
          log "Disabled host #$id ($c)"
          managed_put "$c" "$(echo "$m" | jq -c '.disabled = true')"
        fi
      fi
      ;;
    delete)
      if npm_api DELETE "/api/nginx/proxy-hosts/$id" >/dev/null; then
        log "Deleted host #$id ($c)"
      else
        log "Delete of host #$id ($c) failed; forgetting it anyway"
      fi
      managed_del "$c"
      ;;
  esac
}

#--- Cleanup requests from the webGui ---
handle_cleanup_request() {
  [ -f "$CLEANUP_FILE" ] || return 0
  local action c m
  action=$(jq -r '.action // empty' "$CLEANUP_FILE" 2>/dev/null)
  rm -f "$CLEANUP_FILE"
  case "$action" in disable|delete) ;; *) return 0 ;; esac

  log "Processing cleanup request: $action all managed hosts"
  refresh_caches || { log "Cleanup: NPM unreachable, request dropped"; return 1; }
  for c in $(jq -r 'keys[]' "$(managed_file_or_empty)" 2>/dev/null); do
    m=$(managed_get "$c")
    [ -n "$m" ] && apply_off_action "$c" "$m" "$action"
  done
  log "Cleanup request complete"
}

#--- Reconcile ---
reconcile() {
  local desired containers c enabled m domain port

  desired=$(cat "$STATE_FILE" 2>/dev/null)
  [ -n "$desired" ] || desired="{}"

  containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
  if [ -z "$containers" ]; then
    log "docker not responding; skipping reconcile"
    return
  fi

  refresh_caches || return

  while IFS= read -r c; do
    enabled=$(echo "$desired" | jq -r --arg c "$c" '.[$c].enabled // false')
    m=$(managed_get "$c")

    if [ "$enabled" = "true" ]; then
      domain=$(container_domain "$c") || { [ -n "$m" ] || log "No domain for $c (set DEFAULT_DOMAIN or npm-auto.domain label); skipping"; continue; }
      if [ -n "$m" ]; then
        port=$(container_port "$c") || port=$(echo "$HOSTS_CACHE" | jq -r --argjson id "$(echo "$m" | jq -r .id)" '.[] | select(.id==$id) | .forward_port // empty')
        [ -n "$port" ] || continue
        reconcile_managed_host "$c" "$m" "$domain" "$port"
      else
        # Only create for running containers (ports aren't published otherwise)
        [ "$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || continue
        port=$(container_port "$c") || { log "No published port found for $c; skipping"; continue; }
        create_or_adopt "$c" "$domain" "$port"
      fi
    else
      [ -n "$m" ] && apply_off_action "$c" "$m"
    fi
  done <<< "$containers"

  # Managed entries whose containers no longer exist at all
  for c in $(jq -r 'keys[]' "$(managed_file_or_empty)" 2>/dev/null); do
    if ! echo "$containers" | grep -qxF "$c"; then
      m=$(managed_get "$c")
      [ -n "$m" ] && { log "Container $c is gone; applying off-policy"; apply_off_action "$c" "$m"; }
    fi
  done
}

#--- Main ---
main() {
  mkdir -p "$VAR_DIR"
  log "npm-auto daemon starting (pid $$)"

  while true; do
    load_settings
    handle_cleanup_request

    if [ "$NPM_ENABLED" != "true" ]; then
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    # Re-detect each cycle so a host IP change propagates to all managed
    # entries via drift enforcement without a daemon restart.
    detected=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    if [ -z "$detected" ]; then
      [ -n "$FORWARD_HOST" ] || { log "Cannot determine host LAN IP; retrying"; sleep "$RECONCILE_INTERVAL"; continue; }
    elif [ "$detected" != "$FORWARD_HOST" ]; then
      FORWARD_HOST=$detected
      log "Forwarding target host: $FORWARD_HOST"
    fi

    reconcile
    sleep "$RECONCILE_INTERVAL"
  done
}

main "$@"
