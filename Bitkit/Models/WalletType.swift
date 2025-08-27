import Foundation

enum WalletType {
    case onchain
    case lightning

    var title: String {
        switch self {
        case .onchain:
            return t("lightning__savings").uppercased()
        case .lightning:
            return t("lightning__spending").uppercased()
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

    mutating func toggle() {
        self = self == .lightning ? .onchain : .lightning
    }
}
