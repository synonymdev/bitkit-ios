import SwiftUI

struct PrimaryButtonView: View {
    let title: String
    let size: CustomButton.Size
    let icon: AnyView?
    let isDisabled: Bool
    let isLoading: Bool
    let isPressed: Bool
    let shouldExpand: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon, !isLoading {
                icon
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .textPrimary))
                    .frame(width: 20, height: 20)
            } else {
                if size == .small {
                    CaptionBText(title, textColor: .textPrimary)
                } else {
                    BodySSBText(title, textColor: .textPrimary)
                }
            }
        }
        .frame(maxWidth: (size == .large || shouldExpand) ? .infinity : nil)
        .frame(height: size.height)
        .padding(.horizontal, 16)
        .background(backgroundGradient)
        .cornerRadius(64)
        .shadow(color: shadowColor, radius: 0, x: 0, y: -1)
        .opacity(isDisabled ? 0.3 : 1.0)
        .contentShape(Rectangle())
    }

    private var backgroundGradient: some View {
        if isLoading {
            return AnyView(Color.gray6)
        }
        if isDisabled {
            return AnyView(Color.gray4)
        }

        return AnyView(ButtonGradient(isPressed: isPressed))
    }

    private var shadowColor: Color {
        if isDisabled {
            return .clear
        }
        return isPressed ? Color.white.opacity(0.4) : Color.white.opacity(0.25)
    }
}
