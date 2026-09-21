import SwiftUI

/// Asks for the passphrase of the hidden wallet a transfer signs from. Bitkit never stores it, so it
/// is needed again whenever the Trezor session that held it is gone. What is typed stays local to
/// this sheet and is handed straight to the device session.
struct HwPassphrasePromptSheet: View {
    let isVerifying: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__passphrase_title"))

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("hardware__passphrase_header"), accentColor: .blueAccent)

                BodyMText(t("hardware__passphrase_sign_text"))
                    .padding(.top, 8)

                TextField(
                    t("hardware__passphrase_title"),
                    text: $passphrase,
                    testIdentifier: "HwTransferPassphraseInput"
                )
                // A passphrase is case- and character-exact: never let the keyboard alter it.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__cancel"),
                    variant: .secondary,
                    isDisabled: isVerifying,
                    shouldExpand: true
                ) {
                    onCancel()
                }
                .accessibilityIdentifier("HwTransferPassphraseCancel")

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: passphrase.isEmpty || isVerifying,
                    isLoading: isVerifying,
                    shouldExpand: true
                ) {
                    onSubmit(passphrase)
                }
                .accessibilityIdentifier("HwTransferPassphraseContinue")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .presentationDetents([.height(420)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .screenshotPreventMask(true)
        .task { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HwTransferPassphraseSheet")
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            HwPassphrasePromptSheet(isVerifying: false, onSubmit: { _ in }, onCancel: {})
        }
        .preferredColorScheme(.dark)
}
