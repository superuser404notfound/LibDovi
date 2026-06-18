#!/usr/bin/env bash
# build.sh — cross-compile libdovi for Apple slices and package as Dovi.xcframework
# Usage: ./build.sh
# Outputs: ~/Dev/LibDovi/Dovi.xcframework
#
# Five xcframework slices:
#   macos-arm64_x86_64            (fat: Apple Silicon + Intel Macs)
#   ios-arm64                     (device)
#   ios-arm64_x86_64-simulator    (fat: Apple Silicon + Intel Macs)
#   tvos-arm64                    (device)
#   tvos-arm64-simulator          (Apple Silicon only)
#
# x86_64 is included for macOS and the iOS simulator (Intel-Mac support). The
# tvOS simulator stays arm64-only: x86_64-apple-tvos is a low-tier Rust target
# with no prebuilt std (would need nightly + build-std), and Intel-Mac tvOS
# *simulator* use is not worth that cost. Everything here is stable Rust.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CARGO_DIR="$BUILD_DIR/cargo"
XCFW_OUT="$SCRIPT_DIR/Dovi.xcframework"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo &>/dev/null; then
    echo "ERROR: cargo not found. Install Rust via https://rustup.rs" >&2
    exit 1
fi
if ! command -v cargo-cbuild &>/dev/null; then
    echo "ERROR: cargo-c not found. Install with: cargo install cargo-c" >&2
    exit 1
fi

echo "==> cargo version: $(cargo --version)"

echo "==> Adding rustup targets..."
rustup target add \
    aarch64-apple-tvos aarch64-apple-tvos-sim \
    aarch64-apple-ios aarch64-apple-ios-sim \
    x86_64-apple-darwin x86_64-apple-ios

# dolby_vision 3.3.2 lives in the dovi_tool repo at tag libdovi-3.3.2
DOVI_TAG="libdovi-3.3.2"
DOVI_REPO_DIR="$BUILD_DIR/dovi_tool"

if [ -d "$DOVI_REPO_DIR" ]; then
    echo "==> dovi_tool already cloned, skipping clone"
else
    mkdir -p "$BUILD_DIR"
    echo "==> Cloning dovi_tool at tag $DOVI_TAG..."
    git clone --depth 1 --branch "$DOVI_TAG" \
        https://github.com/quietvoid/dovi_tool.git \
        "$DOVI_REPO_DIR"
fi

CRATE_DIR="$DOVI_REPO_DIR/dolby_vision"
if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: dolby_vision crate not found at $CRATE_DIR" >&2
    exit 1
fi

# build_slice <triple> <sdk-or-empty> <min-cflag-or-empty>
build_slice() {
    local triple="$1" sdk="$2" mincflag="$3"
    echo "==> Building $triple..."
    if [ -z "$sdk" ]; then
        ( cd "$CRATE_DIR"
          cargo cbuild --release --features capi \
            --target "$triple" --target-dir "$CARGO_DIR" )
    else
        local sdkpath cc
        sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
        cc="$(xcrun --sdk "$sdk" --find clang)"
        ( cd "$CRATE_DIR"
          CC="$cc" CFLAGS="-isysroot $sdkpath $mincflag" \
          cargo cbuild --release --features capi \
            --target "$triple" --target-dir "$CARGO_DIR" )
    fi
}

# tvOS
build_slice aarch64-apple-tvos     appletvos        "-mtvos-version-min=17.0"
build_slice aarch64-apple-tvos-sim appletvsimulator "-mtvos-simulator-version-min=17.0"
# iOS
build_slice aarch64-apple-ios      iphoneos         "-mios-version-min=16.0"
build_slice aarch64-apple-ios-sim  iphonesimulator  "-mios-simulator-version-min=16.0"
build_slice x86_64-apple-ios       iphonesimulator  "-mios-simulator-version-min=16.0"
# macOS
build_slice aarch64-apple-darwin   ""               ""
build_slice x86_64-apple-darwin    ""               ""

# Locate a built static library for a triple.
find_lib() {
    local triple="$1"
    local candidate="$CARGO_DIR/$triple/release/libdovi.a"
    if [ -f "$candidate" ]; then echo "$candidate"; return; fi
    local found
    found="$(find "$CARGO_DIR/$triple/release" -maxdepth 1 -name "libdovi.a" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then echo "$found"; return; fi
    echo "ERROR: libdovi.a not found for $triple" >&2
    exit 1
}

# Locate the cargo-c generated header (cbindgen emits it under
# include/<crate>/, named rpu_parser.h). It is the same for every slice and is
# staged as dovi.h so `import Dovi` resolves the module's umbrella header.
find_header() {
    local base="$CARGO_DIR/aarch64-apple-tvos/release" found
    found="$(find "$base" -name "*.h" 2>/dev/null | grep -iE 'rpu_parser|dovi' | head -1)"
    if [ -z "$found" ]; then
        found="$(find "$base" -name "*.h" 2>/dev/null | head -1)"
    fi
    if [ -z "$found" ]; then echo "ERROR: cargo-c header (*.h) not found under $base" >&2; exit 1; fi
    echo "$found"
}

HEADER="$(find_header)"
echo "==> Header: $HEADER"

STAGE_DIR="$BUILD_DIR/xcfw_stage"
rm -rf "$STAGE_DIR"

# stage_slice <slice-name> <.a path>
stage_slice() {
    local name="$1" lib="$2"
    mkdir -p "$STAGE_DIR/$name/Headers"
    cp "$lib" "$STAGE_DIR/$name/libdovi.a"
    cp "$HEADER" "$STAGE_DIR/$name/Headers/dovi.h"
    cat > "$STAGE_DIR/$name/Headers/module.modulemap" << 'MODULEMAP'
module Dovi {
    header "dovi.h"
    export *
}
MODULEMAP
}

# Fat macOS + iOS-simulator slices via lipo (arm64 + x86_64); single-arch for
# the devices and the tvOS simulator.
mkdir -p "$STAGE_DIR/fat"
lipo -create "$(find_lib aarch64-apple-darwin)"  "$(find_lib x86_64-apple-darwin)" -output "$STAGE_DIR/fat/macos.a"
lipo -create "$(find_lib aarch64-apple-ios-sim)" "$(find_lib x86_64-apple-ios)"    -output "$STAGE_DIR/fat/ios-sim.a"

stage_slice macos    "$STAGE_DIR/fat/macos.a"
stage_slice ios-sim  "$STAGE_DIR/fat/ios-sim.a"
stage_slice tvos-sim "$(find_lib aarch64-apple-tvos-sim)"
stage_slice ios      "$(find_lib aarch64-apple-ios)"
stage_slice tvos     "$(find_lib aarch64-apple-tvos)"

rm -rf "$XCFW_OUT"
echo "==> Assembling Dovi.xcframework..."
xcodebuild -create-xcframework \
    -library "$STAGE_DIR/macos/libdovi.a"     -headers "$STAGE_DIR/macos/Headers" \
    -library "$STAGE_DIR/ios/libdovi.a"        -headers "$STAGE_DIR/ios/Headers" \
    -library "$STAGE_DIR/ios-sim/libdovi.a"    -headers "$STAGE_DIR/ios-sim/Headers" \
    -library "$STAGE_DIR/tvos/libdovi.a"       -headers "$STAGE_DIR/tvos/Headers" \
    -library "$STAGE_DIR/tvos-sim/libdovi.a"   -headers "$STAGE_DIR/tvos-sim/Headers" \
    -output "$XCFW_OUT"

echo ""
echo "==> Done. XCFramework at: $XCFW_OUT"
ls "$XCFW_OUT"
for a in "$XCFW_OUT"/*/libdovi.a; do echo "  $a:"; lipo -info "$a" 2>/dev/null | sed 's/^/    /'; done