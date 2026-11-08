#!/usr/bin/env bash
# build.sh — cross-compile libdovi for Apple slices and package as Dovi.xcframework
# Usage: ./build.sh
# Outputs: ~/Dev/LibDovi/Dovi.xcframework
#
# Seven xcframework slices:
#   macos-arm64_x86_64            (fat: Apple Silicon + Intel Macs)
#   ios-arm64                     (device)
#   ios-arm64_x86_64-simulator    (fat: Apple Silicon + Intel Macs)
#   tvos-arm64                    (device)
#   tvos-arm64-simulator          (Apple Silicon only)
#   xros-arm64                    (device)
#   xros-arm64-simulator          (Apple Silicon only)
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
    aarch64-apple-visionos aarch64-apple-visionos-sim \
    x86_64-apple-darwin x86_64-apple-ios

# dolby_vision 3.4.0 lives in the dovi_tool repo at tag libdovi-3.4.0
DOVI_TAG="libdovi-3.4.0"
DOVI_REPO_DIR="$BUILD_DIR/dovi_tool"

# A checkout at a different tag than the one asked for is stale: the clone below is skipped
# whenever the directory exists, so bumping DOVI_TAG alone would rebuild the OLD crate and
# produce an xcframework that changed nothing. Membership, not `git describe`: this repo carries
# two tag series on the same commits (the CLI's `2.3.0` and the library's `libdovi-3.3.2`), so
# describe can answer with the other one and read as a mismatch when it is not.
if [ -d "$DOVI_REPO_DIR" ] && ! git -C "$DOVI_REPO_DIR" tag --points-at HEAD 2>/dev/null | grep -qx "$DOVI_TAG"; then
    echo "==> dovi_tool is not at $DOVI_TAG: discarding and re-cloning"
    rm -rf "$DOVI_REPO_DIR"
fi

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

# Local additions to the C API, kept as patches against the pinned tag. A checkout that already
# carries a patch is left alone; one that carries something else fails the build instead of
# packaging an xcframework whose header does not match the patch set.
for patch in "$SCRIPT_DIR"/patches/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$DOVI_REPO_DIR" apply --reverse --check "$patch" 2>/dev/null; then
        echo "==> Patch already applied: $(basename "$patch")"
    else
        echo "==> Applying patch: $(basename "$patch")"
        git -C "$DOVI_REPO_DIR" apply "$patch"
    fi
done
if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: dolby_vision crate not found at $CRATE_DIR" >&2
    exit 1
fi

# --locked: the crate ships its Cargo.lock at the tag, and without the flag cargo would quietly
# re-resolve whenever that lock no longer satisfies the manifest, so a rebuild could pull other
# dependency versions than the release it claims to reproduce. With it, a stale lock fails the build.
# build_slice <triple> <sdk-or-empty> <min-cflag-or-empty>
build_slice() {
    local triple="$1" sdk="$2" mincflag="$3"
    echo "==> Building $triple..."
    if [ -z "$sdk" ]; then
        ( cd "$CRATE_DIR"
          cargo cbuild --release --locked --features capi \
            --target "$triple" --target-dir "$CARGO_DIR" )
    else
        local sdkpath cc
        sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
        cc="$(xcrun --sdk "$sdk" --find clang)"
        ( cd "$CRATE_DIR"
          CC="$cc" CFLAGS="-isysroot $sdkpath $mincflag" \
          cargo cbuild --release --locked --features capi \
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
# visionOS
build_slice aarch64-apple-visionos     xros        "-mtargetos=xros1.0"
build_slice aarch64-apple-visionos-sim xrsimulator "-mtargetos=xros1.0-simulator"
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
stage_slice xros     "$(find_lib aarch64-apple-visionos)"
stage_slice xros-sim "$(find_lib aarch64-apple-visionos-sim)"

rm -rf "$XCFW_OUT"
echo "==> Assembling Dovi.xcframework..."
xcodebuild -create-xcframework \
    -library "$STAGE_DIR/macos/libdovi.a"     -headers "$STAGE_DIR/macos/Headers" \
    -library "$STAGE_DIR/ios/libdovi.a"        -headers "$STAGE_DIR/ios/Headers" \
    -library "$STAGE_DIR/ios-sim/libdovi.a"    -headers "$STAGE_DIR/ios-sim/Headers" \
    -library "$STAGE_DIR/tvos/libdovi.a"       -headers "$STAGE_DIR/tvos/Headers" \
    -library "$STAGE_DIR/tvos-sim/libdovi.a"   -headers "$STAGE_DIR/tvos-sim/Headers" \
    -library "$STAGE_DIR/xros/libdovi.a"       -headers "$STAGE_DIR/xros/Headers" \
    -library "$STAGE_DIR/xros-sim/libdovi.a"   -headers "$STAGE_DIR/xros-sim/Headers" \
    -output "$XCFW_OUT"

# Build record. The xcframework is built on a local Mac, not in CI, so this file is the provenance a
# consumer gets: inputs, toolchain, the resolved dependency tree and the hash of every shipped
# library. The lock the build used is committed beside it, in case the upstream tag ever moves.
INFO_OUT="$SCRIPT_DIR/BUILD-INFO.txt"
LOCK_OUT="$SCRIPT_DIR/BUILD-INFO.Cargo.lock"
cp "$CRATE_DIR/Cargo.lock" "$LOCK_OUT"
DIRTY=""
git -C "$SCRIPT_DIR" diff --quiet HEAD -- build.sh || DIRTY=" (build.sh differs from it)"
{
    echo "# LibDovi build record"
    echo ""
    echo "Written by build.sh after packaging."
    echo ""
    echo "Built      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Repo HEAD  $(git -C "$SCRIPT_DIR" rev-parse HEAD)$DIRTY"
    echo "build.sh   sha256 $(shasum -a 256 "$SCRIPT_DIR/build.sh" | cut -d' ' -f1)"
    echo ""
    echo "## Host and toolchain"
    echo "macOS      $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
    echo "Xcode      $(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')"
    echo "clang      $(xcrun clang --version | sed -n 1p)"
    for sdk in iphoneos iphonesimulator appletvos appletvsimulator xros xrsimulator macosx; do
        echo "SDK        $sdk $(xcrun --sdk "$sdk" --show-sdk-version) ($(xcrun --sdk "$sdk" --show-sdk-build-version))"
    done
    echo "rustup     $(rustup show active-toolchain | sed -n 1p)"
    rustc -vV | sed 's/^/rustc      /'
    echo "cargo      $(cargo --version)"
    echo "cargo-c    $(cargo cbuild --version)"
    echo ""
    echo "## Source"
    echo "dovi_tool  $DOVI_TAG $(git -C "$DOVI_REPO_DIR" rev-parse HEAD)"
    echo "crate      dolby_vision, cargo cbuild --release --locked --features capi"
    echo "Cargo.lock sha256 $(shasum -a 256 "$CRATE_DIR/Cargo.lock" | cut -d' ' -f1) (copy: BUILD-INFO.Cargo.lock)"
    echo ""
    echo "## Resolved dependencies (aarch64-apple-tvos; the lock is shared by every slice)"
    ( cd "$CRATE_DIR" && cargo tree --locked --features capi --target aarch64-apple-tvos -e normal,build ) \
        | sed "s#$DOVI_REPO_DIR#<dovi_tool>#"
    echo ""
    echo "## Shipped files (sha256)"
    ( cd "$SCRIPT_DIR" && find Dovi.xcframework -type f \( -name 'libdovi.a' -o -name 'dovi.h' \) | sort | while read -r f; do
        echo "$(shasum -a 256 "$f" | cut -d' ' -f1)  $f"
    done )
} > "$INFO_OUT"
echo "==> Build record written to BUILD-INFO.txt"

echo ""
echo "==> Done. XCFramework at: $XCFW_OUT"
ls "$XCFW_OUT"
for a in "$XCFW_OUT"/*/libdovi.a; do echo "  $a:"; lipo -info "$a" 2>/dev/null | sed 's/^/    /'; done