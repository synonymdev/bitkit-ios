import SwiftUI

/// A section with a caption label, content, and a divider below. Used for form-style rows (e.g. "Send from", "Send to").
struct SendSectionView<Content: View>: View {
    private let title: String
    private let dividerSpacing: CGFloat
    @ViewBuilder private let content: () -> Content

    init(_ title: String, dividerSpacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.dividerSpacing = dividerSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(title)
                .padding(.bottom, 8)

            content()

            CustomDivider()
                .padding(.top, dividerSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
