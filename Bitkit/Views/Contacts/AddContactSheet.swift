import SwiftUI

struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (String) -> Void
    let onScanQR: () -> Void

    @State private var pubkyInput: String = ""

    private var canAdd: Bool {
        !pubkyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                            "",
                            text: $pubkyInput,
                            backgroundColor: .clear,
                            font: .custom(Fonts.regular, size: 17),
                            testIdentifier: "AddContactPubkyField"
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                pubkyInput = clipboard
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

                    CustomButton(title: t("contacts__add_button")) {
                        onAdd(pubkyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(!canAdd)
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
            AddContactSheet(onAdd: { _ in }, onScanQR: {})
        }
        .preferredColorScheme(.dark)
}
