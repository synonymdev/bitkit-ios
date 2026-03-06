import SwiftUI

enum WalletOnboardingType {
    case home
    case savings
    case spending

    var localizationKey: String {
        switch self {
        case .home: return "onboarding__empty_wallet"
        case .savings: return "wallet__savings__onboarding"
        case .spending: return "wallet__spending__onboarding"
        }
    }

    var accentColor: Color {
        switch self {
        case .spending: return .purpleAccent
        case .home, .savings: return .brandAccent
        }
    }
}

struct WalletOnboardingView: View {
    let type: WalletOnboardingType

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            DisplayText(t(type.localizationKey), accentColor: type.accentColor)
                .frame(width: 240)

            Image("empty-state-arrow")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 144)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VStack(spacing: 20) {
        WalletOnboardingView(type: .home)
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))

        WalletOnboardingView(type: .savings)
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))

        WalletOnboardingView(type: .spending)
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))
    }
    .padding()
    .preferredColorScheme(.dark)
}
