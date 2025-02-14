import SwiftUI

struct TransferIntro: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "lightning",
                title: NSLocalizedString("lightning__transfer_intro__title", comment: ""),
                text: NSLocalizedString("lightning__transfer_intro__text", comment: ""),
                accentColor: .purpleAccent
            )

            NavigationLink(destination: FundingOptions()) {
                CustomButton(title: NSLocalizedString("lightning__transfer_intro__button", comment: ""))
            }
            .simultaneousGesture(TapGesture().onEnded {
                app.hasSeenTransferIntro = true
            })
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        TransferIntro()
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
