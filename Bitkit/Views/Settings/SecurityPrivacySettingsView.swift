import SwiftUI

struct SecurityPrivacySettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return NSLocalizedString("security__bio_touch_id", comment: "")
        case .faceID:
            return NSLocalizedString("security__bio_face_id", comment: "")
        default:
            return NSLocalizedString("security__bio_face_id", comment: "") // Default to Face ID
        }
    }

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
                        sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin", comment: ""),
                            rightText: NSLocalizedString("settings__security__pin_disabled", comment: "")
                        )
                    }
                } else {
                    NavigationLink(destination: DisablePinView()) {
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
                        title: localizedString(
                            "settings__security__use_bio", comment: "",
                            variables: ["biometryTypeName": biometryTypeName]),
                        toggle: $settings.useBiometrics
                    )

                    // Footer text for Biometrics
                    BodyMText(
                        localizedString(
                            "settings__security__footer", comment: "",
                            variables: ["biometryTypeName": biometryTypeName]),
                        textColor: .textSecondary
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
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel())
        .preferredColorScheme(.dark)
}
