#!/bin/bash
# npm-auto-daemon.sh - watches docker events and syncs with NPM
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

# load settings if exist
if [ -f "${SETTINGS_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${SETTINGS_FILE}"
fi

NPM_ENABLED=${NPM_ENABLED:-"true"}
NPM_HOST=${NPM_HOST:-"127.0.0.1"}
NPM_PORT=${NPM_PORT:-"81"}
NPM_USER=${NPM_USER:-"admin@example.com"}
NPM_PASS=${NPM_PASS:-"changeme"}
DEFAULT_DOMAIN=${DEFAULT_DOMAIN:-"example.com"}
LABEL_OVERRIDES=${LABEL_OVERRIDES:-"true"}

NPM_BASE_URL="http://${NPM_HOST}:${NPM_PORT}"
NPM_TOKEN=""
NPM_COOKIE=""

npm_login() {
  local resp
  resp=$(curl -s -X POST "${NPM_BASE_URL}/api/tokens" -H "Content-Type: application/json"         -d "{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}" || true)
  NPM_TOKEN=$(echo "${resp}" | jq -r '.token // empty')
  if [ -n "${NPM_TOKEN}" ]; then
    log "Obtained API token."
    return 0
  fi
  resp=$(curl -s -c /tmp/npm_cookiejar -X POST "${NPM_BASE_URL}/api/login"         -H "Content-Type: application/json"         -d "{\"email\":\"${NPM_USER}\",\"password\":\"${NPM_PASS}\"}" || true)
  if [ -f /tmp/npm_cookiejar ] && grep -q npm /tmp/npm_cookiejar 2>/dev/null; then
    NPM_COOKIE="/tmp/npm_cookiejar"
    log "Logged in via cookie."
    return 0
  fi
  log "NPM login failed. Response: ${resp}"
  return 1
}

npm_api_call() {
  local method=$1 path=$2 data=${3:-}
  local url="${NPM_BASE_URL}${path}"
  local hdrs=( -H "Content-Type: application/json" )
  if [ -n "${NPM_TOKEN}" ]; then
    hdrs+=( -H "Authorization: Bearer ${NPM_TOKEN}" )
  fi
  if [ -n "${NPM_COOKIE}" ]; then
    hdrs+=( -b "${NPM_COOKIE}" )
  fi
  if [ -n "${data}" ]; then
    curl -s -X "${method}" "${url}" "${hdrs[@]}" -d "${data}"
  else
    curl -s -X "${method}" "${url}" "${hdrs[@]}"
  fi
}

npm_find_cert_for_domain() {
  local domain=$1
  npm_api_call GET "/api/nginx/certificates" | jq -r --arg d "$domain" '.[] | select(.domain == $d) | .id' | head -n1 || true
}

npm_create_or_update_host() {
  local container_name="$1" addr="$2" port="$3" domain="$4"
  local existing
  existing=$(npm_api_call GET "/api/proxy-hosts" | jq -r --arg d "$domain" '.[] | select(.domain_names[]? == $d) | .id' | head -n1 2>/dev/null || true)
  local cert_id
  cert_id=$(npm_find_cert_for_domain "${DEFAULT_DOMAIN}" || true)
  local payload
  payload=$(jq -n --arg dn "$domain" --arg fh "$addr" --arg fp "$port" '{
    domain_names: [$dn],
    forward_scheme: "http",
    forward_host: $fh,
    forward_port: ($fp|tonumber),
    access_list_id: 0,
    enabled: true
  }')
  if [ -n "${existing}" ]; then
    log "Updating proxy host for ${container_name} -> ${domain} (${addr}:${port})"
    npm_api_call PATCH "/api/proxy-hosts/${existing}" "${payload}" >/dev/null || true
    echo "${existing}"
  else
    log "Creating proxy host for ${container_name} -> ${domain} (${addr}:${port})"
    npm_api_call POST "/api/proxy-hosts" "${payload}" >/dev/null || true
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

get_host_ip() {
  ip -4 addr show scope global | awk '/inet/ {sub("/.*","",$2); print $2; exit}'
}

get_container_webui_port() {
  local cname="$1"
  local xml="/boot/config/plugins/dockerMan/templates-user/my-${cname}.xml"
  if [ -f "${xml}" ]; then
    local p
    p=$(grep -P '(?<=Name="WebUI")' "${xml}" | grep -Po '(?<=\>)\d+(?=\<)' | head -n1 || true)
    echo "${p}"
    return
  fi
  docker inspect --format='{{range $p,$conf := .NetworkSettings.Ports}}{{$p}}{{end}}' "${cname}" 2>/dev/null | cut -d '/' -f1 | head -n1 || true
}

handle_enable_for_container() {
  local cname="$1"
  local desired_domain="${DEFAULT_DOMAIN}"
  local forward_ip
  local forward_port
  if [ "${LABEL_OVERRIDES}" = "true" ]; then
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
  forward_ip=${forward_ip:-$(get_host_ip)}
  forward_port=${forward_port:-$(get_container_webui_port "${cname}")}
  if [ -z "${forward_port}" ] || [ "${forward_port}" = "null" ]; then
    log "Cannot determine webUI port for ${cname}; skipping create."
    return
  fi
  if ! npm_login; then
    log "NPM login failed; cannot create host for ${cname}"
    return
  fi
  local new_id
  new_id=$(npm_create_or_update_host "${cname}" "${forward_ip}" "${forward_port}" "${cname}.${desired_domain}")
  if [ -n "${new_id}" ]; then
    local state
    state=$(cat "${STATE_FILE}")
    state=$(echo "${state}" | jq --arg c "${cname}" --arg id "${new_id}" '. + {($c): { "enabled": true, "npm_id": $id, "updated_at": now }}')
    echo "${state}" > "${STATE_FILE}"
  fi
}

handle_disable_for_container() {
  local cname="$1"
  local domain="${cname}.${DEFAULT_DOMAIN}"
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
  local state
  state=$(cat "${STATE_FILE}")
  state=$(echo "${state}" | jq "del(.\"${cname}\")")
  echo "${state}" > "${STATE_FILE}"
}

monitor_events() {
  log "Starting docker events monitor"
  docker events --format '{{json .}}' | while read -r ev; do
    action=$(echo "${ev}" | jq -r '.Action // empty')
    cname=$(echo "${ev}" | jq -r '.Actor.Attributes.name // empty')
    case "${action}" in
      start)
        s=$(cat "${STATE_FILE}")
        enabled=$(echo "${s}" | jq -r --arg c "${cname}" '.[$c].enabled // false')
        if [ "${enabled}" = "true" ]; then
          handle_enable_for_container "${cname}"
        fi
        ;;
      die|stop|kill)
        s=$(cat "${STATE_FILE}")
        enabled=$(echo "${s}" | jq -r --arg c "${cname}" '.[$c].enabled // false')
        if [ "${enabled}" = "true" ]; then
          handle_disable_for_container "${cname}"
        fi
        ;;
      destroy)
        handle_disable_for_container "${cname}"
        ;;
    esac
  done
}

monitor_events & MON_PID=$!
log "npm-auto-daemon started (pid ${MON_PID})"
wait ${MON_PID}
