import SwiftUI

/// Optional step of the connect flow: the passphrase that unlocks a hidden wallet on the paired
/// device. Bitkit binds it to a fresh Trezor session to read that wallet's accounts and never stores
/// it, so it is asked for again whenever the session has to be rebuilt.
struct HwPassphraseView: View {
    @Binding var passphrase: String
    let isSubmitting: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onContinue: () -> Void

    /// Shield width as a fraction of the sheet, matching the other steps' illustration sizing.
    private let shieldWidthRatio: CGFloat = 256.0 / 375.0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__passphrase_title"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("hardware__passphrase_header"), accentColor: .blueAccent)

                BodyMText(t("hardware__passphrase_text"))
                    .padding(.top, 8)

                TextField(
                    t("hardware__passphrase_title"),
                    text: $passphrase,
                    testIdentifier: "HardwareWalletPassphraseInput"
                )
                // A passphrase is case- and character-exact: never let the keyboard alter it.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.top, 32)

                if let errorMessage {
                    BodyMText(errorMessage, textColor: .redAccent)
                        .padding(.top, 16)
                        .accessibilityIdentifier("HwPassphraseError")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)

            GeometryReader { geo in
                Image("shield-figure")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * shieldWidthRatio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__back"),
                    variant: .secondary,
                    isDisabled: isSubmitting,
                    shouldExpand: true
                ) {
                    onBack()
                }
                .accessibilityIdentifier("HardwareWalletPassphraseBack")

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: passphrase.isEmpty || isSubmitting,
                    isLoading: isSubmitting,
                    shouldExpand: true
                ) {
                    onContinue()
                }
                .accessibilityIdentifier("HardwareWalletPassphraseContinue")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .screenshotPreventMask(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareWalletPassphraseScreen")
    }
}

#Preview("Entering") {
    HwPassphraseView(
        passphrase: .constant("satoshirulestheworld"),
        isSubmitting: false,
        errorMessage: nil,
        onBack: {},
        onContinue: {}
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Rejected") {
    HwPassphraseView(
        passphrase: .constant(""),
        isSubmitting: false,
        errorMessage: t("hardware__passphrase_duplicate"),
        onBack: {},
        onContinue: {}
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
