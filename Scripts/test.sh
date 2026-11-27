#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ICONTROL_ROOT"
cargo test --locked --offline --manifest-path Rust/InputCore/Cargo.toml
"$ICONTROL_ROOT/Scripts/build-input-core.sh" debug
cc -std=gnu11 -Wall -Wextra -Werror -I Sources/CRustInput/include Tools/check-input-bridge.c \
  work/rust-input/debug/libicontrol_input.a -o work/rust-input/debug/check-bridge
work/rust-input/debug/check-bridge
"$ICONTROL_ROOT/Scripts/build-fps-daemon.sh" --simulator
swift build --product iControlSimulator
if [ -d Tests/IControlCoreTests ]; then
  swift run -Xswiftc -enable-testing iControlValidation
else
  printf 'Skipped legacy iControlValidation: this checkout does not include Tests/IControlCoreTests.\n' >&2
fi
