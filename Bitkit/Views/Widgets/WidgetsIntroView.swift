import SwiftUI

struct WidgetsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("widgets__widgets"),
            title: t("widgets__onboarding__title"),
            description: t("widgets__onboarding__description"),
            imageName: "puzzle",
            buttonText: t("common__continue"),
            onButtonPress: {
                app.hasSeenWidgetsIntro = true
                navigation.navigate(.widgetsList)
            },
            imagePosition: .center,
            testID: "WidgetsOnboarding"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    WidgetsIntroView()
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
