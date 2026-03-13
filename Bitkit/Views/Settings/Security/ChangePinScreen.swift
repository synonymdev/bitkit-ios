import SwiftUI

struct ChangePinScreen: View {
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("security__pin_disable_title"))
                .padding(.bottom, 16)

            BodyMText(t("security__pin_disable_text"))

            Spacer()

            Image("shield-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                CustomButton(title: "Test", variant: .secondary) {
                    sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                }
                .accessibilityIdentifier("PINCode")

                CustomButton(title: t("security__pin_disable_button")) {
                    sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                }
                .accessibilityIdentifier("DisablePin")
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
