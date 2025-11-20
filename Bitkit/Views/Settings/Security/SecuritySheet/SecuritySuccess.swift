import SwiftUI

struct SecuritySuccess: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Binding var navigationPath: [SecurityRoute]

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return t("security__bio_touch_id")
        case .faceID:
            return t("security__bio_face_id")
        default:
            return t("security__bio_face_id") // Default to Face ID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__success_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(
                    settings.useBiometrics
                        ? t(
                            "security__success_bio",
                            variables: ["biometricsName": biometryTypeName]
                        )
                        : t("security__success_no_bio"),
                    textColor: .textSecondary
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
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}

#Preview {
    SecuritySuccess(navigationPath: .constant([.success]))
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel.shared)
}
