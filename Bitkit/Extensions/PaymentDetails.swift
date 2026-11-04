import Foundation
import LDKNode

extension PaymentDetails {
    var amountSats: UInt64? {
        if let amountMsat {
            return LightningAmountConversion.satsCeil(fromMsats: amountMsat)
        }

        return nil
    }

    var statusDebugEmoji: String {
        switch status {
        case .failed:
            return "❌"
        case .pending:
            return "⏳"
        case .succeeded:
            return "✅"
        }
    }

    var creationTime: Date {
        // LDKNode timestamps are in seconds since Unix epoch
        Date(timeIntervalSince1970: TimeInterval(latestUpdateTimestamp))
    }

    /// The status of this payment if it is one this wallet sent of the Lightning invoice with this hash, or nil otherwise.
    func outboundPaymentStatus(paymentHash: String) -> PaymentStatus? {
        guard direction == .outbound, case let .bolt11(hash, _, _, _, _) = kind, hash == paymentHash else { return nil }
        return status
    }
}
