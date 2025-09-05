import SwiftUI

struct SavingsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("lightning__transfer__nav_title"),
            title: t("lightning__savings_intro__title"),
            description: t("lightning__savings_intro__text"),
            imageName: "piggybank-right",
            buttonText: t("lightning__savings_intro__button"),
            onButtonPress: {
                app.hasSeenTransferToSavingsIntro = true
                navigation.navigate(.savingsAvailability)
            },
            imagePosition: .center,
            testID: "SavingsIntro"
        )
        .navigationBarHidden(true)
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
