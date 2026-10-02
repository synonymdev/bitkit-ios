import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var isRouting = false

    var body: some View {
        OnboardingView(
            navTitle: t("contacts__nav_title"),
            title: t("contacts__intro_title"),
            description: t("contacts__intro_description"),
            imageName: "group",
            buttonText: t("contacts__intro_add_contact"),
            onButtonPress: {
                guard !isRouting else { return }
                isRouting = true
            },
            accentColor: .pubkyGreen,
            imagePosition: .center,
            titleDescriptionSpacing: 8,
            testID: "ContactsIntro"
        )
        .navigationBarHidden(true)
        .task(id: isRouting) {
            guard isRouting else { return }
            defer { isRouting = false }
            await Self.openContacts(app: app, navigation: navigation, pubkyProfile: pubkyProfile, contactsManager: contactsManager)
        }
        .onChange(of: navigation.path) { _, _ in
            isRouting = false
        }
    }

    static func openContacts(
        app: AppViewModel,
        navigation: NavigationViewModel,
        pubkyProfile: PubkyProfileManager,
        contactsManager: ContactsManager
    ) async {
        let origin = navigation.path
        let hasExistingIdentity = await pubkyProfile.hasExistingIdentityForNavigation()
        guard !Task.isCancelled, navigation.path == origin else { return }
        app.hasSeenContactsIntro = true
        if pubkyProfile.isAuthenticated {
            contactsManager.shouldOpenAddContactSheet = true
            navigation.navigate(.contacts)
        } else if hasExistingIdentity {
            navigation.navigate(.contacts)
        } else {
            navigation.navigate(app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro)
        }
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
