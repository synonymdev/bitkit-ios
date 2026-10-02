import SwiftUI

/// Found step: a discovered device with a Connect confirmation. Connect shows a spinner and
/// surfaces an inline error on failure. A Jade waiting for its PIN adds a hint to enter it on the
/// device; Cancel stays available throughout, so the user can back out of the PIN wait.
struct HwFoundView: View {
    let deviceModel: String
    var vendor: HwWalletVendor = .trezor
    let isConnecting: Bool
    var isUnlocking = false
    let errorMessage: String?
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__found_title"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(vendor.foundHeader, accentColor: .blueAccent)

                BodyMText(t("hardware__found_text", variables: ["model": deviceModel]))

                if isUnlocking {
                    BodySText(t("hardware__jade_enter_pin"), textColor: .textPrimary)
                        .padding(.top, 8)
                        .transition(.opacity)
                        .accessibilityIdentifier("HwFoundUnlockHint")
                }

                if let errorMessage {
                    BodyMText(errorMessage, textColor: .redAccent)
                        .padding(.top, 8)
                        .accessibilityIdentifier("HwFoundError")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.2), value: isUnlocking)

            Image(vendor.deviceImageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary, shouldExpand: true) {
                    onCancel()
                }
                .accessibilityIdentifier("HardwareWalletFoundCancel")

                CustomButton(
                    title: t("common__connect"),
                    isDisabled: isConnecting,
                    isLoading: isConnecting,
                    shouldExpand: true
                ) {
                    onConnect()
                }
                .accessibilityIdentifier("HardwareWalletFoundConnect")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareWalletFoundScreen")
    }
}

#Preview {
    HwFoundView(deviceModel: "Trezor Safe 3", isConnecting: false, errorMessage: nil, onConnect: {}, onCancel: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Jade unlocking") {
    HwFoundView(
        deviceModel: "Jade",
        vendor: .blockstream,
        isConnecting: true,
        isUnlocking: true,
        errorMessage: nil,
        onConnect: {},
        onCancel: {}
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
