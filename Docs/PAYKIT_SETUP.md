# Paykit Setup Guide

This guide covers setting up Paykit integration for Bitkit iOS.

## Prerequisites

1. **Xcode 15+** installed
2. **iOS 16+** deployment target
3. **Pubky-ring app** installed on test device (optional but recommended)
4. **Regtest environment** for development testing

## Installation

### 1. Framework Setup

The Paykit integration uses `PaykitMobile.xcframework` which is included in the project. The framework provides:

- Payment execution (Lightning and onchain)
- Directory services for payment method discovery
- Spending limit management
- Auto-pay functionality

### 2. Entitlements

Ensure the following entitlements are configured in `Bitkit.entitlements`:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:bitkit.to</string>
</array>
```

### 3. URL Schemes

The app registers these URL schemes in `Info.plist`:

- `bitkit://` - Main app scheme
- `paykit:` - Paykit payment URIs
- `pip:` - Payment initiation protocol URIs

### 4. Background Tasks

Register the background task identifier in `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>to.bitkit.subscriptions.check</string>
    <string>to.bitkit.paykit.polling</string>
</array>
```

## Configuration

### Pubky Homeserver

The default Pubky homeserver is configured in `DirectoryService.swift`:

```swift
private let pubkyHomeserver = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
```

For development, you can use a local homeserver by setting the environment variable:
```
PUBKY_HOMESERVER_URL=localhost:8080
```

### Electrum/Esplora

Configure the backend URLs in `Env.swift`:

- `ELECTRUM_URL` - Electrum server URL
- `RGS_URL` - Rapid Gossip Sync URL

## Pubky-Ring Integration

### Installing Pubky-Ring

1. Download Pubky-ring from the App Store or TestFlight
2. Install on the same device as Bitkit
3. Launch Pubky-ring and complete initial setup

### Cross-Device Authentication

If Pubky-ring is on a different device:

1. Open Bitkit → Paykit Settings → Connect Pubky-ring
2. Select "QR Code" option
3. Scan the QR code with the device running Pubky-ring
4. Approve the session request in Pubky-ring

### Manual Session Entry

For development or fallback:

1. Open Bitkit → Paykit Settings → Connect Pubky-ring
2. Select "Manual Entry" option
3. Enter the pubkey and session secret from Pubky-ring

## Troubleshooting

### Common Issues

**Issue: "Paykit not initialized"**
- Ensure the wallet has been created and Lightning node is running
- Check that `PaykitIntegrationHelper.setupAsync()` completes successfully

**Issue: "Session expired"**
- Re-authenticate with Pubky-ring
- Sessions have limited validity and must be refreshed

**Issue: "Directory query failed"**
- Check network connectivity
- Verify Pubky homeserver is reachable
- Ensure session is valid

**Issue: "Payment failed"**
- Check Lightning channel capacity
- Verify recipient payment method is valid
- Check spending limits are not exceeded

### Debug Logging

Enable verbose logging by setting the `DEBUG` environment variable:

```swift
// In Xcode scheme, add environment variable:
DEBUG=1
```

Logs are tagged with context:
- `PaykitManager` - Core manager operations
- `PaykitPaymentService` - Payment execution
- `DirectoryService` - Directory queries
- `SpendingLimitManager` - Spending limit operations

## Development Workflow

### Running E2E Tests

1. Set `E2E_BUILD=true` in scheme environment
2. Configure local Electrum backend: `ELECTRUM_URL=localhost:50001`
3. Run BitkitUITests scheme

### Testing Without Pubky-Ring

The app supports simulated sessions for development:

```swift
// In test code:
PubkyRingBridge.shared.handleCallback(url: URL(string: "bitkit://paykit-session?pubkey=...")!)
```

## Next Steps

- [Architecture Overview](PAYKIT_ARCHITECTURE.md)
- [Testing Guide](PAYKIT_TESTING.md)
- [Release Checklist](PAYKIT_RELEASE_CHECKLIST.md)

