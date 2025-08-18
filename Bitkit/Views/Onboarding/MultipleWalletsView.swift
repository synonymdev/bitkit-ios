import SwiftUI

struct MultipleWalletsView: View {
    var body: some View {
        VStack(spacing: 0) {
            OnboardingContent(
                imageName: "phone",
                title: t("onboarding__multiple_header"),
                text: t("onboarding__multiple_text"),
                accentColor: .yellow
            )

            CustomButton(title: t("common__understood"), destination: RestoreWalletView())
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    MultipleWalletsView()
        .preferredColorScheme(.dark)
}
