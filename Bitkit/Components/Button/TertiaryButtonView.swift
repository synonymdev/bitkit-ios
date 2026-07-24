import SwiftUI

struct TertiaryButtonView: View {
    let title: String
    let icon: AnyView?
    let isPressed: Bool
    let labelKerning: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                icon
            }

            BodySSBText(title, textColor: textColor, kerning: labelKerning)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CustomButton.Size.large.height)
        .padding(.horizontal, 16)
        .background(.clear)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        return isPressed ? .textPrimary : .white80
    }
}
