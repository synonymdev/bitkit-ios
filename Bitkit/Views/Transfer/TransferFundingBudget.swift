import Foundation
import LDKNode

/// The on-chain ceiling a transfer-to-spending order has to fit under: the spendable balance minus
/// the fee to sweep it at the fast rate. Shared by the amount and advanced screens so sizing and the
/// pre-order re-check use the same calculation.
@MainActor
enum TransferFundingBudget {
    /// Reserved once per screen and reused: each call advances LDK's receive index, and this address
    /// only ever prices a sweep, never receives.
    static func reserveSizingAddress() async throws -> String {
        let addressType = LDKNode.AddressType.fromStorage(UserDefaults.standard.string(forKey: "selectedAddressType"))
        return try await PrivatePaykitAddressReservationStore.shared.nextNonReservedReceiveAddress(addressType: addressType)
    }

    /// Nil when the fee estimates or the sweep calculation are unavailable: sizing then falls back to
    /// a cheaper estimate, while a funding check skips rather than blocks.
    static func onchainBudget(
        address: String,
        feeEstimatesManager: FeeEstimatesManager,
        wallet: WalletViewModel
    ) async -> UInt64? {
        guard let feeEstimates = await feeEstimatesManager.getEstimates(refresh: true) else { return nil }
        let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeEstimates)
        return try? await wallet.calculateMaxSendableAmount(address: address, satsPerVByte: fastFeeRate)
    }
}
