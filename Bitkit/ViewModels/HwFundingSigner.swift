import BitkitCore
import Observation

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
    let timeouts: (reconnect: Double, compose: Double, sign: Double, broadcast: Double)

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

    /// Reconnects, composes and signs the funding transaction without broadcasting it.
    func prepareSignedFunding(
        order: IBtOrder,
        walletId: String,
        address: String,
        onComposed: (HwFundingTransaction) -> Void = { _ in }
    ) async throws -> HwFundingSignedTx {
        let satsPerVByte = await resolvedSatsPerVByte()
        return try await prepareSignedPayment(
            walletId: walletId,
            address: address,
            sats: order.feeSat,
            satsPerVByte: satsPerVByte,
            onComposed: onComposed
        )
    }

    /// Reconnects, composes and signs a normal on-chain payment without broadcasting it.
    func prepareSignedPayment(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        onComposed: (HwFundingTransaction) -> Void = { _ in }
    ) async throws -> HwFundingSignedTx {
        try await ensureConnected(walletId: walletId)
        let tx = try await compose(walletId: walletId, address: address, sats: sats, satsPerVByte: satsPerVByte)
        onComposed(tx)
        return try await signStep(walletId: walletId, funding: tx)
    }

    /// Broadcasts a signed funding transaction without requiring the hardware device.
    func broadcastSignedFunding(_ signed: HwFundingSignedTx) async throws -> HwFundingBroadcastResult {
        let txId = try await broadcastStep(serializedTx: signed.serializedTx)
        return HwFundingBroadcastResult(
            txId: txId,
            miningFeeSats: signed.miningFeeSats,
            feeRate: UInt64(signed.feeRate.rounded(.up)),
            totalSpent: signed.totalSpent
        )
    }

    /// Best-effort pre-connect of the device before signing (fire-and-forget). Delegates to the
    /// device-session capability, which no-ops unless it's a known BLE device that isn't connected.
    func warmUp(walletId: String) {
        connecting.warmUpConnection(walletId: walletId)
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
            try await withTimeout(timeouts.reconnect) {
                try await connecting.ensureConnected(walletId: walletId)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            disconnectAfterTimeout(walletId: walletId)
            throw HwTransferError.reconnect(isBluetooth: connecting.isKnownBluetoothDevice(walletId: walletId))
        } catch {
            if error.isTrezorUserCancellation() { throw error }
            // Swift has no cause chain, so this must be rethrown explicitly: the catch-all below
            // would otherwise bury "this wallet needs its passphrase" under a reconnect failure and
            // the prompt would never open.
            if let passphrase = error as? HwPassphraseError { throw passphrase }
            if error.isTrezorDeviceBusy() { throw HwTransferError.deviceBusy }
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
        } catch {
            let message = (error as? AppError)?.debugMessage ?? (error as? AppError)?.message ?? error.localizedDescription
            throw HwTransferError.funding(message)
        }
    }

    private func signStep(walletId: String, funding tx: HwFundingTransaction) async throws -> HwFundingSignedTx {
        do {
            return try await signOnce(walletId: walletId, funding: tx)
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            disconnectAfterTimeout(walletId: walletId)
            throw HwTransferError.signingTimeout
        } catch {
            guard error.isTrezorSessionFailure() else { throw error }

            await connecting.disconnectStaleSession(walletId: walletId)
            try await ensureConnected(walletId: walletId)

            do {
                return try await signOnce(walletId: walletId, funding: tx)
            } catch is Timeout {
                disconnectAfterTimeout(walletId: walletId)
                throw HwTransferError.signingTimeout
            } catch {
                if error.isTrezorSessionFailure() {
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
    private func broadcastStep(serializedTx: String) async throws -> String {
        do {
            return try await withTimeout(timeouts.broadcast) {
                try await funding.broadcastFunding(serializedTx: serializedTx)
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
    private(set) var isSigning = false
    private(set) var isBroadcastUnresolved = false
    private(set) var isPassphraseRequired = false
    private(set) var isVerifyingPassphrase = false

    private var pendingPayment: PendingPayment?
    private var operationTask: Task<HwFundingBroadcastResult, Error>?
    private var operationRequest: PaymentRequest?
    private var availabilityRequestId = 0
    private var previewRequestId = 0
    private let signerFactory: @MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner

    var isActive: Bool {
        walletId != nil
    }

    var hasPendingBroadcast: Bool {
        pendingPayment != nil
    }

    init(
        walletId: String? = nil,
        signerFactory: @escaping @MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner = { manager, address, satsPerVByte in
            HwSendCoordinator.signer(
                manager: manager,
                address: address,
                satsPerVByte: satsPerVByte
            )
        }
    ) {
        self.walletId = walletId
        self.signerFactory = signerFactory
    }

    func seedAvailable(walletId: String, availableSats: UInt64) {
        guard self.walletId == walletId else { return }
        self.availableSats = availableSats
    }

    func selectWallet(_ walletId: String?, initialAvailableSats: UInt64 = 0) {
        guard self.walletId != walletId else { return }
        guard operationTask == nil, !isBroadcastUnresolved else { return }

        availabilityRequestId += 1
        previewRequestId += 1
        self.walletId = walletId
        pendingPayment = nil
        availableSats = walletId == nil ? 0 : initialAvailableSats
        previewFeeSats = 0
        isSigning = false
        isBroadcastUnresolved = false
        isPassphraseRequired = false
        isVerifyingPassphrase = false
    }

    func refreshAvailable(
        manager: HwWalletManager,
        destinationAddress: String,
        satsPerVByte: UInt64
    ) async {
        guard let walletId else { return }

        guard !destinationAddress.isEmpty else {
            if self.walletId == walletId {
                availableSats = manager.fundingBalance(walletId: walletId)
            }
            return
        }

        availabilityRequestId += 1
        let requestId = availabilityRequestId

        func apply(_ available: UInt64) {
            guard self.walletId == walletId, availabilityRequestId == requestId else { return }
            availableSats = available
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
        let request = PaymentRequest(address: address, sats: sats, satsPerVByte: satsPerVByte)
        if pendingPayment?.request != request {
            pendingPayment = nil
        }
        let fee = try await manager.estimateOfflineFundingMiningFee(
            walletId: walletId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte
        )
        guard self.walletId == walletId, previewRequestId == requestId else { return nil }
        previewFeeSats = fee
        return fee
    }

    func signAndBroadcast(
        manager: HwWalletManager,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        beforeBroadcast: @escaping () async throws -> Void = {}
    ) async throws -> HwFundingBroadcastResult {
        guard let walletId else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "The send flow has no wallet id")
        }
        let request = PaymentRequest(address: address, sats: sats, satsPerVByte: satsPerVByte)
        if let operationTask {
            guard operationRequest == request else { throw HwTransferError.deviceBusy }
            return try await operationTask.value
        }

        let task = Task { @MainActor in
            isSigning = true
            defer { isSigning = false }

            let signer = signerFactory(manager, address, satsPerVByte)
            let signed: HwFundingSignedTx
            if let pendingPayment, pendingPayment.request == request {
                signed = pendingPayment.signedTx
            } else {
                signed = try await signer.prepareSignedPayment(
                    walletId: walletId,
                    address: address,
                    sats: sats,
                    satsPerVByte: satsPerVByte,
                    onComposed: { [weak self] in self?.previewFeeSats = $0.miningFeeSats }
                )
                pendingPayment = PendingPayment(request: request, signedTx: signed)
            }

            if pendingPayment?.isPreparedForBroadcast != true {
                try await beforeBroadcast()
                pendingPayment?.isPreparedForBroadcast = true
            }

            isBroadcastUnresolved = true
            do {
                return try await signer.broadcastSignedFunding(signed)
            } catch {
                let outcomeIsUncertain = (error as? HwTransferError) == .broadcastUncertain
                if !outcomeIsUncertain, !error.isBroadcastConnectivityFailure() {
                    pendingPayment = nil
                    isBroadcastUnresolved = false
                }
                throw error
            }
        }
        operationRequest = request
        operationTask = task
        defer {
            operationRequest = nil
            operationTask = nil
        }
        return try await task.value
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

    func completeBroadcast() {
        pendingPayment = nil
        isBroadcastUnresolved = false
    }

    func cancel() {
        isVerifyingPassphrase = false
        isPassphraseRequired = false
        guard !isBroadcastUnresolved else { return }
        operationTask?.cancel()
        operationTask = nil
        operationRequest = nil
        pendingPayment = nil
        isSigning = false
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
            timeouts: (reconnect: 30, compose: 45, sign: 120, broadcast: 120)
        )
    }

    private struct PaymentRequest: Equatable {
        let address: String
        let sats: UInt64
        let satsPerVByte: UInt64
    }

    private struct PendingPayment {
        let request: PaymentRequest
        let signedTx: HwFundingSignedTx
        var isPreparedForBroadcast = false
    }
}
