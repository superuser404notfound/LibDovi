# LibDovi

[libdovi](https://github.com/quietvoid/dovi_tool) (the C API of the `dolby_vision` Rust crate, the reference Dolby Vision RPU library behind `dovi_tool`) cross-compiled for Apple platforms and packaged as a SwiftPM binary target.

Used by [AetherEngine](https://github.com/superuser404notfound/AetherEngine) to convert Dolby Vision Profile 7 RPUs to single-layer Profile 8.1 live (`dovi_convert_rpu_with_mode(rpu, 2)`), so the player engages real Dolby Vision on dual-layer UHD-BD remuxes instead of plain HDR10.

## Consuming

```swift
.package(url: "https://github.com/superuser404notfound/LibDovi", from: "2.1.0"),
// then add the product:
.product(name: "Dovi", package: "LibDovi"),
```

`import Dovi` exposes the libdovi C API (`dovi_parse_unspec62_nalu`, `dovi_convert_rpu_with_mode`, `dovi_write_unspec62_nalu`, the free functions, etc.).

## Additions to the upstream C API

`patches/` holds additions to the C API, applied by `build.sh` on top of the pinned dovi_tool tag. They only add entry points; nothing upstream is changed or removed.

- `dovi_rpu_set_polynomial_mapping(rpu, component, pivots, num_pivots, coefs)` replaces one component's reshaping curve with a piecewise second-order polynomial: 2 to 9 absolute pivots, and `c0, c1, c2` per piece in the normalised domain (`out = c0 + c1*x + c2*x^2`, input and output in [0, 1]). It accepts only profile 8 RPUs with fixed-point coefficients, splits each coefficient into its integer and `coefficient_log2_denom` fraction parts, and marks the RPU modified so the CRC is rewritten on the next write.

## Slices

`Dovi.xcframework` ships seven slices:

- `macos-arm64_x86_64` (fat: Apple Silicon + Intel Macs)
- `ios-arm64` (device)
- `ios-arm64_x86_64-simulator` (fat: Apple Silicon + Intel Macs)
- `tvos-arm64` (device)
- `tvos-arm64-simulator` (Apple Silicon only)
- `xros-arm64` (device)
- `xros-arm64-simulator` (Apple Silicon only)

Minimum deployment tvOS 17.0 / iOS 16.0 / visionOS 1.0. The tvOS and visionOS simulators stay arm64-only: there is no Intel Vision Pro, and `x86_64-apple-tvos` is a low-tier Rust target with no prebuilt std (would need nightly + `-Z build-std`) whose Intel-Mac tvOS-simulator use is not worth that cost. Everything is built with stable Rust.

## Rebuilding

`./build.sh` cross-compiles libdovi (`dolby_vision` 3.4.0, `capi` feature) via `cargo-c` for each slice and assembles the XCFramework. Requires Rust stable (the tvOS and visionOS targets are tier-2 with prebuilt std) and `cargo-c`:

```sh
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim \
    aarch64-apple-ios aarch64-apple-ios-sim \
    aarch64-apple-visionos aarch64-apple-visionos-sim \
    x86_64-apple-ios x86_64-apple-darwin
cargo install cargo-c
./build.sh
```

The prebuilt `Dovi.xcframework` is committed (mirroring FFmpegBuild), so consumers do not need a Rust toolchain.

## Build record

The library is built on a local Mac, not in CI, so there is no attestation. `./build.sh` writes [`BUILD-INFO.txt`](BUILD-INFO.txt) instead: the dovi_tool tag and commit, Xcode, clang, SDK, rustc, cargo and cargo-c versions, the resolved dependency tree, and the SHA-256 of every shipped `libdovi.a` and header. The build runs with `--locked` against the `Cargo.lock` the crate ships at its tag, and a copy of that lock is committed as [`BUILD-INFO.Cargo.lock`](BUILD-INFO.Cargo.lock).

The first record was written by a rebuild of 2.1.0 with this toolchain, and every `libdovi.a` it produced is byte-identical to the one committed for 2.1.0, so it describes those binaries as well. Earlier releases have no record.

## License

libdovi is dual-licensed MIT / Apache-2.0 (see the upstream dovi_tool repository) and is consumed here under the MIT option. The packaging in this repo (build script, SwiftPM stubs) is MIT, see [LICENSE](LICENSE). No additional restrictions.
