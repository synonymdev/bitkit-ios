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
                CaptionBText(title, textColor: textColor)
            } else {
                BodySSBText(title, textColor: textColor)
            }
        }
        .frame(maxWidth: size == .large ? .infinity : nil)
        .frame(height: buttonHeight)
        .padding(.horizontal, 16)
        // TODO: Add background blur
        .background(
            RoundedRectangle(cornerRadius: 64)
                .fill(isPressed ? Color.white10 : Color.white01)
                .overlay(
                    RoundedRectangle(cornerRadius: 64)
                        .strokeBorder(borderColor, lineWidth: strokeWidth)
                )
        )
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        return isDisabled ? .white32 : .white80
    }

    private var borderColor: Color {
        return isDisabled ? .clear : Color(hex: 0x3A3A3A)
    }

    private var buttonHeight: CGFloat {
        switch size {
        case .small: return 37
        case .large: return 56
        }
    }

    private var strokeWidth: CGFloat {
        switch size {
        case .small: return 1
        case .large: return 2
        }
    }
}
