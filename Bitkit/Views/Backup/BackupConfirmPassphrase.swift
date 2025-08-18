import SwiftUI

struct BackupConfirmPassphrase: View {
    @Binding var navigationPath: [BackupRoute]
    let passphrase: String

    @State private var enteredText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__pass_confirm"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(t("security__pass_confirm_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)

                TextField(t("security__pass").capitalized, text: $enteredText)
                    .focused($isTextFieldFocused)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .submitLabel(.done)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: t("common__continue"),
                        isDisabled: enteredText != passphrase,
                    ) {
                        navigationPath.append(.reminder)
                    }
                }
                .padding(.top, 32)
            }.padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Auto-focus the text field when the view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isTextFieldFocused = true
            }
        }
    }
}
