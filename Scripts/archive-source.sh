#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONTROL_DIST="$ICONTROL_ROOT/dist"
ICONTROL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ICONTROL_ROOT/Resources/Info.plist")"
mkdir -p "$ICONTROL_DIST" "$ICONTROL_ROOT/work"
ICONTROL_EXPORT="$(mktemp -d "$ICONTROL_ROOT/work/source-export.XXXXXX")"
trap 'rm -rf "$ICONTROL_EXPORT"' EXIT
ICONTROL_SOURCE="$ICONTROL_EXPORT/iControl"
mkdir -p "$ICONTROL_SOURCE"
for ICONTROL_ITEM in .gitignore Package.swift README.md LICENSE THIRD_PARTY_NOTICES.md Device Resources Scripts Sources Tests Tools; do
  ditto --norsrc "$ICONTROL_ROOT/$ICONTROL_ITEM" "$ICONTROL_SOURCE/$ICONTROL_ITEM"
done
find "$ICONTROL_SOURCE" -type f -name .DS_Store -delete
ditto -c -k --norsrc --keepParent "$ICONTROL_SOURCE" "$ICONTROL_DIST/iControl-$ICONTROL_VERSION-source.zip"
(
  cd "$ICONTROL_DIST"
  if [ -f "iControl-$ICONTROL_VERSION-mac.zip" ]; then
    shasum -a 256 "iControl-$ICONTROL_VERSION-mac.zip" "iControl-$ICONTROL_VERSION-source.zip" > SHA256SUMS.txt
  else
    shasum -a 256 "iControl-$ICONTROL_VERSION-source.zip" > SHA256SUMS.txt
  fi
)
printf 'Source archive: %s\n' "$ICONTROL_DIST/iControl-$ICONTROL_VERSION-source.zip"
