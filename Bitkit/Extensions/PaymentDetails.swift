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
}

extension PaymentKind {
    /// A payment for a BOLT 11 invoice, including one the primary node delivers through a just-in-time channel.
    var isBolt11Invoice: Bool {
        switch self {
        case .bolt11, .bolt11Jit: true
        default: false
        }
    }
}
