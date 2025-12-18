import SwiftUI

struct ScannerManualEntryPrompt: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button(action: onCancel) {
                    Image("x-mark")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .accessibilityIdentifier("DialogCancel")
            }

            BodyMSBText(t("other__scan__manual_prompt"))

            SwiftUI.TextField("", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color.white10)
                .cornerRadius(10)
                .accessibilityIdentifier("QRInput")

            CustomButton(title: t("common__yes_proceed"), shouldExpand: true) {
                onSubmit()
            }
            .accessibilityIdentifier("DialogConfirm")

            Spacer()
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("QRDialog")
    }
}
