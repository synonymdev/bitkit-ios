import SwiftUI

/// A circular button with a gradient background, used for action icons (copy, share, edit, delete).
struct GradientCircleButton: View {
    let icon: String?
    let systemIcon: String?
    let iconSize: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    /// `iconSize` compensates for assets exported without the standard icon padding.
    init(icon: String, iconSize: CGFloat = 24, accessibilityLabel: String, action: @escaping () -> Void) {
        self.icon = icon
        systemIcon = nil
        self.iconSize = iconSize
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    init(systemIcon: String, accessibilityLabel: String, action: @escaping () -> Void) {
        icon = nil
        self.systemIcon = systemIcon
        iconSize = 24
        self.accessibilityLabel = accessibilityLabel
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
                    .shadow(color: .white10, radius: 0, x: 0, y: -1)

                if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: iconSize, height: iconSize)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
