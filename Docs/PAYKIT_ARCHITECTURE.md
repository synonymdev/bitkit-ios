# Paykit Architecture

This document describes the architecture of the Paykit integration in Bitkit iOS.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    UI Layer (SwiftUI)                       │
│  PaykitDashboardView, PaymentRequestsView, ContactsView     │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  ViewModels                                  │
│  NoisePaymentViewModel, AutoPayViewModel, etc.              │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Services Layer                              │
│  PaykitPaymentService, DirectoryService, SpendingLimitMgr   │
│  SubscriptionBackgroundService, PaykitPollingService        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Storage Layer                               │
│  PaykitKeychainStorage, ContactStorage, ReceiptStore        │
│  SubscriptionStorage, AutoPayStorage                        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Integration Layer                           │
│  PaykitManager, PaykitIntegrationHelper, PubkyRingBridge    │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  External Dependencies                       │
│  PaykitMobile.xcframework, LDKNode, Pubky Directory         │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### PaykitManager

The central coordinator for Paykit functionality.

**Responsibilities:**
- Initialize Paykit with wallet credentials
- Manage session state with Pubky-ring
- Coordinate between services
- Handle lifecycle events

**Key Properties:**
```swift
public class PaykitManager {
    static let shared = PaykitManager()
    
    var client: PaykitMobileClient?
    var isReady: Bool
    var sessionState: SessionState
}
```

### PaykitPaymentService

High-level payment execution service.

**Responsibilities:**
- Detect payment types (Lightning, onchain, Paykit)
- Execute payments with appropriate method
- Enforce spending limits
- Generate and store receipts

**Payment Flow:**
```
1. Receive payment request
2. Detect payment type
3. Check spending limits (if peer pubkey provided)
4. Reserve spending amount (atomic operation)
5. Execute payment via LDK or Paykit
6. Commit or rollback spending
7. Store receipt
8. Return result
```

### DirectoryService

Handles Pubky directory operations.

**Responsibilities:**
- Discover payment methods for recipients
- Publish payment endpoints
- Import profiles from Pubky-app
- Manage follows/contacts

**Directory Schema:**

The Pubky directory uses a hierarchical structure for storing Paykit-related data:

```
/pub/paykit.app/v0/
  ├── endpoints/{pubkey}/              # Payment endpoints
  │   └── {methodId}.json            # Endpoint configuration (Lightning, onchain, etc.)
  ├── subscriptions/
  │   ├── requests/{recipientPubkey}/ # Payment requests
  │   │   └── {requestId}.json      # Request metadata (amount, memo, expiry)
  │   └── proposals/{recipientPubkey}/ # Subscription proposals
  │       └── {proposalId}.json      # Proposal metadata (amount, frequency, etc.)
  └── profiles/{pubkey}/              # User profiles
      └── profile.json               # Profile data (name, bio, avatar URL)
```

**Directory Path Conventions:**
- All paths use z-base32 encoded pubkeys
- JSON files contain UTF-8 encoded metadata
- Files are versioned and can be updated atomically
- Directory listings return file names, not contents (for privacy)
- Authentication required for write operations
- Read operations are public (unauthenticated)

**Example Request File Structure:**
```json
{
  "requestId": "abc123...",
  "fromPubkey": "ybndrfg8...",
  "toPubkey": "ybndrfg8...",
  "amountSats": 10000,
  "memo": "Payment for services",
  "methodId": "lightning",
  "createdAt": 1234567890,
  "expiresAt": 1234567890
}
```

### SpendingLimitManager

Thread-safe spending limit enforcement.

**Responsibilities:**
- Reserve spending amounts atomically
- Commit successful payments
- Rollback failed payments
- Track per-peer limits

**Atomic Operation Pattern:**
```swift
try await spendingLimitManager.executeWithSpendingLimit(
    peerPubkey: pubkey,
    amountSats: amount
) {
    // Payment execution
    return paymentResult
}
```

### PubkyRingBridge

Handles communication with Pubky-ring app.

**Responsibilities:**
- Request sessions via URL scheme
- Handle session callbacks
- Generate QR codes for cross-device auth
- Poll for cross-device session responses

**Authentication Methods:**
1. Same-device (URL scheme)
2. Cross-device QR code
3. Manual session entry

## Background Services

### SubscriptionBackgroundService

Processes subscription payments in background.

**Trigger:** `BGProcessingTask` (iOS BGTaskScheduler)
**Interval:** Every 15 minutes (minimum iOS allows)

**Flow:**
1. Check for due subscriptions
2. Wait for node ready
3. Evaluate auto-pay rules
4. Execute approved payments
5. Send notifications

### PaykitPollingService

Polls Pubky directory for updates.

**Trigger:** `BGProcessingTask`
**Interval:** Every 15 minutes

**Checks:**
- New payment requests
- New subscription proposals
- Profile updates

## Storage Architecture

### PaykitKeychainStorage

Secure storage using iOS Keychain.

**Stored Data:**
- Receipts
- Contacts
- Subscriptions
- Auto-pay settings
- Spending limits

### Data Models

```swift
// Receipt
struct PaykitReceipt {
    let id: String
    let type: PaykitReceiptType
    let recipient: String
    let amountSats: UInt64
    let feeSats: UInt64
    let paymentHash: String?
    let preimage: String?
    let timestamp: Date
    var status: PaykitReceiptStatus
}

// Subscription
struct BitkitSubscription {
    let id: String
    var providerPubkey: String
    var amountSats: UInt64
    var frequency: String
    var isActive: Bool
    var nextPaymentAt: Date?
}

// Auto-Pay Rule
struct AutoPayRule {
    let id: String
    let name: String
    let peerPubkey: String?
    var maxAmountSats: UInt64?
    var enabled: Bool
}
```

## Data Flow

### Payment Request Flow

```
User                    Bitkit                    Pubky Directory
  │                        │                              │
  ├─── Create Request ────▶│                              │
  │                        ├──── Publish Request ────────▶│
  │                        │                              │
  │                        │◀──── Request Published ──────┤
  │◀── Show QR/Share ──────┤                              │
```

### Payment Execution Flow

```
Payer                   Bitkit                    Recipient
  │                        │                              │
  ├─── Scan/Enter ────────▶│                              │
  │                        ├──── Discover Methods ───────▶│
  │                        │◀────── Methods List ─────────┤
  │                        │                              │
  │                        ├──── Reserve Spending ────────│
  │                        │                              │
  │                        ├──── Execute Payment ────────▶│
  │                        │◀──── Payment Preimage ───────┤
  │                        │                              │
  │                        ├──── Commit Spending ─────────│
  │                        │                              │
  │◀── Payment Success ────┤                              │
```

## Error Handling

### Error Types

```swift
enum PaykitPaymentError {
    case notInitialized
    case invalidRecipient(String)
    case amountRequired
    case insufficientFunds
    case paymentFailed(String)
    case timeout
    case spendingLimitExceeded(Int64)
}
```

### Recovery Strategies

1. **Not Initialized:** Wait for node ready, retry
2. **Invalid Recipient:** Validate format, show user feedback
3. **Spending Limit:** Request manual approval
4. **Payment Failed:** Log error, offer retry
5. **Timeout:** Retry with backoff

## Threading Model

- **UI:** Main thread (SwiftUI)
- **Payment Execution:** Background queues
- **Storage:** Serial queue per storage type
- **FFI Calls:** Dedicated background queue

## Security Considerations

1. **Session Management:** Sessions expire and require refresh
2. **Spending Limits:** Atomic operations prevent race conditions
3. **Keychain Storage:** Sensitive data encrypted at rest
4. **Preimage Handling:** Preimages are stored securely for proof-of-payment

## Extension Points

### Adding New Payment Types

1. Add case to `DetectedPaymentType`
2. Implement detection in `detectPaymentType()`
3. Add execution method in `PaykitPaymentService`
4. Update UI to support new type

### Adding New Auto-Pay Rules

1. Add rule type to `AutoPayRule`
2. Update `AutoPayEvaluator.evaluate()`
3. Add UI for rule configuration

## Related Documentation

- [Setup Guide](PAYKIT_SETUP.md)
- [Testing Guide](PAYKIT_TESTING.md)
- [Release Checklist](PAYKIT_RELEASE_CHECKLIST.md)

