import BitkitCore
import Foundation

// // Extension to provide LDK-node compatible fee rates
public extension FeeRates {
    func getSatsPerVbyte(for speed: TransactionSpeed) -> UInt32 {
        switch speed {
        case .fast:
            return fast
        case .medium:
            return mid
        case .slow:
            return slow
        case let .custom(customRate):
            return customRate
        }
    }
}
