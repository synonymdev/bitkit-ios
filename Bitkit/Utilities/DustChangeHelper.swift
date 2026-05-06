import Foundation

/// Helper for detecting dust change during on-chain sends.
enum DustChangeHelper {
    /// Returns true if the expected change would be dust (below dust limit).
    /// - Parameters:
    ///   - totalInput: Total sats from selected UTXOs (or spendable balance)
    ///   - amountSats: Amount to send to recipient
    ///   - normalFee: Fee for a normal send (recipient + change outputs)
    ///   - dustLimit: Minimum non-dust amount (default: Env.dustLimit)
    /// - Returns: true when change would be dust
    static func wouldCreateDustChange(
        totalInput: UInt64,
        amountSats: UInt64,
        normalFee: UInt64,
        dustLimit: UInt64 = UInt64(Env.dustLimit)
    ) -> Bool {
        let expectedChange = Int64(totalInput) - Int64(amountSats) - Int64(normalFee)
        return expectedChange >= 0 && expectedChange < Int64(dustLimit)
    }

    /// Returns true only when the caller is allowed to use sendAll to avoid dust change.
    static func shouldUseSendAllToAvoidDust(
        totalInput: UInt64,
        amountSats: UInt64,
        normalFee: UInt64,
        isMaxAmount: Bool,
        dustLimit: UInt64 = UInt64(Env.dustLimit)
    ) -> Bool {
        isMaxAmount && wouldCreateDustChange(
            totalInput: totalInput,
            amountSats: amountSats,
            normalFee: normalFee,
            dustLimit: dustLimit
        )
    }
}
