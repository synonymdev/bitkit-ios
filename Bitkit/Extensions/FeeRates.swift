// //
// //  BitkitFeeRate.swift
// //  Bitkit
// //
// //  Created by Jason van den Berg on 2025/05/01.
// //

import Foundation

// // Extension to provide LDK-node compatible fee rates
extension FeeRates {
    public func getSatsPerVbyte(for speed: TransactionSpeed) -> UInt32 {
        switch speed {
        case .fast:
            return self.fast
        case .medium:
            return self.mid
        case .slow:
            return self.slow
        case .custom(let customRate):
            return customRate
        }
    }
}
