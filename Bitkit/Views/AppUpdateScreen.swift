import SwiftUI

struct AppUpdateScreen: View {
    var body: some View {
        OnboardingView(
            navTitle: t("other__update_critical_nav_title"),
            title: t("other__update_critical_title"),
            description: t("other__update_critical_text"),
            imageName: "exclamation-mark",
            buttonText: t("other__update_critical_button"),
            showBackButton: false,
            showMenuButton: false,
            onButtonPress: {
                openAppStore()
            },
            imagePosition: .center,
            testID: "CriticalUpdate"
        )
        .navigationBarHidden(true)
    }

    private func openAppStore() {
        UIApplication.shared.open(URL(string: Env.appStoreUrl)!)
    }
}
