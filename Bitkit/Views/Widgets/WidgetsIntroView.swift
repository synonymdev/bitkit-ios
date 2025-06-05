import SwiftUI

struct WidgetsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("widgets__onboarding__title"),
            description: localizedString("widgets__onboarding__description"),
            imageName: "puzzle",
            buttonText: localizedString("common__continue"),
            onButtonPress: {
                app.hasSeenWidgetsIntro = true
                navigation.navigate(.widgetsList)
            },
            imagePosition: .center,
            testID: "WidgetsIntro"
        )
        .backToWalletButton()
    }
}

#Preview {
    WidgetsIntroView()
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
