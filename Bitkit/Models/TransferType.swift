import Foundation

enum TransferType: String, Codable {
    case toSpending = "TO_SPENDING"
    case toSavings = "TO_SAVINGS"
    case manualSetup = "MANUAL_SETUP"
    case forceClose = "FORCE_CLOSE"
    case coopClose = "COOP_CLOSE"

    func isToSavings() -> Bool {
        switch self {
        case .toSavings, .coopClose, .forceClose:
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
