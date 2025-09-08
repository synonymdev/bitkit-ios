import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("slashtags__contacts"),
            title: t("slashtags__onboarding_header"),
            description: t("slashtags__onboarding_text"),
            imageName: "group",
            buttonText: t("slashtags__onboarding_button"),
            onButtonPress: {
                app.hasSeenContactsIntro = true
                navigation.navigate(.contacts)
            },
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
            .preferredColorScheme(.dark)
    }
}
