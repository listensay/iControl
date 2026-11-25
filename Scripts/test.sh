#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ICONTROL_ROOT"
mkdir -p work
"$ICONTROL_ROOT/Scripts/build-fps-daemon.sh" --simulator
swift run -Xswiftc -enable-testing iControlValidation
