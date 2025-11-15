#!/bin/bash

#==============================================================================
# npm-auto-service.sh
#
# This script manages the npm-auto daemon.
#==============================================================================

#--- Configuration ---#
PIDFILE="/var/run/npm-auto.pid"
DAEMON="/usr/local/emhttp/plugins/npm-auto/scripts/npm-auto-daemon.sh"

#--- Functions ---#
start() {
  if [ -f "$PIDFILE" ]; then
    echo "npm-auto is already running."
    exit 1
  fi

  echo "Starting npm-auto daemon..."
  /usr/bin/nohup "$DAEMON" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
}

stop() {
  if [ ! -f "$PIDFILE" ]; then
    echo "npm-auto is not running."
    exit 1
  fi

  echo "Stopping npm-auto daemon..."
  kill "$(cat "$PIDFILE")"
  rm "$PIDFILE"
}

restart() {
  stop
  start
}

status() {
  if [ -f "$PIDFILE" ]; then
    echo "npm-auto is running."
  else
    echo "npm-auto is not running."
  fi
}

#--- Main logic ---#
case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
