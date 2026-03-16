import SwiftUI

struct ChangePinScreen: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var navTitle: String {
        settings.pinEnabled ? t("security__pin_disable_title") : t("settings__security__pin")
    }

    var description: String {
        settings.pinEnabled ? t("security__pin_disable_text") : t("security__pin_security_text")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navTitle)
                .padding(.bottom, 16)

            BodyMText(description)

            Spacer()

            Image("shield-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                if settings.pinEnabled {
                    CustomButton(title: t("security__cp_title"), variant: .secondary) {
                        sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                    }
                    .accessibilityIdentifier("PINCode")

                    CustomButton(title: t("security__pin_disable_button")) {
                        sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                    }
                    .accessibilityIdentifier("DisablePin")
                } else {
                    CustomButton(title: t("security__pin_enable_button")) {
                        sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                    }
                    .accessibilityIdentifier("EnablePin")
                }
            }

            // CustomButton(
            //     title: t("security__pin_disable_button"),
            //     destination: PinCheckView(
            //         title: t("security__pin_enter"),
            //         explanation: "",
            //         onCancel: {},
            //         onPinVerified: { pin in
            //             do {
            //                 try settings.removePin(pin: pin)
            //                 dismiss()
            //             } catch {
            //                 Logger.error("Failed to remove PIN: \(error)", context: "DisablePinView")
            //                 // Still dismiss even if there's an error, as the PIN was verified
            //                 dismiss()
            //             }
            //         }
            //     )
            // )
            // .accessibilityIdentifier("DisablePin")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
