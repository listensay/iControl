#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONTROL_TOOLS="$ICONTROL_ROOT/work/toolchain"
ICONTROL_SDK_REV=0222fd5413cf4b9af096f37b4621afa2688572f7
mkdir -p "$ICONTROL_TOOLS"
if [ ! -d "$ICONTROL_TOOLS/sdks/iPhoneOS16.5.sdk" ]; then
  if [ ! -d "$ICONTROL_TOOLS/sdks/.git" ]; then
    git init "$ICONTROL_TOOLS/sdks"
    git -C "$ICONTROL_TOOLS/sdks" remote add origin https://github.com/theos/sdks.git
  fi
  git -C "$ICONTROL_TOOLS/sdks" sparse-checkout init --cone
  git -C "$ICONTROL_TOOLS/sdks" sparse-checkout set iPhoneOS16.5.sdk
  git -C "$ICONTROL_TOOLS/sdks" fetch --depth=1 --filter=blob:none origin "$ICONTROL_SDK_REV"
  git -C "$ICONTROL_TOOLS/sdks" checkout --detach "$ICONTROL_SDK_REV"
fi
if [ ! -x "$ICONTROL_TOOLS/ldid" ]; then
  curl --fail --location --retry 2 --output "$ICONTROL_TOOLS/ldid.download" \
    https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus8/ldid_macosx_arm64
  ICONTROL_DIGEST="$(shasum -a 256 "$ICONTROL_TOOLS/ldid.download")"
  [ "${ICONTROL_DIGEST%% *}" = 99b8c3052c188184e259b9c512f8ceb7c40ca89e44c99bb96b38c4bd635ff4df ]
  mv "$ICONTROL_TOOLS/ldid.download" "$ICONTROL_TOOLS/ldid"
  chmod 755 "$ICONTROL_TOOLS/ldid"
fi
printf 'iPad SDK and local signing tool are ready.\n'
