#!/bin/bash

set -e

CWD=$(pwd)
TMP_DIR="$CWD/tmp/tmp.$((RANDOM % 1000000))"
VERSION=$(date +"%Y.%m.%d")
PKG_NAME="npm-auto"
ARCHIVE_DIR="$CWD/archive"
PLG_FILE="$CWD/$PKG_NAME.plg"

# Create a new version number if a package already exists for today
if [ -f "$ARCHIVE_DIR/$PKG_NAME-$VERSION.txz" ]; then
  i=1
  while [ -f "$ARCHIVE_DIR/$PKG_NAME-$VERSION-$i.txz" ]; do
    i=$((i+1))
  done
  VERSION="$VERSION-$i"
fi

FILENAME="$ARCHIVE_DIR/$PKG_NAME-$VERSION.txz"

# Create the package
mkdir -p "$TMP_DIR"
cp -r "$CWD/src/." "$TMP_DIR"
(cd "$TMP_DIR" && makepkg -l y -c y "$FILENAME")

# Update the .plg file
MD5=$(md5sum "$FILENAME" | awk '{print $1}')
sed -i "s/<!ENTITY version ".*">/<!ENTITY version "$VERSION">/" "$PLG_FILE"
sed -i "s/<!ENTITY md5 ".*">/<!ENTITY md5 "$MD5">/" "$PLG_FILE"

# Cleanup
rm -rf "$TMP_DIR"

echo "Package created: $FILENAME"
echo "Version: $VERSION"
echo "MD5: $MD5"
echo "PLG file updated"
