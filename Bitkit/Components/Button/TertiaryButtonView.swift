import SwiftUI

struct TertiaryButtonView: View {
    let title: String
    let icon: AnyView?
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                icon
            }

            BodySSBText(title, textColor: textColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CustomButton.Size.large.height)
        .padding(.horizontal, CustomButton.Size.large.horizontalPadding)
        .background(.clear)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        return isPressed ? .textPrimary : .white80
    }
}
