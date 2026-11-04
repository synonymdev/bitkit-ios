import BitkitCore
import Observation

struct RetainedHardwareOnchainPayment {
    let signedTx: HwFundingSignedTx
    let hasAttemptedBroadcast: Bool
    var isRefusedForNavigation: Bool = false
}

/// What an ordinary hardware send must do about the wallet's retained send before any device contact.
enum HwRetainedSendStatus: Equatable {
    case none
    /// The same payment may go out again, using these original bytes and no device prompt.
    case retry(HwFundingSignedTx)
    /// A different payment, or a retry that was refused. Signing needs the user to abandon the retained send first.
    case blocking

    var retrySignedTx: HwFundingSignedTx? {
        guard case let .retry(signedTx) = self else { return nil }
        return signedTx
    }
}

/// Orchestrates an on-chain payment from a hardware wallet: reconnect the device, compose the exact
/// payment, sign it on-device, and broadcast. Owns the per-phase timeouts and fee-reserve math.
///
/// Pure orchestration over the injected `HwTransferFunding` / `HwTransferConnecting` capabilities —
/// it holds no UI state, so device signing can be tested independently of its callers.
@MainActor
struct HwFundingSigner {
    /// Device balance and the amount available to fund after holding back an on-chain fee reserve.
    struct Availability: Equatable {
        let balanceSats: UInt64
        let available: UInt64
    }

    let funding: HwTransferFunding
    let connecting: HwTransferConnecting
    let feeRateProvider: () async -> UInt64?
    /// Provides a fee-estimation destination address (an app receive address); never broadcast to.
    let addressProvider: () async throws -> String
    let timeouts: (compose: Double, sign: Double, broadcast: Double)

    /// Conservative vbyte reserve, used only as a fallback when the real coin-selection estimate
    /// (a `sendMax` compose) is unavailable.
    var txVBytes: UInt64 = 1200
    /// Minimum fallback fee rate when fee estimates are temporarily unavailable.
    var fallbackSatsPerVByte: UInt64 = 3
    /// Fallback fee percentage used when fee estimates are temporarily unavailable.
    var fallbackFeePercent: Double = 0.1

    /// Resolve the device balance and the amount available to fund. Prefers the real max-sendable
    /// (same coin-selection fee as the software wallet), falling back to the reserve estimate.
    func availability(
        walletId: String,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> Availability {
        let account = try funding.getFundingAccount(walletId: walletId, addressType: addressType)
        let available = await maxSpendable(walletId: walletId, balanceSats: account.balanceSats, addressType: addressType)
        return Availability(balanceSats: account.balanceSats, available: available)
    }

    /// The amount available to fund. Computes the exact max-sendable via a `sendMax` compose at the
    /// target fee rate; when the fee rate, address, or compose is unavailable, falls back to the
    /// conservative reserve clamp.
    private func maxSpendable(walletId: String, balanceSats: UInt64, addressType: AddressScriptType) async -> UInt64 {
        if let satsPerVByte = await feeRateProvider(),
           let address = try? await addressProvider(),
           let spendable = try? await funding.maxSpendableFunding(
               walletId: walletId,
               destinationAddress: address,
               satsPerVByte: satsPerVByte,
               addressType: addressType
           )
        {
            return min(balanceSats, spendable)
        }
        let reserve = await Self.feeReserve(
            balanceSats: balanceSats,
            satsPerVByte: feeRateProvider(),
            txVBytes: txVBytes,
            fallbackSatsPerVByte: fallbackSatsPerVByte,
            fallbackFeePercent: fallbackFeePercent
        )
        return balanceSats > reserve ? balanceSats - reserve : 0
    }

    /// Reconnects, composes and signs a normal on-chain payment without broadcasting it.
    /// `onConnectingDevice` brackets every reconnect (true before it, false once it returns or throws),
    /// including the one before a sign retry: the phases a caller may abandon because nothing is on the
    /// device to sign yet.
    func prepareSignedPayment(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        onComposed: (HwFundingTransaction) -> Void = { _ in },
        onConnectingDevice: (Bool) -> Void = { _ in }
    ) async throws -> HwFundingSignedTx {
        do {
            onConnectingDevice(true)
            defer { onConnectingDevice(false) }
            try await ensureConnected(walletId: walletId)
        }
        let tx = try await compose(walletId: walletId, address: address, sats: sats, satsPerVByte: satsPerVByte)
        onComposed(tx)
        return try await signStep(walletId: walletId, funding: tx, onConnectingDevice: onConnectingDevice)
    }

    /// Broadcasts a signed funding transaction without requiring the hardware device.
    func broadcastSignedFunding(
        _ signed: HwFundingSignedTx,
        paymentDeadline: PaykitPreciseInstant? = nil,
        beforeDispatch: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) async throws -> HwFundingBroadcastResult {
        let txId = try await broadcastStep(serializedTx: signed.serializedTx, paymentDeadline: paymentDeadline, beforeDispatch: beforeDispatch)
        return HwFundingBroadcastResult(
            txId: txId,
            miningFeeSats: signed.miningFeeSats,
            feeRate: UInt64(signed.feeRate.rounded(.up)),
            totalSpent: signed.totalSpent
        )
    }

    /// Offline compose for the exact payment amount; does not require a connected device.
    func estimateOfflineFundingMiningFee(walletId: String, address: String, sats: UInt64) async throws -> UInt64 {
        let satsPerVByte = await resolvedSatsPerVByte()
        return try await funding.estimateOfflineFundingMiningFee(
            walletId: walletId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte,
            addressType: hwFundingDefaultAddressType
        )
    }

    private func ensureConnected(walletId: String) async throws {
        do {
            try await withTimeout(connecting.reconnectTimeout(walletId: walletId)) {
                try await connecting.ensureConnected(walletId: walletId)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            disconnectAfterTimeout(walletId: walletId)
            throw HwTransferError.reconnect(isBluetooth: connecting.isKnownBluetoothDevice(walletId: walletId))
        } catch {
            if error.isHwUserCancellation() {
                throw error
            }
            // Swift has no cause chain, so this must be rethrown explicitly: the catch-all below
            // would otherwise bury "this wallet needs its passphrase" under a reconnect failure and
            // the prompt would never open.
            if let passphrase = error as? HwPassphraseError {
                throw passphrase
            }
            if error is HwWalletMismatchError {
                throw HwTransferError.walletMismatch
            }
            if let vendor = error.hwBusyVendor {
                throw HwTransferError.deviceBusy(vendor)
            }
            // A Jade that refuses to open (wrong PIN, unreachable PIN server, wrong network) says why
            // in words the user can act on, which the reconnect copy would hide.
            if error.underlyingJadeError != nil, !error.isJadeSessionFailure() {
                throw HwTransferError.generic(HwErrorPresenter.userMessage(from: error))
            }
            throw HwTransferError.reconnect(isBluetooth: connecting.isKnownBluetoothDevice(walletId: walletId))
        }
    }

    private func compose(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64
    ) async throws -> HwFundingTransaction {
        do {
            return try await withTimeout(timeouts.compose) {
                try await funding.composeFundingTransaction(
                    walletId: walletId,
                    address: address,
                    sats: sats,
                    satsPerVByte: satsPerVByte,
                    addressType: hwFundingDefaultAddressType
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            disconnectAfterTimeout(walletId: walletId)
            throw HwTransferError.signingTimeout
        } catch where error.underlyingJadeError != nil {
            // A Jade compose reconnects to read the fingerprint, so it fails the way a reconnect does
            // and is reported the same way instead of with the raw core description.
            if error.isJadeUserCancellation() {
                throw error
            }
            if error.isJadeDeviceBusy() {
                throw HwTransferError.deviceBusy(.blockstream)
            }
            let message = HwErrorPresenter.userMessage(from: error)
            throw error.isJadeSessionFailure() ? HwTransferError.funding(message) : HwTransferError.generic(message)
        } catch {
            let message = (error as? AppError)?.debugMessage ?? (error as? AppError)?.message ?? error.localizedDescription
            throw HwTransferError.funding(message)
        }
    }

    private func signStep(
        walletId: String,
        funding tx: HwFundingTransaction,
        onConnectingDevice: (Bool) -> Void = { _ in }
    ) async throws -> HwFundingSignedTx {
        do {
            return try await signOnce(walletId: walletId, funding: tx)
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            disconnectAfterTimeout(walletId: walletId)
            throw HwTransferError.signingTimeout
        } catch {
            guard error.isHwSessionFailure() else { throw error }

            await connecting.disconnectStaleSession(walletId: walletId)
            do {
                onConnectingDevice(true)
                defer { onConnectingDevice(false) }
                try await ensureConnected(walletId: walletId)
            }

            do {
                return try await signOnce(walletId: walletId, funding: tx)
            } catch is Timeout {
                disconnectAfterTimeout(walletId: walletId)
                throw HwTransferError.signingTimeout
            } catch {
                if error.isHwSessionFailure() {
                    await connecting.disconnectStaleSession(walletId: walletId)
                }
                throw error
            }
        }
    }

    private func signOnce(walletId: String, funding tx: HwFundingTransaction) async throws -> HwFundingSignedTx {
        try await withTimeout(timeouts.sign) {
            try await funding.signFunding(walletId: walletId, funding: tx)
        }
    }

    /// Broadcast the signed tx under its own timeout, separate from signing. A broadcast that has
    /// already been handed to the network must never be reported as a signing timeout, so a timeout
    /// here surfaces `.broadcastUncertain` (the funding tx may still confirm) without tearing down the
    /// device session.
    private func broadcastStep(
        serializedTx: String,
        paymentDeadline: PaykitPreciseInstant?,
        beforeDispatch: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> String {
        do {
            return try await withTimeout(timeouts.broadcast) {
                try await funding.broadcastFunding(serializedTx: serializedTx, paymentDeadline: paymentDeadline, beforeDispatch: beforeDispatch)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            throw HwTransferError.broadcastUncertain
        }
        // Any other (real broadcast) error propagates to the caller's generic handler.
    }

    private func resolvedSatsPerVByte() async -> UInt64 {
        await feeRateProvider() ?? fallbackSatsPerVByte
    }

    /// Start recovery without making the timed-out UI operation wait on a transport that may also
    /// be stuck. The next connect remains serialized behind this cleanup by the device manager.
    private func disconnectAfterTimeout(walletId: String) {
        connecting.scheduleStaleSessionCleanup(walletId: walletId)
    }

    /// Pure fee-reserve computation. With a known fee rate: `rate × vbytes`. Without one (estimates
    /// unavailable): `max(minReserve, balance × fallbackPercent)`.
    static func feeReserve(
        balanceSats: UInt64,
        satsPerVByte: UInt64?,
        txVBytes: UInt64 = 1200,
        fallbackSatsPerVByte: UInt64 = 3,
        fallbackFeePercent: Double = 0.1
    ) -> UInt64 {
        guard let satsPerVByte else {
            let minReserve = fallbackSatsPerVByte * txVBytes
            let fallback = UInt64(Double(balanceSats) * fallbackFeePercent)
            return max(minReserve, fallback)
        }
        return satsPerVByte * txVBytes
    }

    private struct Timeout: Error {}

    /// Race an async operation against a timeout without structurally waiting for the losing task.
    /// This matters for blocking service calls that cannot observe Swift task cancellation.
    private func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream<Result<T, Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let operationTask = Task {
            do {
                try await continuation.yield(.success(operation()))
            } catch {
                continuation.yield(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continuation.yield(.failure(Timeout()))
            } catch is CancellationError {
                // The operation completed or its caller was cancelled.
            } catch {
                continuation.yield(.failure(error))
            }
        }

        return try await withTaskCancellationHandler {
            defer {
                operationTask.cancel()
                timeoutTask.cancel()
                continuation.finish()
            }
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            throw CancellationError()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
    }
}

/// Send-sheet state for a normal on-chain payment funded and signed by a paired hardware wallet.
@Observable
@MainActor
final class HwSendCoordinator {
    private(set) var walletId: String?

    private(set) var availableSats: UInt64 = 0
    private(set) var previewFeeSats: UInt64 = 0
    private(set) var isFundingSourceLoading = false
    private(set) var isPreviewLoading = false
    private(set) var isSigning = false
    private(set) var isConnectingDevice = false
    private(set) var isBroadcastUnresolved = false
    private(set) var isPassphraseRequired = false
    private(set) var isVerifyingPassphrase = false

    private var pendingPayment: PendingPayment?
    private var operationTask: Task<HwFundingBroadcastResult, Error>?
    private var operationRequest: PaymentRequest?
    private var operationSession: OperationSession?
    private var isRetainingSignedPayment = false
    private var isAuthorizingPayment = false
    /// Bumped by every sign attempt and every cancel. A cancelled task can keep running until its
    /// device call returns, and must not write over the state of an attempt started after it.
    private var signingAttempt = 0
    private var availabilityRequestId = 0
    private var previewRequestId = 0
    private let signerFactory: @MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner
    /// Durable because this coordinator only lives for one presentation of the send sheet.
    private let retainedSends: HwRetainedSendService

    var isActive: Bool {
        walletId != nil
    }

    var hasPendingBroadcast: Bool {
        pendingPayment != nil
    }

    /// Whether the sign screen may be left. Reaching the device (a Jade may wait minutes for its PIN)
    /// can be abandoned, and leaving cancels it. An uncertain broadcast keeps navigation locked;
    /// a definite refusal permits leaving while the original signed Shop payment stays retained.
    var canLeave: Bool {
        (!isSigning || isConnectingDevice) && !isBroadcastUnresolved
    }

    init(
        walletId: String? = nil,
        signerFactory: @escaping @MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner = { manager, address, satsPerVByte in
            HwSendCoordinator.signer(
                manager: manager,
                address: address,
                satsPerVByte: satsPerVByte
            )
        },
        retainedSends: HwRetainedSendService = .shared
    ) {
        self.walletId = walletId
        self.signerFactory = signerFactory
        self.retainedSends = retainedSends
    }

    func seedAvailable(walletId: String, availableSats: UInt64, retainedFeeSats: UInt64? = nil) {
        guard self.walletId == walletId else { return }
        self.availableSats = availableSats
        if let retainedFeeSats {
            previewFeeSats = retainedFeeSats
            isFundingSourceLoading = false
            isPreviewLoading = false
        }
    }

    func selectWallet(
        _ walletId: String?,
        initialAvailableSats: UInt64 = 0,
        showsLoading: Bool = false
    ) {
        guard self.walletId != walletId, operationTask == nil, !isBroadcastUnresolved else { return }

        availabilityRequestId += 1
        previewRequestId += 1
        self.walletId = walletId
        pendingPayment = nil
        availableSats = walletId == nil ? 0 : initialAvailableSats
        previewFeeSats = 0
        isFundingSourceLoading = walletId != nil && showsLoading
        isPreviewLoading = false
        isSigning = false
        isConnectingDevice = false
        isBroadcastUnresolved = false
        isPassphraseRequired = false
        isVerifyingPassphrase = false
    }

    func refreshAvailable(
        manager: HwWalletManager,
        destinationAddress: String,
        satsPerVByte: UInt64?
    ) async {
        guard let walletId else { return }

        availabilityRequestId += 1
        let requestId = availabilityRequestId
        isFundingSourceLoading = true

        func apply(_ available: UInt64) {
            guard self.walletId == walletId, availabilityRequestId == requestId else { return }
            availableSats = available
            isFundingSourceLoading = false
        }

        guard let satsPerVByte else {
            apply(availableSats)
            return
        }

        guard !destinationAddress.isEmpty else {
            apply(manager.fundingBalance(walletId: walletId))
            return
        }

        do {
            let signer = signerFactory(manager, destinationAddress, satsPerVByte)
            let available = try await signer.availability(walletId: walletId).available
            apply(available)
        } catch {
            let balance = manager.fundingBalance(walletId: walletId)
            let reserve = HwFundingSigner.feeReserve(
                balanceSats: balance,
                satsPerVByte: satsPerVByte
            )
            apply(balance > reserve ? balance - reserve : 0)
        }
    }

    func preparePreview(
        manager: HwWalletManager,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64
    ) async throws -> UInt64? {
        guard let walletId else { return nil }
        previewRequestId += 1
        let requestId = previewRequestId
        isPreviewLoading = true
        previewFeeSats = 0
        let request = PaymentRequest(address: address, sats: sats, satsPerVByte: satsPerVByte)
        if pendingPayment?.request != request, pendingPayment?.isAttemptedOrdinarySend != true {
            pendingPayment = nil
        }
        do {
            let signer = signerFactory(manager, address, satsPerVByte)
            let fee = try await signer.estimateOfflineFundingMiningFee(walletId: walletId, address: address, sats: sats)
            guard self.walletId == walletId, previewRequestId == requestId else { return nil }
            previewFeeSats = fee
            isFundingSourceLoading = false
            isPreviewLoading = false
            return fee
        } catch {
            if self.walletId == walletId, previewRequestId == requestId {
                isFundingSourceLoading = false
                isPreviewLoading = false
            }
            throw error
        }
    }

    func signAndBroadcast(
        manager: HwWalletManager,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        paymentDeadline: PaykitPreciseInstant? = nil,
        paymentRequestId: PaykitPaymentRequest.ID? = nil,
        loadSignedPayment: @escaping () async throws -> RetainedHardwareOnchainPayment? = { nil },
        beforeFirstBroadcast: @escaping (HwFundingSignedTx) async throws -> Void = { _ in },
        beforeBroadcastAttempt: @escaping () async throws -> Void = {},
        retainSignedPayment: @escaping (HwFundingSignedTx) async throws -> Void = { _ in },
        markSignedPaymentRefused: @escaping (HwFundingSignedTx, Bool) async throws -> Void = { _, _ in },
        clearSignedPaymentBeforeDispatch: @escaping (HwFundingSignedTx) async -> Bool = { _ in true },
        afterBroadcast: @escaping (HwFundingBroadcastResult) async -> Void = { _ in },
        afterFailure: @escaping (PrivatePaymentListSendOutcome) async -> Void = { _ in }
    ) async throws -> HwFundingBroadcastResult {
        guard let walletId else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "The send flow has no wallet id")
        }
        let request = PaymentRequest(address: address, sats: sats, satsPerVByte: satsPerVByte)
        if let pendingPayment, isBroadcastUnresolved || pendingPayment.hasBroadcastAttempted {
            if pendingPayment.paymentRequestId == nil, paymentRequestId == nil {
                guard pendingPayment.request.isSamePayment(address: address, sats: sats) else {
                    throw HwTransferError.broadcastUncertain
                }
            } else {
                guard pendingPayment.request == request, pendingPayment.paymentRequestId == paymentRequestId else {
                    throw PaykitPaymentRequestError.operationInProgress
                }
            }
        }
        if let operationTask {
            guard operationRequest == request else { throw HwTransferError.deviceBusy(manager.vendor(walletId: walletId)) }
            return try await operationTask.value
        }

        signingAttempt += 1
        let attempt = signingAttempt
        let signer = signerFactory(manager, address, satsPerVByte)
        isSigning = true

        let task = Task { @MainActor in
            defer {
                if signingAttempt == attempt {
                    isSigning = false
                    isConnectingDevice = false
                }
            }

            if pendingPayment == nil, let restored = try await loadSignedPayment() {
                pendingPayment = PendingPayment(request: request, signedTx: restored.signedTx, paymentRequestId: paymentRequestId)
                pendingPayment?.isPreparedForBroadcast = true
                pendingPayment?.hasBroadcastAttempted = restored.hasAttemptedBroadcast
                isBroadcastUnresolved = restored.hasAttemptedBroadcast && !restored.isRefusedForNavigation
            }
            if paymentRequestId == nil, let retained = try await retainedSends.record(walletId: walletId) {
                guard retained.isSamePayment(address: address, sats: sats) else { throw HwTransferError.broadcastUncertain }
                try Task.checkCancellation()
                pendingPayment = PendingPayment(
                    request: request,
                    signedTx: retained.signedTx,
                    paymentRequestId: nil,
                    isPreparedForBroadcast: true,
                    hasBroadcastAttempted: true
                )
                isBroadcastUnresolved = false
            }
            let signed: HwFundingSignedTx
            if let pendingPayment,
               pendingPayment.request == request
               || (pendingPayment.isAttemptedOrdinarySend && pendingPayment.request.isSamePayment(address: address, sats: sats))
            {
                signed = pendingPayment.signedTx
            } else {
                signed = try await signer.prepareSignedPayment(
                    walletId: walletId,
                    address: address,
                    sats: sats,
                    satsPerVByte: satsPerVByte,
                    onComposed: { [weak self] composed in
                        guard let self, signingAttempt == attempt else { return }
                        previewFeeSats = composed.miningFeeSats
                    },
                    onConnectingDevice: { [weak self] isConnecting in
                        guard let self, signingAttempt == attempt else { return }
                        isConnectingDevice = isConnecting
                    }
                )
                try Task.checkCancellation()
                pendingPayment = PendingPayment(request: request, signedTx: signed, paymentRequestId: paymentRequestId)
            }

            if pendingPayment?.isPreparedForBroadcast != true {
                try await beforeFirstBroadcast(signed)
                try Task.checkCancellation()
                pendingPayment?.isPreparedForBroadcast = true
            }

            func retainBeforeDispatch() async throws {
                if paymentRequestId == nil {
                    try await retainedSends.retain(HwRetainedSend(
                        walletId: walletId,
                        address: address,
                        sats: sats,
                        serializedTx: signed.serializedTx,
                        miningFeeSats: signed.miningFeeSats,
                        feeRate: signed.feeRate,
                        totalSpent: signed.totalSpent
                    ))
                } else {
                    try await retainSignedPayment(signed)
                }
            }

            func clearBeforeDispatch() async -> Bool {
                if paymentRequestId == nil {
                    return await releaseRetainedSend(walletId: walletId)
                }
                return await clearSignedPaymentBeforeDispatch(signed)
            }

            let hadPriorBroadcastAttempt = pendingPayment?.hasBroadcastAttempted == true
            let priorBroadcastWasUnresolved = isBroadcastUnresolved
            var broadcastWasAttempted = hadPriorBroadcastAttempt
            isAuthorizingPayment = true
            defer { isAuthorizingPayment = false }
            do {
                do {
                    try await beforeBroadcastAttempt()
                    try Task.checkCancellation()
                    guard signingAttempt == attempt else { throw CancellationError() }
                    try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline)
                } catch {
                    guard signingAttempt == attempt else { throw error }
                    if !broadcastWasAttempted {
                        pendingPayment = nil
                    }
                    throw error
                }

                do {
                    // Cancellation keeps this operation's ownership until its receipt is either
                    // retained for submission or durably cleared. No newer task may reuse it meanwhile.
                    isRetainingSignedPayment = true
                    defer { isRetainingSignedPayment = false }
                    try await retainBeforeDispatch()
                    do {
                        try Task.checkCancellation()
                        guard signingAttempt == attempt else { throw CancellationError() }
                    } catch {
                        if !hadPriorBroadcastAttempt {
                            let cleared = await clearBeforeDispatch()
                            if !cleared {
                                isBroadcastUnresolved = paymentRequestId != nil
                                broadcastWasAttempted = true
                                pendingPayment?.hasBroadcastAttempted = true
                            }
                        }
                        throw error
                    }
                }
                isBroadcastUnresolved = true
                broadcastWasAttempted = true
                pendingPayment?.hasBroadcastAttempted = true
                do {
                    let result = try await signer.broadcastSignedFunding(signed, paymentDeadline: paymentDeadline) { [self] in
                        try Task.checkCancellation()
                        guard signingAttempt == attempt else { throw CancellationError() }
                        try await markSignedPaymentRefused(signed, false)
                        try Task.checkCancellation()
                        guard signingAttempt == attempt else { throw CancellationError() }
                    }
                    if paymentRequestId == nil {
                        await releaseRetainedSend(walletId: walletId)
                    }
                    await afterBroadcast(result)
                    return result
                } catch {
                    // Navigation may unlock after a definite refusal; the receipt still guards funds.
                    let underlying = (error as? AppError)?.underlyingError ?? error
                    let notSubmitted = underlying as? PreparedOnchainSendNotSubmitted
                    let failure = notSubmitted?.underlying ?? error
                    let refused = failure.isHardwareBroadcastRefusal()
                    if notSubmitted == nil, paymentRequestId != nil, refused {
                        try? await markSignedPaymentRefused(signed, true)
                    }
                    let dispatchIsUncertain = notSubmitted == nil
                    isBroadcastUnresolved = dispatchIsUncertain ? paymentRequestId != nil && !refused : priorBroadcastWasUnresolved
                    if notSubmitted != nil {
                        if hadPriorBroadcastAttempt, !priorBroadcastWasUnresolved, paymentRequestId != nil {
                            try? await markSignedPaymentRefused(signed, true)
                        }
                        // A queued retry can expire without changing the uncertainty of an earlier attempt.
                        let cleared: Bool = if hadPriorBroadcastAttempt {
                            false
                        } else {
                            await clearBeforeDispatch()
                        }
                        let retainsBroadcastAttempt = hadPriorBroadcastAttempt || !cleared
                        isBroadcastUnresolved = hadPriorBroadcastAttempt ? priorBroadcastWasUnresolved : !cleared && paymentRequestId != nil
                        broadcastWasAttempted = retainsBroadcastAttempt
                        pendingPayment?.hasBroadcastAttempted = retainsBroadcastAttempt
                        if !retainsBroadcastAttempt {
                            pendingPayment = nil
                        }
                        throw failure
                    }
                    if paymentRequestId == nil {
                        throw await settleRetainedSend(walletId: walletId, failure: failure, isRetry: hadPriorBroadcastAttempt)
                    }
                    throw failure
                }
            } catch {
                guard signingAttempt == attempt else { throw error }
                if !broadcastWasAttempted {
                    pendingPayment = nil
                }
                await afterFailure(broadcastWasAttempted ? .uncertain : .definitePreBroadcastFailure)
                throw error
            }
        }
        operationRequest = request
        operationTask = task
        operationSession = OperationSession(walletId: walletId, connecting: signer.connecting)
        defer {
            if signingAttempt == attempt {
                operationRequest = nil
                operationTask = nil
                operationSession = nil
            }
        }
        return try await task.value
    }

    /// Whether the selected wallet's retained send lets this ordinary payment go out. Unreadable storage counts as blocking,
    /// because treating it as no record would allow a second signature. A Shop payment keeps its own retained receipt, so an
    /// incoming request never consults the store.
    func retainedSendStatus(address: String, sats: UInt64, hasIncomingRequest: Bool) async -> HwRetainedSendStatus {
        guard !hasIncomingRequest, let walletId else { return .none }
        do {
            if let retained = try await retainedSends.record(walletId: walletId) {
                guard retained.isSamePayment(address: address, sats: sats), !retained.retryWasRefused else { return .blocking }
                return .retry(retained.signedTx)
            }
        } catch {
            Logger.warn("Failed to read retained hardware send: \(type(of: error))", context: "HwSendCoordinator")
            return .blocking
        }
        guard let pendingPayment, pendingPayment.isAttemptedOrdinarySend else { return .none }
        return pendingPayment.request.isSamePayment(address: address, sats: sats) ? .retry(pendingPayment.signedTx) : .blocking
    }

    /// Discards the retained ordinary send so the next attempt signs anew. Only call this after the user accepted a second payment.
    func abandonRetainedPayment() async {
        guard let walletId, operationTask == nil else { return }
        do {
            try await retainedSends.abandon(walletId: walletId)
        } catch {
            Logger.warn("Failed to abandon retained hardware send: \(type(of: error))", context: "HwSendCoordinator")
        }
        if pendingPayment?.paymentRequestId == nil {
            pendingPayment = nil
        }
    }

    func reconnectWithPassphrase(
        _ passphrase: String,
        manager: HwWalletManager
    ) async throws {
        guard let walletId else { return }
        isVerifyingPassphrase = true
        defer { isVerifyingPassphrase = false }
        try await manager.reconnectWithPassphrase(walletId: walletId, passphrase: passphrase)
        guard isPassphraseRequired else { throw CancellationError() }
        isPassphraseRequired = false
    }

    func requestPassphrase() {
        isPassphraseRequired = true
    }

    func dismissPassphrase() {
        isPassphraseRequired = false
    }

    func completionRoute(
        result: HwFundingBroadcastResult,
        walletId: String,
        requestId: PaykitPaymentRequest.ID?,
        paymentIdentity: String?,
        completeContactPayment: (String) async -> Bool
    ) async -> SendRoute {
        let verified = await completeContactPayment(result.txId)
        if let requestId, !verified {
            return .hardwarePending(requestId: requestId, walletId: walletId, transactionId: result.txId, paymentIdentity: paymentIdentity)
        }
        return .success(paymentId: result.txId, walletId: walletId)
    }

    func resolveObservedShopPayment(
        _ resolution: PaykitOnchainPaymentResolution,
        paymentIdentity: String?,
        currentIdentity: String?
    ) -> SendRoute? {
        guard !isSigning, isBroadcastUnresolved,
              let pendingPayment,
              pendingPayment.hasBroadcastAttempted,
              pendingPayment.paymentRequestId == resolution.requestId,
              walletId == resolution.walletId,
              PubkyPublicKeyFormat.matches(resolution.identity, paymentIdentity),
              PubkyPublicKeyFormat.matches(resolution.identity, currentIdentity),
              let txid = try? SignedTransactionId.fromHex(pendingPayment.signedTx.serializedTx),
              txid.caseInsensitiveCompare(resolution.transactionId) == .orderedSame
        else { return nil }
        completeBroadcast()
        return .success(paymentId: txid, walletId: resolution.walletId)
    }

    func completeBroadcast() {
        pendingPayment = nil
        isBroadcastUnresolved = false
    }

    func cancel() {
        availabilityRequestId += 1
        previewRequestId += 1
        isFundingSourceLoading = false
        isPreviewLoading = false
        isVerifyingPassphrase = false
        isPassphraseRequired = false
        guard !isBroadcastUnresolved else { return }
        let retainsAttemptedPayment = pendingPayment?.hasBroadcastAttempted == true
        let abandonedSession = operationSession
        operationTask?.cancel()
        // Receipt persistence/cleanup is suspended work. Keep the cancelled operation registered
        // until it finishes, so a concurrent send joins it instead of adopting its receipt.
        guard !isRetainingSignedPayment, !isAuthorizingPayment else { return }
        signingAttempt += 1
        operationTask = nil
        operationRequest = nil
        operationSession = nil
        if !retainsAttemptedPayment {
            pendingPayment = nil
        }
        isSigning = false
        isConnectingDevice = false
        // A Swift cancel never reaches the device, which would otherwise keep connecting (or wait for
        // a PIN) for a payment nobody is waiting on. The next connect waits for this release.
        if let abandonedSession {
            abandonedSession.connecting.scheduleStaleSessionCleanup(walletId: abandonedSession.walletId)
        }
    }

    /// Decides whether a failed ordinary broadcast keeps its retained send, and returns the error to surface: a send that is
    /// kept for an unknown reason may already be out, so it must not read as a definite failure. `isRetry` matters because a
    /// refusal such as `bad-txns-inputs-missingorspent` on a retry may describe our own earlier accepted transaction.
    private func settleRetainedSend(walletId: String, failure: Error, isRetry: Bool) async -> Error {
        let refused = failure.isHardwareBroadcastRefusal()
        if isRetry {
            if refused {
                do {
                    try await retainedSends.markRetryRefused(walletId: walletId)
                } catch {
                    Logger.warn("Failed to mark retained hardware send refused: \(type(of: error))", context: "HwSendCoordinator")
                }
                return HwTransferError.broadcastUncertain
            }
        } else if refused {
            await releaseRetainedSend(walletId: walletId)
            pendingPayment = nil
        } else if failure.isDefiniteElectrumConnectFailure() {
            await releaseRetainedSend(walletId: walletId)
            pendingPayment?.hasBroadcastAttempted = false
        }
        if refused || failure.isBroadcastConnectivityFailure() || failure is CancellationError {
            return failure
        }
        return HwTransferError.broadcastUncertain
    }

    /// A failed release only leaves the record behind, so the next attempt rebroadcasts or warns rather than signing again.
    @discardableResult
    private func releaseRetainedSend(walletId: String) async -> Bool {
        do {
            try await retainedSends.release(walletId: walletId)
            return true
        } catch {
            Logger.warn("Failed to release retained hardware send: \(type(of: error))", context: "HwSendCoordinator")
            return false
        }
    }

    private static func signer(
        manager: HwWalletManager,
        address: String,
        satsPerVByte: UInt64
    ) -> HwFundingSigner {
        HwFundingSigner(
            funding: manager,
            connecting: manager,
            feeRateProvider: { satsPerVByte },
            addressProvider: { address },
            timeouts: (compose: 45, sign: 120, broadcast: 120)
        )
    }

    private struct PaymentRequest: Equatable {
        let address: String
        let sats: UInt64
        let satsPerVByte: UInt64

        func isSamePayment(address: String, sats: UInt64) -> Bool {
            self.address == address && self.sats == sats
        }
    }

    private struct PendingPayment {
        let request: PaymentRequest
        let signedTx: HwFundingSignedTx
        let paymentRequestId: PaykitPaymentRequest.ID?
        var isPreparedForBroadcast = false
        var hasBroadcastAttempted = false

        var isAttemptedOrdinarySend: Bool {
            paymentRequestId == nil && hasBroadcastAttempted
        }
    }

    private struct OperationSession {
        let walletId: String
        let connecting: HwTransferConnecting
    }
}

private extension HwRetainedSend {
    var signedTx: HwFundingSignedTx {
        HwFundingSignedTx(serializedTx: serializedTx, miningFeeSats: miningFeeSats, feeRate: feeRate, totalSpent: totalSpent)
    }

    /// Fee is deliberately not compared: a changed fee on the same payee and amount is the sharpest double-pay case.
    func isSamePayment(address: String, sats: UInt64) -> Bool {
        self.address == address && self.sats == sats
    }
}

/// A recoverable failure surfaced by the hardware-wallet transfer flow. The Sign screen maps each
/// case to the matching localized toast.
enum HwTransferError: Error, Equatable {
    /// Reconnect failed. `isBluetooth` selects the softer INFO toast for a known BLE device
    /// (advertises intermittently — "check that it is unlocked and try again") vs the ERROR toast.
    case reconnect(isBluetooth: Bool)
    case signingTimeout
    case broadcastUncertain
    /// Signed tx is retained but Electrum/network is unreachable — retry broadcast later.
    case broadcastConnectivity
    /// The device is locked or otherwise busy before signing can start. Carries the vendor so the
    /// toast can name the device.
    case deviceBusy(HwWalletVendor)
    /// Firmware error (code 99) — user must reconnect the device.
    case firmwareReconnect
    /// The entered passphrase opened a different wallet than the one being spent from.
    case passphraseMismatch
    /// The device holds another wallet than the one being spent from, so reconnecting cannot help.
    case walletMismatch
    case funding(String?)
    case generic(String?)
}

/// The hardware-wallet funding capability the transfer flow needs. Implemented by `HwWalletManager`;
/// declared as a protocol so the flow stays testable.
@MainActor
protocol HwTransferFunding: Sendable {
    func getFundingAccount(walletId: String, addressType: AddressScriptType) throws -> HwFundingAccount
    func maxSpendableFunding(
        walletId: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType: AddressScriptType
    ) async throws -> UInt64
    func composeFundingTransaction(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType
    ) async throws -> HwFundingTransaction
    /// Offline coin-selection estimate for the exact funding amount (`fingerprint: nil`); fee only.
    func estimateOfflineFundingMiningFee(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType
    ) async throws -> UInt64
    func signFunding(walletId: String, funding: HwFundingTransaction) async throws -> HwFundingSignedTx
    func broadcastFunding(
        serializedTx: String,
        paymentDeadline: PaykitPreciseInstant?,
        beforeDispatch: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> String
}

/// The device-session capability the transfer flow needs for on-device signing, addressed by wallet
/// identity: a device holds one wallet open at a time, so reaching a given wallet is more than
/// reaching its transport. Implemented by `HwWalletManager`.
@MainActor
protocol HwTransferConnecting: Sendable {
    func ensureConnected(walletId: String) async throws
    /// How long `ensureConnected` may take for this wallet's device before the flow gives up.
    func reconnectTimeout(walletId: String) -> Double
    func disconnectStaleSession(walletId: String) async
    func scheduleStaleSessionCleanup(walletId: String)
    /// Whether the wallet is reachable over a known Bluetooth device, so a reconnect failure can show
    /// the softer BLE "check that it is unlocked and try again" toast instead of the generic error.
    func isKnownBluetoothDevice(walletId: String) -> Bool
    /// Best-effort pre-connect when the sign screen appears, so tapping Open Trezor Connect is less
    /// likely to hit a cold reconnect. Fire-and-forget.
    func warmUpConnection(walletId: String)
    /// Whether the wallet's passphrase has to be collected again before the device can sign for it.
    func needsPassphrase(walletId: String) -> Bool
    /// Reopens a hidden wallet for signing, refusing a session that resolves to a different wallet.
    func reconnectWithPassphrase(walletId: String, passphrase: String) async throws
}

// MARK: - Hardware transfer capability conformances

extension HwWalletManager: HwTransferFunding {}
extension HwWalletManager: HwTransferConnecting {}
