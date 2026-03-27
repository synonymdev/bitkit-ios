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
        .background(isPressed ? Color.white10 : Color.clear)
        .background(BlurView())
        .overlay(RoundedRectangle(cornerRadius: 64).strokeBorder(borderColor, lineWidth: strokeWidth))
        .cornerRadius(64)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        isDisabled ? .white32 : .white80
    }

    private var borderColor: Color {
        isDisabled ? .clear : .gray4
    }

    private var buttonHeight: CGFloat {
        switch size {
        case .small: 37
        case .large: 56
        }
    }

    private var strokeWidth: CGFloat {
        switch size {
        case .small: 1
        case .large: 2
        }
    }
}
