import SwiftUI

struct NotificationsSettings: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var notificationManager: PushNotificationManager

    var text: String {
        if settings.enableNotifications {
            return t("settings__notifications__settings__enabled")
        } else {
            return t("settings__notifications__settings__disabled")
        }
    }

    var buttonTitle: String {
        if notificationManager.authorizationStatus == .denied {
            return t("settings__notifications__settings__button__disabled", variables: ["platform": "iOS"])
        } else {
            return t("settings__notifications__settings__button__enabled", variables: ["platform": "iOS"])
        }
    }

    var isDenied: Bool {
        return notificationManager.authorizationStatus == .denied
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NavigationBar(title: t("settings__notifications__nav_title"))

                SettingsListLabel(
                    title: t("settings__notifications__settings__toggle"),
                    toggle: $settings.enableNotifications,
                    disabled: isDenied
                )
                .padding(.top, 16)

                if isDenied {
                    BodyMBoldText(t("settings__notifications__settings__denied"), textColor: .redAccent)
                        .padding(.top, 16)
                } else {
                    BodyMText(text)
                        .padding(.top, 16)
                }

                NotificationPreview(disabled: !settings.enableNotifications, enableAmount: settings.enableNotificationsAmount)
                    .padding(.top, 16)

                if !isDenied {
                    CaptionMText(t("settings__notifications__settings__privacy__label"))
                        .padding(.top, 32)

                    SettingsListLabel(
                        title: t("settings__notifications__settings__privacy__text"),
                        toggle: $settings.enableNotificationsAmount
                    )
                }

                CaptionMText(t("settings__notifications__settings__notifications__label"))
                    .padding(.top, 32)

                if isDenied {
                    BodyMText(t("settings__notifications__settings__notifications__text"))
                        .padding(.top, 16)
                }

                CustomButton(
                    title: buttonTitle,
                    variant: .secondary,
                    icon: Image("bell"),
                    action: {
                        openPhoneSettings()
                    }
                )
                .padding(.top, 16)

                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
    }

    private func openPhoneSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}
