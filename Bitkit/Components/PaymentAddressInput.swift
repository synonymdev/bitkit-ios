import SwiftUI

struct PaymentAddressInput: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let placeholder: String
    let testIdentifier: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                TitleText(placeholder, textColor: .textSecondary).padding(20)
            }
            TextEditor(text: $text)
                .focused(isFocused)
                .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                .padding(20)
                .frame(maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .font(.custom(Fonts.bold, size: 22))
                .foregroundColor(.textPrimary)
                .accentColor(.brandAccent)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .dismissKeyboardOnReturn(text: $text, isFocused: isFocused)
                .accessibilityValue(text)
                .accessibilityIdentifier(testIdentifier)
        }
        .background(Color.white06)
        .cornerRadius(8)
    }
}
