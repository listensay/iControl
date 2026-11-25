#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONTROL_SOURCE="$ICONTROL_ROOT/Device/FPSDaemon"
ICONTROL_RESOURCES="$ICONTROL_ROOT/Sources/IControlApp/Resources"
mkdir -p "$ICONTROL_ROOT/work" "$ICONTROL_RESOURCES/FPSDaemon"
if [ "${1:-}" = --simulator ]; then
  xcrun clang -fobjc-arc -DFPSD_SIMULATOR=1 -O2 -Wall -Wextra \
    -Wno-unused-function -Wno-unused-variable \
    "$ICONTROL_SOURCE/main.m" "$ICONTROL_SOURCE/DeviceCursor.m" "$ICONTROL_SOURCE/DeviceCursorHost.m" -framework Foundation -framework CoreFoundation \
    -o "$ICONTROL_ROOT/work/fps-daemon-simulator"
  "$ICONTROL_ROOT/work/fps-daemon-simulator" --version
  exit 0
fi
ICONTROL_SDK="${ICONTROL_IPHONE_SDK:-$ICONTROL_ROOT/work/toolchain/sdks/iPhoneOS16.5.sdk}"
ICONTROL_LDID="${ICONTROL_LDID_PATH:-$ICONTROL_ROOT/work/toolchain/ldid}"
if [ ! -d "$ICONTROL_SDK" ] || [ ! -x "$ICONTROL_LDID" ]; then
  "$ICONTROL_ROOT/Scripts/prepare-ios-toolchain.sh"
fi
ICONTROL_BINARY="$ICONTROL_RESOURCES/FPSDaemon/icontrol-fpsd"
xcrun clang -target arm64-apple-ios14.0 -isysroot "$ICONTROL_SDK" -fobjc-arc -O2 \
  -Wall -Wextra -Wno-unused-variable "$ICONTROL_SOURCE/main.m" "$ICONTROL_SOURCE/DeviceCursor.m" "$ICONTROL_SOURCE/DeviceCursorHost.m" \
  -framework Foundation -framework CoreFoundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ICONTROL_SOURCE/Info.plist" -o "$ICONTROL_BINARY"
"$ICONTROL_LDID" -S"$ICONTROL_SOURCE/entitlements.plist" "$ICONTROL_BINARY"
ICONTROL_HASH="$(shasum -a 256 "$ICONTROL_BINARY")"
printf '{"version":"1.4.0","protocol":1,"deviceCursor":true,"architecture":"arm64","minimumIOS":"14.0","sha256":"%s"}\n' \
  "${ICONTROL_HASH%% *}" > "$ICONTROL_RESOURCES/FPSDaemon/manifest.json"
tar -czf "$ICONTROL_RESOURCES/ThirdPartySources/iControl-FPSDaemon-1.4.0-source.tar.gz" \
  -C "$ICONTROL_ROOT/Device" FPSDaemon
cp "$ICONTROL_SOURCE/COPYING" "$ICONTROL_RESOURCES/FPSDaemon/COPYING"
cp "$ICONTROL_SOURCE/HIDBridge.h" "$ICONTROL_RESOURCES/FPSDaemon/HIDBridge.h"
cp "$ICONTROL_SOURCE/CursorHosting-NOTICE.txt" "$ICONTROL_RESOURCES/FPSDaemon/CursorHosting-NOTICE.txt"
file "$ICONTROL_BINARY"
