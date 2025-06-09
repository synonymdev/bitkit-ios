import SwiftUI

struct SavingsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("lightning__savings_intro__title"),
            description: localizedString("lightning__savings_intro__text"),
            imageName: "piggybank-right",
            buttonText: localizedString("lightning__savings_intro__button"),
            onButtonPress: {
                app.hasSeenTransferToSavingsIntro = true
                navigation.navigate(.savingsAvailability)
            },
            imagePosition: .center,
            testID: "SavingsIntro"
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        SavingsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
