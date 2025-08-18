import SwiftUI

enum EmptyStateType {
    case home
    case savings
    case spending

    var localizationKey: String {
        switch self {
        case .home:
            return "onboarding__empty_wallet"
        case .savings:
            return "wallet__savings__onboarding"
        case .spending:
            return "wallet__spending__onboarding"
        }
    }

    var accentColor: Color {
        switch self {
        case .spending:
            return .purpleAccent
        case .home, .savings:
            return .brandAccent
        }
    }
}

struct EmptyStateView: View {
    let type: EmptyStateType
    var onClose: (() -> Void)?

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 0) {
                DisplayText(
                    t(type.localizationKey),
                    accentColor: type.accentColor
                )
                .frame(width: 224)

                Image("empty-state-arrow")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 144)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 115)
            .overlay {
                if let onClose {
                    VStack {
                        Button(action: {
                            Haptics.play(.buttonTap)
                            onClose()
                        }) {
                            Image("x-mark")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(.textSecondary)
                                .frame(width: 16, height: 16)
                        }
                        .frame(width: 44, height: 44)
                        .offset(x: 16, y: -16)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        EmptyStateView(type: .home, onClose: {})
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))

        EmptyStateView(type: .savings, onClose: {})
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))

        EmptyStateView(type: .spending, onClose: {})
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))
    }
    .padding()
    .preferredColorScheme(.dark)
}
