import SwiftUI

struct SecondaryButtonView: View {
    let title: String
    let size: CustomButton.Size
    let icon: AnyView?
    let isDisabled: Bool
    let isPressed: Bool
    var isLoading: Bool = false
    let shouldExpand: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon, !isLoading {
                icon
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: textColor))
                    .frame(width: 20, height: 20)
            } else if size == .small {
                CaptionBText(title, textColor: textColor)
            } else {
                BodySSBText(title, textColor: textColor)
            }
        }
        .frame(maxWidth: (size == .large || shouldExpand) ? .infinity : nil)
        .frame(height: size.height)
        .padding(.horizontal, 16)
        .background(isPressed ? Color.white10 : Color.clear)
        .background(BlurView())
        .overlay(RoundedRectangle(cornerRadius: 64).strokeBorder(borderColor, lineWidth: strokeWidth))
        .cornerRadius(64)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        guard !isDisabled else { return .white32 }
        return size == .small ? .white64 : .white80
    }

    private var borderColor: Color {
        guard !isDisabled else { return .clear }
        return size == .small ? .white16 : .gray4
    }

    private var strokeWidth: CGFloat {
        switch size {
        case .small: 1
        case .large: 2
        }
    }
}
