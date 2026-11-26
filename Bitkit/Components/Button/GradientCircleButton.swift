import SwiftUI

/// A circular button with a gradient background, used for action icons (copy, share, edit, delete).
struct GradientCircleButton: View {
    let icon: String?
    let systemIcon: String?
    let accessibilityLabel: String
    let isLoading: Bool
    let action: () -> Void

    init(icon: String, accessibilityLabel: String, isLoading: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        systemIcon = nil
        self.accessibilityLabel = accessibilityLabel
        self.isLoading = isLoading
        self.action = action
    }

    init(systemIcon: String, accessibilityLabel: String, action: @escaping () -> Void) {
        icon = nil
        self.systemIcon = systemIcon
        self.accessibilityLabel = accessibilityLabel
        isLoading = false
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.gray5, .gray6],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(topInnerHighlight)

                if isLoading {
                    ActivityIndicator(size: 24)
                } else if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
            .frame(width: 48, height: 48)
        }
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Figma's 1px top-only inside stroke: the crescent between the circle and the same circle
    /// shifted down by 1pt, so the edge is 1pt at the top and fades out towards the sides.
    private var topInnerHighlight: some View {
        Circle()
            .subtracting(Circle().offset(x: 0, y: 1))
            .fill(Color.white10)
    }
}
