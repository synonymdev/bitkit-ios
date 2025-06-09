import SwiftUI

struct TransferIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("lightning__transfer_intro__title"),
            description: localizedString("lightning__transfer_intro__text"),
            imageName: "lightning",
            buttonText: localizedString("lightning__transfer_intro__button"),
            onButtonPress: {
                app.hasSeenTransferToSpendingIntro = true
                navigation.navigate(.fundingOptions)
            },
            accentColor: .purpleAccent,
            imagePosition: .center,
            testID: "TransferIntro"
        )
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        TransferIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
