import SwiftUI

struct TagInputForm: View {
    @Binding var tagText: String
    @FocusState.Binding var isTextFieldFocused: Bool
    var isLoading: Bool = false
    var autoFocus: Bool = true
    var textFieldTestId: String?
    var buttonTestId: String?
    var onSubmit: (String) async -> Void

    private var trimmedTag: String {
        tagText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        CaptionMText(t("wallet__tags_new"))
            .padding(.bottom, 8)

        TextField(
            t("wallet__tags_new_enter"),
            text: $tagText,
            backgroundColor: .white08,
            testIdentifier: textFieldTestId
        )
        .focused($isTextFieldFocused)
        .disabled(isLoading)
        .autocapitalization(.none)
        .autocorrectionDisabled(true)
        .submitLabel(.done)
        .onSubmit {
            if !trimmedTag.isEmpty {
                Task { await onSubmit(trimmedTag) }
            }
        }

        Spacer()

        CustomButton(
            title: t("wallet__tags_add_button"),
            isDisabled: trimmedTag.isEmpty,
            isLoading: isLoading
        ) {
            Task { await onSubmit(trimmedTag) }
        }
        .buttonBottomPadding(isFocused: isTextFieldFocused)
        .accessibilityIdentifierIfPresent(buttonTestId)
        .task {
            if autoFocus {
                isTextFieldFocused = true
            }
        }
    }
}
