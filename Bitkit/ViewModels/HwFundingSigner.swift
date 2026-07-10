import BitkitCore

/// Orchestrates funding a Lightning channel from a hardware wallet: reconnect the device, compose
/// the exact on-chain payment, sign it on-device, and broadcast. Owns the per-phase timeouts and the
/// fee-reserve math.
///
/// Pure orchestration over the injected `HwTransferFunding` / `HwTransferConnecting` capabilities —
/// it holds no UI state and doesn't touch `TransferViewModel`, so the device-signing flow can be
/// tested in isolation. `TransferViewModel` keeps the coordination that genuinely reuses the transfer
/// machinery (spending limits, order watching, published state).
@MainActor
struct HwFundingSigner {
    private static let alreadyBroadcastMarkers = [
        "already in block chain",
        "already in blockchain",
        "already in mempool",
        "already-in-block-chain",
        "already-in-mempool",
        "txn-already-known",
        "transaction already exists",
        "already known",
    ]

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
    var fallbackSatsPerVByte: UInt64 = 1
    /// Fallback fee percentage used when fee estimates are temporarily unavailable.
    var fallbackFeePercent: Double = 0.1

    /// Resolve the device balance and the amount available to fund. Prefers the real max-sendable
    /// (same coin-selection fee as the software wallet), falling back to the reserve estimate.
    func availability(
        deviceId: String,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> Availability {
        let account = try funding.getFundingAccount(deviceId: deviceId, addressType: addressType)
        let available = await maxSpendable(deviceId: deviceId, balanceSats: account.balanceSats, addressType: addressType)
        return Availability(balanceSats: account.balanceSats, available: available)
    }

    /// The amount available to fund. Computes the exact max-sendable via a `sendMax` compose at the
    /// target fee rate; when the fee rate, address, or compose is unavailable, falls back to the
    /// conservative reserve clamp.
    private func maxSpendable(deviceId: String, balanceSats: UInt64, addressType: AddressScriptType) async -> UInt64 {
        if let satsPerVByte = await feeRateProvider(),
           let address = try? await addressProvider(),
           let spendable = try? await funding.maxSpendableFunding(
               deviceId: deviceId,
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
        deviceId: String,
        address: String,
        onComposed: (HwFundingTransaction) -> Void = { _ in }
    ) async throws -> HwFundingSignedTx {
        try await ensureConnected(deviceId: deviceId)
        let satsPerVByte = await resolvedSatsPerVByte()
        let tx = try await compose(deviceId: deviceId, address: address, sats: order.feeSat, satsPerVByte: satsPerVByte)
        onComposed(tx)
        return try await signStep(deviceId: deviceId, funding: tx)
    }

    /// Broadcasts a signed funding transaction without requiring the hardware device.
    func broadcastSignedFunding(_ signed: HwFundingSignedTx) async throws -> HwFundingBroadcastResult {
        let txId: String
        do {
            txId = try await broadcastStep(serializedTx: signed.serializedTx)
        } catch {
            guard let signedTxId = signed.txId, Self.isAlreadyBroadcastError(error) else { throw error }
            txId = signedTxId
        }
        return HwFundingBroadcastResult(
            txId: txId,
            miningFeeSats: signed.miningFeeSats,
            feeRate: UInt64(signed.feeRate.rounded(.up)),
            totalSpent: signed.totalSpent
        )
    }

    /// Best-effort pre-connect of the device before signing (fire-and-forget). Delegates to the
    /// device-session capability, which no-ops unless it's a known BLE device that isn't connected.
    func warmUp(deviceId: String) {
        connecting.warmUpConnection(deviceId: deviceId)
    }

    private func ensureConnected(deviceId: String) async throws {
        do {
            try await withTimeout(timeouts.reconnect) {
                try await connecting.ensureConnected(deviceId: deviceId)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A device-decline during reconnect must stay silent — propagate it raw so the caller's
            // cancellation check catches it, rather than surfacing a reconnect error.
            if error.isTrezorUserCancellation() { throw error }
            throw HwTransferError.reconnect(isBluetooth: connecting.isKnownBluetoothDevice(deviceId: deviceId))
        }
    }

    private func compose(
        deviceId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64
    ) async throws -> HwFundingTransaction {
        do {
            return try await withTimeout(timeouts.compose) {
                try await funding.composeFundingTransaction(
                    deviceId: deviceId,
                    address: address,
                    sats: sats,
                    satsPerVByte: satsPerVByte,
                    addressType: hwFundingDefaultAddressType
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            await connecting.disconnectStaleSession(deviceId: deviceId)
            throw HwTransferError.signingTimeout
        } catch {
            let message = (error as? AppError)?.debugMessage ?? (error as? AppError)?.message ?? error.localizedDescription
            throw HwTransferError.funding(message)
        }
    }

    private func signStep(deviceId: String, funding tx: HwFundingTransaction) async throws -> HwFundingSignedTx {
        do {
            return try await withTimeout(timeouts.sign) {
                try await funding.signFunding(deviceId: deviceId, funding: tx)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            await connecting.disconnectStaleSession(deviceId: deviceId)
            throw HwTransferError.signingTimeout
        }
        // Any other (real signing) error propagates to the caller's generic handler.
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

    private static func isAlreadyBroadcastError(_ error: Error) -> Bool {
        let messages = [
            (error as? AppError)?.message,
            (error as? AppError)?.debugMessage,
            error.localizedDescription,
        ].compactMap { $0?.lowercased() }
        if messages.contains(where: { message in alreadyBroadcastMarkers.contains(where: message.contains) }) {
            return true
        }
        if let underlyingError = (error as? AppError)?.underlyingError {
            return isAlreadyBroadcastError(underlyingError)
        }
        return false
    }

    /// Pure fee-reserve computation. With a known fee rate: `rate × vbytes`. Without one (estimates
    /// unavailable): `max(minReserve, balance × fallbackPercent)`.
    static func feeReserve(
        balanceSats: UInt64,
        satsPerVByte: UInt64?,
        txVBytes: UInt64 = 1200,
        fallbackSatsPerVByte: UInt64 = 1,
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

    /// Race an async operation against a timeout. Cancellation (user dismiss) propagates as
    /// `CancellationError`; the deadline throws `Timeout`.
    private func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Timeout() }
            return result
        }
    }
}
