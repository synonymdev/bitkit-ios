# Bitkit iOS - Paykit Integration Build Configuration

This guide explains how to configure the Bitkit iOS Xcode project to integrate PaykitMobile.

## Current Status: ✅ INTEGRATED

The XCFrameworks have been automatically added to the Xcode project using the `add_paykit_frameworks.py` script.

## Prerequisites

- Xcode 14.0 or later
- PaykitMobile XCFramework (pre-built and included)
- PubkyNoise XCFramework (pre-built and included)
- Swift bindings (pre-generated and included)

## Automated Setup (Already Done)

The following steps have been automated:

1. ✅ XCFrameworks copied to `Bitkit/PaykitIntegration/Frameworks/`
2. ✅ Swift bindings copied to `Bitkit/PaykitIntegration/FFI/`
3. ✅ `project.pbxproj` updated with framework references
4. ✅ Embed Frameworks build phase added

## Manual Steps (If Rebuilding)

### Step 1: Build XCFrameworks

```bash
cd paykit-rs-master/paykit-mobile
./build-ios.sh
```

### Step 2: Copy Files

```bash
# Copy XCFrameworks
cp -r PaykitMobile.xcframework bitkit-ios/Bitkit/PaykitIntegration/Frameworks/
cp -r PubkyNoise.xcframework bitkit-ios/Bitkit/PaykitIntegration/Frameworks/

# Copy Swift bindings
cp swift/generated/PaykitMobile.swift bitkit-ios/Bitkit/PaykitIntegration/FFI/
cp swift/generated/PaykitMobileFFI.h bitkit-ios/Bitkit/PaykitIntegration/FFI/
cp swift/generated/PaykitMobileFFI.modulemap bitkit-ios/Bitkit/PaykitIntegration/FFI/
```

### Step 3: Run Automation Script

```bash
cd bitkit-ios
python3 add_paykit_frameworks.py
```

## Known Issues

### Pre-existing (Not Paykit-related)

1. **secp256k1 Package Missing**: SPM package dependency issue
2. **PipUniFFI Module**: Separate dependency from Bitkit base

These issues must be resolved in the base Bitkit project.

## Troubleshooting

### iCloud Path Timeouts

When building from iCloud Drive, xcodebuild may timeout. Solution:

```bash
# Copy to local path
cp -r bitkit-ios ~/bitkit-ios-local
cd ~/bitkit-ios-local
xcodebuild -project Bitkit.xcodeproj -scheme Bitkit build
```

### Framework Not Found

Verify paths in `project.pbxproj`:
- Path should be: `Bitkit/PaykitIntegration/Frameworks/PaykitMobile.xcframework`
- sourceTree should be: `SOURCE_ROOT`

### Module Not Found

Check that FFI files are in the correct location:
- `Bitkit/PaykitIntegration/FFI/PaykitMobile.swift`
- `Bitkit/PaykitIntegration/FFI/PaykitMobileFFI.h`
- `Bitkit/PaykitIntegration/FFI/PaykitMobileFFI.modulemap`

## Verification Checklist

- [x] PaykitMobile.xcframework added to project
- [x] PubkyNoise.xcframework added to project
- [x] Swift bindings added and compile
- [x] Build settings configured (via automation)
- [ ] Pre-existing secp256k1 issue resolved
- [ ] Pre-existing PipUniFFI issue resolved
- [ ] Project builds successfully
- [ ] PaykitManager initializes without errors
- [ ] All tests pass
