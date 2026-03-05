import Foundation

/// Helper for determining when to use sendAll to avoid creating dust change outputs.
enum DustChangeHelper {
    /// Returns true if the expected change would be dust (below dust limit), so sendAll should be used.
    /// - Parameters:
    ///   - totalInput: Total sats from selected UTXOs (or spendable balance)
    ///   - amountSats: Amount to send to recipient
    ///   - normalFee: Fee for a normal send (recipient + change outputs)
    ///   - dustLimit: Minimum non-dust amount (default: Env.dustLimit)
    /// - Returns: true when change would be dust and sendAll should be used
    static func shouldUseSendAllToAvoidDust(
        totalInput: UInt64,
        amountSats: UInt64,
        normalFee: UInt64,
        dustLimit: UInt64 = UInt64(Env.dustLimit)
    ) -> Bool {
        let expectedChange = Int64(totalInput) - Int64(amountSats) - Int64(normalFee)
        return expectedChange >= 0 && expectedChange < Int64(dustLimit)
    }
}
