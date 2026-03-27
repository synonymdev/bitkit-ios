import SwiftUI

struct ChangePinScreen: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var navTitle: String {
        settings.pinEnabled ? t("security__pin_change_title") : t("settings__security__pin")
    }

    var description: String {
        settings.pinEnabled ? t("security__pin_change_text") : t("security__pin_security_text")
    }

    var image: String {
        settings.pinEnabled ? "shield-check-figure" : "shield-figure"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navTitle)
                .padding(.bottom, 16)

            BodyMText(description)

            Spacer()

            Image(image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                if settings.pinEnabled {
                    CustomButton(title: t("security__cp_title"), variant: .secondary) {
                        sheets.showSheet(.security, data: SecurityConfig(initialRoute: .changePin))
                    }
                    .accessibilityIdentifier("ChangePIN")

                    CustomButton(title: t("security__pin_disable_button")) {
                        sheets.showSheet(.security, data: SecurityConfig(initialRoute: .disablePin))
                    }
                    .accessibilityIdentifier("DisablePin")
                } else {
                    CustomButton(title: t("security__pin_enable_button")) {
                        sheets.showSheet(.security, data: SecurityConfig(initialRoute: .setupPin))
                    }
                    .accessibilityIdentifier("EnablePin")
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
