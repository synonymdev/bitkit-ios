import SwiftUI

struct SecondaryButtonView: View {
    let title: String
    let size: CustomButton.Size
    let icon: AnyView?
    let isDisabled: Bool
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                icon
            }

            if size == .small {
                CaptionBText(title, textColor: foregroundColor)
            } else {
                BodySSBText(title, textColor: foregroundColor)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .padding(.horizontal, size.horizontalPadding)
        // TODO: Add background blur
        .background(
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .fill(isPressed ? Color.white10 : Color.white01)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .stroke(borderColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }

    private var foregroundColor: Color {
        if isDisabled {
            return .white32
        }
        return .white80
    }

    private var borderColor: Color {
        if isDisabled {
            return .clear
        }
        return Color(hex: 0x3A3A3A)
    }
}
