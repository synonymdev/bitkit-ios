import SwiftUI

struct MultipleWalletsView: View {
    var body: some View {
        VStack(spacing: 0) {
            OnboardingContent(
                imageName: "phone",
                title: NSLocalizedString("onboarding__multiple_header", comment: ""),
                text: NSLocalizedString("onboarding__multiple_text", comment: ""),
                accentColor: .yellow
            )

            CustomButton(title: NSLocalizedString("common__understood", comment: ""), destination: RestoreWalletView())
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    MultipleWalletsView()
        .preferredColorScheme(.dark)
}
