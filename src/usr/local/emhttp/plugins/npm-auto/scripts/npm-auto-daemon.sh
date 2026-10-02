#!/bin/bash

#==============================================================================
# npm-auto-daemon.sh
#
# Reconciliation daemon: converges Nginx Proxy Manager proxy hosts with the
# desired state selected via the Docker-tab toggles.
#
#   npm-auto-daemon.sh            run until stopped (started by rc.npm-auto)
#   npm-auto-daemon.sh --cleanup  apply a pending cleanup request and exit
#
# Ownership split (avoids write races with the webGui PHP):
#   npm-auto.cfg         - settings, written by /update.php (settings page)
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
PLUGIN_DIR="/usr/local/emhttp/plugins/npm-auto"
BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="$BASE_DIR/var"
CFG_FILE="$BASE_DIR/npm-auto.cfg"
STATE_FILE="$VAR_DIR/state.json"
MANAGED_FILE="$VAR_DIR/managed.json"
CLEANUP_FILE="$VAR_DIR/cleanup_request.json"
LOG_FILE="/var/log/npm-auto.log"
STATUS_FILE="/var/run/npm-auto-status.json"
RECONCILE_INTERVAL=15

#--- Settings: default.cfg overlaid with npm-auto.cfg ---
# Read line by line rather than sourced: the values are typed into a web form.
declare -A CFG
read_cfg() {
  local f line key val
  CFG=()
  for f in "$PLUGIN_DIR/default.cfg" "$CFG_FILE"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]] || continue
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      CFG[$key]=$val
    done < "$f"
  done
}

load_settings() {
  read_cfg
  SERVICE=${CFG[SERVICE]:-disable}
  NPM_HOST=${CFG[NPM_HOST]:-}
  NPM_PORT=${CFG[NPM_PORT]:-81}
  NPM_USER=${CFG[NPM_USER]:-}
  NPM_PASS=${CFG[NPM_PASS]:-}
  DEFAULT_DOMAIN=$(echo "${CFG[DEFAULT_DOMAIN]:-}" | tr '[:upper:]' '[:lower:]')
  LABEL_OVERRIDES=${CFG[LABEL_OVERRIDES]:-yes}
  AUTO_SSL=${CFG[AUTO_SSL]:-yes}
  TOGGLE_OFF_ACTION=${CFG[TOGGLE_OFF_ACTION]:-disable}   # keep|disable|delete
  # A blank host means NPM runs here, on the address entries forward to.
  NPM_BASE_URL="http://${NPM_HOST:-$FORWARD_HOST}:$NPM_PORT"
}

#--- Logging ---
# /var/log is a small tmpfs on Unraid (128M), shared with syslog. A failure
# that repeats every cycle must not be allowed to fill it: an expired-token
# loop once wrote ~95MB here in ten weeks. So an identical message is logged
# at most once per LOG_REPEAT_SECS, and the file is trimmed past LOG_MAX_BYTES.
# The seen-markers live in a file because log() often runs inside $(...).
LOG_SEEN_DIR="/var/run/npm-auto-logseen"
LOG_REPEAT_SECS=3600
LOG_MAX_BYTES=5242880

log() {
  local msg="$*" key marker now
  now=$(date +%s)
  key=$(printf '%s' "$msg" | md5sum | cut -c1-16)
  marker="$LOG_SEEN_DIR/$key"
  mkdir -p "$LOG_SEEN_DIR"
  if [ -f "$marker" ] && [ $((now - $(cat "$marker" 2>/dev/null || echo 0))) -lt "$LOG_REPEAT_SECS" ]; then
    return 0
  fi
  echo "$now" > "$marker"
  echo "$(date -Iseconds) $msg" >> "$LOG_FILE"
}

trim_log() {
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -c 1048576 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

#--- Status, for the settings page and getState ---
write_status() {
  # write_status <ok|error> [message]
  local tmp
  tmp=$(mktemp)
  jq -n --arg npm "$1" --arg err "${2:-}" --arg fh "$FORWARD_HOST" --argjson pid $$ \
    '{time: now | floor, pid: $pid, npm: $npm, error: (if $err == "" then null else $err end), forward_host: $fh}' \
    > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$STATUS_FILE"
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

managed_entry() {
  # managed_entry <id> <domain> -> json for a live (not disabled) managed host
  jq -nc --argjson id "$1" --arg d "$2" '{id: $id, domain: $d, disabled: false}'
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
  if [ -z "$NPM_USER" ] || [ -z "$NPM_PASS" ]; then
    log "NPM login skipped: set the NPM user and password in Settings > npm-auto"
    return 1
  fi
  # Body built by jq (credentials may contain quotes or backslashes) and fed
  # on stdin, so the password never appears on a command line (ps, /proc).
  resp=$(jq -n --arg u "$NPM_USER" --arg p "$NPM_PASS" '{identity: $u, secret: $p}' \
    | curl -s -m 15 -X POST "$NPM_BASE_URL/api/tokens" \
        -H "Content-Type: application/json" \
        --data-binary @-)
  token=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null)
  if [ -n "$token" ]; then
    (umask 077; echo "$token" > "$TOKEN_FILE")
    log "NPM login OK ($NPM_BASE_URL)"
    return 0
  fi
  log "NPM login FAILED ($NPM_BASE_URL): $(echo "$resp" | tr -s '[:space:]' ' ' | head -c 300)"
  return 1
}

npm_api() {
  # npm_api <method> <path> [json-data] -> response body; retries once on 401
  local method=$1 path=$2 data=${3:-} resp http_code out NPM_TOKEN
  for _ in 1 2; do
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
    # NPM reports an expired token as 400 (TokenExpiredError), not 401 -
    # without this the cached token is reused forever and nothing reconciles.
    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ] \
       || { [ "$http_code" = "400" ] && echo "$out" | grep -q -E 'TokenExpiredError|Token has expired'; }; then
      rm -f "$TOKEN_FILE"
      continue
    fi
    if [ "${http_code:0:1}" = "2" ]; then
      echo "$out"
      return 0
    fi
    log "NPM API $method $path failed (HTTP $http_code): $(echo "$out" | tr -s '[:space:]' ' ' | head -c 300)"
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
  printf '%s' "$HOSTS_CACHE" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$HOSTS_SNAPSHOT"
  return 0
}

host_live() {
  # host_live <id> -> compact json of the live proxy host, or empty
  echo "$HOSTS_CACHE" | jq -c --argjson id "$1" '.[] | select(.id == $id)' 2>/dev/null
}

host_update() {
  # host_update <id> <jq-mutation-filter> [jq args...]  e.g. '.enabled = true'
  # Fetches the live object, applies the mutation, strips read-only fields, PUTs.
  local id=$1 filter=$2 live payload
  shift 2
  live=$(host_live "$id")
  [ -n "$live" ] || return 1
  payload=$(echo "$live" | jq -c "$@" "$filter
    | .locations = (.locations // [])
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
# One `docker inspect` per pass for every container, rather than several per
# container. Ports are the live bindings, so a stopped container has none.
declare -A CT_RUNNING CT_LABEL_DOMAIN CT_LABEL_PORT CT_WEBUI_PORT CT_MIN_PORT

load_containers() {
  # -> 0 with the CT_* maps filled, 1 when docker does not answer or lists nothing
  local ids name running ldomain lport wport mport sep=$'\x1f'
  CT_RUNNING=() CT_LABEL_DOMAIN=() CT_LABEL_PORT=() CT_WEBUI_PORT=() CT_MIN_PORT=()
  ids=$(docker ps -aq 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  # shellcheck disable=SC2086 # one id per word
  while IFS=$sep read -r name running ldomain lport wport mport; do
    [ -n "$name" ] || continue
    CT_RUNNING[$name]=$running
    CT_LABEL_DOMAIN[$name]=$ldomain
    CT_LABEL_PORT[$name]=$lport
    CT_WEBUI_PORT[$name]=$wport
    CT_MIN_PORT[$name]=$mport
  done < <(docker inspect $ids 2>/dev/null | jq -r '
    .[]
    | (.NetworkSettings.Ports // {}) as $ports
    # Unraid template WebUI label, e.g. "http://[IP]:[PORT:8989]/"
    | ((.Config.Labels["net.unraid.docker.webui"] // "") | capture("\\[PORT:(?<p>[0-9]+)\\]").p // "") as $wp
    | [ (.Name | ltrimstr("/")),
        (.State.Running | tostring),
        (.Config.Labels["npm-auto.domain"] // ""),
        (.Config.Labels["npm-auto.port"] // ""),
        ([ $ports | to_entries[] | select(.value != null and $wp != "" and (.key | startswith($wp + "/")))
           | .value[0].HostPort ][0] // ""),
        ([ $ports | to_entries[] | select(.value != null) | .value[0].HostPort | tonumber? ] | min // "" | tostring)
      ] | join("\u001f")')
  # Nothing listed reads as "every managed container is gone", which would
  # apply the off-policy to all of them; a docker hiccup must not do that.
  [ ${#CT_RUNNING[@]} -gt 0 ]
}

container_port() {
  # Best published host port for <container>:
  #   npm-auto.port label > Unraid WebUI label port > lowest published host port
  local c=$1 label=${CT_LABEL_PORT[$1]:-}
  if [ "$LABEL_OVERRIDES" = "yes" ] && [ -n "$label" ]; then
    if [[ "$label" =~ ^[0-9]{1,5}$ ]]; then
      echo "$label"
      return 0
    fi
    log "Ignoring npm-auto.port label '$label' on $c: not a port number"
  fi
  if [ -n "${CT_WEBUI_PORT[$c]:-}" ]; then
    echo "${CT_WEBUI_PORT[$c]}"
    return 0
  fi
  if [ -n "${CT_MIN_PORT[$c]:-}" ]; then
    echo "${CT_MIN_PORT[$c]}"
    return 0
  fi
  return 1
}

container_domain() {
  # container_domain <container> <state-json>
  # Subdomain override (set from the Docker tab, kept in state.json)
  #   > npm-auto.domain label > <lowercased-container>.<DEFAULT_DOMAIN>
  local c=$1 sub
  sub=$(echo "$2" | jq -r --arg c "$c" '.[$c].subdomain // empty')
  if [ -n "$sub" ] && [ -n "$DEFAULT_DOMAIN" ]; then
    echo "$sub.$DEFAULT_DOMAIN"
    return 0
  fi
  if [ "$LABEL_OVERRIDES" = "yes" ] && [ -n "${CT_LABEL_DOMAIN[$c]:-}" ]; then
    echo "${CT_LABEL_DOMAIN[$c]}"
    return 0
  fi
  [ -n "$DEFAULT_DOMAIN" ] || return 1
  echo "$(echo "$c" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-').$DEFAULT_DOMAIN"
}

valid_domain() {
  # valid_domain <name> -> exit 0 for a plain hostname. Refused otherwise
  # (quotes, spaces, a typo'd label) rather than sent on to NPM.
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

#--- Proxy host management ---
claimant_of() {
  # claimant_of <id> <container> -> name of a DIFFERENT container managing id
  jq -r --argjson id "$1" --arg c "$2" \
    'to_entries[] | select(.value.id == $id and .key != $c) | .key' \
    "$(managed_file_or_empty)" | head -n1
}

is_stamped() {
  # is_stamped <host-json> -> exit 0 if the entry bears our meta stamp
  [ "$(echo "$1" | jq -r '.meta.npm_auto // false')" = "true" ]
}

is_disabled() {
  # is_disabled <host-json> -> exit 0 if NPM has the entry switched off
  [ "$(echo "$1" | jq -r '.enabled == false or .enabled == 0')" = "true" ]
}

adopt_entry() {
  # adopt_entry <container> <id> <domain> <host-json>
  local c=$1 id=$2 domain=$3 match=$4
  managed_put "$c" "$(managed_entry "$id" "$domain")"
  if ! is_stamped "$match"; then
    host_update "$id" '.meta = ((.meta // {}) + {npm_auto: true})' \
      && log "Stamped adopted host #$id ($c) with npm_auto marker"
  fi
  if is_disabled "$match"; then
    host_update "$id" '.enabled = true' && log "Re-enabled adopted host #$id ($c)"
  fi
}

create_or_adopt() {
  # create_or_adopt <container> <domain> <port>
  # Adopt on an exact domain + forward-target match, or on a partial match
  # when the entry bears our npm_auto stamp (a previously managed entry -
  # e.g. after a container rename or plugin reinstall - drift then heals
  # the changed half). Unstamped partial matches are conflicts (webGui
  # rejects these up-front; this is the backstop).
  local c=$1 domain=$2 port=$3 payload resp id cert_id match claimant

  match=$(echo "$HOSTS_CACHE" | jq -c --arg d "$domain" \
    '[.[] | select(.domain_names | index($d))][0] // empty')
  if [ -n "$match" ]; then
    id=$(echo "$match" | jq -r '.id')
    claimant=$(claimant_of "$id" "$c")
    if [ -n "$claimant" ]; then
      log "CONFLICT: $c wants $domain but NPM entry #$id is already managed for container $claimant; skipping"
      return 1
    fi
    if [ "$(echo "$match" | jq -r '.forward_host')" = "$FORWARD_HOST" ] \
       && [ "$(echo "$match" | jq -r '.forward_port')" = "$port" ]; then
      log "Adopting proxy host #$id for $c ($domain -> $FORWARD_HOST:$port) - now fully managed"
      adopt_entry "$c" "$id" "$domain" "$match"
    elif is_stamped "$match"; then
      log "Auto-adopting stamped host #$id for $c ($domain) - target will be updated by drift enforcement"
      adopt_entry "$c" "$id" "$domain" "$match"
    else
      log "CONFLICT: $c wants $domain -> $FORWARD_HOST:$port but NPM entry #$id already proxies $domain -> $(echo "$match" | jq -r '.forward_host'):$(echo "$match" | jq -r '.forward_port'); not touching it"
    fi
    return 0
  fi

  # No domain match; check entries already proxying this forward target
  match=$(echo "$HOSTS_CACHE" | jq -c --arg h "$FORWARD_HOST" --argjson p "$port" \
    '[.[] | select(.forward_host == $h and .forward_port == $p)][0] // empty')
  if [ -n "$match" ]; then
    id=$(echo "$match" | jq -r '.id')
    claimant=$(claimant_of "$id" "$c")
    if [ -z "$claimant" ] && is_stamped "$match"; then
      log "Auto-adopting stamped host #$id for $c (target $FORWARD_HOST:$port) - domain will be updated to $domain by drift enforcement"
      adopt_entry "$c" "$id" "$domain" "$match"
      return 0
    fi
    log "CONFLICT: $c wants target $FORWARD_HOST:$port but NPM entry #$id ($(echo "$match" | jq -r '.domain_names[0]')) already proxies it; skipping"
    return 1
  fi

  cert_id=""
  [ "$AUTO_SSL" = "yes" ] && cert_id=$(pick_cert "$domain")

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
    locations: [],
    meta: { npm_auto: true }
  }')
  resp=$(npm_api POST "/api/nginx/proxy-hosts" "$payload") || return 1
  id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$id" ]; then
    log "Create proxy host for $c ($domain) returned no id: $(echo "$resp" | head -c 300)"
    return 1
  fi
  log "Created proxy host #$id: $domain -> $FORWARD_HOST:$port ($c)${cert_id:+ [cert #$cert_id, SSL forced]}"
  managed_put "$c" "$(managed_entry "$id" "$domain")"
}

# shellcheck disable=SC2016 # $d, $fh, $fp, $cert in the drift filters are jq variables
reconcile_managed_host() {
  # reconcile_managed_host <container> <managed-json> <domain> <port>
  # Bring an already-managed host in line with desired config (drift repair).
  local c=$1 m=$2 domain=$3 port=$4
  local id live cert_id="" current_cert
  id=$(echo "$m" | jq -r '.id')
  live=$(host_live "$id")

  if [ -z "$live" ]; then
    # Deleted out from under us (externally); forget and recreate next pass
    log "Managed host #$id ($c) no longer exists in NPM; forgetting it"
    managed_del "$c"
    return 0
  fi

  # Re-enable if we (or someone) disabled it while the toggle is on
  if is_disabled "$live"; then
    if host_update "$id" '.enabled = true'; then
      log "Re-enabled host #$id ($c)"
      m=$(echo "$m" | jq -c '.disabled = false')
      managed_put "$c" "$m"
    fi
    live=$(echo "$live" | jq -c '.enabled = true')
  fi

  # Enforce desired domain, forward target, and certificate on every managed
  # host. forward_host enforcement is what bulk-updates all managed entries
  # if the Unraid host's LAN IP ever changes. The mutation names its values
  # as jq variables, so nothing from a label or setting is spliced into code.
  local -a drift=()
  local changes="" domain_changed=""
  if [ "$(echo "$live" | jq -r --arg d "$domain" '.domain_names == [$d]')" != "true" ]; then
    drift+=('.domain_names = [$d]'); changes+=", domain $domain"
    domain_changed=1
  fi
  if [ "$(echo "$live" | jq -r '.forward_host')" != "$FORWARD_HOST" ]; then
    drift+=('.forward_host = $fh'); changes+=", forward host $FORWARD_HOST"
  fi
  if [ "$(echo "$live" | jq -r '.forward_port')" != "$port" ]; then
    drift+=('.forward_port = $fp'); changes+=", forward port $port"
  fi
  # Attach a certificate when there is none, and re-pick when the domain is
  # changing - the old certificate may not cover the new name.
  if [ "$AUTO_SSL" = "yes" ]; then
    current_cert=$(echo "$live" | jq -r '.certificate_id // 0')
    if [ "$current_cert" = "0" ] || [ -n "$domain_changed" ]; then
      cert_id=$(pick_cert "$domain")
      if [ -n "$cert_id" ] && [ "$cert_id" != "$current_cert" ]; then
        drift+=('.certificate_id = $cert | .ssl_forced = true'); changes+=", certificate #$cert_id"
      fi
    fi
  fi

  if [ ${#drift[@]} -gt 0 ]; then
    local filter
    filter=$(IFS='|'; echo "${drift[*]}")
    if host_update "$id" "$filter" --arg d "$domain" --arg fh "$FORWARD_HOST" \
         --argjson fp "$port" --argjson cert "${cert_id:-0}"; then
      log "Updated host #$id ($c): ${changes#, }"
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
  # -> 0 after a pass that reached NPM, 1 when it could not
  local desired c enabled m domain port
  local -A seen=()

  desired=$(cat "$STATE_FILE" 2>/dev/null)
  echo "$desired" | jq -e 'type == "object"' >/dev/null 2>&1 || desired="{}"

  if ! load_containers; then
    log "docker not responding; skipping reconcile"
    return 0
  fi

  refresh_caches || return 1

  # Only containers with the switch on, or with an entry to manage, need work.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -z "${seen[$c]:-}" ] || continue
    seen[$c]=1
    enabled=$(echo "$desired" | jq -r --arg c "$c" '.[$c].enabled // false')
    m=$(managed_get "$c")

    if [ -z "${CT_RUNNING[$c]:-}" ]; then
      # The container no longer exists at all
      [ -n "$m" ] && { log "Container $c is gone; applying off-policy"; apply_off_action "$c" "$m"; }
      continue
    fi

    if [ "$enabled" = "true" ]; then
      domain=$(container_domain "$c" "$desired") || { [ -n "$m" ] || log "No domain for $c (set a default domain or an npm-auto.domain label); skipping"; continue; }
      valid_domain "$domain" || { log "Invalid domain '$domain' for $c (check the default domain / npm-auto.domain label); skipping"; continue; }
      if [ -n "$m" ]; then
        port=$(container_port "$c") || port=$(echo "$HOSTS_CACHE" | jq -r --argjson id "$(echo "$m" | jq -r .id)" '.[] | select(.id==$id) | .forward_port // empty')
        [ -n "$port" ] || continue
        reconcile_managed_host "$c" "$m" "$domain" "$port"
      else
        # Only create for running containers (ports aren't published otherwise)
        [ "${CT_RUNNING[$c]}" = "true" ] || continue
        port=$(container_port "$c") || { log "No published port found for $c; skipping"; continue; }
        create_or_adopt "$c" "$domain" "$port"
      fi
    else
      [ -n "$m" ] && apply_off_action "$c" "$m"
    fi
  done < <(
    echo "$desired" | jq -r 'to_entries[] | select(.value.enabled == true) | .key'
    jq -r 'keys[]' "$(managed_file_or_empty)" 2>/dev/null
  )
  return 0
}

detect_forward_host() {
  # Re-detected each cycle so a host IP change propagates to all managed
  # entries via drift enforcement without a restart.
  local detected
  detected=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  if [ -z "$detected" ]; then
    [ -n "$FORWARD_HOST" ] || return 1
  elif [ "$detected" != "$FORWARD_HOST" ]; then
    FORWARD_HOST=$detected
    log "Forwarding target host: $FORWARD_HOST"
  fi
}

#--- Main ---
FORWARD_HOST=""

main() {
  mkdir -p "$VAR_DIR"

  if [ "${1:-}" = "--cleanup" ]; then
    detect_forward_host
    load_settings
    handle_cleanup_request
    exit $?
  fi

  rm -rf "$LOG_SEEN_DIR"
  # Settings may have changed host or user since the token was issued.
  rm -f "$TOKEN_FILE"
  # Leave promptly when stopped, even mid-sleep.
  trap 'log "npm-auto daemon stopping"; rm -f "$STATUS_FILE"; exit 0' TERM INT
  log "npm-auto daemon starting (pid $$)"

  while true; do
    trim_log
    if ! detect_forward_host; then
      log "Cannot determine host LAN IP; retrying"
      write_status error "Cannot determine this server's LAN IP"
    else
      load_settings
      if [ "$SERVICE" != "enable" ]; then
        log "npm-auto is disabled in settings; daemon exiting"
        rm -f "$STATUS_FILE"
        exit 0
      fi
      handle_cleanup_request
      if [ -z "$NPM_USER" ] || [ -z "$NPM_PASS" ]; then
        log "NPM user and password not set; waiting for settings"
        write_status error "NPM user and password are not set"
      elif reconcile; then
        write_status ok
      else
        write_status error "Cannot reach NPM at $NPM_BASE_URL or log in (see the log)"
      fi
    fi
    sleep "$RECONCILE_INTERVAL" &
    wait $!
  done
}

# Sourced (by a test harness) rather than run: define functions only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
