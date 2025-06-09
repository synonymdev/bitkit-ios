import SwiftUI

struct QuickpayIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("settings__quickpay__intro__title"),
            description: localizedString("settings__quickpay__intro__description"),
            imageName: "fast-forward",
            buttonText: localizedString("common__continue"),
            onButtonPress: {
                app.hasSeenQuickpayIntro = true
                navigation.navigate(.quickpay)
            },
            accentColor: .greenAccent,
            imagePosition: .center,
            testID: "QuickpayIntro"
        )
        .navigationTitle(localizedString("settings__quickpay__nav_title"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        QuickpayIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
