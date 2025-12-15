# Paykit Integration Guide for iOS

This document outlines the integration steps for Paykit Phase 4 features in Bitkit iOS.

## Overview

Phase 4 adds smart checkout flow and payment profiles to Bitkit. The backend infrastructure (bitkit-core) has been implemented, and this guide covers the iOS UI integration.

## Changes Made

### 1. Payment Profile UI
- **File**: `Bitkit/Views/Settings/PaymentProfileView.swift`
- **Navigation**: Added `Route.paymentProfile` to `NavigationViewModel.swift`
- **Integration**: Linked from `GeneralSettingsView.swift`

**Features**:
- QR code display for Pubky URI
- Toggle switches for enabling/disabling payment methods (onchain, lightning)
- Real-time updates to published endpoints

### 2. Smart Checkout Flow

**Backend** (bitkit-core):
- Added `paykit_smart_checkout()` FFI function
- Returns `PaykitCheckoutResult` with method, endpoint, and privacy flags
- Automatically prefers private channels over public directory

**Scanner Integration**:
- Added `PubkyPayment` variant to `Scanner` enum in `bitkit-core`
- Scanner detects `pubky://` and `pubky:` URIs
- Pubky IDs are z-base-32 encoded public keys

## Integration Steps

### Step 1: Handle PubkyPayment in Scanner

Add handling for the new `PubkyPayment` scanner type in `AppViewModel.swift`:

```swift
// In handleScannedData(_ uri: String) async throws
case let .pubkyPayment(data: pubkyPayment):
    Logger.debug("Pubky Payment: \(pubkyPayment)")
    await handlePubkyPayment(pubkyPayment.pubkey)
```

### Step 2: Implement Smart Checkout Handler

Add new method to `AppViewModel.swift`:

```swift
private func handlePubkyPayment(_ pubkey: String) async {
    do {
        // Call smart checkout to get best available payment method
        let result = try await paykitSmartCheckout(
            pubkey: pubkey,
            preferredMethod: nil  // or "lightning"/"onchain" based on user preference
        )
        
        // Check if it's a private channel (requires interactive protocol)
        if result.requiresInteractive {
            // TODO: Implement interactive payment flow
            // This requires the full PaykitInteractive integration
            toast(
                type: .info,
                title: "Private Payment",
                description: "Interactive payment flow not yet implemented"
            )
            return
        }
        
        // Public directory payment - treat as regular invoice
        if result.methodId == "lightning" {
            // Decode lightning invoice
            if case let .lightning(invoice) = try await decode(invoice: result.endpoint) {
                handleScannedLightningInvoice(invoice, bolt11: result.endpoint)
            }
        } else if result.methodId == "onchain" {
            // Decode bitcoin address
            if case let .onChain(invoice) = try await decode(invoice: "bitcoin:\(result.endpoint)") {
                handleScannedOnchainInvoice(invoice)
            }
        }
        
    } catch {
        Logger.error(error, context: "Failed to handle Pubky payment")
        toast(
            type: .error,
            title: "Payment Error",
            description: "Could not fetch payment methods for this contact"
        )
    }
}
```

### Step 3: Connect Payment Profile UI to bitkit-core

Update `PaymentProfileView.swift` to call the actual FFI functions:

```swift
// In loadPaymentProfile()
do {
    // Get user's public key from wallet
    guard let userPublicKey = wallet.pubkyId else {
        return
    }
    
    pubkyUri = "pubky://\(userPublicKey)"
    
    // Check which methods are currently enabled
    let methods = try await paykitGetSupportedMethodsForKey(pubkey: userPublicKey)
    
    enableOnchain = methods.methods.contains { $0.methodId == "onchain" }
    enableLightning = methods.methods.contains { $0.methodId == "lightning" }
    
} catch {
    app.toast(error)
}
```

```swift
// In updatePaymentMethod()
do {
    if enabled {
        let endpoint = method == "onchain" ? wallet.onchainAddress : wallet.bolt11
        
        try await paykitSetEndpoint(methodId: method, endpoint: endpoint)
        
        app.toast(
            type: .success,
            title: "Payment method enabled",
            description: "\(method.capitalized) is now publicly available"
        )
    } else {
        try await paykitRemoveEndpoint(methodId: method)
        
        app.toast(
            type: .success,
            title: "Payment method disabled",
            description: "\(method.capitalized) removed from public profile"
        )
    }
} catch {
    // Revert toggle on error
    if method == "onchain" {
        enableOnchain = !enabled
    } else {
        enableLightning = !enabled
    }
    app.toast(error)
}
```

### Step 4: Initialize Paykit Session

Ensure Paykit is initialized when the app starts. In your app initialization code:

```swift
// During wallet setup/unlock
Task {
    do {
        let secretKeyHex = // Get from wallet's key management
        let homeserverPubkey = // Get from user's homeserver config
        
        try await paykitInitialize(
            secretKeyHex: secretKeyHex,
            homeserverPubkey: homeserverPubkey
        )
    } catch {
        Logger.error(error, context: "Failed to initialize Paykit")
    }
}
```

### Step 5: Add Rotation Monitoring (Optional)

Add periodic checks for endpoint rotation:

```swift
// Call this periodically (e.g., on app foreground)
Task {
    do {
        guard let userPublicKey = wallet.pubkyId else { return }
        
        let methodsToRotate = try await paykitCheckRotationNeeded(pubkey: userPublicKey)
        
        if !methodsToRotate.isEmpty {
            // Show user notification that they should rotate their endpoints
            app.toast(
                type: .warning,
                title: "Rotate Payment Endpoints",
                description: "Some payment methods have been used and should be rotated for privacy"
            )
        }
    } catch {
        Logger.error(error, context: "Failed to check rotation")
    }
}
```

## Testing

1. **Payment Profile**:
   - Open Settings → General → Payment Profile
   - Toggle on "On-chain Bitcoin"
   - Verify QR code displays your Pubky URI
   - Have another user scan the QR code and verify they see your payment endpoint

2. **Smart Checkout**:
   - Generate a Pubky URI for a test contact with published endpoints
   - Scan the QR code
   - Verify it navigates to the send flow with the correct payment method pre-filled

3. **Privacy**:
   - Verify that private channels are preferred over public directory
   - Verify that endpoints rotate after receiving payments

## Future Enhancements

1. **Interactive Payments**: Full integration of PaykitInteractive for private receipt-based payments
2. **Receipts History**: UI to display payment receipts with metadata
3. **Contact Management**: Store frequently used Pubky contacts for quick payments
4. **Rotation Automation**: Automatically rotate endpoints after use

## References

- Paykit Roadmap: `paykit-rs-master/PAYKIT_ROADMAP.md`
- Phase 3 Report: `paykit-rs-master/FINAL_DELIVERY_REPORT.md`
- Noise Integration Review: `NOISE_INTEGRATION_REVIEW.md`

