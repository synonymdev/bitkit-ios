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
    var onClose: () -> Void

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 0) {
                DisplayText(
                    NSLocalizedString(type.localizationKey, comment: ""),
                    accentColor: type.accentColor
                )
                .frame(width: 224)

                Image("empty-state-arrow")
                    .resizable()
                    .scaledToFit()
                    .padding(.leading, 4)
                    .frame(maxHeight: 144)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 100)
            .overlay {
                VStack {
                    Button(action: {
                        Haptics.play(.buttonTap)
                        onClose()
                    }) {
                        Image("x-mark")
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16, alignment: .topTrailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    Spacer()
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
