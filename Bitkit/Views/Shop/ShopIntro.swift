import SwiftUI

struct ShopIntro: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            title: t("other__shop__intro__title"),
            description: t("other__shop__intro__description"),
            imageName: "bag",
            buttonText: t("other__shop__intro__button"),
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
