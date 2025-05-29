import SwiftUI

struct SecurityPrivacySettingsView: View {
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

                SettingsListLabel(
                    title: "Show recently paid contacts",
                    toggle: $settings.showRecentlyPaidContacts
                )

                // PIN Code Section
                Button(action: {
                    // TODO: Navigate to PIN settings
                }) {
                    SettingsListLabel(
                        title: NSLocalizedString("settings__security__pin", comment: ""),
                        rightText: settings.hasPinEnabled
                            ? NSLocalizedString("settings__security__pin_enabled", comment: "")
                            : NSLocalizedString("settings__security__pin_disabled", comment: "")
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    // TODO: Navigate to change PIN
                }) {
                    SettingsListLabel(
                        title: NSLocalizedString("settings__security__pin_change", comment: "")
                    )
                }
                .buttonStyle(PlainButtonStyle())

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
                BodyMText("When enabled, you can use Face ID instead of your PIN to unlock your wallet or send payments.", textColor: .textSecondary)
                    .padding(16)
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
