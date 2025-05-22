import SwiftUI

struct SpendingIntroView: View {
    var body: some View {
        VStack {
            OnboardingContent(
                imageName: "coin-stack-x",
                title: NSLocalizedString("lightning__spending_intro__title", comment: ""),
                text: NSLocalizedString("lightning__spending_intro__text", comment: ""),
                accentColor: .purpleAccent
            )

            CustomButton(
                title: NSLocalizedString("lightning__transfer__nav_title", comment: ""),
                destination: FundTransferView()
            )
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        SpendingIntroView()
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
