import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    var body: some View {
        OnboardingView(
            navTitle: t("contacts__nav_title"),
            title: t("contacts__intro_title"),
            description: t("contacts__intro_description"),
            imageName: "group",
            buttonText: t("common__continue"),
            onButtonPress: {
                app.hasSeenContactsIntro = true
                if pubkyProfile.isAuthenticated {
                    navigation.navigate(.contacts)
                } else if app.hasSeenProfileIntro {
                    navigation.navigate(.pubkyRingAuth)
                } else {
                    navigation.navigate(.profileIntro)
                }
            },
            accentColor: .pubkyGreen,
            imagePosition: .center,
            testID: "ContactsIntro"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        ContactsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .preferredColorScheme(.dark)
    }
}
