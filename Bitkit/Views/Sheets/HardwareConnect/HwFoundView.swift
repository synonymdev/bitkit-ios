import SwiftUI

/// Found step: a discovered device with a Connect confirmation. Connect shows a spinner and
/// surfaces an inline error on failure.
struct HwFoundView: View {
    let deviceModel: String
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__found_title"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(t("hardware__found_header"), accentColor: .blueAccent)

                BodyMText(t("hardware__found_text", variables: ["model": deviceModel]))

                if let errorMessage {
                    BodyMText(errorMessage, textColor: .redAccent)
                        .padding(.top, 8)
                        .accessibilityIdentifier("HwFoundError")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)

            Image("trezor")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary, shouldExpand: true) {
                    onCancel()
                }
                .accessibilityIdentifier("HwFoundCancel")

                CustomButton(
                    title: t("common__connect"),
                    isDisabled: isConnecting,
                    isLoading: isConnecting,
                    shouldExpand: true
                ) {
                    onConnect()
                }
                .accessibilityIdentifier("HwFoundConnect")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("HardwareWalletFoundScreen")
    }
}

#Preview {
    HwFoundView(deviceModel: "Trezor Safe 3", isConnecting: false, errorMessage: nil, onConnect: {}, onCancel: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
