import SwiftUI

/// A section with a caption label, content, and a divider below. Used for form-style rows (e.g. "Send from", "Send to").
struct SendSectionView<Content: View>: View {
    private let title: String
    private let labelLineHeight: CGFloat?
    private let labelKerning: CGFloat
    private let dividerSpacing: CGFloat
    @ViewBuilder private let content: () -> Content

    init(
        _ title: String,
        dividerSpacing: CGFloat = 16,
        labelKerning: CGFloat = 0.8,
        labelLineHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.labelKerning = labelKerning
        self.labelLineHeight = labelLineHeight
        self.dividerSpacing = dividerSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(title, kerning: labelKerning, lineHeight: labelLineHeight)
                .padding(.bottom, 8)

            content()

            CustomDivider()
                .padding(.top, dividerSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
