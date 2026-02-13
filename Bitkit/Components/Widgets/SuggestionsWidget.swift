import SwiftUI

struct SuggestionsWidget: View {
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?
    /// When true, only two cards are shown and taps do nothing (e.g. detail preview).
    var isPreview: Bool = false

    var body: some View {
        BaseWidget(
            type: .suggestions,
            isEditing: isEditing,
            hasBackground: false,
            onEditingEnd: onEditingEnd
        ) {
            Suggestions(isPreview: isPreview)
        }
    }
}
