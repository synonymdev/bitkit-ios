# Bitkit UI Tests

End-to-end tests for Paykit integration with Pubky-ring.

## Test Structure

### Test Files

- **`PaykitE2ETests.swift`** - Comprehensive E2E tests for all Paykit features
  - Session management flows
  - Noise key derivation
  - Profile and contacts
  - Backup and restore
  - Cross-app integration

### Test Helpers

- **`Helpers/PubkyRingTestHelper.swift`** - Simulates Pubky-ring app interactions
  - Test session/keypair creation
  - Callback simulation
  - App detection utilities
  - Test data factory

- **`Helpers/WalletTestHelper.swift`** - Wallet operation helpers
  - Navigation to Paykit features
  - Wallet state verification
  - Session and contact verification
  - Payment flow helpers
  - UI assertion utilities

- **`Helpers/XCUIElementExtensions.swift`** - XCUIElement utilities
  - Wait for non-existence
  - Conditional tap helpers
  - Wait and tap combos

## Running Tests

### Via Xcode

1. Open `Bitkit.xcodeproj`
2. Select Bitkit scheme
3. Choose a simulator (iPhone 15, iOS 17.0+)
4. Press `Cmd+U` to run all tests
5. Or use Test Navigator (Cmd+6) to run specific tests

### Via Command Line

```bash
# Run all UI tests
xcodebuild test \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0'

# Run specific test class
xcodebuild test \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
  -only-testing:BitkitUITests/PaykitE2ETests

# Run specific test method
xcodebuild test \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
  -only-testing:BitkitUITests/PaykitE2ETests/testSessionFlow_RequestAndReceive
```

## Test Coverage

| Feature | Test Count | Status |
|---------|-----------|--------|
| Session Management | 4 | ✅ Complete |
| Noise Key Derivation | 2 | ✅ Complete |
| Profile & Contacts | 2 | ✅ Complete |
| Backup & Restore | 2 | ✅ Complete |
| Cross-App Integration | 3 | ✅ Complete |
| **Total** | **13 tests** | ✅ Complete |

## Test Scenarios

### Session Management

1. **Request and Receive** - Full session request flow
   - Tests Pubky-ring integration
   - Verifies callback handling
   - Checks session persistence

2. **Persistence** - Session restoration after app restart
   - Terminates and relaunches app
   - Verifies session restored from keychain

3. **Expiration Handling** - Session expiration warnings
   - Checks for expiration warnings
   - Verifies refresh button availability

4. **Graceful Degradation** - Behavior when Pubky-ring not installed
   - Tests fallback UI (QR code option)
   - Verifies install prompts

### Noise Key Derivation

1. **Derivation Flow** - Key derivation via Pubky-ring
   - Tests keypair request flow
   - Verifies cache integration

2. **Cache Hit/Miss** - Cache behavior
   - Verifies cache effectiveness
   - Tests cache status indicators

### Profile & Contacts

1. **Profile Fetching** - Profile data retrieval
   - Tests profile request from Pubky-ring
   - Verifies fallback to Pubky SDK
   - Checks directory lookup

2. **Follows Sync** - Contact synchronization
   - Tests follows list retrieval
   - Verifies contact import
   - Checks sync completion

### Backup & Restore

1. **Export** - Session/key backup
   - Verifies export UI
   - Tests backup file creation

2. **Import** - Session/key restoration
   - Verifies import UI
   - Tests backup file validation

### Cross-App Integration

1. **Cross-Device Auth** - QR code authentication
   - Tests QR code generation
   - Verifies link sharing

2. **Payment Flow** - End-to-end payment
   - Tests Paykit payment option
   - Verifies payment completion

3. **Contact Discovery** - Directory-based discovery
   - Tests contact discovery
   - Verifies results display

## Test Prerequisites

### Required Setup

1. **Simulator Configuration**
   - iOS 17.0 or later
   - iPhone 15 or similar device
   - Sufficient storage for app + test data

2. **Wallet Setup**
   - Tests assume wallet is initialized
   - Some tests require active Lightning node
   - Background tasks should be enabled in simulator

3. **Network Access**
   - Tests may make real network calls
   - Consider using test backend for reproducibility

### Optional Setup

1. **Pubky-ring App**
   - Install Pubky-ring on simulator for full integration tests
   - Tests gracefully degrade if not installed

2. **Test Data**
   - Use consistent test pubkey: `z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK`
   - Test device IDs and sessions are generated automatically

## Test Configuration

### Launch Arguments

Tests use `--uitesting` launch argument for test-specific behavior:

```swift
app.launchArguments.append("--uitesting")
```

### Test Data

Test helpers provide factory methods for consistent data:

```swift
// Generate unique test pubkey
let pubkey = TestDataFactory.generatePubkey()

// Generate test device ID
let deviceId = TestDataFactory.generateDeviceId()

// Generate test session secret
let sessionSecret = TestDataFactory.generateSessionSecret()

// Generate hex keypair
let (secretKey, publicKey) = TestDataFactory.generateHexKeypair()
```

## Debugging Tests

### Common Issues

1. **Test Timeout**
   - Increase timeout values if network is slow
   - Check simulator performance settings

2. **Element Not Found**
   - Verify UI implementation matches test expectations
   - Check for accessibility identifiers

3. **Callback Not Received**
   - Ensure URL scheme registered correctly
   - Check deep link handling in app

### Debug Tips

```swift
// Take screenshot on failure
XCTContext.runActivity(named: "Screenshot") { activity in
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    activity.add(attachment)
}

// Add breakpoint in test
// Set breakpoint and use LLDB:
po app.debugDescription

// Print element hierarchy
po app.descendants(matching: .any).allElementsBoundByIndex
```

## CI/CD Integration

### GitHub Actions Example

```yaml
- name: Run UI Tests
  run: |
    xcodebuild test \
      -project Bitkit.xcodeproj \
      -scheme Bitkit \
      -sdk iphonesimulator \
      -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
      -resultBundlePath TestResults.xcresult
      
- name: Upload Test Results
  uses: actions/upload-artifact@v3
  if: always()
  with:
    name: test-results
    path: TestResults.xcresult
```

## Maintenance

### Adding New Tests

1. Add test method to `PaykitE2ETests`
2. Use test helpers for common operations
3. Follow existing naming conventions
4. Add documentation to this README

### Updating Test Helpers

1. Modify helper files in `Helpers/`
2. Ensure backward compatibility
3. Update documentation if API changes

## Related Documentation

- [Paykit Setup Guide](../Docs/PAYKIT_SETUP.md)
- [Paykit Testing Guide](../Docs/PAYKIT_TESTING.md)
- [Architecture Overview](../Docs/PAYKIT_ARCHITECTURE.md)

