import SwiftUI

struct ProfileIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("slashtags__onboarding_profile1_header"),
            description: localizedString("slashtags__onboarding_profile1_text"),
            imageName: "crown",
            buttonText: localizedString("common__continue"),
            onButtonPress: {
                app.hasSeenProfileIntro = true
                navigation.navigate(.profile)
            },
            imagePosition: .center,
            testID: "ProfileIntro"
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("slashtags__profile"))
        .backToWalletButton()
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
