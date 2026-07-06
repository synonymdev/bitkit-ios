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
    let timeouts: (reconnect: Double, compose: Double, sign: Double)

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

    /// Reconnect → compose → sign+broadcast. Throws `HwTransferError` for recoverable failures and
    /// rethrows `CancellationError` when the caller's task is cancelled (user dismissed the flow).
    /// Any non-timeout sign/broadcast error propagates as-is for the caller's generic handling.
    func sign(order: IBtOrder, deviceId: String, address: String) async throws -> HwFundingBroadcastResult {
        try await ensureConnected(deviceId: deviceId)
        let satsPerVByte = await resolvedSatsPerVByte()
        let tx = try await compose(deviceId: deviceId, address: address, sats: order.feeSat, satsPerVByte: satsPerVByte)
        return try await signAndBroadcast(deviceId: deviceId, funding: tx)
    }

    private func ensureConnected(deviceId: String) async throws {
        do {
            try await withTimeout(timeouts.reconnect) {
                try await connecting.ensureConnected(deviceId: deviceId)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HwTransferError.reconnect
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

    private func signAndBroadcast(
        deviceId: String,
        funding tx: HwFundingTransaction
    ) async throws -> HwFundingBroadcastResult {
        do {
            return try await withTimeout(timeouts.sign) {
                try await funding.signAndBroadcastFunding(deviceId: deviceId, funding: tx)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is Timeout {
            await connecting.disconnectStaleSession(deviceId: deviceId)
            throw HwTransferError.signingTimeout
        }
        // Any other (real sign/broadcast) error propagates to the caller's generic handler.
    }

    private func resolvedSatsPerVByte() async -> UInt64 {
        await feeRateProvider() ?? fallbackSatsPerVByte
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
