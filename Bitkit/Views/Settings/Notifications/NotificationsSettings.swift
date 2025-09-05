import SwiftUI

struct NotificationsSettings: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    var text: String {
        if settings.notificationServerRegistered {
            return t("settings__notifications__settings__enabled")
        } else {
            return t("settings__notifications__settings__disabled")
        }
    }

    var buttonTitle: String {
        if settings.notificationAuthorizationStatus == .denied {
            return t("settings__notifications__settings__button__disabled", variables: ["platform": "iOS"])
        } else {
            return t("settings__notifications__settings__button__enabled", variables: ["platform": "iOS"])
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NavigationBar(title: t("settings__notifications__nav_title"))

                SettingsListLabel(
                    title: t("settings__notifications__settings__toggle"),
                    toggle: Binding(
                        get: { settings.notificationServerRegistered },
                        set: { newValue in
                            if newValue {
                                // Enable notifications (request permission and register)
                                NotificationService.shared.requestPushNotificationPermission()
                            } else {
                                // Disable notifications (unregister)
                                NotificationService.shared.unregisterFromRemoteNotifications()
                                // Optionally unregister from server when endpoint is available
                                Task {
                                    try? await NotificationService.shared.unregisterFromServer()
                                }
                                // Update the state immediately since we're unregistering
                                settings.notificationServerRegistered = false
                            }
                        }
                    ),
                    disabled: settings.notificationAuthorizationStatus == .denied
                )
                .padding(.top, 16)

                if settings.notificationAuthorizationStatus == .denied {
                    BodyMBoldText(t("settings__notifications__settings__denied"), textColor: .redAccent)
                        .padding(.top, 16)
                }

                if settings.notificationAuthorizationStatus != .denied {
                    BodyMText(text)
                        .padding(.top, 16)
                }

                NotificationPreview(
                    disabled: !settings.notificationServerRegistered,
                    enableAmount: settings.enableNotificationsAmount
                )
                .padding(.top, 16)

                if settings.notificationAuthorizationStatus != .denied {
                    VStack(alignment: .leading, spacing: 16) {
                        CaptionText(
                            t("settings__notifications__settings__privacy__label").uppercased(),
                        )
                    }
                    .padding(.top, 32)

                    SettingsListLabel(
                        title: t("settings__notifications__settings__privacy__text"),
                        toggle: $settings.enableNotificationsAmount
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    CaptionText(
                        t("settings__notifications__settings__notifications__label").uppercased(),
                    )
                }
                .padding(.top, 32)

                if settings.notificationAuthorizationStatus == .denied {
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
        .onAppear {
            settings.checkNotificationPermission()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                settings.checkNotificationPermission()
            }
        }
    }

    private func openPhoneSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }

    private struct NotificationPreview: View {
        var disabled: Bool
        var enableAmount: Bool

        var amountText: String {
            if enableAmount {
                return "₿ 21 000 ($21.00)"
            } else {
                return t("settings__notifications__settings__preview__text")
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image("app-icon")
                    .resizable()
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(t("settings__notifications__settings__preview__title"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: 0x222222))
                        Spacer()
                        Text(t("settings__notifications__settings__preview__time"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: 0x3F3F3F).opacity(0.5))
                    }

                    Text(amountText)
                        .font(.system(size: 15))
                        .foregroundColor(Color(hex: 0x3F3F3F))
                }
            }
            .padding(9)
            .background(Color.white80)
            .cornerRadius(16)
            .overlay(disabled ? Color.black.opacity(0.7) : Color.clear)
        }
    }
}
