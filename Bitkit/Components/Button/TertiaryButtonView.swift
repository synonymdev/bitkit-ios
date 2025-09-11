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

            BodySSBText(title, textColor: foregroundColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CustomButton.Size.large.height)
        .padding(.horizontal, CustomButton.Size.large.horizontalPadding)
        .background(.clear)
        .cornerRadius(CustomButton.Size.large.cornerRadius)
        .contentShape(Rectangle())
    }

    private var foregroundColor: Color {
        return isPressed ? .textPrimary : .white80
    }
}
