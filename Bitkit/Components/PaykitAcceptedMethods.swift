import SwiftUI

enum PaykitPaymentOption: String, CaseIterable {
    case savings, spending, usdt

    var asset: PaykitAsset {
        self == .usdt ? .usd : .btc
    }

    var title: String {
        switch self {
        case .savings: t("lightning__savings")
        case .spending: t("lightning__spending")
        case .usdt: "USDT"
        }
    }

    var color: Color {
        switch self {
        case .savings: .brandAccent
        case .spending: .purpleAccent
        case .usdt: .usdtAccent
        }
    }

    func endpoints(in available: [String]) -> [String] {
        available.filter {
            guard let method = PublicPaykitService.MethodId(rawValue: $0) else { return false }
            switch self {
            case .savings: return method.onchainNetwork != nil
            case .spending: return method == .bitcoinLightningBolt11 || method == .bitcoinLightningLnurl
            case .usdt: return method == .usdtArbitrum
            }
        }
    }
}

struct PaykitAcceptedMethods: View {
    let title: String
    let available: [String]
    let selected: [String]
    let identifierPrefix: String
    let onSelect: (PaykitPaymentOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(title, textColor: .white64)
            HStack(spacing: 8) {
                ForEach(PaykitPaymentOption.allCases, id: \.self) { option in
                    let endpoints = option.endpoints(in: available)
                    if !endpoints.isEmpty {
                        let isSelected = endpoints.contains(where: selected.contains)
                        NumberPadActionButton(
                            text: option.title,
                            trailingImageName: isSelected ? "x-mark" : nil,
                            titleKerning: 1, titleLineHeight: 18,
                            color: isSelected ? option.color : .white32,
                            variant: .secondary
                        ) { onSelect(option) }
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityIdentifier("\(identifierPrefix)Accept-\(option.rawValue)")
                    }
                }
            }
        }
    }
}
