enum WalletType {
    case onchain
    case lightning

    var title: String {
        switch self {
        case .onchain: t("lightning__savings")
        case .lightning: t("lightning__spending")
        }
    }

    var imageAsset: String {
        switch self {
        case .onchain: "btc"
        case .lightning: "ln"
        }
    }

    mutating func toggle() {
        self = self == .lightning ? .onchain : .lightning
    }
}
