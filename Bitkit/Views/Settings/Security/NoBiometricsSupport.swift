import SwiftUI

struct NoBiometricsSupport: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var navigateToSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(
                NSLocalizedString("security__bio_not_available", comment: ""),
                textColor: .textSecondary
            )

            Spacer()

            Image("cog")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)

            Spacer()

            HStack(spacing: 8) {
                // Skip button
                CustomButton(
                    title: NSLocalizedString("common__skip", comment: ""),
                    variant: .secondary
                ) {
                    // Set biometrics to false and continue
                    settings.useBiometrics = false
                    navigateToSuccess = true
                }

                // Phone Settings button
                CustomButton(
                    title: NSLocalizedString("security__bio_phone_settings", comment: ""),
                    variant: .primary
                ) {
                    openPhoneSettings()
                }
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(NSLocalizedString("security__bio", comment: ""))
        .navigationDestination(isPresented: $navigateToSuccess) {
            SecuritySetupSuccess()
        }
    }

    private func openPhoneSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}

#Preview {
    NoBiometricsSupport()
        .environmentObject(AppViewModel())
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel())
}
