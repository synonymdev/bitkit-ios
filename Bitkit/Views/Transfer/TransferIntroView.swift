import SwiftUI

struct TransferIntroView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            OnboardingContent(
                imageName: "lightning",
                title: NSLocalizedString("lightning__transfer_intro__title", comment: ""),
                text: NSLocalizedString("lightning__transfer_intro__text", comment: ""),
                accentColor: .purpleAccent
            )

            NavigationLink(destination: FundingOptionsView()) {
                CustomButton(title: NSLocalizedString("lightning__transfer_intro__button", comment: ""))
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    app.hasSeenTransferToSpendingIntro = true
                })
        }
        .padding()
        .onAppear {
            app.showTabBar = false
        }
    }
}

#Preview {
    NavigationView {
        TransferIntroView()
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
