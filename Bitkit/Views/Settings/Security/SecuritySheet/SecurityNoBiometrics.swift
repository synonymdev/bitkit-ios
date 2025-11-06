import SwiftUI

struct SecurityNoBiometrics: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @Binding var navigationPath: [SecurityRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__bio"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(t("security__bio_not_available"))

                Spacer()

                Image("cog")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)

                Spacer()

                HStack(spacing: 16) {
                    CustomButton(
                        title: t("common__skip"),
                        variant: .secondary
                    ) {
                        // Set biometrics to false and continue
                        settings.useBiometrics = false
                        navigationPath.append(.success)
                    }

                    // Phone Settings button
                    CustomButton(title: t("security__bio_phone_settings")) {
                        openPhoneSettings()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func openPhoneSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}

#Preview {
    SecurityNoBiometrics(navigationPath: .constant([.biometrics]))
        .environmentObject(SettingsViewModel.shared)
}
