#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ICONTROL_ROOT"
test "$(uname -m)" = arm64 || { printf 'Mac packaging requires an Apple Silicon host.\n' >&2; exit 1; }
python3 Tools/check-release-version.py
python3 Tools/verify-docs.py
ICONTROL_DIST="$ICONTROL_ROOT/dist"
ICONTROL_APP="$ICONTROL_DIST/iControl.app"
ICONTROL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ICONTROL_ROOT/Resources/Info.plist")"
ICONTROL_ARCHIVE="$ICONTROL_DIST/iControl-$ICONTROL_VERSION-mac.zip"
ICONTROL_PACKAGES="$ICONTROL_ROOT/Sources/IControlApp/Resources/ServerPackages"
mkdir -p "$ICONTROL_DIST" "$ICONTROL_ROOT/work"
case "${1:-}" in
  '') "$ICONTROL_ROOT/Scripts/build-fps-daemon.sh" ;;
  --bundled-fps) ;; # Keep the signed device binary that was exercised on hardware.
  *) printf 'Usage: %s [--bundled-fps]\n' "$0" >&2; exit 2 ;;
esac
python3 Tools/verify-fps-package.py
(
  cd "$ICONTROL_PACKAGES"
  shasum -a 256 -c SHA256SUMS.txt
)
"$ICONTROL_ROOT/Scripts/build-input-core.sh" release
swift build --configuration release --product iControl
ICONTROL_BIN_DIR="$(swift build --configuration release --show-bin-path)"
ICONTROL_STAGING="$ICONTROL_DIST/iControl-staging.app"
rm -rf "$ICONTROL_STAGING"
mkdir -p "$ICONTROL_STAGING/Contents/MacOS" "$ICONTROL_STAGING/Contents/Resources"
cp "$ICONTROL_BIN_DIR/iControl" "$ICONTROL_STAGING/Contents/MacOS/iControl"
cp "$ICONTROL_ROOT/Resources/Info.plist" "$ICONTROL_STAGING/Contents/Info.plist"
ditto "$ICONTROL_BIN_DIR/iControl_IControlApp.bundle" "$ICONTROL_STAGING/Contents/Resources/iControl_IControlApp.bundle"
ICONTROL_DOC_ROOT="$ICONTROL_STAGING/Contents/Resources/iControl_IControlApp.bundle/Resources"
for ICONTROL_DOC in README.md README.zh-CN.md LICENSE THIRD_PARTY_NOTICES.md; do
  cp "$ICONTROL_ROOT/$ICONTROL_DOC" "$ICONTROL_DOC_ROOT/$ICONTROL_DOC"
done
ditto --norsrc "$ICONTROL_ROOT/docs" "$ICONTROL_DOC_ROOT/docs"
python3 Tools/verify-docs.py "$ICONTROL_DOC_ROOT"
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
