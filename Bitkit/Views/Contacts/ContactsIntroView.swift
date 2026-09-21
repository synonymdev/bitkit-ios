import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    var body: some View {
        OnboardingView(
            navTitle: t("contacts__nav_title"),
            title: t("contacts__intro_title"),
            description: t("contacts__intro_description"),
            imageName: "group",
            buttonText: t("contacts__intro_add_contact"),
            onButtonPress: {
                app.hasSeenContactsIntro = true
                if pubkyProfile.isAuthenticated {
                    contactsManager.shouldOpenAddContactSheet = true
                    navigation.navigate(.contacts)
                } else if app.hasSeenProfileIntro {
                    navigation.navigate(.pubkyChoice)
                } else {
                    navigation.navigate(.profileIntro)
                }
            },
            accentColor: .pubkyGreen,
            imagePosition: .center,
            titleDescriptionSpacing: 8,
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
            .environmentObject(ContactsManager())
            .preferredColorScheme(.dark)
    }
}
