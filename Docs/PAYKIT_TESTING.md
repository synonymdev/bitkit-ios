# Paykit Testing Guide

This guide covers testing strategies and procedures for Paykit integration.

## Test Categories

### 1. Unit Tests

Located in `BitkitTests/PaykitIntegration/`

**Run All Unit Tests:**
```bash
xcodebuild test -scheme Bitkit -destination 'platform=iOS Simulator,name=iPhone 15'
```

**Run Specific Test File:**
```bash
xcodebuild test -scheme Bitkit -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:BitkitTests/ContactStorageTests
```

**Test Files:**
- `ContactStorageTests.swift` - Contact persistence
- `DirectoryServiceTests.swift` - Directory operations
- `PaykitPaymentServiceTests.swift` - Payment execution
- `SpendingLimitManagerTests.swift` - Spending limits
- `AutoPayStorageTests.swift` - Auto-pay rules
- `PubkyRingBridgeTests.swift` - Pubky-ring integration

### 2. Integration Tests

Integration tests verify components work together correctly.

**Test Scenarios:**
- Payment flow from UI to LDK
- Directory discovery and publication
- Subscription payment execution
- Auto-pay evaluation and execution

### 3. E2E Tests

Located in `BitkitUITests/PaykitE2ETests.swift`

**Run E2E Tests:**
```bash
xcodebuild test -scheme BitkitUITests -destination 'platform=iOS Simulator,name=iPhone 15'
```

**Requirements:**
- E2E_BUILD environment variable set to "true"
- Local Electrum server running (localhost:50001)
- Optional: Pubky-ring app installed for cross-app tests

## Test Environment Setup

### 1. Local Electrum/Esplora

```bash
# Start local regtest node
bitcoind -regtest -daemon

# Start Electrum server
electrs --network regtest
```

### 2. Pubky Directory (Development)

```bash
# Start local Pubky homeserver
pubky-homeserver --port 8080
```

### 3. Test Wallet

The E2E test suite automatically creates a test wallet if needed. For manual testing:

1. Launch app with `--e2e` argument
2. Create new wallet
3. Fund with regtest coins

## E2E Test Cases

### Session Management

| Test | Description | Requires Pubky-ring |
|------|-------------|---------------------|
| `testSessionRequestFromPubkyRing` | Request session from Pubky-ring | Optional |
| `testPubkyRingNotInstalledGracefulDegradation` | Verify fallback options | No |
| `testSessionExpirationAndRefresh` | Session lifecycle | Yes |
| `testCrossDeviceQRAuthentication` | QR code auth flow | No |
| `testManualSessionEntry` | Manual session fallback | No |

### Payment Flows

| Test | Description |
|------|-------------|
| `testCreatePaymentRequest` | Create and verify payment request |
| `testPayPaymentRequest` | Execute payment to request |
| `testSpendingLimitEnforcement` | Verify limits are enforced |

### Subscriptions

| Test | Description |
|------|-------------|
| `testCreateSubscription` | Create recurring subscription |
| `testAutoPayExecution` | Verify auto-pay processes payment |

### Contacts

| Test | Description |
|------|-------------|
| `testContactDiscovery` | Discover contacts from directory |
| `testProfileImport` | Import profile from Pubky |

## Manual Testing Checklist

### Payment Request Flow

- [ ] Create payment request with amount
- [ ] Generate QR code
- [ ] Share request link
- [ ] Verify request appears in list
- [ ] Pay the request from another wallet
- [ ] Verify payment receipt created

### Subscription Flow

- [ ] Create subscription
- [ ] Verify next payment date calculated
- [ ] Wait for background task (or trigger manually)
- [ ] Verify auto-pay processes (if enabled)
- [ ] Check notification received

### Cross-Device Auth

- [ ] Select QR code option
- [ ] Verify QR code displayed
- [ ] Scan with Pubky-ring on another device
- [ ] Approve session in Pubky-ring
- [ ] Verify session active in Bitkit

### Spending Limits

- [ ] Set daily spending limit
- [ ] Attempt payment below limit → Success
- [ ] Attempt payment above limit → Blocked
- [ ] Verify remaining limit displayed

## Debugging Tests

### Enable Verbose Logging

```swift
// In test setUp()
Logger.setLevel(.debug)
```

### Inspect Test State

```swift
// Print current state during test
print("Current subscriptions: \(subscriptionStorage.listSubscriptions())")
```

### Capture Screenshots

```swift
// In XCUITest
let screenshot = app.screenshot()
let attachment = XCTAttachment(screenshot: screenshot)
attachment.name = "PaymentSuccess"
attachment.lifetime = .keepAlways
add(attachment)
```

## Test Data

### Test Pubkeys

```swift
let testPubkey = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
```

### Test Invoices (Regtest)

```swift
let testInvoice = "lnbcrt10u1..."
```

### Test Addresses (Regtest)

```swift
let testAddress = "bcrt1q..."
```

## Continuous Integration

### GitHub Actions Workflow

```yaml
name: Paykit Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.0.app
      - name: Run Unit Tests
        run: |
          xcodebuild test \
            -scheme Bitkit \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -only-testing:BitkitTests
```

## Known Limitations

1. **E2E Cross-App Tests:** Require Pubky-ring to be installed and may need manual interaction
2. **Background Task Tests:** Cannot be fully automated due to iOS scheduling
3. **Real Payment Tests:** Require funded regtest wallet

## Reporting Issues

When reporting test failures:

1. Include full test log
2. Note device/simulator model and iOS version
3. Specify if Pubky-ring was installed
4. Include any relevant screenshots

## Related Documentation

- [Setup Guide](PAYKIT_SETUP.md)
- [Architecture Overview](PAYKIT_ARCHITECTURE.md)
- [Release Checklist](PAYKIT_RELEASE_CHECKLIST.md)

