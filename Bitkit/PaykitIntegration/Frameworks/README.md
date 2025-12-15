# Paykit Integration Frameworks

This directory contains pre-built XCFrameworks for Paykit and Pubky-Noise integration.

## Current Approach (Interim)

Libraries are currently copied from source builds:
- `PaykitMobile.xcframework` - from `paykit-rs-master/paykit-mobile`
- `PubkyNoise.xcframework` - from `pubky-noise-main`

## Future: Swift Package Manager

Once these libraries are production-ready, they should be published as SPM packages following the pattern used for `bitkit-core`:

```swift
// Package.swift or Xcode project
.package(url: "https://github.com/BitcoinErrorLog/paykit-rs", branch: "main")
```

This will eliminate the need for copied binaries and ensure automatic updates.

## Rebuilding Libraries

If you need to rebuild the libraries:

```bash
# PaykitMobile
cd paykit-rs-master/paykit-mobile
./build-ios.sh --framework

# PubkyNoise  
cd pubky-noise-main
./build-ios.sh
```

Then copy the generated XCFrameworks to this directory.

