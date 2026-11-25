#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ICONTROL_ROOT"
ICONTROL_DIST="$ICONTROL_ROOT/dist"
ICONTROL_APP="$ICONTROL_DIST/iControl.app"
ICONTROL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ICONTROL_ROOT/Resources/Info.plist")"
ICONTROL_ARCHIVE="$ICONTROL_DIST/iControl-$ICONTROL_VERSION-mac.zip"
ICONTROL_PACKAGES="$ICONTROL_ROOT/Sources/IControlApp/Resources/ServerPackages"
mkdir -p "$ICONTROL_DIST" "$ICONTROL_ROOT/work"
"$ICONTROL_ROOT/Scripts/build-fps-daemon.sh"
(
  cd "$ICONTROL_PACKAGES"
  shasum -a 256 -c SHA256SUMS.txt
)
swift build --configuration release --product iControl
ICONTROL_BIN_DIR="$(swift build --configuration release --show-bin-path)"
ICONTROL_STAGING="$ICONTROL_DIST/iControl-staging.app"
rm -rf "$ICONTROL_STAGING"
mkdir -p "$ICONTROL_STAGING/Contents/MacOS" "$ICONTROL_STAGING/Contents/Resources"
cp "$ICONTROL_BIN_DIR/iControl" "$ICONTROL_STAGING/Contents/MacOS/iControl"
cp "$ICONTROL_ROOT/Resources/Info.plist" "$ICONTROL_STAGING/Contents/Info.plist"
ditto "$ICONTROL_BIN_DIR/iControl_IControlApp.bundle" "$ICONTROL_STAGING/Contents/Resources/iControl_IControlApp.bundle"
cp "$ICONTROL_ROOT/README.md" "$ICONTROL_STAGING/Contents/Resources/iControl_IControlApp.bundle/Resources/README.md"
ICONTROL_ICONSET="$ICONTROL_ROOT/work/AppIcon.iconset"
mkdir -p "$ICONTROL_ICONSET"
swift "$ICONTROL_ROOT/Scripts/make-icon.swift" "$ICONTROL_ICONSET"
iconutil --convert icns --output "$ICONTROL_STAGING/Contents/Resources/AppIcon.icns" "$ICONTROL_ICONSET"
chmod 755 "$ICONTROL_STAGING/Contents/MacOS/iControl"
plutil -lint "$ICONTROL_STAGING/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$ICONTROL_STAGING"
codesign --verify --deep --strict "$ICONTROL_STAGING"
"$ICONTROL_STAGING/Contents/MacOS/iControl" --version
"$ICONTROL_STAGING/Contents/MacOS/iControl" --verify-resources
if [ -d "$ICONTROL_APP" ]; then
  rm -rf "$ICONTROL_DIST/iControl-previous.app"
  mv "$ICONTROL_APP" "$ICONTROL_DIST/iControl-previous.app"
fi
mv "$ICONTROL_STAGING" "$ICONTROL_APP"
ditto -c -k --sequesterRsrc --keepParent "$ICONTROL_APP" "$ICONTROL_ARCHIVE"
(
  cd "$ICONTROL_DIST"
  shasum -a 256 "iControl-$ICONTROL_VERSION-mac.zip" > SHA256SUMS.txt
)
printf '\nApplication: %s\nArchive: %s\n' "$ICONTROL_APP" "$ICONTROL_ARCHIVE"
