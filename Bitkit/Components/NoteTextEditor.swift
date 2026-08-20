import SwiftUI

struct NoteTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let testIdentifier: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                BodySSBText(placeholder, textColor: .textSecondary)
            }

            TextEditor(text: $text)
                .focused(isFocused)
                .font(.custom(Fonts.semiBold, size: 15))
                .foregroundColor(.textPrimary)
                .accentColor(.brandAccent)
                .submitLabel(.done)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: -8, leading: -5, bottom: -5, trailing: -5))
                .frame(minHeight: 30, maxHeight: 50)
                .dismissKeyboardOnReturn(text: $text, isFocused: isFocused)
                .accessibilityValue(text)
                .accessibilityIdentifier(testIdentifier)
        }
        .padding()
        .background(Color.white06)
        .cornerRadius(8)
    }
}
