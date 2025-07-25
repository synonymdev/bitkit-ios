import SwiftUI

struct SecuritySuccess: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Binding var navigationPath: [SecurityRoute]

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
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__success_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(
                    settings.useBiometrics
                        ? localizedString(
                            "security__success_bio",
                            variables: ["biometricsName": biometryTypeName]
                        )
                        : localizedString("security__success_no_bio"),
                    textColor: .textSecondary,
                )

                Spacer()

                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)

                Spacer()

                HStack(alignment: .center, spacing: 0) {
                    BodyMSBText(localizedString("security__success_payments"))

                    Spacer()

                    Toggle("", isOn: $settings.requirePinForPayments)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                }
                .padding(.bottom, 32)

                CustomButton(title: localizedString("common__ok")) {
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
        .environmentObject(SettingsViewModel())
}
