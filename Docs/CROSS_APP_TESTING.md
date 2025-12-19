# Cross-App Testing with Pubky-ring

This guide covers end-to-end testing of Bitkit's Paykit integration with the real Pubky-ring app.

## Overview

Cross-app testing verifies the complete integration between Bitkit and Pubky-ring, including:
- Session delegation and authentication
- Noise key derivation for interactive payments
- Profile and contact synchronization
- Backup/restore operations

## Prerequisites

### Development Environment

1. **macOS**: Ventura 14.0+ or Sonoma 15.0+
2. **Xcode**: 15.0+
3. **iOS Simulator**: iOS 17.0+
4. **Node.js**: 18+ (for Pubky-ring React Native app)
5. **Ruby**: 3.0+ (for CocoaPods)

### Source Repositories

Clone these repositories into the same parent directory:

```bash
# Parent directory structure
vibes/
├── bitkit-ios/
├── pubky-ring/
└── pubky-core-main/  # Optional: for local homeserver
```

### Network Requirements

- Local homeserver OR access to dev/staging Pubky homeserver
- Internet access for Electrum/Esplora backend (unless using local)

## Setup Instructions

### Step 1: Build Pubky-ring

```bash
cd pubky-ring

# Install dependencies
yarn install

# Install iOS pods
cd ios && pod install && cd ..

# Build for iOS Simulator
npx react-native run-ios --simulator="iPhone 15"
```

**Alternative: Build with Xcode**
1. Open `pubky-ring/ios/pubkyring.xcworkspace`
2. Select "iPhone 15" simulator
3. Build and run (Cmd+R)

### Step 2: Build Bitkit

```bash
cd bitkit-ios

# Build via Xcode
open Bitkit.xcodeproj
# Select "Bitkit" scheme
# Select same simulator as Pubky-ring
# Build and run (Cmd+R)
```

### Step 3: Configure Homeserver

Both apps must use the same homeserver. Options:

**Option A: Local Homeserver (Recommended for Testing)**
```bash
cd pubky-core-main

# Build and run homeserver
cargo run -p pubky-homeserver -- --port 8080

# Homeserver URL: http://localhost:8080
```

**Option B: Development Homeserver**
```
URL: https://dev.homeserver.pubky.org
```

**Configure in Bitkit:**
```swift
// In Env.swift, set:
static let pubkyHomeserverUrl = "http://localhost:8080"
```

**Configure in Pubky-ring:**
```typescript
// In src/utils/config.ts, set:
export const HOMESERVER_URL = "http://localhost:8080";
```

## Test Scenarios

### Scenario 1: Session Authentication Flow

**Purpose**: Verify Bitkit can request and receive a delegated session from Pubky-ring.

**Steps:**

1. **In Bitkit:**
   - Navigate to Settings → Paykit → Sessions
   - Tap "Connect Pubky-ring"
   
2. **Automatic Handoff:**
   - Bitkit should launch Pubky-ring via URL scheme
   - URL format: `pubkyring://auth?callback=bitkit://paykit-session&scope=read,write`

3. **In Pubky-ring:**
   - Approve the session request
   - Grant requested capabilities (read, write)
   - Tap "Authorize"

4. **Return to Bitkit:**
   - Pubky-ring calls back: `bitkit://paykit-session?pubky=...&session_secret=...`
   - Verify session appears in Sessions list
   - Check session details (capabilities, expiry)

**Expected Results:**
- Session is stored securely in Keychain
- Session appears in UI with correct capabilities
- Subsequent Paykit operations use the session

**Verification Code:**
```swift
// In PaykitE2ETests.swift
func testSessionFlow_WithRealPubkyRing() throws {
    // Navigate and request
    WalletTestHelper.navigateToSessionManagement(app: app)
    app.buttons["Connect Pubky-ring"].tap()
    
    // Wait for Pubky-ring to launch
    let pubkyRing = XCUIApplication(bundleIdentifier: "to.pubky.ring")
    XCTAssertTrue(pubkyRing.wait(for: .runningForeground, timeout: 10))
    
    // Authorize in Pubky-ring
    pubkyRing.buttons["Authorize"].tap()
    
    // Wait for callback
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    
    // Verify session
    XCTAssertTrue(WalletTestHelper.hasActiveSession(app: app))
}
```

### Scenario 2: Noise Key Derivation

**Purpose**: Verify Bitkit can request Noise keypairs for interactive payments.

**Prerequisites**: Active session from Scenario 1

**Steps:**

1. **In Bitkit:**
   - Navigate to Settings → Paykit → Direct Pay
   - Select a recipient with interactive payment support
   - Tap "Pay via Direct Channel"

2. **Key Request:**
   - Bitkit requests keypair: `pubkyring://noise-keypair?device_id=...&epoch=...`
   - Pubky-ring derives keypair from master seed

3. **In Pubky-ring:**
   - Approve keypair derivation
   - Return derived keypair to Bitkit

4. **Payment Execution:**
   - Bitkit establishes Noise channel
   - Payment completes

**Expected Results:**
- Keypair cached for device/epoch
- Subsequent requests for same device/epoch use cache
- Payment succeeds with interactive handshake

### Scenario 3: Profile Synchronization

**Purpose**: Verify profile data synchronizes between apps.

**Prerequisites**: Active session

**Steps:**

1. **In Pubky-ring:**
   - Set profile name to "Test User"
   - Set bio to "Testing cross-app sync"
   - Save profile

2. **In Bitkit:**
   - Navigate to Settings → Paykit → Profile
   - Tap "Sync Profile"

3. **Verify:**
   - Profile name matches "Test User"
   - Bio matches "Testing cross-app sync"
   - Avatar displays correctly

**Verification:**
```swift
func testProfileSync_FromPubkyRing() throws {
    // Setup profile in Pubky-ring first
    // ... (manual or scripted)
    
    WalletTestHelper.navigateToPaykit(app: app)
    app.buttons["Profile"].tap()
    app.buttons["Sync Profile"].tap()
    
    // Wait for sync
    Thread.sleep(forTimeInterval: 5)
    
    let nameLabel = app.staticTexts["ProfileName"]
    XCTAssertTrue(nameLabel.waitForExistence(timeout: 10))
    XCTAssertEqual(nameLabel.label, "Test User")
}
```

### Scenario 4: Contact Discovery via Follows

**Purpose**: Verify Bitkit can import contacts from Pubky-ring follows.

**Prerequisites**: Active session, follows configured in Pubky-ring

**Steps:**

1. **In Pubky-ring:**
   - Follow several users (friends, contacts)
   - Ensure they have payment endpoints published

2. **In Bitkit:**
   - Navigate to Settings → Paykit → Contacts
   - Tap "Sync from Pubky-ring"

3. **Verify:**
   - Contacts appear with names from follows
   - Payment methods are detected
   - Contacts are usable for payments

**Expected Results:**
- Contacts sync from follows list
- Payment-enabled contacts show payment options
- Contacts persist after app restart

### Scenario 5: Cross-Device QR Authentication

**Purpose**: Verify session can be established via QR code when Pubky-ring is on a different device.

**Steps:**

1. **In Bitkit (Device A):**
   - Navigate to Settings → Paykit → Sessions
   - Tap "Connect Pubky-ring"
   - Select "Use QR Code"

2. **Display QR:**
   - Bitkit displays QR code containing auth URL
   - QR encodes: `pubkyring://auth?callback=https://relay.bitkit.to/callback/...`

3. **In Pubky-ring (Device B):**
   - Open QR scanner
   - Scan the QR code from Device A
   - Approve session

4. **Session Callback:**
   - Pubky-ring sends session to relay
   - Bitkit polls relay or receives push
   - Session established

**Expected Results:**
- QR code displays correctly
- Cross-device handshake completes
- Session works same as direct integration

### Scenario 6: Backup and Restore

**Purpose**: Verify session backup/restore between devices.

**Steps:**

1. **Export (Device A):**
   - Navigate to Settings → Paykit → Backup
   - Tap "Export Sessions"
   - Save encrypted backup file

2. **Import (Device B):**
   - Fresh Bitkit installation
   - Navigate to Settings → Paykit → Backup
   - Tap "Import Sessions"
   - Select backup file

3. **Verify:**
   - Sessions restored correctly
   - Sessions are functional
   - Paykit operations work

**Expected Results:**
- Backup file is encrypted
- Import prompts for decryption
- All sessions restore correctly

## Automated Test Execution

### Running Cross-App Tests

```bash
# Ensure both apps are installed on simulator
# Run cross-app test suite
xcodebuild test \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
  -only-testing:BitkitUITests/PaykitE2ETests
```

### Test Configuration

Tests automatically detect Pubky-ring installation:

```swift
// In PubkyRingTestHelper.swift
static func isPubkyRingInstalled() -> Bool {
    let pubkyRing = XCUIApplication(bundleIdentifier: "to.pubky.ring")
    return pubkyRing.exists
}
```

Tests gracefully degrade when Pubky-ring is not installed.

## Troubleshooting

### Common Issues

#### 1. URL Scheme Not Registered

**Symptom**: Bitkit cannot launch Pubky-ring

**Solution**: Verify `pubkyring://` scheme is registered in Pubky-ring's `Info.plist`:
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>pubkyring</string>
        </array>
    </dict>
</array>
```

#### 2. Callback Not Received

**Symptom**: Bitkit doesn't receive session after Pubky-ring approval

**Solution**: 
1. Verify `bitkit://` scheme is registered in Bitkit's `Info.plist`
2. Check callback URL is correctly formatted
3. Verify app is returning to foreground

#### 3. Homeserver Connection Failed

**Symptom**: Session works but profile/follows don't sync

**Solution**:
1. Verify both apps use same homeserver URL
2. Check homeserver is running and accessible
3. Test with curl: `curl http://localhost:8080/health`

#### 4. Simulator Network Issues

**Symptom**: Apps cannot communicate or reach homeserver

**Solution**:
1. Reset simulator network: Hardware → Reset Network
2. Ensure simulator has internet access
3. Use `http://localhost` not `http://127.0.0.1`

### Debug Logging

**Enable in Bitkit:**
```swift
// Add to test setUp
ProcessInfo.processInfo.environment["PAYKIT_DEBUG"] = "1"
```

**Enable in Pubky-ring:**
```typescript
// In app initialization
if (__DEV__) {
  console.log("Debug mode enabled");
}
```

### Capturing Test Evidence

```swift
// Screenshot on test step
XCTContext.runActivity(named: "Session Approval") { activity in
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.lifetime = .keepAlways
    activity.add(attachment)
}
```

## CI/CD Integration

### GitHub Actions Workflow

```yaml
name: Cross-App E2E Tests

on:
  push:
    branches: [main]
  pull_request:

jobs:
  cross-app-tests:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          path: bitkit-ios
          
      - uses: actions/checkout@v4
        with:
          repository: synonymdev/pubky-ring
          path: pubky-ring
          
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '18'
          
      - name: Install Pubky-ring Dependencies
        run: |
          cd pubky-ring
          yarn install
          cd ios && pod install
          
      - name: Build Pubky-ring for Simulator
        run: |
          xcodebuild build \
            -workspace pubky-ring/ios/pubkyring.xcworkspace \
            -scheme pubkyring \
            -sdk iphonesimulator \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0'
            
      - name: Install Pubky-ring on Simulator
        run: |
          xcrun simctl install booted pubky-ring/ios/build/Debug-iphonesimulator/pubkyring.app
          
      - name: Build and Test Bitkit
        run: |
          cd bitkit-ios
          xcodebuild test \
            -project Bitkit.xcodeproj \
            -scheme Bitkit \
            -sdk iphonesimulator \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
            -only-testing:BitkitUITests/PaykitE2ETests \
            -resultBundlePath TestResults.xcresult
            
      - name: Upload Test Results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: cross-app-test-results
          path: bitkit-ios/TestResults.xcresult
```

## Test Metrics

### Success Criteria

| Metric | Target |
|--------|--------|
| Session establishment | < 5 seconds |
| Key derivation | < 500ms (cached: < 10ms) |
| Profile sync | < 3 seconds |
| Contact discovery | < 10 seconds for 50 contacts |
| Backup export | < 2 seconds |
| Backup import | < 2 seconds |

### Coverage Goals

| Area | Tests | Status |
|------|-------|--------|
| Session Management | 4 | ✅ Complete |
| Key Derivation | 2 | ✅ Complete |
| Profile/Contacts | 2 | ✅ Complete |
| Backup/Restore | 2 | ✅ Complete |
| Cross-Device | 2 | ✅ Complete |
| Payment Flows | 2 | ✅ Complete |

## Related Documentation

- [Paykit Setup Guide](PAYKIT_SETUP.md)
- [Paykit Architecture](PAYKIT_ARCHITECTURE.md)
- [UI Tests README](../BitkitUITests/README.md)
- [Release Checklist](PAYKIT_RELEASE_CHECKLIST.md)

