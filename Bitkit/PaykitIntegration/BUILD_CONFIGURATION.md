# Bitkit iOS - Paykit Integration Build Configuration

This guide explains how to configure the Bitkit iOS Xcode project to integrate PaykitMobile.

## Prerequisites

- Xcode 14.0 or later
- PaykitMobile XCFramework built (see `paykit-rs-master/paykit-mobile/BUILD.md`)
- Swift bindings generated

## Step 1: Add XCFramework to Project

1. Build the XCFramework:
   ```bash
   cd paykit-rs-master/paykit-mobile
   ./build-ios.sh
   ```

2. Locate the generated XCFramework:
   - `paykit-rs-master/paykit-mobile/PaykitMobile.xcframework/`

3. In Xcode, select the Bitkit project
4. Go to target "Bitkit" → General → "Frameworks, Libraries, and Embedded Content"
5. Click "+" and add `PaykitMobile.xcframework`
6. Set "Embed & Sign"

## Step 2: Add Swift Bindings

1. Locate generated Swift files:
   - `paykit-rs-master/paykit-mobile/swift/generated/PaykitMobile.swift`
   - `paykit-rs-master/paykit-mobile/swift/generated/PaykitMobileFFI.h`
   - `paykit-rs-master/paykit-mobile/swift/generated/PaykitMobileFFI.modulemap`

2. Add to Xcode project:
   - Right-click Bitkit project → Add Files
   - Select the three files above
   - Ensure "Copy items if needed" is checked
   - Add to Bitkit target

## Step 3: Configure Build Settings

1. Select Bitkit target → Build Settings
2. Search for "Framework Search Paths"
3. Add: `$(PROJECT_DIR)/PaykitIntegration/Frameworks`
4. Search for "Library Search Paths"
5. Add: `$(PROJECT_DIR)/PaykitIntegration/Frameworks`

## Step 4: Verify Integration

1. Build the project (⌘+B)
2. Verify no compilation errors
3. Run tests to confirm PaykitManager initializes

## Troubleshooting

### Framework Not Found
- Ensure XCFramework is added to "Frameworks, Libraries, and Embedded Content"
- Check Framework Search Paths include XCFramework location

### Module Not Found
- Verify modulemap is in the correct location
- Check that Swift bindings are added to the target

### Link Errors
- Ensure XCFramework is set to "Embed & Sign"
- Clean build folder (⌘+Shift+K) and rebuild

## Verification Checklist

- [ ] XCFramework added to project
- [ ] Swift bindings added and compile
- [ ] Build settings configured
- [ ] Project builds successfully
- [ ] PaykitManager initializes without errors
- [ ] Tests pass
