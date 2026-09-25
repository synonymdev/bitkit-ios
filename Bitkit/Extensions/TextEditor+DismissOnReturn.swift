import SwiftUI

private struct DismissKeyboardOnReturnModifier: ViewModifier {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, newValue in
                guard isEnabled, isFocused.wrappedValue else { return }
                if newValue.last == "\n" {
                    text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    isFocused.wrappedValue = false
                }
            }
    }
}

extension View {
    func dismissKeyboardOnReturn(text: Binding<String>, isFocused: FocusState<Bool>.Binding, isEnabled: Bool = true) -> some View {
        modifier(DismissKeyboardOnReturnModifier(text: text, isFocused: isFocused, isEnabled: isEnabled))
    }
}
