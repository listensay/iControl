#!/bin/bash
# Prepare the native Mac static library consumed by the CRustInput SwiftPM target.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config=${1:-debug}
usage() { echo "Usage: $0 [debug|release]" >&2; exit 2; }
[ "$#" -le 1 ] || usage
case "$config" in debug) profile=dev ;; release) profile=release ;; *) usage ;; esac
[ "$(uname -s)" = Darwin ] || { echo 'Build the Swift app on macOS. The Rust tests also run on Linux.' >&2; exit 1; }
case "$(uname -m)" in arm64) target=aarch64-apple-darwin ;; x86_64) target=x86_64-apple-darwin ;; *) exit 1 ;; esac
command -v cargo >/dev/null || { echo 'Install stable Rust (cargo and rustc) to build the input core.' >&2; exit 1; }

output="$root/work/rust-input/$config"
cargo_dir="$root/work/rust-input/cargo"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --offline --profile "$profile" \
    --manifest-path "$root/Rust/InputCore/Cargo.toml" --target-dir "$cargo_dir" --target "$target"
mkdir -p "$output"
stage=$(mktemp -d "$output/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
archive=libicontrol_input.a
built="$cargo_dir/$target/$config/$archive"
digest=$(shasum -a 256 "$built")
printf '#define ICONTROL_INPUT_BUILD_ID "%s"\n' "${digest%% *}" > "$stage/build-stamp.h"
# The shim embeds the digest so SwiftPM must relink even on a Rust-only change.
if [ ! -f "$output/$archive" ] || ! cmp -s "$stage/build-stamp.h" "$output/build-stamp.h"; then
    cp "$built" "$stage/$archive"
    mv "$stage/$archive" "$output/$archive"
    mv "$stage/build-stamp.h" "$output/build-stamp.h"
fi
printf 'Rust input core (%s, %s): %s/%s\n' "$config" "$target" "$output" "$archive"
