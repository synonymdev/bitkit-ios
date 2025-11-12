import SwiftUI

private struct DismissKeyboardOnReturnModifier: ViewModifier {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { newValue in
                guard isFocused.wrappedValue else { return }
                if newValue.last == "\n" {
                    text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    isFocused.wrappedValue = false
                }
            }
    }
}

extension View {
    func dismissKeyboardOnReturn(text: Binding<String>, isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(DismissKeyboardOnReturnModifier(text: text, isFocused: isFocused))
    }
}
