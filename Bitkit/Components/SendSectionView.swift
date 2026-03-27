import SwiftUI

/// A section with a caption label, content, and a divider below. Used for form-style rows (e.g. "Send from", "Send to").
struct SendSectionView<Content: View>: View {
    private let title: String
    @ViewBuilder private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(title)
                .padding(.bottom, 8)

            content()

            CustomDivider()
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
