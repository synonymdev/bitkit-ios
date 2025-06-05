import SwiftUI

struct SpendingIntroView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("lightning__spending_intro__title"),
            description: localizedString("lightning__spending_intro__text"),
            imageName: "coin-stack-x",
            buttonText: localizedString("lightning__spending_intro__button"),
            onButtonPress: {
                navigation.navigate(.fundingOptions)
            },
            accentColor: .purpleAccent,
            imagePosition: .center,
            testID: "SpendingIntro"
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        SpendingIntroView()
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
