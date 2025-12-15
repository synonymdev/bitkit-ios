# Paykit Integration for Bitkit iOS

This module integrates the Paykit payment coordination protocol with Bitkit iOS.

## Overview

Paykit enables Bitkit to execute payments through a standardized protocol that supports:
- Lightning Network payments
- On-chain Bitcoin transactions
- Payment discovery and routing
- Receipt generation and proof verification

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       Bitkit iOS App                         │
├─────────────────────────────────────────────────────────────┤
│  PaykitPaymentService                                        │
│  - High-level payment API                                    │
│  - Payment type detection                                    │
│  - Receipt management                                        │
├─────────────────────────────────────────────────────────────┤
│  PaykitManager                                               │
│  - Client lifecycle management                               │
│  - Executor registration                                     │
│  - Network configuration                                     │
├─────────────────────────────────────────────────────────────┤
│  Executors                                                   │
│  ├── BitkitBitcoinExecutor (onchain payments)               │
│  └── BitkitLightningExecutor (Lightning payments)           │
├─────────────────────────────────────────────────────────────┤
│  LightningService / CoreService (Bitkit)                    │
└─────────────────────────────────────────────────────────────┘
```

## Setup

### Prerequisites

1. PaykitMobile UniFFI bindings must be generated and linked
2. Bitkit wallet must be initialized
3. Lightning node must be running

### Initialization

```swift
// During app startup, after wallet is ready
do {
    try PaykitIntegrationHelper.setup()
} catch {
    Logger.error("Paykit setup failed: \(error)")
}
```

### Making Payments

```swift
// Using the high-level service
let service = PaykitPaymentService.shared

// Lightning payment
let result = try await service.pay(to: "lnbc10u1p0...", amountSats: nil)

// On-chain payment
let result = try await service.pay(to: "bc1q...", amountSats: 50000, feeRate: 10.0)

// Check result
if result.success {
    print("Payment succeeded: \(result.receipt.id)")
} else {
    print("Payment failed: \(result.error?.userMessage ?? "Unknown error")")
}
```

## File Structure

```
Bitkit/PaykitIntegration/
├── PaykitManager.swift           # Client lifecycle management
├── PaykitIntegrationHelper.swift # Convenience setup methods
├── Executors/
│   ├── BitkitBitcoinExecutor.swift   # On-chain payment execution
│   └── BitkitLightningExecutor.swift # Lightning payment execution
├── Services/
│   └── PaykitPaymentService.swift    # High-level payment API
└── README.md                     # This file
```

## Configuration

### Network Configuration

Network is automatically mapped from `Env.network`:

| Bitkit Network | Paykit Bitcoin | Paykit Lightning |
|----------------|----------------|------------------|
| `.bitcoin`     | `.mainnet`     | `.mainnet`       |
| `.testnet`     | `.testnet`     | `.testnet`       |
| `.regtest`     | `.regtest`     | `.regtest`       |
| `.signet`      | `.testnet`     | `.testnet`       |

### Timeout Configuration

```swift
// Default: 60 seconds
PaykitPaymentService.shared.paymentTimeout = 120.0
```

### Receipt Storage

```swift
// Disable automatic receipt storage
PaykitPaymentService.shared.autoStoreReceipts = false
```

## Error Handling

All errors are mapped to user-friendly messages:

```swift
do {
    let result = try await service.pay(to: recipient, amountSats: amount)
} catch let error as PaykitPaymentError {
    // Show user-friendly message
    showAlert(error.userMessage)
}
```

| Error | User Message |
|-------|--------------|
| `.notInitialized` | "Please wait for the app to initialize" |
| `.invalidRecipient` | "Please check the payment address or invoice" |
| `.amountRequired` | "Please enter an amount" |
| `.insufficientFunds` | "You don't have enough funds for this payment" |
| `.paymentFailed` | "Payment could not be completed. Please try again." |
| `.timeout` | "Payment is taking longer than expected" |

## Testing

Run unit tests:
```bash
xcodebuild test -scheme Bitkit -destination 'platform=iOS Simulator,name=iPhone 15'
```

Test files:
- `BitkitTests/PaykitIntegration/PaykitManagerTests.swift`
- `BitkitTests/PaykitIntegration/BitkitBitcoinExecutorTests.swift`
- `BitkitTests/PaykitIntegration/BitkitLightningExecutorTests.swift`
- `BitkitTests/PaykitIntegration/PaykitPaymentServiceTests.swift`

## Production Checklist

- [ ] Generate PaykitMobile bindings for release targets
- [ ] Link `libpaykit_mobile.a` in Xcode project
- [ ] Configure Library Search Paths
- [ ] Uncomment FFI binding code (search for `// TODO: Uncomment`)
- [ ] Test on testnet before mainnet
- [ ] Configure error monitoring (Sentry/Crashlytics)
- [ ] Enable feature flag for gradual rollout

## Rollback Plan

If issues arise in production:

1. **Immediate**: Disable Paykit feature flag
2. **App Update**: Revert to previous version without Paykit
3. **Data**: Receipt data is stored locally and independent of Paykit

## Troubleshooting

### "PaykitManager has not been initialized"
Ensure `PaykitIntegrationHelper.setup()` is called during app startup.

### "Payment timed out"
- Check network connectivity
- Verify Lightning node is synced
- Increase `paymentTimeout` if needed

### "Payment failed"
- Check wallet balance
- Verify recipient address/invoice is valid
- Check Lightning channel capacity

## API Reference

See inline documentation in source files for detailed API reference.
