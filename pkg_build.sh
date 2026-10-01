#!/bin/bash
#==============================================================================
# pkg_build.sh - build the npm-auto Slackware package (.txz)
#
#   ./pkg_build.sh          build archive/npm-auto-<version>.txz and point
#                           npm-auto.plg at it (version + MD5 entities)
#   ./pkg_build.sh --check  build into a scratch dir and verify it; touches
#                           neither archive/ nor npm-auto.plg (used by CI)
#
# Works from a clean checkout on macOS (bsdtar) or Linux (GNU tar). Needs
# bash, tar, xz and md5sum (macOS: `md5 -q` is used as a fallback).
#
# Version scheme: YYYY.MM.DD, then YYYY.MM.DD-01, -02 ... for further builds
# the same day. Unraid compares plugin versions with strcmp(), so the counter
# is zero-padded: an unpadded "-10" would sort below "-9" and never be
# offered as an update.
#==============================================================================

set -euo pipefail

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  "") ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG_NAME="npm-auto"
SRC_DIR="$ROOT/src"
PLUGIN_SUBDIR="usr/local/emhttp/plugins/$PKG_NAME"
PLG_FILE="$ROOT/$PKG_NAME.plg"

if [ "$CHECK_ONLY" = 1 ]; then
  ARCHIVE_DIR=$(mktemp -d)
else
  ARCHIVE_DIR="$ROOT/archive"
fi
STAGE=$(mktemp -d)
cleanup() {
  rm -rf "$STAGE"
  [ "$CHECK_ONLY" = 1 ] && rm -rf "$ARCHIVE_DIR"
  return 0
}
trap cleanup EXIT

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

#--- Version ---
VERSION=$(date +"%Y.%m.%d")
if [ -f "$ARCHIVE_DIR/$PKG_NAME-$VERSION.txz" ]; then
  i=1
  while [ -f "$ARCHIVE_DIR/$PKG_NAME-$VERSION-$(printf '%02d' "$i").txz" ]; do
    i=$((i + 1))
  done
  VERSION="$VERSION-$(printf '%02d' "$i")"
fi
FILENAME="$ARCHIVE_DIR/$PKG_NAME-$VERSION.txz"

#--- Stage ---
[ -d "$SRC_DIR/$PLUGIN_SUBDIR" ] || { echo "Missing $SRC_DIR/$PLUGIN_SUBDIR" >&2; exit 1; }
cp -R "$SRC_DIR/." "$STAGE"
find "$STAGE" \( -name ".DS_Store" -o -name "._*" \) -exec rm -f {} +

# Normalise permissions: directories and executables 755, everything else 644.
# (A checkout's modes depend on the umask and on git's core.fileMode.)
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/$PLUGIN_SUBDIR"/scripts/*.sh \
          "$STAGE/$PLUGIN_SUBDIR"/event/* \
          "$STAGE/$PLUGIN_SUBDIR/webGui/settings.php"

#--- Pack ---
# Owner must be root (uid/gid 0): installpkg extracts to / as root, and any
# other owner chowns /, /usr, ... on the server (breaks sshd StrictModes etc.).
# GNU tar and bsdtar spell this differently.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  OWNER_OPTS=(--owner=0 --group=0 --numeric-owner --sort=name)
else
  # bsdtar (macOS): also keep extended attributes such as
  # com.apple.provenance out of the archive.
  OWNER_OPTS=(--uid 0 --gid 0 --numeric-owner --no-xattrs)
fi
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -cJf "$FILENAME" "${OWNER_OPTS[@]}" .)

#--- Verify ---
LISTING=$(tar -tvJf "$FILENAME" 2>/dev/null)
for f in npm-auto.page npm-auto.Docker.page npm-auto.js npm-auto.css \
         scripts/npm-auto-daemon.sh scripts/npm-auto-service.sh \
         event/started event/stopping_svcs \
         webGui/settings.php webGui/settings_ui.php; do
  echo "$LISTING" | grep -q "\./$PLUGIN_SUBDIR/$f\$" \
    || { echo "Package is missing $PLUGIN_SUBDIR/$f" >&2; exit 1; }
done
if echo "$LISTING" | grep -q -E '\.DS_Store|/\._'; then
  echo "Package contains macOS metadata" >&2; exit 1
fi
if echo "$LISTING" | awk '{print $2}' | grep -v -q -E '^(0/0|root/root)$'; then
  echo "Package contains entries not owned by root (0/0)" >&2; exit 1
fi

MD5=$(md5_of "$FILENAME")

if [ "$CHECK_ONLY" = 1 ]; then
  echo "Check build OK: $PKG_NAME-$VERSION.txz ($MD5); archive/ and .plg untouched"
  exit 0
fi

#--- Point the .plg at the new package ---
TMP_PLG_FILE=$(mktemp)
sed -e "s/<!ENTITY version \".*\">/<!ENTITY version \"$VERSION\">/" \
    -e "s/<!ENTITY md5 \".*\">/<!ENTITY md5 \"$MD5\">/" \
    "$PLG_FILE" > "$TMP_PLG_FILE"
mv "$TMP_PLG_FILE" "$PLG_FILE"

echo "Package created: $FILENAME"
echo "Version: $VERSION"
echo "MD5: $MD5"
echo "PLG file updated - add a <CHANGES> entry for $VERSION, then commit"
echo "npm-auto.plg and archive/$PKG_NAME-$VERSION.txz together."
