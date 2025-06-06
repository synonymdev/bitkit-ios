import SwiftUI

struct SecurityPrivacySettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Privacy Settings Section
                SettingsListLabel(
                    title: NSLocalizedString("settings__security__swipe_balance_to_hide", comment: ""),
                    toggle: $settings.swipeBalanceToHide
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__hide_balance_on_open", comment: ""),
                    toggle: $settings.hideBalanceOnOpen
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__clipboard", comment: ""),
                    toggle: $settings.readClipboard
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__warn_100", comment: ""),
                    toggle: $settings.warnWhenSendingOver100
                )

                //TODO: Place back when contacts are implemented
                // SettingsListLabel(
                //     title: "Show recently paid contacts",
                //     toggle: $settings.showRecentlyPaidContacts
                // )

                // PIN Code Section
                if !settings.pinEnabled {
                    Button {
                        app.showSetupSecuritySheet = true
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin", comment: ""),
                            rightText: NSLocalizedString("settings__security__pin_disabled", comment: "")
                        )
                    }
                } else {
                    //TODO: change to disable pin with a flag in the view
                    NavigationLink(destination: PinChangeView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin", comment: ""),
                            rightText: NSLocalizedString("settings__security__pin_enabled", comment: "")
                        )
                    }
                }

                if settings.pinEnabled {
                    NavigationLink(destination: PinChangeView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin_change", comment: "")
                        )
                    }

                    SettingsListLabel(
                        title: NSLocalizedString("settings__security__pin_launch", comment: ""),
                        toggle: $settings.requirePinOnLaunch
                    )

                    SettingsListLabel(
                        title: NSLocalizedString("settings__security__pin_idle", comment: ""),
                        toggle: $settings.requirePinWhenIdle
                    )

                    SettingsListLabel(
                        title: NSLocalizedString("settings__security__pin_payments", comment: ""),
                        toggle: $settings.requirePinForPayments
                    )

                    SettingsListLabel(
                        title: "Use Face ID instead",
                        toggle: $settings.useFaceIDInstead
                    )

                    // Footer text for Face ID
                    BodyMText(
                        "When enabled, you can use Face ID instead of your PIN to unlock your wallet or send payments.", textColor: .textSecondary
                    )
                    .padding(16)
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings__security__title", comment: ""))
    }
}

#Preview {
    SecurityPrivacySettingsView()
        .environmentObject(SettingsViewModel())
        .preferredColorScheme(.dark)
}
