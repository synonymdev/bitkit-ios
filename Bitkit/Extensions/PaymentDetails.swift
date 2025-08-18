import Foundation
import LDKNode

extension PaymentDetails {
    var amountSats: UInt64? {
        if let amountMsat {
            return amountMsat / 1000
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
