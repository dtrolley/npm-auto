#!/bin/bash
BASE_DIR="/usr/local/emhttp/plugins/npm-auto"
DAEMON="${BASE_DIR}/scripts/npm-auto-daemon.sh"
PIDFILE="/var/run/npm-auto.pid"
LOG="/boot/config/plugins/npm-auto/var/npm-auto.log"
case "$1" in
  start)
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then echo "Already running"; exit 0; fi
    nohup bash "${DAEMON}" >> "${LOG}" 2>&1 & echo $! > "${PIDFILE}"; echo "Started";;
  stop)
    if [ -f "${PIDFILE}" ]; then kill $(cat "${PIDFILE}") 2>/dev/null || true; rm -f "${PIDFILE}"; echo "Stopped"; else echo "Not running"; fi ;;
  status)
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then echo "Running"; else echo "Not running"; fi ;;
  *)
    echo "Usage: $0 {start|stop|status}"; exit 2;;
esac
