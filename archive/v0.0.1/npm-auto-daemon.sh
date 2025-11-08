#!/bin/bash
# npm-auto-daemon.sh
set -euo pipefail

BASE_DIR="/boot/config/plugins/npm-auto"
VAR_DIR="${BASE_DIR}/var"
STATE_FILE="${VAR_DIR}/state.json"
SETTINGS_FILE="${VAR_DIR}/settings.cfg"
LOGFILE="${VAR_DIR}/npm-auto.log"

mkdir -p "${VAR_DIR}"
touch "${LOGFILE}"
touch "${STATE_FILE}"

log() { echo "$(date -Iseconds) $*" | tee -a "${LOGFILE}"; }

# load settings (simple KEY=VALUE file)
if [ -f "${SETTINGS_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${SETTINGS_FILE}"
fi

# defaults
NPM_ENABLED=${NPM_ENABLED:-"false"}
NPM_HOST=${NPM_HOST:-"127.0.0.1"}
NPM_PORT=${NPM_PORT:-"81"}
NPM_USER=${NPM_USER:-"admin@example.com"}
NPM_PASS=${NPM_PASS:-"changeme"}
DEFAULT_DOMAIN=${DEFAULT_DOMAIN:-"example.com"}
LABEL_OVERRIDES=${LABEL_OVERRIDES:-"true"}  # allow labels by default

# state helper
read_state() {
  if [ -f "${STATE_FILE}" ]; then
    cat "${STATE_FILE}"
  else
    echo "{}"
  fi
}
write_state() {
  local tmp="$(mktemp)"
  echo "$1" >"$tmp"
  mv "$tmp" "${STATE_FILE}"
}

# Minimal NPM API helper functions
NPM_BASE_URL="http://${NPM_HOST}:${NPM_PORT}"
NPM_TOKEN=""        # JWT token if available
NPM_COOKIE=""       # cookie session store

npm_login() {
  # simple login: obtain jwt token via /api/access/tokens? or /api/login
  # NPM has internal auth; we use /api/nginx-proxy-manager/auth/ (schema varies by version)
  # We'll attempt classic login endpoint: POST /api/auth/login (common)
  local resp
  resp=$(curl -s -X POST "${NPM_BASE_URL}/api/tokens" -H "Content-Type: application/json" \
    -d "{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}" || true)
  # If token returned as {"token":"..."} use it; else attempt legacy login
  NPM_TOKEN=$(echo "${resp}" | jq -r '.token // empty')
  if [ -n "${NPM_TOKEN}" ]; then
    log "Obtained API token."
    return 0
  fi

  # Fallback: try old login endpoint to get cookie session
  resp=$(curl -s -c /tmp/npm_cookiejar -X POST "${NPM_BASE_URL}/api/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${NPM_USER}\",\"password\":\"${NPM_PASS}\"}" || true)
  if [ -f /tmp/npm_cookiejar ] && grep -q npm /tmp/npm_cookiejar 2>/dev/null; then
    NPM_COOKIE="/tmp/npm_cookiejar"
    log "Logged in via cookie."
    return 0
  fi

  log "NPM login failed. Response: ${resp}"
  return 1
}

npm_api_call() {
  # usage: npm_api_call METHOD PATH [data]
  local method=$1 path=$2 data=${3:-}
  local url="${NPM_BASE_URL}${path}"
  local hdrs=(-H "Content-Type: application/json")
  if [ -n "${NPM_TOKEN}" ]; then
    hdrs+=(-H "Authorization: Bearer ${NPM_TOKEN}")
  fi
  if [ -n "${NPM_COOKIE}" ]; then
    hdrs+=(-b "${NPM_COOKIE}")
  fi

  if [ -n "${data}" ]; then
    curl -s -X "${method}" "${url}" "${hdrs[@]}" -d "${data}"
  else
    curl -s -X "${method}" "${url}" "${hdrs[@]}"
  fi
}

# Find cert by name (domain). returns certificate id or empty
npm_find_cert_for_domain() {
  local domain=$1
  # /api/nginx/certs or /api/certificates - attempt common endpoints
  npm_api_call GET "/api/nginx/certificates" | jq -r --arg d "$domain" '.[] | select(.domain == $d) | .id' | head -n1
}

# create or update proxy host
npm_create_or_update_host() {
  local container_name="$1" addr="$2" port="$3" domain="$4"
  # first see if host exists with meta name/container label; we search by domain
  local existing
  existing=$(npm_api_call GET "/api/proxy-hosts" | jq -r --arg d "$domain" '.[] | select(.domain_names[]? == $d) | .id' | head -n1 2>/dev/null || true)

  # find cert
  local cert_id
  cert_id=$(npm_find_cert_for_domain "${DEFAULT_DOMAIN}" || true)
  local ssl_options="null"
  if [ -n "${cert_id}" ]; then
    ssl_options="{\"certificate_id\": ${cert_id}, \"ssl_forced\": true, \"meta\": {\"letsencrypt\":false}}"
  else
    ssl_options="null"
  fi

  # build payload (fields based on schema; some NPM versions differ - we keep minimal required)
  # Use internal IP/port mapping
  read -r -d '' payload <<EOF || true
{
  "domain_names": ["${domain}"],
  "forward_scheme":"http",
  "forward_host":"${addr}",
  "forward_port":${port},
  "access_list_id":0,
  "enabled":true
}
EOF

  if [ -n "${existing}" ]; then
    log "Updating proxy host for ${container_name} -> ${domain} (${addr}:${port})"
    npm_api_call PATCH "/api/proxy-hosts/${existing}" "${payload}" >/dev/null
    echo "${existing}"
  else
    log "Creating proxy host for ${container_name} -> ${domain} (${addr}:${port})"
    npm_api_call POST "/api/proxy-hosts" "${payload}" >/dev/null
    # Attempt to find the created host
    local id
    id=$(npm_api_call GET "/api/proxy-hosts" | jq -r --arg d "$domain" '.[] | select(.domain_names[]? == $d) | .id' | head -n1)
    echo "${id}"
  fi
}

npm_delete_host_by_domain() {
  local domain="$1"
  local id
  id=$(npm_api_call GET "/api/proxy-hosts" | jq -r --arg d "$domain" '.[] | select(.domain_names[]? == $d) | .id' | head -n1)
  if [ -n "${id}" ]; then
    log "Deleting NPM host id=${id} domain=${domain}"
    npm_api_call DELETE "/api/proxy-hosts/${id}" >/dev/null || true
  fi
}

# Helper: get default host IP (assume host IP)
get_host_ip() {
  # find the main non-loopback IPv4 address
  ip -4 addr show scope global | awk '/inet/ {sub("/.*","",$2); print $2; exit}'
}

# Helper: get container port (attempt using template XML)
get_container_webui_port() {
  local cname="$1"
  # use the grep command provided (reads template file)
  local xml="/boot/config/plugins/dockerMan/templates-user/my-${cname}.xml"
  if [ -f "${xml}" ]; then
    local p
    p=$(grep -P '(?<=Name="WebUI")' "${xml}" | grep -Po '(?<=\>)\d+(?=\<)' | head -n1 || true)
    echo "${p}"
    return
  fi
  # fallback: inspect container ports
  docker inspect --format='{{range $p,$conf := .NetworkSettings.Ports}}{{$p}}{{end}}' "${cname}" 2>/dev/null | cut -d '/' -f1 | head -n1 || true
}

# react to container toggles/state
handle_enable_for_container() {
  local cname="$1"
  local desired_domain="${DEFAULT_DOMAIN}"
  local forward_ip
  local forward_port

  # discover container labels (docker inspect)
  if [ "${LABEL_OVERRIDES}" = "true" ]; then
    # label keys: com.npm-auto.domain, com.npm-auto.ip, com.npm-auto.port
    lbls=$(docker inspect --format '{{json .Config.Labels}}' "${cname}" 2>/dev/null)
    if [ -n "${lbls}" ] && [ "${lbls}" != "null" ]; then
      vdomain=$(echo "${lbls}" | jq -r '."com.npm-auto.domain" // empty')
      vip=$(echo "${lbls}" | jq -r '."com.npm-auto.ip" // empty')
      vport=$(echo "${lbls}" | jq -r '."com.npm-auto.port" // empty')
      [ -n "${vdomain}" ] && desired_domain="${vdomain}"
      [ -n "${vip}" ] && forward_ip="${vip}"
      [ -n "${vport}" ] && forward_port="${vport}"
    fi
  fi

  # defaults
  forward_ip=${forward_ip:-$(get_host_ip)}
  forward_port=${forward_port:-$(get_container_webui_port "${cname}")}

  if [ -z "${forward_port}" ] || [ "${forward_port}" = "null" ]; then
    log "Cannot determine webUI port for ${cname}; skipping create."
    return
  fi

  # ensure login
  if ! npm_login; then
    log "NPM login failed; cannot create host for ${cname}"
    return
  fi

  local new_id
  new_id=$(npm_create_or_update_host "${cname}" "${forward_ip}" "${forward_port}" "${cname}.${desired_domain}")
  if [ -n "${new_id}" ]; then
    # update state
    local state
    state=$(read_state)
    state=$(echo "${state}" | jq --arg c "${cname}" --arg id "${new_id}" '. + {($c): { "enabled": true, "npm_id": $id }}')
    write_state "${state}"
  fi
}

handle_disable_for_container() {
  local cname="$1"
  # domain name expected to be <container>.<DEFAULT_DOMAIN> (or read from state/labels)
  local domain="${cname}.${DEFAULT_DOMAIN}"
  if [ -f "${SETTINGS_FILE}" ]; then
    source "${SETTINGS_FILE}" # reload DEFAULT_DOMAIN possibly changed
  fi
  # try label override for domain
  if [ "${LABEL_OVERRIDES}" = "true" ]; then
    lbls=$(docker inspect --format '{{json .Config.Labels}}' "${cname}" 2>/dev/null)
    if [ -n "${lbls}" ] && [ "${lbls}" != "null" ]; then
      vdomain=$(echo "${lbls}" | jq -r '."com.npm-auto.domain" // empty')
      [ -n "${vdomain}" ] && domain="${vdomain}"
    fi
  fi

  if ! npm_login; then
    log "NPM login failed; cannot delete host for ${cname}"
    return
  fi

  npm_delete_host_by_domain "${domain}"

  # update state
  local state
  state=$(read_state)
  state=$(echo "${state}" | jq "del(.\"${cname}\")")
  write_state "${state}"
}

# Monitor docker events in background
monitor_events() {
  log "Starting docker events monitor"
  docker events --format '{{json .}}' | while read -r ev; do
    # example event JSON has Type, Action, Actor.Attributes.name
    action=$(echo "${ev}" | jq -r '.Action // empty')
    typ=$(echo "${ev}" | jq -r '.Type // empty')
    cname=$(echo "${ev}" | jq -r '.Actor.Attributes.name // empty')

    # react to start/stop/die/kill events
    case "${action}" in
      start)
        # if we have state that says enabled, re-create host
        s=$(read_state)
        enabled=$(echo "${s}" | jq -r --arg c "$cname" '.[$c].enabled // false')
        if [ "${enabled}" = "true" ]; then
          handle_enable_for_container "${cname}"
        fi
        ;;
      die|stop|kill)
        # remove host
        s=$(read_state)
        enabled=$(echo "${s}" | jq -r --arg c "$cname" '.[$c].enabled // false')
        if [ "${enabled}" = "true" ]; then
          handle_disable_for_container "${cname}"
        fi
        ;;
      destroy)
        # container removed - remove host entirely
        handle_disable_for_container "${cname}"
        ;;
    esac
  done
}

# A simple HTTP control endpoint can be created by echoing files into /var/www/plugins/..., but we keep daemon simple: it will watch state file
# Start main monitor
monitor_events &
MON_PID=$!

log "npm-auto-daemon started (pid ${MON_PID})"

# Wait forever
wait ${MON_PID}

