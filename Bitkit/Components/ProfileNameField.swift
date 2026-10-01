import SwiftUI

/// Display-caps name input. The stored name keeps its original casing and an uppercased copy is drawn over
/// the field while it is not being edited. `textCase` must stay off the `TextField`: it uppercases the existing
/// text once editing starts and writes that back into the binding.
struct ProfileNameField: View {
    @Binding var name: String
    let accessibilityId: String
    var focusesWhenEmpty = false

    @FocusState private var isFocused: Bool

    private var showsUppercasedName: Bool {
        !isFocused && !name.isEmpty
    }

    var body: some View {
        SwiftUI.TextField(t("profile__create_name_placeholder"), text: $name)
            .font(Fonts.black(size: 44))
            .kerning(-1)
            .multilineTextAlignment(.center)
            .foregroundColor(showsUppercasedName ? .clear : .textPrimary)
            .autocorrectionDisabled()
            .focused($isFocused)
            .overlay {
                if showsUppercasedName {
                    SwiftUI.Text(name.uppercased())
                        .font(Fonts.black(size: 44))
                        .kerning(-1)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier(accessibilityId)
            .task {
                if focusesWhenEmpty, name.isEmpty {
                    isFocused = true
                }
            }
    }
}
