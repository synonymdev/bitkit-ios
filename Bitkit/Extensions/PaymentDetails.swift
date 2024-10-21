//
//  PaymentDetails.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/04.
//

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
}
