import SwiftUI

struct NoteTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let testIdentifier: String
    let isFocused: FocusState<Bool>.Binding
    var minHeight: CGFloat = 30
    var maxHeight: CGFloat = 50
    var backgroundColor: Color = .white06
    var allowsLineBreaks = false
    var textKerning: CGFloat?
    var textLineHeight: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                BodySSBText(placeholder, textColor: .textSecondary, kerning: textKerning ?? 0.4, lineHeight: textLineHeight)
            }

            TextEditor(text: $text)
                .focused(isFocused)
                .font(.custom(Fonts.semiBold, size: 15))
                .kerning(textKerning ?? 0)
                .transformEnvironment(\._lineHeightMultiple) { value in
                    if let textLineHeight, let font = UIFont(name: Fonts.semiBold, size: 15) {
                        value = textLineHeight / font.lineHeight
                    }
                }
                .foregroundColor(.textPrimary)
                .accentColor(.brandAccent)
                .submitLabel(allowsLineBreaks ? .return : .done)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: -8, leading: -5, bottom: -5, trailing: -5))
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .dismissKeyboardOnReturn(text: $text, isFocused: isFocused, isEnabled: !allowsLineBreaks)
                .accessibilityValue(text)
                .accessibilityIdentifier(testIdentifier)
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }
}
