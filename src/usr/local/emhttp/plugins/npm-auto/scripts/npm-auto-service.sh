#!/bin/bash

#==============================================================================
# npm-auto-service.sh
#
# Manages the npm-auto daemon.
#==============================================================================

PIDFILE="/var/run/npm-auto.pid"
DAEMON="/usr/local/emhttp/plugins/npm-auto/scripts/npm-auto-daemon.sh"

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "npm-auto is already running."
    return 0
  fi
  rm -f "$PIDFILE"
  echo "Starting npm-auto daemon..."
  /usr/bin/nohup "$DAEMON" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
}

stop() {
  if ! is_running; then
    echo "npm-auto is not running."
    rm -f "$PIDFILE"
    return 0
  fi
  echo "Stopping npm-auto daemon..."
  kill "$(cat "$PIDFILE")"
  rm -f "$PIDFILE"
}

restart() {
  stop
  start
}

status() {
  if is_running; then
    echo "npm-auto is running (pid $(cat "$PIDFILE"))."
  else
    echo "npm-auto is not running."
  fi
}

case "$1" in
  start)   start ;;
  stop)    stop ;;
  restart) restart ;;
  status)  status ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
