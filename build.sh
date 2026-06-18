#!/usr/bin/env bash
# build.sh — cross-compile libdovi for Apple slices and package as Dovi.xcframework
# Usage: ./build.sh
# Outputs: ~/Dev/LibDovi/Dovi.xcframework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
XCFW_OUT="$SCRIPT_DIR/Dovi.xcframework"

# Require cargo in ~/.cargo/bin (sourced or explicit path)
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
echo "==> cargo-cbuild found: $(command -v cargo-cbuild)"

# Ensure required rustup targets
echo "==> Adding rustup targets..."
rustup target add aarch64-apple-tvos
rustup target add aarch64-apple-tvos-sim
# aarch64-apple-darwin is the host, always present

# dolby_vision 3.3.2 lives in the dovi_tool repo at tag libdovi-3.3.2
DOVI_TAG="libdovi-3.3.2"
DOVI_REPO_DIR="$BUILD_DIR/dovi_tool"

if [ -d "$DOVI_REPO_DIR" ]; then
    echo "==> dovi_tool already cloned at $DOVI_REPO_DIR, skipping clone"
else
    mkdir -p "$BUILD_DIR"
    echo "==> Cloning dovi_tool at tag $DOVI_TAG..."
    git clone --depth 1 --branch "$DOVI_TAG" \
        https://github.com/quietvoid/dovi_tool.git \
        "$DOVI_REPO_DIR"
fi

# The dolby_vision crate (with capi feature) is in the dolby_vision sub-crate
CRATE_DIR="$DOVI_REPO_DIR/dolby_vision"
if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: dolby_vision crate not found at $CRATE_DIR" >&2
    exit 1
fi

echo "==> Building for aarch64-apple-tvos (device)..."
SDK_TVOS="$(xcrun --sdk appletvos --show-sdk-path)"
CLANG_TVOS="$(xcrun --sdk appletvos --find clang)"
(
  cd "$CRATE_DIR"
  CC="$CLANG_TVOS" \
  CFLAGS="-isysroot $SDK_TVOS -mtvos-version-min=17.0" \
  cargo cbuild --release --features capi \
    --target aarch64-apple-tvos \
    --target-dir "$BUILD_DIR/cargo"
)

echo "==> Building for aarch64-apple-tvos-sim (simulator)..."
SDK_SIM="$(xcrun --sdk appletvsimulator --show-sdk-path)"
CLANG_SIM="$(xcrun --sdk appletvsimulator --find clang)"
(
  cd "$CRATE_DIR"
  CC="$CLANG_SIM" \
  CFLAGS="-isysroot $SDK_SIM -mtvos-simulator-version-min=17.0" \
  cargo cbuild --release --features capi \
    --target aarch64-apple-tvos-sim \
    --target-dir "$BUILD_DIR/cargo"
)

echo "==> Building for aarch64-apple-darwin (macOS host)..."
(
  cd "$CRATE_DIR"
  cargo cbuild --release --features capi \
    --target aarch64-apple-darwin \
    --target-dir "$BUILD_DIR/cargo"
)

# Locate the built static libraries
find_lib() {
    local triple="$1"
    local candidate="$BUILD_DIR/cargo/$triple/release/libdovi.a"
    if [ -f "$candidate" ]; then
        echo "$candidate"
        return
    fi
    # cargo-c may put it under a different sub-path
    local found
    found="$(find "$BUILD_DIR/cargo/$triple/release" -name "libdovi.a" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then
        echo "$found"
        return
    fi
    echo "ERROR: libdovi.a not found for $triple under $BUILD_DIR/cargo/$triple/release" >&2
    exit 1
}

LIB_TVOS="$(find_lib aarch64-apple-tvos)"
LIB_SIM="$(find_lib aarch64-apple-tvos-sim)"
LIB_MACOS="$(find_lib aarch64-apple-darwin)"

echo "==> tvOS device lib:    $LIB_TVOS"
echo "==> tvOS sim lib:       $LIB_SIM"
echo "==> macOS lib:          $LIB_MACOS"

# Locate the generated header (cargo-c places it alongside the .a)
find_header() {
    local triple="$1"
    local dir
    dir="$(dirname "$(find_lib "$triple")")"
    # cargo-c generates dovi.h next to the .a
    local candidate="$dir/dovi.h"
    if [ -f "$candidate" ]; then
        echo "$candidate"
        return
    fi
    # Some cargo-c versions put it in include/
    local found
    found="$(find "$BUILD_DIR/cargo/$triple/release" -name "*.h" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then
        echo "$found"
        return
    fi
    # Also check top-level include in crate dir
    found="$(find "$CRATE_DIR" -maxdepth 3 -name "dovi.h" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then
        echo "$found"
        return
    fi
    echo "ERROR: dovi.h not found for $triple" >&2
    exit 1
}

HEADER_TVOS="$(find_header aarch64-apple-tvos)"
echo "==> Header: $HEADER_TVOS"

# Prepare per-slice staging directories for xcodebuild -create-xcframework
# The -library flag takes a .a; the -headers flag takes a directory.
STAGE_DIR="$BUILD_DIR/xcfw_stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/tvos/Headers"
mkdir -p "$STAGE_DIR/tvos-sim/Headers"
mkdir -p "$STAGE_DIR/macos/Headers"

cp "$LIB_TVOS"  "$STAGE_DIR/tvos/libdovi.a"
cp "$LIB_SIM"   "$STAGE_DIR/tvos-sim/libdovi.a"
cp "$LIB_MACOS" "$STAGE_DIR/macos/libdovi.a"

# Copy header into each slice's Headers dir (xcodebuild expects a directory)
for slice in tvos tvos-sim macos; do
    cp "$HEADER_TVOS" "$STAGE_DIR/$slice/Headers/dovi.h"
done

# Remove existing xcframework to allow idempotent re-runs
rm -rf "$XCFW_OUT"

echo "==> Assembling Dovi.xcframework..."
xcodebuild -create-xcframework \
    -library "$STAGE_DIR/tvos/libdovi.a"     -headers "$STAGE_DIR/tvos/Headers" \
    -library "$STAGE_DIR/tvos-sim/libdovi.a" -headers "$STAGE_DIR/tvos-sim/Headers" \
    -library "$STAGE_DIR/macos/libdovi.a"    -headers "$STAGE_DIR/macos/Headers" \
    -output "$XCFW_OUT"

echo ""
echo "==> Done! XCFramework at: $XCFW_OUT"
echo "==> Contents:"
ls "$XCFW_OUT"
