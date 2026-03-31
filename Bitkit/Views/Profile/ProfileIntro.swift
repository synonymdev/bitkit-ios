import SwiftUI

struct ProfileIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("profile__nav_title"),
            title: t("profile__intro_title"),
            description: t("profile__intro_description"),
            imageName: "crown",
            buttonText: t("common__continue"),
            onButtonPress: {
                app.hasSeenProfileIntro = true
                navigation.navigate(.pubkyChoice)
            },
            accentColor: .pubkyGreen,
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
    }
    .preferredColorScheme(.dark)
}
