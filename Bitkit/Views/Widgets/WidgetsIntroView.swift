import SwiftUI

struct WidgetsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            OnboardingContent(
                imageName: "puzzle",
                title: localizedString("widgets__onboarding__title"),
                text: localizedString("widgets__onboarding__description"),
                accentColor: .brandAccent
            )

            CustomButton(title: localizedString("common__continue")) {
                app.hasSeenWidgetsIntro = true
                navigation.navigate(.widgetsList)
            }
        }
        .padding(.horizontal, 32)
        .backToWalletButton()
    }
}

#Preview {
    WidgetsIntroView()
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
