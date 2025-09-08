import SwiftUI

struct ProfileIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("slashtags__profile"),
            title: t("slashtags__onboarding_profile1_header"),
            description: t("slashtags__onboarding_profile1_text"),
            imageName: "crown",
            buttonText: t("common__continue"),
            onButtonPress: {
                app.hasSeenProfileIntro = true
                navigation.navigate(.profile)
            },
            imagePosition: .center,
            testID: "ProfileIntro"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        ProfileIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
