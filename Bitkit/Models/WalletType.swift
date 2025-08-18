import Foundation

enum WalletType {
    case onchain
    case lightning

    var title: String {
        switch self {
        case .onchain:
            return NSLocalizedString("lightning__savings", comment: "").uppercased()
        case .lightning:
            return NSLocalizedString("lightning__spending", comment: "").uppercased()
        }
    }

    var imageAsset: String {
        switch self {
        case .onchain:
            return "btc"
        case .lightning:
            return "ln"
        }
    }
}
