import SwiftUI

struct TransferIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack {
            OnboardingContent(
                imageName: "lightning",
                title: localizedString("lightning__transfer_intro__title"),
                text: localizedString("lightning__transfer_intro__text"),
                accentColor: .purpleAccent
            )

            CustomButton(title: localizedString("lightning__transfer_intro__button")) {
                app.hasSeenTransferToSpendingIntro = true
                navigation.navigate(.fundingOptions)
            }
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        TransferIntroView()
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
