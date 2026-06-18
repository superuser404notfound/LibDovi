# LibDovi

[libdovi](https://github.com/quietvoid/dovi_tool) (the C API of the `dolby_vision` Rust crate, the reference Dolby Vision RPU library behind `dovi_tool`) cross-compiled for Apple platforms and packaged as a SwiftPM binary target.

Used by [AetherEngine](https://github.com/superuser404notfound/AetherEngine) to convert Dolby Vision Profile 7 RPUs to single-layer Profile 8.1 live (`dovi_convert_rpu_with_mode(rpu, 2)`), so the Apple TV engages real Dolby Vision on dual-layer UHD-BD remuxes instead of plain HDR10.

## Consuming

```swift
.package(url: "https://github.com/superuser404notfound/LibDovi", from: "1.0.0"),
// then add the product:
.product(name: "Dovi", package: "LibDovi"),
```

`import Dovi` exposes the libdovi C API (`dovi_parse_unspec62_nalu`, `dovi_convert_rpu_with_mode`, `dovi_write_unspec62_nalu`, the free functions, etc.).

## Slices

`Dovi.xcframework` ships three slices: `macos-arm64`, `tvos-arm64`, `tvos-arm64-simulator`. Minimum tvOS 17.0. (x86_64 tvOS simulator is omitted: it needs nightly Rust + `-Z build-std`, and all Apple TV hardware plus the Xcode default simulator are arm64.)

## Rebuilding

`./build.sh` cross-compiles libdovi (`dolby_vision` 3.3.2, `capi` feature) via `cargo-c` for each slice and assembles the XCFramework. Requires Rust stable (the tvOS targets are tier-2 with prebuilt std) and `cargo-c`:

```sh
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim
cargo install cargo-c
./build.sh
```

The prebuilt `Dovi.xcframework` is committed (mirroring FFmpegBuild), so consumers do not need a Rust toolchain.

## License

libdovi is dual-licensed MIT / Apache-2.0 (see the upstream dovi_tool repository). This packaging carries no additional restrictions.
