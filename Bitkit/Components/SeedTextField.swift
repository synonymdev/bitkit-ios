import SwiftUI

struct SeedTextField: View {
    let index: Int
    let text: Binding<String>
    let isLastField: Bool
    @FocusState.Binding var focusedField: Int?

    var body: some View {
        TextField("", text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(height: 47)
            .frame(maxWidth: .infinity)
            .focused($focusedField, equals: index)
            .submitLabel(isLastField ? .done : .next)
            .onSubmit {
                if isLastField {
                    focusedField = nil
                } else {
                    focusedField = index + 1
                }
            }
    }
}
