import SwiftUI

/// Searching step of the Connect Hardware flow: the dashed-ring loading animation while scanning for
/// a nearby device, with an inline error message when a scan pass fails.
struct HwSearchingView: View {
    let errorMessage: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__connect_title"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(t("hardware__connect_header"), accentColor: .blueAccent)

                BodyMText(
                    errorMessage ?? t("hardware__connect_text"),
                    textColor: errorMessage != nil ? .redAccent : .textSecondary
                )
                .frame(minHeight: 40, alignment: .top)
                .accessibilityIdentifier(
                    errorMessage != nil ? "HardwareWalletSearchingError" : "HardwareWalletSearchingText"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)

            HwSearchingAnimation()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            CustomButton(title: t("common__cancel"), variant: .secondary, shouldExpand: true) {
                onCancel()
            }
            .accessibilityIdentifier("HardwareWalletSearchingCancel")
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareWalletSearchingScreen")
    }
}

#Preview {
    HwSearchingView(errorMessage: nil, onCancel: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Error") {
    HwSearchingView(errorMessage: t("hardware__search_error"), onCancel: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
