import SwiftUI

struct SecuritySuccess: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID: t("security__bio_touch_id")
        default: t("security__bio_face_id")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__success_title"))

            VStack(spacing: 0) {
                BodyMText(
                    settings.useBiometrics
                        ? t("security__success_bio", variables: ["biometricsName": biometryTypeName])
                        : t("security__success_no_bio")
                )

                Spacer()

                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)

                Spacer()

                HStack(alignment: .center, spacing: 0) {
                    BodyMSBText(t("security__success_payments"))

                    Spacer()

                    Toggle("", isOn: $settings.requirePinForPayments)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                        .accessibilityIdentifier("ToggleBioForPayments")
                }
                .padding(.bottom, 32)

                CustomButton(title: t("common__ok")) {
                    sheets.hideSheet()
                    navigation.navigateBack()
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}

#Preview {
    SecuritySuccess()
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel.shared)
}
