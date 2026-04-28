import SwiftUI

struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentPublicKey: String?
    let onAdd: (String) -> Void
    let onScanQR: () -> Void

    @State private var pubkyInput: String = ""

    private var validationResult: AddContactValidationResult {
        resolveAddContactValidation(input: pubkyInput, ownPublicKey: currentPublicKey)
    }

    private var validationMessage: String? {
        validationResult.localizedMessage
    }

    private var canAdd: Bool {
        if case .valid = validationResult {
            return true
        }

        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("contacts__add_title"))

            VStack(alignment: .leading, spacing: 16) {
                BodyMText(t("contacts__add_description"))

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("contacts__add_pubky_label"), textColor: .white64)

                    HStack(spacing: 8) {
                        TextField(
                            t("contacts__add_pubky_placeholder"),
                            text: $pubkyInput,
                            backgroundColor: .clear,
                            font: .custom(Fonts.regular, size: 17),
                            testIdentifier: "AddContactPubkyField"
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .onChange(of: pubkyInput) { _, newValue in
                            let boundedInput = PubkyPublicKeyFormat.bounded(newValue)
                            if boundedInput != newValue {
                                pubkyInput = boundedInput
                            }
                        }

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                pubkyInput = PubkyPublicKeyFormat.bounded(clipboard)
                            }
                        } label: {
                            Image("clipboard")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.white64)
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityIdentifier("AddContactPaste")
                        .accessibilityLabel(t("common__paste"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white08)
                    .cornerRadius(8)

                    if let validationMessage {
                        BodySText(validationMessage, textColor: .redAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 16) {
                    CustomButton(
                        title: t("contacts__add_scan_qr"),
                        variant: .secondary,
                        icon: Image(systemName: "viewfinder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white80)
                    ) {
                        onScanQR()
                        dismiss()
                    }
                    .accessibilityIdentifier("AddContactScanQR")

                    CustomButton(title: t("contacts__add_button"), isDisabled: !canAdd) {
                        guard case let .valid(normalizedKey) = validationResult else {
                            return
                        }

                        onAdd(normalizedKey)
                        dismiss()
                    }
                    .accessibilityIdentifier("AddContactAdd")
                }
            }
            .padding(.horizontal, 16)
        }
        .sheetBackground()
        .presentationDetents([.medium])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.hidden)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AddContactSheet(currentPublicKey: nil, onAdd: { _ in }, onScanQR: {})
        }
        .preferredColorScheme(.dark)
}
