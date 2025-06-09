import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("slashtags__onboarding_header"),
            description: localizedString("slashtags__onboarding_text"),
            imageName: "group",
            buttonText: localizedString("slashtags__onboarding_button"),
            onButtonPress: {
                app.hasSeenContactsIntro = true
                navigation.navigate(.contacts)
            },
            imagePosition: .center,
            testID: "ContactsIntro"
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("slashtags__contacts"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        ContactsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
