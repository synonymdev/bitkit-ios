import SwiftUI

struct QuickpayIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: t("settings__quickpay__intro__title"),
            description: t("settings__quickpay__intro__description"),
            imageName: "fast-forward",
            buttonText: t("common__continue"),
            onButtonPress: {
                app.hasSeenQuickpayIntro = true
                navigation.navigate(.quickpay)
            },
            accentColor: .greenAccent,
            imagePosition: .center,
            testID: "QuickpayIntro"
        )
        .navigationTitle(t("settings__quickpay__nav_title"))
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
