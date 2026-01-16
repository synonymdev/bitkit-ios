import SwiftUI

struct ComingSoonScreen: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("coming_soon__nav_title"),
            title: t("coming_soon__headline"),
            description: t("coming_soon__description"),
            imageName: "stopwatch",
            buttonText: t("coming_soon__button"),
            onButtonPress: {
                navigation.reset()
            },
            imagePosition: .center,
            testID: "ComingSoon"
        )
        .navigationBarHidden(true)
    }
}
