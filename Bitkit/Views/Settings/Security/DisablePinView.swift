import SwiftUI

struct DisablePinView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(t("security__pin_disable_text"))

            Spacer()

            Image("shield-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)

            Spacer()

            CustomButton(
                title: t("security__pin_disable_button"),
                destination: PinCheckView(
                    title: t("security__pin_enter"),
                    explanation: "",
                    onCancel: {},
                    onPinVerified: { pin in
                        do {
                            try settings.removePin(pin: pin)
                            dismiss()
                        } catch {
                            Logger.error("Failed to remove PIN: \(error)", context: "DisablePinView")
                            // Still dismiss even if there's an error, as the PIN was verified
                            dismiss()
                        }
                    }
                )
            )
        }
        .navigationTitle(t("security__pin_disable_title"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        DisablePinView()
    }
    .preferredColorScheme(.dark)
    .environmentObject(SettingsViewModel())
}
