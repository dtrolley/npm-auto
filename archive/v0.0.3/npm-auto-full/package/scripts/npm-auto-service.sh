#!/bin/bash
# service wrapper - start/stop the daemon and keep pidfile
BASE_DIR="/usr/local/emhttp/plugins/npm-auto"
DAEMON="${BASE_DIR}/scripts/npm-auto-daemon.sh"
PIDFILE="/var/run/npm-auto.pid"
LOG="/boot/config/plugins/npm-auto/var/npm-auto.log"

case "$1" in
  start)
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then
      echo "npm-auto already running (pid $(cat ${PIDFILE}))"
      exit 0
    fi
    nohup bash "${DAEMON}" >> "${LOG}" 2>&1 &
    echo $! > "${PIDFILE}"
    echo "Started npm-auto (pid $!)"
    ;;
  stop)
    if [ -f "${PIDFILE}" ]; then
      kill $(cat "${PIDFILE}") 2>/dev/null || true
      rm -f "${PIDFILE}"
      echo "Stopped"
    else
      echo "Not running"
    fi
    ;;
  restart)
    $0 stop
    sleep 1
    $0 start
    ;;
  status)
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then
      echo "Running (pid $(cat ${PIDFILE}))"
    else
      echo "Not running"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 2
    ;;
esac
