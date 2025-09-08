import SwiftUI

struct NotificationsIntro: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    private func onEnable() {
        // Request permission and mark as seen
        NotificationService.shared.requestPushNotificationPermission()
        app.hasSeenNotificationsIntro = true
        navigation.navigate(.notifications)
    }

    var body: some View {
        OnboardingView(
            navTitle: t("settings__notifications__nav_title"),
            title: t("settings__notifications__intro__title"),
            description: t("settings__notifications__intro__text"),
            imageName: "bell-figure",
            buttonText: t("settings__notifications__intro__button"),
            onButtonPress: onEnable,
            accentColor: .blueAccent,
            imagePosition: .center,
            testID: "NotificationsIntro"
        )
        .navigationBarHidden(true)
    }
}
