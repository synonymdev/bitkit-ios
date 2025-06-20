import SwiftUI

struct ShopIntro: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: localizedString("other__shop__intro__title"),
            description: localizedString("other__shop__intro__description"),
            imageName: "bag",
            buttonText: localizedString("other__shop__intro__button"),
            onButtonPress: {
                app.hasSeenShopIntro = true
                navigation.navigate(.shopDiscover)
            },
            titleColor: .yellowAccent,
            imagePosition: .center,
            testID: "ShopIntro"
        )
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        ShopIntro()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
