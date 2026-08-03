import SwiftUI

struct BottomActionBar<Content: View>: View {
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        horizontalPadding: CGFloat = 16,
        bottomPadding: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.customBlack.opacity(0), .customBlack],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)

            content()
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .background(Color.customBlack)
        }
    }
}
