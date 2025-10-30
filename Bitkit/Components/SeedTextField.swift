import BitkitCore
import SwiftUI

struct SeedTextField: View {
    let index: Int
    let text: Binding<String>
    let isLastField: Bool
    @FocusState.Binding var focusedField: Int?

    private var isFocused: Bool {
        focusedField == index
    }

    private var font: Font {
        isFocused ? .custom(Fonts.semiBold, size: 17) : .custom(Fonts.regular, size: 17)
    }

    private var labelColor: Color {
        let word = text.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !isFocused && !word.isEmpty && !isValidBip39Word(word: word) {
            return .redAccent
        }
        return .textSecondary
    }

    private var textColor: Color {
        let word = text.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !isFocused && !word.isEmpty && !isValidBip39Word(word: word) {
            return .redAccent
        }
        return .textPrimary
    }

    var body: some View {
        HStack(spacing: 0) {
            BodyMSBText("\(index + 1).", textColor: labelColor)
                .frame(width: 26, alignment: .leading)

            SwiftUI.TextField("", text: text)
                .accentColor(.brandAccent)
                .font(font)
                .foregroundColor(textColor)
                .kerning(0.4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(height: 47)
                .focused($focusedField, equals: index)
                .submitLabel(isLastField ? .done : .next)
                .onSubmit {
                    focusedField = isLastField ? nil : index + 1
                }
                .accessibilityIdentifier("Word-\(index)")
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 16)
        .background(Color.white10)
        .cornerRadius(8)
    }
}
