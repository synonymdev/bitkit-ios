import Foundation

enum TransferType: String, Codable {
    case toSpending = "TO_SPENDING"
    case toSavings = "TO_SAVINGS"
    case manualSetup = "MANUAL_SETUP"
    case forceClose = "FORCE_CLOSE"
    case coopClose = "COOP_CLOSE"
    /// The Spark balance leaving on-chain without the Spark operators.
    case sparkExit = "SPARK_EXIT"

    func isToSavings() -> Bool {
        switch self {
        case .toSavings, .coopClose, .forceClose, .sparkExit:
            return true
        default:
            return false
        }
    }

    func isToSpending() -> Bool {
        switch self {
        case .toSpending, .manualSetup:
            return true
        default:
            return false
        }
    }
}
