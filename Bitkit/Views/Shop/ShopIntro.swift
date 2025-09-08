import SwiftUI

struct ShopIntro: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("other__shop__intro__title"),
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
        .navigationBarHidden(true)
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
