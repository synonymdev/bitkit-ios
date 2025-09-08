import SwiftUI

struct SpendingIntroView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("lightning__transfer__nav_title"),
            title: t("lightning__spending_intro__title"),
            description: t("lightning__spending_intro__text"),
            imageName: "coin-stack-x",
            buttonText: t("lightning__spending_intro__button"),
            onButtonPress: {
                navigation.navigate(.spendingAmount)
            },
            accentColor: .purpleAccent,
            imagePosition: .center,
            testID: "SpendingIntro"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        SpendingIntroView()
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
