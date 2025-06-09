import SwiftUI

struct SecuritySetupSuccess: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel

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
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                BodyMText(
                    settings.useBiometrics
                        ? localizedString(
                            "security__success_bio", comment: "",
                            variables: ["biometricsName": biometryTypeName]
                        )
                        : NSLocalizedString("security__success_no_bio", comment: ""),
                    textColor: .textSecondary,
                )
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 48)

            Spacer()

            // Success illustration
            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 274, height: 274)

            Spacer()

            // Payment requirement toggle and button
            VStack(spacing: 24) {
                VStack {
                    HStack {
                        BodyMSBText(
                            NSLocalizedString("security__success_payments", comment: ""),
                            textColor: .textPrimary
                        )

                        Spacer()

                        Toggle("", isOn: $settings.requirePinForPayments)
                            .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                            .labelsHidden()
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .padding(.horizontal, 32)

                // Done button
                CustomButton(
                    title: NSLocalizedString("common__ok", comment: ""),
                    variant: .primary
                ) {
                    app.showSetupSecuritySheet = false
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(NSLocalizedString("security__success_title", comment: ""))
    }
}

#Preview {
    SecuritySetupSuccess()
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel())
}
