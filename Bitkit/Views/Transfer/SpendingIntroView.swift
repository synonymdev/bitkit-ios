import SwiftUI

struct SpendingIntroView: View {
    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "coin-stack-x",
                title: NSLocalizedString("lightning__spending_intro__title", comment: ""),
                text: NSLocalizedString("lightning__spending_intro__text", comment: ""),
                accentColor: .purpleAccent
            )

            NavigationLink(destination: FundTransferView()) {
                CustomButton(title: NSLocalizedString("lightning__transfer__nav_title", comment: ""))
            }
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
