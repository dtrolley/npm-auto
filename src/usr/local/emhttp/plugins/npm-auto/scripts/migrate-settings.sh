#!/bin/bash
#==============================================================================
# migrate-settings.sh - run by the .plg on install/upgrade
#
# Until 2026.10 settings lived in var/settings.json, written by the plugin's
# own form. They now live in npm-auto.cfg, written by Unraid's /update.php
# like any other plugin's. Converts once; the old file is kept, renamed.
#==============================================================================

BASE="/boot/config/plugins/npm-auto"
CFG="$BASE/npm-auto.cfg"
OLD="$BASE/var/settings.json"

[ -f "$CFG" ] && exit 0
[ -f "$OLD" ] || exit 0

if jq -r '
  def on:  . == true or . == "true";
  def yn:  if . == false or . == "false" then "no" else "yes" end;
  def str: (. // "") | tostring | gsub("[\"\r\n]"; "");
  "SERVICE=\"\(if .NPM_ENABLED | on then "enable" else "disable" end)\"",
  "NPM_HOST=\"\(.NPM_HOST | str)\"",
  "NPM_PORT=\"\((.NPM_PORT // "81") | str)\"",
  "NPM_USER=\"\(.NPM_USER | str)\"",
  "NPM_PASS=\"\(.NPM_PASS | str)\"",
  "DEFAULT_DOMAIN=\"\(.DEFAULT_DOMAIN | str | ascii_downcase)\"",
  "LABEL_OVERRIDES=\"\(.LABEL_OVERRIDES | yn)\"",
  "AUTO_SSL=\"\(.AUTO_SSL | yn)\"",
  "TOGGLE_OFF_ACTION=\"\((.TOGGLE_OFF_ACTION // "disable") | str)\""
' "$OLD" > "$CFG.tmp" 2>/dev/null; then
  mv "$CFG.tmp" "$CFG"
  mv "$OLD" "$OLD.migrated"
  echo "npm-auto: settings moved to $CFG"
else
  rm -f "$CFG.tmp"
  echo "npm-auto: could not read $OLD; settings start from defaults"
fi
