import SwiftUI

struct TertiaryButtonView: View {
    let title: String
    var titleKerning: CGFloat = 0.4
    var titleLineHeight: CGFloat?
    let icon: AnyView?
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                icon
            }

            BodySSBText(title, textColor: textColor, kerning: titleKerning, lineHeight: titleLineHeight)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(minHeight: CustomButton.Size.large.height)
        .padding(.horizontal, 16)
        .background(.clear)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        return isPressed ? .textPrimary : .white80
    }
}
