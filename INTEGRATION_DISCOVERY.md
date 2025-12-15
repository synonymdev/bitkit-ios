# Paykit Integration Discovery - iOS

This document outlines the integration points for connecting Paykit-rs with Bitkit iOS.

## Repository Structure

### Key Services

#### LightningService
- **Location**: `Bitkit/Services/LightningService.swift`
- **Type**: Singleton (`LightningService.shared`)
- **Purpose**: Manages LDKNode Lightning Network operations
- **Dependencies**: `LDKNode`, `BitkitCore`

**Key Methods for Paykit Integration**:

1. **Lightning Payment**:
   ```swift
   func send(bolt11: String, sats: UInt64? = nil, params: SendingParameters? = nil) async throws -> PaymentHash
   ```
   - **Location**: Line 368
   - **Returns**: `PaymentHash` (from LDKNode)
   - **Usage**: Pay Lightning invoices
   - **Error Handling**: Throws `AppError`

2. **Onchain Payment**:
   ```swift
   func send(
       address: String,
       sats: UInt64,
       satsPerVbyte: UInt32,
       utxosToSpend: [SpendableUtxo]? = nil,
       isMaxAmount: Bool = false
   ) async throws -> Txid
   ```
   - **Location**: Line 330
   - **Returns**: `Txid` (from LDKNode)
   - **Usage**: Send Bitcoin on-chain
   - **Error Handling**: Throws `AppError`

3. **Payment Access**:
   ```swift
   var payments: [PaymentDetails]? { node?.listPayments() }
   ```
   - **Location**: Line 548 (extension)
   - **Returns**: Array of payment details
   - **Usage**: Get payment status and preimage

4. **Payment Events**:
   ```swift
   func listenForEvents(onEvent: ((Event) -> Void)? = nil)
   ```
   - **Location**: Line 554
   - **Event Types**: `.paymentSuccessful(paymentId, paymentHash, paymentPreimage, feePaidMsat)`
   - **Usage**: Listen for payment completion

#### CoreService
- **Location**: `Bitkit/Services/CoreService.swift`
- **Type**: Singleton (`CoreService.shared`)
- **Purpose**: Manages onchain wallet operations and activity tracking
- **Dependencies**: `BitkitCore`

**Key Methods for Paykit Integration**:

1. **Transaction Lookup**:
   - Use `ActivityService` (nested in CoreService) to lookup transactions
   - Access via `CoreService.shared.activityService`

2. **Fee Estimation**:
   - Use `CoreService.shared.blocktank.getFees()` for fee rates
   - Returns `FeeRates` object with different speed options

## API Mappings for Paykit Executors

### BitcoinExecutorFFI Implementation

#### sendToAddress
- **Bitkit API**: `LightningService.shared.send(address:sats:satsPerVbyte:utxosToSpend:isMaxAmount:)`
- **Async Pattern**: `async throws -> Txid`
- **Bridging**: Use `Task` with `withCheckedThrowingContinuation`
- **Return Mapping**: 
  - `Txid` → Extract `.hex` for `BitcoinTxResultFfi.txid`
  - Need to query transaction for fee, vout, confirmations

#### estimateFee
- **Bitkit API**: `CoreService.shared.blocktank.getFees()`
- **Return**: Fee in satoshis for target blocks
- **Mapping**: Convert `TransactionSpeed` to target blocks

#### getTransaction
- **Bitkit API**: Use `CoreService` or `ActivityService` to lookup transaction
- **Query**: By `txid` (String)
- **Return**: `BitcoinTxResultFfi` or `nil`

#### verifyTransaction
- **Bitkit API**: Get transaction via `getTransaction`, verify outputs
- **Return**: Boolean

### LightningExecutorFFI Implementation

#### payInvoice
- **Bitkit API**: `LightningService.shared.send(bolt11:sats:params:)`
- **Async Pattern**: `async throws -> PaymentHash`
- **Bridging**: Use `Task` with `withCheckedThrowingContinuation`
- **Payment Completion**: 
  - Option 1: Listen to `Event.paymentSuccessful` (includes preimage)
  - Option 2: Poll `LightningService.shared.payments` array
- **Return Mapping**: 
  - `PaymentHash` → `LightningPaymentResultFfi.paymentHash`
  - Extract preimage from event or payment details

#### decodeInvoice
- **Bitkit API**: `BitkitCore.decode(invoice: String)` → `LightningInvoice`
- **Mapping**:
  - `LightningInvoice.paymentHash` → `DecodedInvoiceFfi.paymentHash`
  - `LightningInvoice.amountMsat` → `DecodedInvoiceFfi.amountMsat`
  - `LightningInvoice.description` → `DecodedInvoiceFfi.description`
  - `LightningInvoice.payeePubkey` → `DecodedInvoiceFfi.payee`
  - `LightningInvoice.expiry` → `DecodedInvoiceFfi.expiry`
  - `LightningInvoice.timestamp` → `DecodedInvoiceFfi.timestamp`

#### estimateFee
- **Bitkit API**: `CoreService.shared.blocktank.getFees()` for routing fees
- **Return**: Fee in millisatoshis

#### getPayment
- **Bitkit API**: `LightningService.shared.payments` → `[PaymentDetails]?`
- **Find by**: `paymentHash` (compare hex strings)
- **Extract**: `PaymentDetails.preimage`, `amountMsat`, `feePaidMsat`, `status`

#### verifyPreimage
- **Implementation**: Compute SHA256 of preimage, compare with payment hash
- **Library**: CryptoKit or CommonCrypto

## Error Types

### AppError
- **Location**: Defined in Bitkit error handling
- **Structure**: 
  ```swift
  struct AppError: Error {
      let message: String?
      let debugMessage: String?
      let serviceError: ServiceError?
  }
  ```
- **Mapping to PaykitMobileError**:
  - `ServiceError.nodeNotSetup` → `PaykitMobileError.Internal`
  - `ServiceError.nodeNotStarted` → `PaykitMobileError.Internal`
  - General errors → `PaykitMobileError.Transport`

## Network Configuration

### Current Network Setup
- **Location**: `Bitkit/Constants/Env.swift`
- **Property**: `Env.network: LDKNode.Network`
- **Values**: `.bitcoin`, `.testnet`, `.regtest`, `.signet`
- **Mapping to Paykit**:
  - `.bitcoin` → `BitcoinNetworkFfi.mainnet` / `LightningNetworkFfi.mainnet`
  - `.testnet` → `BitcoinNetworkFfi.testnet` / `LightningNetworkFfi.testnet`
  - `.regtest` → `BitcoinNetworkFfi.regtest` / `LightningNetworkFfi.regtest`
  - `.signet` → `BitcoinNetworkFfi.testnet` / `LightningNetworkFfi.testnet` (fallback)

## Async/Sync Patterns

### Current Pattern
- **Bitkit Services**: All use `async/await` (Swift concurrency)
- **Paykit FFI**: Synchronous methods
- **Bridging Strategy**: Use `Task` with `withCheckedThrowingContinuation`

### Example Bridge Pattern
```swift
func syncMethod() throws -> Result {
    return try withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let result = try await asyncMethod()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

## Thread Safety

- **LightningService**: Singleton, accessed via `.shared`
- **CoreService**: Singleton, accessed via `.shared`
- **FFI Methods**: May be called from any thread
- **Strategy**: `withCheckedThrowingContinuation` handles thread safety

## Payment Completion Handling

### Event-Based Approach (Recommended)
```swift
// Set up event listener before payment
var paymentPreimage: String?
let semaphore = DispatchSemaphore(value: 0)

LightningService.shared.listenForEvents { event in
    if case .paymentSuccessful(_, let hash, let preimage, _) = event,
       hash == paymentHash {
        paymentPreimage = preimage
        semaphore.signal()
    }
}

// Start payment
let paymentHash = try await LightningService.shared.send(bolt11: invoice)

// Wait for completion
if semaphore.wait(timeout: .now() + 60) == .timedOut {
    throw PaykitMobileError.NetworkTimeout(message: "Payment timeout")
}
```

### Polling Approach (Alternative)
```swift
let paymentHash = try await LightningService.shared.send(bolt11: invoice)

var attempts = 0
while attempts < 60 {
    if let payments = LightningService.shared.payments,
       let payment = payments.first(where: { $0.paymentHash == paymentHash }),
       let preimage = payment.preimage {
        break
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    attempts += 1
}
```

## Transaction Details Extraction

### Challenge
- `LightningService.send()` returns only `Txid`
- `BitcoinTxResultFfi` needs: fee, vout, confirmations, blockHeight

### Solution
1. Return initial result with `confirmations: 0`, `blockHeight: nil`
2. Query transaction details after broadcast:
   ```swift
   let txid = try await LightningService.shared.send(...)
   try await Task.sleep(nanoseconds: 2_000_000_000) // Wait for propagation
   let txDetails = try await CoreService.shared.getTransaction(txid: txid)
   // Extract fee, vout, confirmations
   ```

## File Structure for Integration

### Proposed Structure
```
Bitkit/
└── PaykitIntegration/
    ├── PaykitManager.swift
    ├── PaykitIntegrationHelper.swift
    ├── Executors/
    │   ├── BitkitBitcoinExecutor.swift
    │   └── BitkitLightningExecutor.swift
    └── Services/
        └── PaykitPaymentService.swift
```

## Dependencies

### Current Dependencies
- `LDKNode`: Lightning Network node implementation
- `BitkitCore`: Core wallet functionality
- `Foundation`: Standard library

### New Dependencies
- `PaykitMobile`: Generated UniFFI bindings (to be added)

## Next Steps

1. ✅ Discovery complete (this document)
2. ⏳ Set up Paykit-rs dependency
3. ⏳ Generate UniFFI bindings
4. ⏳ Configure Xcode build settings
5. ⏳ Implement executors
6. ⏳ Register executors with PaykitClient
7. ⏳ Integration testing
