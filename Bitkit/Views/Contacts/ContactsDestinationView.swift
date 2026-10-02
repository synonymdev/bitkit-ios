import SwiftUI

struct ContactsDestinationView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var contactsManager: ContactsManager

    @State private var hasExistingIdentity: Bool?

    var body: some View {
        Group {
            if let hasExistingIdentity {
                if !pubkyProfile.isAuthenticated, hasExistingIdentity {
                    ProfileDestinationView(hasSeenIntro: app.hasSeenProfileIntro)
                } else if !app.hasSeenContactsIntro, contactsManager.contacts.isEmpty {
                    ContactsIntroView()
                } else if pubkyProfile.isAuthenticated {
                    ContactsListView()
                } else if app.hasSeenProfileIntro {
                    PubkyChoiceView()
                } else {
                    ProfileIntroView()
                }
            } else {
                VStack {
                    NavigationBar(title: t("contacts__nav_title"))
                        .padding(.horizontal, 16)
                    Spacer()
                    ActivityIndicator(size: 32)
                        .accessibilityIdentifier("ContactsIdentityLoading")
                    Spacer()
                }
                .background(Color.customBlack)
                .navigationBarHidden(true)
            }
        }
        .task {
            let exists = await pubkyProfile.hasExistingIdentityForNavigation()
            guard !Task.isCancelled else { return }
            hasExistingIdentity = exists
        }
    }
}
