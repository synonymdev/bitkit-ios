# Paykit Production Configuration Guide

This document outlines the configuration required before releasing Paykit features to production.

## Pre-Release Configuration Checklist

### 1. Pubky Homeserver Configuration

**Location:** `Bitkit/PaykitIntegration/Services/DirectoryService.swift`

**Current Setting:**
```swift
private let pubkyHomeserver = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
```

**Verification:**
- [ ] Confirm this is the production homeserver pubkey
- [ ] Test directory queries against production homeserver
- [ ] Verify homeserver is accessible and stable

**Environment-Specific Configuration:**
- Development: Can use staging homeserver via environment variable
- Production: Must use production homeserver

### 2. Relay Server Configuration

**Location:** `Bitkit/PaykitIntegration/Services/PubkyRingBridge.swift`

**Current Setting:**
```swift
public static var sessionRelayUrl: String {
    if let envUrl = ProcessInfo.processInfo.environment["PUBKY_RELAY_URL"] {
        return envUrl
    }
    return "https://relay.pubky.app/sessions"
}
```

**Verification:**
- [ ] Confirm `https://relay.pubky.app/sessions` is production relay
- [ ] Test cross-device authentication with production relay
- [ ] Verify relay server is accessible and stable

### 3. Cross-Device Authentication URL

**Location:** `Bitkit/PaykitIntegration/Services/PubkyRingBridge.swift`

**Current Setting:**
```swift
public static var crossDeviceWebUrl: String {
    if let envUrl = ProcessInfo.processInfo.environment["PUBKY_CROSS_DEVICE_URL"] {
        return envUrl
    }
    return "https://pubky.app/auth"
}
```

**Verification:**
- [ ] Confirm `https://pubky.app/auth` is production URL
- [ ] Test QR code generation and sharing
- [ ] Verify web page loads correctly

### 4. Network Configuration

**Location:** `Bitkit/Constants/Env.swift`

**Verification:**
- [ ] Network is set to `.bitcoin` for mainnet (currently `.regtest`)
- [ ] Electrum server URLs are production endpoints
- [ ] Esplora server URLs are production endpoints
- [ ] RGS (Rapid Gossip Sync) URLs are production endpoints

### 5. Background Task Registration

**Location:** `Bitkit/AppDelegate_integration.swift` or `BitkitApp.swift`

**Verification:**
- [ ] `SubscriptionBackgroundService.registerBackgroundTask()` is called
- [ ] `PaykitPollingService.registerBackgroundTask()` is called
- [ ] Background task identifiers are registered in `Info.plist`:
  - `to.bitkit.subscriptions.check`
  - `to.bitkit.paykit.polling`

### 6. URL Scheme Configuration

**Location:** `Bitkit/Info.plist`

**Verification:**
- [ ] `bitkit://` scheme is registered
- [ ] `paykit:` scheme is registered
- [ ] `pip:` scheme is registered
- [ ] Deep link handlers are implemented

### 7. Feature Flags

**Verification:**
- [ ] Paykit features are enabled for production
- [ ] Debug logging is disabled
- [ ] Test data is removed
- [ ] Mock services are replaced with real implementations

### 8. Security Configuration

**Verification:**
- [ ] Keychain access groups are configured correctly
- [ ] Sensitive data is stored in Keychain (not UserDefaults)
- [ ] Session secrets are handled securely
- [ ] Preimages are not logged

### 9. Error Monitoring

**Verification:**
- [ ] Crash reporting is configured (Sentry/Crashlytics)
- [ ] Paykit errors are logged appropriately
- [ ] User-facing error messages are clear and actionable

### 10. Performance

**Verification:**
- [ ] Background tasks complete within time budget
- [ ] Directory queries don't block UI
- [ ] Payment execution is responsive
- [ ] Storage operations are efficient

## Environment Variables

For development/testing, these environment variables can override defaults:

- `PUBKY_RELAY_URL` - Override relay server URL
- `PUBKY_CROSS_DEVICE_URL` - Override cross-device auth URL
- `PUBKY_HOMESERVER` - Override homeserver pubkey (not currently used)

## Testing Checklist

Before releasing to production:

- [ ] Test on physical device (not just simulator)
- [ ] Test with real funds (small amounts)
- [ ] Test cross-device authentication
- [ ] Test background task execution
- [ ] Test network failure scenarios
- [ ] Test session expiration and refresh
- [ ] Test Pubky-ring not installed scenario

## Rollback Plan

If issues arise in production:

1. **Immediate**: Disable Paykit features via feature flag (if implemented)
2. **Short-term**: Push app update disabling Paykit
3. **Data**: Receipt and subscription data is stored locally and will persist

## Related Documentation

- [Setup Guide](PAYKIT_SETUP.md)
- [Architecture Overview](PAYKIT_ARCHITECTURE.md)
- [Release Checklist](PAYKIT_RELEASE_CHECKLIST.md)

